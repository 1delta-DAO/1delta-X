#!/usr/bin/env bash
# End-to-end smoke of the ROUTE strategy on an anvil Rootstock fork.
# NOT part of CI (`make test-ts` never runs it): it needs network access to a
# Rootstock RPC and anvil/forge on PATH.
#
#   packages/beta-filler/e2e/fork-e2e.sh            # from anywhere in the repo
#   FORK_URL=https://… PORT=8546 packages/beta-filler/e2e/fork-e2e.sh
#
# What it does, against a fresh fork:
#   1. deploys Permit3 + Settlement + SettlementLens (`make deploy-core`, core-deploy
#      profile) and an operator-gated AggregatorFillSolver with its RouteSandbox
#      (`make deploy-aggregator-fill`, solvers-deploy profile), exactly as the
#      runbook in packages/beta-filler/README.md does on mainnet;
#   2. funds three test makers (RBTC → WRBTC, Permit3 approval) and signs a
#      WRBTC → USDT0 order for each, priced off the live Oku pool:
#        a. DIRECT  — delta-verify, exclusiveFiller = the solver (what the app signs
#                     when VITE_DEPLOYMENTS.solver is set), 97% of the quote
#        b. PULL    — plain pull delivery, exclusiveFiller 0, 97% of the quote
#        c. greedy  — pull, 100% of the quote: must be SKIPPED as unprofitable
#        d. sushi   — pull, 97%, Oku routes off (ROUTE_OKU_PULL=0): the live Sushi API
#                     route (RedSnwapper calldata) runs through the sandbox
#                     (SKIP_SUSHI=1 skips it; it needs api.sushi.com and a fresh fork)
#   3. feeds each order to `beta-filler fill-json` (bypassing the orderbook) in
#      LIVE mode, route strategy only;
#   4. asserts each maker received at least the owed USDT0 (and c. nothing).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$PKG/../.." && pwd)"
FORK_URL="${FORK_URL:-https://public-node.rsk.co}"
PORT="${PORT:-8546}"
RPC="http://127.0.0.1:$PORT"
WORK="$(mktemp -d)"

# anvil's well-known dev keys: #0 deploys, #1 is the filler/operator EOA.
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
OPERATOR_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
OPERATOR=$(cast wallet address "$OPERATOR_KEY")

WRBTC=0x542fDA317318eBF1d3DEAf76E0b632741A7e677d
USDT0=0x779Ded0c9e1022225f8E0630b35a9b54bE713736
WETH=0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590
USDRIF=0x3A15461d8aE0F0Fb5Fa2629e9DA7D66A794a6e37

command -v anvil >/dev/null || { echo "anvil not found — install foundry"; exit 2; }

echo ">> anvil fork of $FORK_URL on :$PORT (work dir $WORK)"
# Rootstock prices gas at ~0.026 gwei with no EIP-1559 base fee; mirror that so the
# filler's gas costing sees realistic numbers.
anvil --fork-url "$FORK_URL" --port "$PORT" --silent \
  --gas-price 26065600 --block-base-fee-per-gas 0 >"$WORK/anvil.log" 2>&1 &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null || true; rm -rf "$WORK"' EXIT
for _ in $(seq 1 60); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
[ "$(cast chain-id --rpc-url "$RPC")" = "30" ] || { echo "fork is not chain 30"; exit 1; }

# Rootstock's block gas limit is 10M and SettlementLens needs ~7.3M: forge's default
# 130% estimate multiplier would exceed the block limit. `--legacy`: Rootstock has
# no EIP-1559 fee market. `--slow`: one tx at a time, each after the last receipt
# (a burst of three large creates can leave the last one unmined in anvil's pool).
DEPLOY_ARGS="--private-key $DEPLOYER_KEY --gas-estimate-multiplier 110 --legacy --slow"

echo ">> 1a. core deploy"
make -s -C "$ROOT" deploy-core RPC="$RPC" DEPLOY_ARGS="$DEPLOY_ARGS" | tee "$WORK/core.log" >/dev/null
grep -q "ONCHAIN EXECUTION COMPLETE & SUCCESSFUL" "$WORK/core.log" || { cat "$WORK/core.log"; echo "core deploy failed"; exit 1; }
addr_of() { awk -v n="$1" '$1==n {getline; print $2; exit}' "$WORK/core.log"; }
PERMIT3=$(addr_of Permit3); SETTLEMENT=$(addr_of Settlement); LENS=$(addr_of SettlementLens)
echo "   Permit3 $PERMIT3  Settlement $SETTLEMENT  Lens $LENS"

echo ">> 1b. AggregatorFillSolver deploy (gated to $OPERATOR, sandboxed routes)"
SETTLEMENT=$SETTLEMENT OPERATORS=$OPERATOR \
  make -s -C "$ROOT" deploy-aggregator-fill RPC="$RPC" DEPLOY_ARGS="$DEPLOY_ARGS" | tee "$WORK/agg.log" >/dev/null
SOLVER=$(awk '$1=="AggregatorFillSolver" && $2 ~ /^0x/ {print $2; exit}' "$WORK/agg.log")
SANDBOX=$(awk '$1=="RouteSandbox" && $2 ~ /^0x/ {print $2; exit}' "$WORK/agg.log")
grep -q "immutables verified" "$WORK/agg.log" || { echo "solver deploy did not verify"; exit 1; }
echo "   AggregatorFillSolver $SOLVER  RouteSandbox $SANDBOX"

export RPC_URL="$RPC" SETTLEMENT PERMIT3 LENS AGGREGATOR_SOLVER="$SOLVER"
balance() { cast call "$1" "balanceOf(address)(uint256)" "$2" --rpc-url "$RPC" | awk '{print $1}'; }

run_case() { # name mode price_pct expect(filled|skipped) maker_key_index [extra filler env...]
  local name=$1 mode=$2 pct=$3 expect=$4 idx=$5
  shift 5
  local key; key=0x$(printf 'b0b%061x' "$idx")
  local maker; maker=$(cast wallet address "$key")
  cast rpc anvil_setBalance "$maker" 0x3635C9ADC5DEA00000 --rpc-url "$RPC" >/dev/null
  echo ">> 2/3. case $name: $mode order at $pct% of the quote"
  local line
  line=$(cd "$PKG" && MAKER_KEY=$key MODE=$mode PRICE_PCT=$pct OUT="$WORK/$name.json" npx tsx e2e/make-order.ts | tail -1)
  echo "   $line"
  local owed; owed=$(sed -E 's/.* owed=([0-9]+).*/\1/' <<<"$line")
  # anvil's eth_gasPrice answers 1 gwei whatever --gas-price says (Rootstock: ~0.026), so
  # lift the filler's MAX_GAS_PRICE_GWEI ceiling (default 0.1) for the fork only.
  (cd "$PKG" && env PRIVATE_KEY=$OPERATOR_KEY ORDERBOOK_URL=http://unused.invalid INVENTORY_ENABLED=0 \
     DRY_RUN=0 STATE_FILE="$WORK/state.json" MAX_GAS_PRICE_GWEI=2 "$@" npx tsx src/bin.ts fill-json "$WORK/$name.json") | tee "$WORK/$name.out"
  local got; got=$(balance "$USDT0" "$maker")
  if [ "$expect" = filled ]; then
    grep -q '"status":"filled"' "$WORK/$name.out" || { echo "FAIL $name: not filled"; exit 1; }
    [ "$(echo "$got >= $owed" | bc)" = 1 ] || { echo "FAIL $name: maker got $got < owed $owed"; exit 1; }
    echo "   OK maker received $got USDT0 units (owed $owed)"
  else
    grep -q '"status":"skipped"' "$WORK/$name.out" || { echo "FAIL $name: expected a skip"; exit 1; }
    [ "$got" = 0 ] || { echo "FAIL $name: maker unexpectedly received $got"; exit 1; }
    echo "   OK skipped, maker untouched"
  fi
}

# The Sushi case runs FIRST: the API quotes live mainnet state, and every fill below
# moves the fork's WRBTC/USDT0 pool away from it (snwap's amountOutMin then fails, and
# the filler falls back to the Oku route — which is what the later pull case sees).
if [ "${SKIP_SUSHI:-0}" != 1 ]; then
  run_case sushi pull 97 filled 4 ROUTE_OKU_PULL=0
  grep -q "✓ \[route\] filled pull .*(sushi, quote" "$WORK/sushi.out" || { echo "FAIL sushi: the fill did not go through the Sushi route"; exit 1; }
fi
run_case direct direct 97 filled 1
run_case pull pull 97 filled 2
run_case greedy pull 100 skipped 3

echo ">> spread collected by the operator (profitRecipient = 0 ⇒ msg.sender):"
echo "   WRBTC $(balance $WRBTC "$OPERATOR")   USDT0 $(balance $USDT0 "$OPERATOR")"
echo ">> solver holds: WRBTC $(balance $WRBTC "$SOLVER")   USDT0 $(balance $USDT0 "$SOLVER")"
echo ">> sandbox holds: WRBTC $(balance $WRBTC "$SANDBOX")   USDT0 $(balance $USDT0 "$SANDBOX")"
[ "$(balance $WRBTC "$SANDBOX")" = 0 ] && [ "$(balance $USDT0 "$SANDBOX")" = 0 ] || { echo "FAIL: the sandbox kept tokens"; exit 1; }
echo "PASS"
