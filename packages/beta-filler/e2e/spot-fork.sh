#!/usr/bin/env bash
# SPOT fork smoke test (LOCAL ONLY, INVENTORY-POLICY §9). On an anvil fork of Rootstock
# mainnet, against the LIVE Settlement / Permit3 / Lens, plus a fresh AggregatorFillSolver
# on the live Settlement (the spot strategy values tickets with the route's pool quoting,
# which needs a solver the anvil operator runs): the operator holds a small WRBTC reserve,
# a maker signs a 20 USD₮0 → WRBTC PULL order, and the REAL filler fills it FROM THE
# RESERVE (inventory strategy, `spot` path) — not through the route.
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
echo ">> fork at $FORK_BLOCK (work dir $WORK)"
cast rpc anvil_setBalance "$OPERATOR" 0xDE0B6B3A7640000 --rpc-url "$RPC" >/dev/null
cast rpc anvil_setBalance 0x0000000000000000000000000000000000000000 0xDE0B6B3A7640000 --rpc-url "$RPC" >/dev/null

echo ">> a fresh AggregatorFillSolver on the live Settlement (operator $OPERATOR)"
SETTLEMENT=$SETTLEMENT OPERATORS=$OPERATOR make -s -C "$ROOT" deploy-aggregator-fill RPC="$RPC" \
  DEPLOY_ARGS="--private-key $DEPLOYER_KEY --gas-estimate-multiplier 110 --legacy --slow" >"$WORK/agg.log" 2>&1 || { tail -20 "$WORK/agg.log"; exit 1; }
SOLVER=$(awk '$1=="AggregatorFillSolver" && $2 ~ /^0x/ {print $2; exit}' "$WORK/agg.log")
echo "   solver $SOLVER"

OP_WRBTC_HOLDER=0xaef6fabf3b0c9e5f9d6d5170afc703a633479bbd
USDT0=0x779Ded0c9e1022225f8E0630b35a9b54bE713736
# The operator's spot reserve: 0.0006 WRBTC (~$50), and USD₮0 above its reserve.
cast rpc anvil_impersonateAccount $OP_WRBTC_HOLDER --rpc-url "$RPC" >/dev/null
cast send $WRBTC "transfer(address,uint256)" "$OPERATOR" 600000000000000 --from $OP_WRBTC_HOLDER --unlocked --rpc-url "$RPC" >/dev/null
cast send $USDT0 "transfer(address,uint256)" "$OPERATOR" 300000000 --from $OP_WRBTC_HOLDER --unlocked --rpc-url "$RPC" >/dev/null
KEY=0x$(printf 'c0de%060x' 31); MAKER=$(cast wallet address "$KEY")
cast rpc anvil_setBalance "$MAKER" 0xDE0B6B3A7640000 --rpc-url "$RPC" >/dev/null
echo ">> maker $MAKER signs 20 USD₮0 → WRBTC (pull) at ${PRICE_PCT:-98} % of the pool quote"
(cd "$PKG" && env RPC_URL=$RPC SETTLEMENT=$SETTLEMENT PERMIT3=$PERMIT3 AGGREGATOR_SOLVER=$SOLVER MAKER_KEY=$KEY MODE=pull \
  TOKEN_IN=USDT0 TOKEN_OUT=WRBTC FUNDING=direct AMOUNT=20 NONCE=256 PRICE_PCT=${PRICE_PCT:-98} OUT="$WORK/spot.json" npx tsx e2e/sim-order.ts | tail -1)
B0=$(cast call $WRBTC 'balanceOf(address)(uint256)' "$MAKER" --rpc-url "$RPC" | awk '{print $1}')
echo ">> the real filler (inventory with SPOT_RESERVES) fills it from the reserve"
(cd "$PKG" && env PRIVATE_KEY=$OPERATOR_KEY RPC_URL=$RPC ORDERBOOK_URL=http://unused.invalid DRY_RUN=0 STATE_FILE="$WORK/state.json" \
  SETTLEMENT=$SETTLEMENT PERMIT3=$PERMIT3 LENS=$LENS AGGREGATOR_SOLVER=$SOLVER ROUTE_PROFIT_RECIPIENT=$SOLVER INVENTORY_ENABLED=1 \
  SPOT_RESERVES="$WRBTC:60:3000,0x3A15461d8aE0F0Fb5Fa2629e9DA7D66A794a6e37:50:500" USDT0_RESERVE=100 \
  RPC_TIMEOUT_MS=300000 MAX_GAS_PRICE_GWEI=2 SUSHI_ENABLED=0 NORDSTERN_ENABLED=0 \
  npx tsx src/bin.ts fill-json "$WORK/spot.json") >"$WORK/fill.out" 2>&1 || true
grep -E "spot|outcome" "$WORK/fill.out" | cut -c1-260 | tail -4
grep -q '"status":"filled"' "$WORK/fill.out" || { echo "!! not filled (see $WORK/fill.out)"; exit 1; }
grep -q '"strategy":"inventory"' "$WORK/fill.out" || { echo "!! filled, but not from the reserve (see $WORK/fill.out)"; exit 1; }
B1=$(cast call $WRBTC 'balanceOf(address)(uint256)' "$MAKER" --rpc-url "$RPC" | awk '{print $1}')
echo "   maker WRBTC +$((B1 - B0)) wei; operator WRBTC $(cast call $WRBTC 'balanceOf(address)(uint256)' $OPERATOR --rpc-url "$RPC" | awk '{print $1}'), USD₮0 $(cast call $USDT0 'balanceOf(address)(uint256)' $OPERATOR --rpc-url "$RPC" | awk '{print $1}')"
echo "OK"
