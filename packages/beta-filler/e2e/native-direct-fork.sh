#!/usr/bin/env bash
# NATIVE-DIRECT fork e2e (LOCAL ONLY, task 30): the intended raw-RBTC flow, end to end, with
# the REAL filler. On an anvil fork of Rootstock mainnet, against the LIVE Settlement /
# Permit3 / Lens:
#
#   1. deploy `NativeBalance` and a solver v3 (`AggregatorFillSolver` with NATIVE_BALANCE /
#      WNATIVE) exactly as `make deploy-aggregator-fill` will on mainnet;
#   2. BASELINE: makers sign the app's DIRECT market order, USD₮0 → WRBTC, and the real
#      filler (route strategy, `fill-json`) fills it;
#   3. NATIVE: a second maker signs the same order with leg 0 naming the `NativeBalance`
#      view (the app's `nativeOut: { nativeBalance }` shape), and the same filler fills it.
#
# Asserts: both filled; the native maker's RBTC balance rose by at least the signed amount
# and its WRBTC did not move; the solver ends holding no RBTC and at most its 1-wei floors
# (zero capital); and the native fill's RECEIPT gas (what the filler pays, refunds applied,
# 21k base and calldata included) is within MAX_DELTA (default 35,000) of the baseline's.
#
# The fork's blocks carry no `minimumGasPrice` and anvil runs with a zero base fee, so the
# filler prices gas at 0 here; MIN_PROFIT_RBTC gives the direct plan the margin it keeps as
# input residue (a zero margin makes the plan's input ceiling equal the input, which the
# filler refuses). Neither changes the gas the fill uses.
#
#   packages/beta-filler/e2e/native-direct-fork.sh            # FORK_URL optional
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$PKG/../.." && pwd)"
PORT="${PORT:-8552}"
RPC="http://127.0.0.1:$PORT"
WORK="${WORK:-$(mktemp -d)}"
MAX_DELTA="${MAX_DELTA:-35000}"
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
OPERATOR_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
OPERATOR=$(cast wallet address "$OPERATOR_KEY")
WRBTC=0x542fDA317318eBF1d3DEAf76E0b632741A7e677d
USDT0=0x779Ded0c9e1022225f8E0630b35a9b54bE713736
export SETTLEMENT=0xe6EDbb5c49Fb4CFb313476e3B78E274D3584ddf5 PERMIT3=0xabaefb5ae495Dcbce40d1e057346f31A500668a8 LENS=0xF9e905EdCC376FDaBF62Ca0966624611721C5206

ANVIL_PID=""
trap '[ -n "$ANVIL_PID" ] && kill $ANVIL_PID 2>/dev/null || true' EXIT
for url in ${FORK_URL:-} https://public-node.rsk.co https://rpc-gateway.1delta.io/30 https://mycrypto.rsk.co; do
  FORK_BLOCK="$(cast block-number --rpc-url "$url" 2>/dev/null || true)"
  [ -n "$FORK_BLOCK" ] || continue
  anvil --fork-url "$url" --fork-block-number "$FORK_BLOCK" --port "$PORT" --silent --retries 10 --timeout 120000 \
    --gas-price 26065600 --block-base-fee-per-gas 0 --disable-min-priority-fee >"$WORK/anvil.log" 2>&1 &
  ANVIL_PID=$!
  for _ in $(seq 1 90); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break 2; sleep 1; done
  kill $ANVIL_PID 2>/dev/null || true; ANVIL_PID=""
done
[ "$(cast chain-id --rpc-url "$RPC" 2>/dev/null)" = 30 ] || { echo "no fork"; exit 1; }
echo ">> fork at $FORK_BLOCK (work dir $WORK)"
cast rpc anvil_setBalance "$OPERATOR" 0xDE0B6B3A7640000 --rpc-url "$RPC" >/dev/null
cast rpc anvil_setBalance "$(cast wallet address "$DEPLOYER_KEY")" 0xDE0B6B3A7640000 --rpc-url "$RPC" >/dev/null

echo ">> 1. NativeBalance + solver v3 (operator $OPERATOR)"
NB=$(cd "$ROOT" && FOUNDRY_PROFILE=periphery-deploy forge create packages/periphery/src/NativeBalance.sol:NativeBalance \
  --private-key "$DEPLOYER_KEY" --rpc-url "$RPC" --legacy --broadcast 2>"$WORK/nb.err" | awk '/Deployed to/{print $3}')
[ -n "$NB" ] || { cat "$WORK/nb.err"; exit 1; }
SETTLEMENT=$SETTLEMENT OPERATORS=$OPERATOR NATIVE_BALANCE=$NB make -s -C "$ROOT" deploy-aggregator-fill RPC="$RPC" \
  DEPLOY_ARGS="--private-key $DEPLOYER_KEY --gas-estimate-multiplier 110 --legacy --slow" >"$WORK/agg.log" 2>&1 || { tail -20 "$WORK/agg.log"; exit 1; }
grep -q "immutables verified" "$WORK/agg.log" || { tail -20 "$WORK/agg.log"; echo "solver deploy did not verify"; exit 1; }
SOLVER=$(awk '$1=="AggregatorFillSolver" && $2 ~ /^0x/ {print $2; exit}' "$WORK/agg.log")
echo "   NativeBalance $NB  solver $SOLVER"

balance() { cast call "$1" 'balanceOf(address)(uint256)' "$2" --rpc-url "$RPC" | awk '{print $1}'; }

# fill_case <name> <maker-key-index> <seed-wrbtc-wei> [extra sim-order env...]: sign, fill
# with the real filler, check the maker's WRBTC delta ≥ owed, print the fill's receipt gas.
WRBTC_HOLDER=0xaeF6fABf3b0C9e5F9d6D5170AfC703A633479Bbd # the live WRBTC/USD₮0 pool
fill_case() {
  local name=$1 idx=$2 seed=$3
  shift 3
  local key; key=0x$(printf 'c0de%060x' "$idx")
  local maker; maker=$(cast wallet address "$key")
  cast rpc anvil_setBalance "$maker" 0xDE0B6B3A7640000 --rpc-url "$RPC" >/dev/null
  if [ "$seed" != 0 ]; then
    cast rpc anvil_impersonateAccount $WRBTC_HOLDER --rpc-url "$RPC" >/dev/null
    cast rpc anvil_setBalance $WRBTC_HOLDER 0xDE0B6B3A7640000 --rpc-url "$RPC" >/dev/null
    cast send $WRBTC 'transfer(address,uint256)' "$maker" "$seed" --from $WRBTC_HOLDER --unlocked --legacy --rpc-url "$RPC" >/dev/null
    cast rpc anvil_stopImpersonatingAccount $WRBTC_HOLDER --rpc-url "$RPC" >/dev/null
  fi
  local line
  line=$(cd "$PKG" && env RPC_URL=$RPC AGGREGATOR_SOLVER=$SOLVER MAKER_KEY=$key MODE=direct TOKEN_IN=USDT0 TOKEN_OUT=WRBTC \
    FUNDING=direct AMOUNT=${AMOUNT:-50} NONCE=256 PRICE_PCT=${PRICE_PCT:-97} OUT="$WORK/$name.json" "$@" npx tsx e2e/sim-order.ts | tail -1)
  local owed; owed=$(sed -E 's/.* owed=([0-9]+).*/\1/' <<<"$line")
  local w0; w0=$(balance $WRBTC "$maker")
  (cd "$PKG" && env PRIVATE_KEY=$OPERATOR_KEY RPC_URL=$RPC ORDERBOOK_URL=http://unused.invalid DRY_RUN=0 STATE_FILE="$WORK/state.json" \
    SETTLEMENT=$SETTLEMENT PERMIT3=$PERMIT3 LENS=$LENS AGGREGATOR_SOLVER=$SOLVER ROUTE_PROFIT_RECIPIENT=$SOLVER INVENTORY_ENABLED=0 \
    NATIVE_BALANCE=$NB MIN_PROFIT_RBTC=${MIN_PROFIT_RBTC:-0.000001} RPC_TIMEOUT_MS=300000 MAX_GAS_PRICE_GWEI=2 SUSHI_ENABLED=0 NORDSTERN_ENABLED=0 \
    npx tsx src/bin.ts fill-json "$WORK/$name.json") >"$WORK/$name.out" 2>&1 || true
  grep -q '"status":"filled"' "$WORK/$name.out" || { grep -E "outcome|reason|error" "$WORK/$name.out" | tail -5 >&2; echo "FAIL $name: not filled (see $WORK/$name.out)" >&2; exit 1; }
  local got; got=$(echo "$(balance $WRBTC "$maker") - $w0" | bc)
  [ "$(echo "$got >= $owed" | bc)" = 1 ] || { echo "FAIL $name: maker got $got WRBTC < owed $owed" >&2; exit 1; }
  local tx; tx=$(grep -oE '"tx":"0x[0-9a-fA-F]{64}"' "$WORK/$name.out" | tail -1 | cut -d'"' -f4)
  local gas; gas=$(cast receipt "$tx" gasUsed --rpc-url "$RPC")
  echo "   OK $name: maker received $got WRBTC (owed $owed) · fill gas $gas" >&2
  echo "$gas"
}

# Order matters for gas: the solver's first fill of a token seeds its 1-wei floor (a cold
# zero → non-zero SSTORE), and a maker holding no WRBTC pays one too. So: a warm-up fill
# first (not measured), then the baseline twice — maker with no WRBTC, and maker already
# holding some — and the native fill, whose maker never holds WRBTC at all.
echo ">> 2. baseline: DIRECT USD₮0 → WRBTC"
fill_case warmup 1 0 >/dev/null
GAS_W0=$(fill_case wrapped_fresh 3 0)
GAS_W=$(fill_case wrapped_holder 4 1000)

echo ">> 3. native: DIRECT USD₮0 → RBTC through NativeBalance"
KEY_N=0x$(printf 'c0de%060x' 2); MAKER_N=$(cast wallet address "$KEY_N")
cast rpc anvil_setBalance "$MAKER_N" 0xDE0B6B3A7640000 --rpc-url "$RPC" >/dev/null
# The maker's own setup txs (funding, approve) are sent before the fill: snapshot after them.
(cd "$PKG" && env RPC_URL=$RPC AGGREGATOR_SOLVER=$SOLVER MAKER_KEY=$KEY_N MODE=direct TOKEN_IN=USDT0 TOKEN_OUT=WRBTC \
  FUNDING=direct AMOUNT=${AMOUNT:-50} NONCE=256 PRICE_PCT=${PRICE_PCT:-97} NATIVE_BALANCE=$NB OUT="$WORK/native.json" \
  npx tsx e2e/sim-order.ts | tail -1) >"$WORK/native.order"
echo "   native: $(cat "$WORK/native.order")"
OWED_N=$(sed -E 's/.* owed=([0-9]+).*/\1/' "$WORK/native.order")
RBTC0=$(cast balance "$MAKER_N" --rpc-url "$RPC")
(cd "$PKG" && env PRIVATE_KEY=$OPERATOR_KEY RPC_URL=$RPC ORDERBOOK_URL=http://unused.invalid DRY_RUN=0 STATE_FILE="$WORK/state.json" \
  SETTLEMENT=$SETTLEMENT PERMIT3=$PERMIT3 LENS=$LENS AGGREGATOR_SOLVER=$SOLVER ROUTE_PROFIT_RECIPIENT=$SOLVER INVENTORY_ENABLED=0 \
  NATIVE_BALANCE=$NB MIN_PROFIT_RBTC=${MIN_PROFIT_RBTC:-0.000001} RPC_TIMEOUT_MS=300000 MAX_GAS_PRICE_GWEI=2 SUSHI_ENABLED=0 NORDSTERN_ENABLED=0 \
  npx tsx src/bin.ts fill-json "$WORK/native.json") >"$WORK/native.out" 2>&1 || true
grep -q '"status":"filled"' "$WORK/native.out" || { grep -E "outcome|reason|error" "$WORK/native.out" | tail -5; echo "FAIL native: not filled (see $WORK/native.out)"; exit 1; }
TX_N=$(grep -oE '"tx":"0x[0-9a-fA-F]{64}"' "$WORK/native.out" | tail -1 | cut -d'"' -f4)
GAS_N=$(cast receipt "$TX_N" gasUsed --rpc-url "$RPC")
RBTC1=$(cast balance "$MAKER_N" --rpc-url "$RPC")
GOT_N=$(echo "$RBTC1 - $RBTC0" | bc)
[ "$(echo "$GOT_N >= $OWED_N" | bc)" = 1 ] || { echo "FAIL native: maker got $GOT_N wei RBTC < owed $OWED_N"; exit 1; }
[ "$(balance $WRBTC "$MAKER_N")" = 0 ] || { echo "FAIL native: the maker received WRBTC"; exit 1; }
[ "$(cast balance "$SOLVER" --rpc-url "$RPC")" = 0 ] || { echo "FAIL native: the solver kept RBTC"; exit 1; }
[ "$(balance $WRBTC "$SOLVER")" -le 1 ] || { echo "FAIL native: the solver kept WRBTC beyond its floor"; exit 1; }
[ "$(balance $USDT0 "$SOLVER")" -ge 0 ] # the USD₮0 spread is retained by design (retain mode)
echo "   OK maker received $GOT_N wei RBTC (owed $OWED_N), no WRBTC · fill gas $GAS_N"

DELTA=$((GAS_N - GAS_W))
echo ">> receipt gas (what the filler pays): WRBTC to a maker holding none $GAS_W0 · WRBTC to a maker holding some $GAS_W · RBTC via NativeBalance $GAS_N"
echo "   native − wrapped(holder) = $DELTA (limit $MAX_DELTA) · native − wrapped(fresh) = $((GAS_N - GAS_W0))"
[ "$DELTA" -le "$MAX_DELTA" ] || { echo "FAIL: native overhead $DELTA > $MAX_DELTA"; exit 1; }
echo "OK"
