#!/usr/bin/env bash
# NATIVE-OUT fork smoke test (LOCAL ONLY, task 28). On an anvil fork of Rootstock mainnet:
# the LIVE Settlement / Permit3 / Lens and the LIVE NativeUnwrapModule (0xB6107a1D…C735),
# plus a fresh AggregatorFillSolver deployed against the live Settlement with an anvil
# operator (the live solver's operator key is a Worker secret). A maker signs the app's
# native-out shape — USD₮0 in, WRBTC leg to the module + its MAKE item, pull — and the REAL
# filler (route strategy, `fill-json`) is run on it.
#
# RESULT (2026-10-14): the route REFUSES it, by design. The solver's `executeFill` drives
# `PostInputs`, which is item-free (it reverted `ReverseModeRequiresNoItems` before the
# refusal was added), and `executeItemFill` goes through `matchSettle`, which refuses a
# pre-funded MAKE item. This script pins that refusal. That a holder of WRBTC fills the
# shape through a plain `fill` against the live Settlement + module is proven by
# packages/modules/transfer/test/fork/NativeUnwrapRootstock.fork.t.sol.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$PKG/../.." && pwd)"
PORT="${PORT:-8551}"
RPC="http://127.0.0.1:$PORT"
WORK="${WORK:-$(mktemp -d)}"
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
OPERATOR_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
OPERATOR=$(cast wallet address "$OPERATOR_KEY")
MODULE=0xB6107a1DEa7Ae04129aBc27ce607249049f3C735
WRBTC=0x542fDA317318eBF1d3DEAf76E0b632741A7e677d
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
[ "$(cast codesize $MODULE --rpc-url "$RPC")" -gt 0 ] || { echo "no NativeUnwrapModule at $MODULE"; exit 1; }
echo ">> fork at $FORK_BLOCK (work dir $WORK)"
cast rpc anvil_setBalance "$OPERATOR" 0xDE0B6B3A7640000 --rpc-url "$RPC" >/dev/null
cast rpc anvil_setBalance 0x0000000000000000000000000000000000000000 0xDE0B6B3A7640000 --rpc-url "$RPC" >/dev/null

echo ">> a fresh AggregatorFillSolver on the live Settlement (operator $OPERATOR)"
SETTLEMENT=$SETTLEMENT OPERATORS=$OPERATOR make -s -C "$ROOT" deploy-aggregator-fill RPC="$RPC" \
  DEPLOY_ARGS="--private-key $DEPLOYER_KEY --gas-estimate-multiplier 110 --legacy --slow" >"$WORK/agg.log" 2>&1 || { tail -20 "$WORK/agg.log"; exit 1; }
SOLVER=$(awk '$1=="AggregatorFillSolver" && $2 ~ /^0x/ {print $2; exit}' "$WORK/agg.log")
echo "   solver $SOLVER"

KEY=0x$(printf 'c0de%060x' 21); MAKER=$(cast wallet address "$KEY")
cast rpc anvil_setBalance "$MAKER" 0xDE0B6B3A7640000 --rpc-url "$RPC" >/dev/null
echo ">> maker $MAKER signs 50 USD₮0 → raw RBTC (native-out, pull) at ${PRICE_PCT:-97} % of the pool quote"
(cd "$PKG" && env RPC_URL=$RPC SETTLEMENT=$SETTLEMENT PERMIT3=$PERMIT3 AGGREGATOR_SOLVER=$SOLVER MAKER_KEY=$KEY MODE=pull NATIVE_OUT=1 \
  TOKEN_IN=USDT0 TOKEN_OUT=WRBTC FUNDING=direct AMOUNT=50 NONCE=256 PRICE_PCT=${PRICE_PCT:-97} OUT="$WORK/native.json" npx tsx e2e/sim-order.ts | tail -1)
OWED=$(python3 -c "import json; print(json.load(open('$WORK/native.json'))['order']['legsOut'][0]['start'])")
B0=$(cast balance "$MAKER" --rpc-url "$RPC")

echo ">> the real filler fills it (route strategy)"
(cd "$PKG" && env PRIVATE_KEY=$OPERATOR_KEY RPC_URL=$RPC ORDERBOOK_URL=http://unused.invalid DRY_RUN=0 STATE_FILE="$WORK/state.json" \
  SETTLEMENT=$SETTLEMENT PERMIT3=$PERMIT3 LENS=$LENS AGGREGATOR_SOLVER=$SOLVER ROUTE_PROFIT_RECIPIENT=$SOLVER INVENTORY_ENABLED=0 \
  RPC_TIMEOUT_MS=300000 MAX_GAS_PRICE_GWEI=2 SUSHI_ENABLED=0 NORDSTERN_ENABLED=0 ROUTE_OKU_PULL=1 \
  npx tsx src/bin.ts fill-json "$WORK/native.json") >"$WORK/fill.out" 2>&1 || true
grep -E "outcome" "$WORK/fill.out" | cut -c1-260 | tail -1
grep -q 'pre-funded MAKE' "$WORK/fill.out" || { echo "!! expected the route to refuse the native-out shape (see $WORK/fill.out)"; exit 1; }
echo "OK (refused as expected: the route cannot fill native-out; inventory only)"
