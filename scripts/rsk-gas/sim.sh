#!/usr/bin/env bash
# Rootstock fill-gas SIMULATION (local only). It runs real fills on an anvil fork and
# re-prices each one to Rootstock's gas schedule (reprice.py).
#
#   scripts/rsk-gas/sim.sh            # all cases, table at the end
#
# 1. anvil forks Rootstock mainnet and deploys core + AggregatorFillSolver with the
#    repo's deploy targets (the same steps as packages/beta-filler/e2e/fork-e2e.sh;
#    operator = anvil key #1).
# 2. Each case signs an app-shaped market order (e2e/sim-order.ts: fill-once on a packed
#    nonce; funding direct / Permit3 / ERC-2612). The REAL filler fills it
#    (`beta-filler fill-json`, retain mode, pool plans).
# 3. `cast run --trace-printer` replays the fill on revm, which charges the Cancun
#    schedule. reprice.py converts that trace to Rootstock's schedule. It reproduced
#    every live beta fill receipt to the gas unit (236,601 / 258,692 / 281,345 /
#    409,065, 2026-10-12).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PKG="$ROOT/packages/beta-filler"
FORK_URL="${FORK_URL:-https://public-node.rsk.co}"
PORT="${PORT:-8547}"
RPC="http://127.0.0.1:$PORT"
WORK="${WORK:-$(mktemp -d)}"
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
OPERATOR_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
OPERATOR=$(cast wallet address "$OPERATOR_KEY")

# The public Rootstock RPCs time out now and then: retry anvil's start on each URL.
ANVIL_PID=""
trap '[ -n "$ANVIL_PID" ] && kill $ANVIL_PID 2>/dev/null || true' EXIT
for url in $FORK_URL https://public-node.rsk.co https://rpc-gateway.1delta.io/30 https://mycrypto.rsk.co; do
  for attempt in 1 2; do
    # A PINNED block lets anvil keep its fork cache (~/.foundry/cache/rpc) across runs.
    FORK_BLOCK="${FORK_BLOCK:-$(cast block-number --rpc-url "$url" 2>/dev/null || true)}"
    [ -n "$FORK_BLOCK" ] || continue
    anvil --fork-url "$url" --fork-block-number "$FORK_BLOCK" --port "$PORT" --silent --retries 10 --timeout 120000 \
      --gas-price 26065600 --block-base-fee-per-gas 0 >"$WORK/anvil.log" 2>&1 &
    ANVIL_PID=$!
    for _ in $(seq 1 90); do
      cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break 3
      kill -0 $ANVIL_PID 2>/dev/null || break
      sleep 1
    done
    kill $ANVIL_PID 2>/dev/null || true
    echo "   anvil on $url failed (attempt $attempt): $(tail -1 "$WORK/anvil.log")"
  done
done
[ "$(cast chain-id --rpc-url "$RPC" 2>/dev/null)" = 30 ] || { echo "no fork"; exit 1; }
DEPLOY_ARGS="--private-key $DEPLOYER_KEY --gas-estimate-multiplier 110 --legacy --slow"
echo ">> deploy core + solver on the fork (work dir $WORK)"
make -s -C "$ROOT" deploy-core RPC="$RPC" DEPLOY_ARGS="$DEPLOY_ARGS" >"$WORK/core.log" 2>&1 || { tail -20 "$WORK/core.log"; exit 1; }
addr_of() { awk -v n="$1" '$1==n {getline; print $2; exit}' "$WORK/core.log"; }
PERMIT3=$(addr_of Permit3); SETTLEMENT=$(addr_of Settlement); LENS=$(addr_of SettlementLens)
SETTLEMENT=$SETTLEMENT OPERATORS=$OPERATOR make -s -C "$ROOT" deploy-aggregator-fill RPC="$RPC" DEPLOY_ARGS="$DEPLOY_ARGS" >"$WORK/agg.log" 2>&1 || { tail -20 "$WORK/agg.log"; exit 1; }
SOLVER=$(awk '$1=="AggregatorFillSolver" && $2 ~ /^0x/ {print $2; exit}' "$WORK/agg.log")
echo "   Settlement $SETTLEMENT  Permit3 $PERMIT3  solver $SOLVER"
export RPC_URL="$RPC" SETTLEMENT PERMIT3 LENS AGGREGATOR_SOLVER="$SOLVER"

RESULTS="$WORK/results.tsv"
: >"$RESULTS"
# case <label> <maker idx> <nonce> <fund 0|1> KEY=VAL… (sim-order env)
run() {
  local label=$1 idx=$2 nonce=$3 fund=$4
  shift 4
  local key; key=0x$(printf 'c0de%060x' "$idx")
  local maker; maker=$(cast wallet address "$key")
  cast rpc anvil_setBalance "$maker" 0x3635C9ADC5DEA00000 --rpc-url "$RPC" >/dev/null
  (cd "$PKG" && env MAKER_KEY=$key NONCE=$nonce FUND=$fund OUT="$WORK/$label.json" "$@" npx tsx e2e/sim-order.ts | tail -1) >"$WORK/$label.order"
  (cd "$PKG" && env PRIVATE_KEY=$OPERATOR_KEY ORDERBOOK_URL=http://unused.invalid INVENTORY_ENABLED=0 DRY_RUN=0 \
     STATE_FILE="$WORK/state.json" RPC_TIMEOUT_MS=300000 MAX_GAS_PRICE_GWEI=2 HOURLY_GAS_RBTC=100 SUSHI_ENABLED=0 NORDSTERN_ENABLED=0 ROUTE_OKU_PULL=1 \
     ROUTE_PROFIT_RECIPIENT="$SOLVER" npx tsx src/bin.ts fill-json "$WORK/$label.json") >"$WORK/$label.out" 2>&1 || true
  local tx; tx=$(grep -o '"tx":"0x[0-9a-f]*"' "$WORK/$label.out" | tail -1 | cut -d'"' -f4 || true)
  if [ -z "$tx" ] || ! grep -q '"status":"filled"' "$WORK/$label.out"; then
    echo "!! $label: not filled — $(grep -o '"reason":"[^"]*"' "$WORK/$label.out" | tail -1 | cut -c1-200 || true)"; return 0
  fi
  cast run "$tx" -r "$RPC" --trace-printer >"$WORK/$label.trace" 2>&1
  local used; used=$(grep -o "Gas used: [0-9]*" "$WORK/$label.trace" | grep -o "[0-9]*")
  python3 "$HERE/reprice.py" "$WORK/$label.trace" --tx "$tx" --rpc "$RPC" --gas-used "$used" >"$WORK/$label.json.gas"
  python3 - "$label" "$WORK/$label.json.gas" >>"$RESULTS" <<'PY'
import json, sys
d = json.load(open(sys.argv[2]))
print("\t".join([sys.argv[1], str(d["rsk_gas_used_sim"]), str(d["cancun_gas_used"]), json.dumps(d["sstores"])]))
PY
  echo "   $label: $(tail -1 "$RESULTS" | cut -f2) RSK gas"
}

# anvil prices gas at 1 gwei (~40x Rootstock): tickets large enough that the fill clears it.
S="AMOUNT=0.01"
echo ">> cases"
run warmup-solver          1 256 1 MODE=direct TOKEN_IN=WRBTC TOKEN_OUT=USDT0 FUNDING=direct $S
run direct-first-maker     2 256 1 MODE=direct TOKEN_IN=WRBTC TOKEN_OUT=USDT0 FUNDING=direct $S
run direct-repeat          2 257 1 MODE=direct TOKEN_IN=WRBTC TOKEN_OUT=USDT0 FUNDING=direct $S
run direct-repeat-permit3  2 258 1 MODE=direct TOKEN_IN=WRBTC TOKEN_OUT=USDT0 FUNDING=permit3 $S
run pull-repeat            2 259 1 MODE=pull   TOKEN_IN=WRBTC TOKEN_OUT=USDT0 FUNDING=direct $S
run direct-2hop-first-out  2 260 1 MODE=direct TOKEN_IN=WRBTC TOKEN_OUT=USDRIF FUNDING=direct $S
run direct-2hop-repeat     2 261 1 MODE=direct TOKEN_IN=WRBTC TOKEN_OUT=USDRIF FUNDING=direct $S
run gasless-first-maker    3 256 1 MODE=direct TOKEN_IN=USDT0 TOKEN_OUT=WRBTC FUNDING=permit2612 AMOUNT=800
run gasless-repeat         3 257 1 MODE=direct TOKEN_IN=USDT0 TOKEN_OUT=WRBTC FUNDING=permit2612 AMOUNT=800
run usdt0-direct-repeat    3 258 1 MODE=direct TOKEN_IN=USDT0 TOKEN_OUT=WRBTC FUNDING=direct AMOUNT=800
run usdrif-pull-first      4 256 1 MODE=pull   TOKEN_IN=USDRIF TOKEN_OUT=USDT0 FUNDING=direct AMOUNT=800
run usdrif-pull-repeat     4 257 1 MODE=pull   TOKEN_IN=USDRIF TOKEN_OUT=USDT0 FUNDING=direct AMOUNT=800

echo
echo "case                     rsk_gas  cancun   sstores"
awk -F'\t' '{printf "%-24s %7s  %7s  %s\n", $1, $2, $3, $4}' "$RESULTS"
echo "(work dir: $WORK)"
