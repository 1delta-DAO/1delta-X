#!/usr/bin/env bash
# RIF RAIL fork smoke test (LOCAL ONLY). On an anvil fork of Rootstock mainnet, against the
# LIVE beta contracts (Settlement / Lens), with a fresh operator key:
#   1. `beta-filler refill 60`: USDT0 → USDRIF on the 0.05 % pool, then `redeemTP` (queued at MoC);
#   2. a maker signs a USDT0 → RIF PULL order (sim-order.ts) at PRICE_PCT of the RIF pool's quote;
#   3. `beta-filler fill-json` fills it from the RIF float (inventory strategy, route off).
# anvil answers eth_gasPrice with 1 gwei (~40× Rootstock), so the ticket is large (500 USDT0)
# and priced at PRICE_PCT (default 90) of the pool's quote, for the fill to clear its gas.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
PORT="${PORT:-8548}"
RPC="http://127.0.0.1:$PORT"
WORK="${WORK:-$(mktemp -d)}"
OPERATOR_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
OPERATOR=$(cast wallet address "$OPERATOR_KEY")
USDT0=0x779Ded0c9e1022225f8E0630b35a9b54bE713736
USDRIF=0x3A15461d8aE0F0Fb5Fa2629e9DA7D66A794a6e37
RIF=0x2AcC95758f8b5F583470ba265EB685a8F45fC9D5
QUEUE=0x47f5014115d3bb29B20b5168Ee75050D6f8c3Bf1
export SETTLEMENT=0xe6EDbb5c49Fb4CFb313476e3B78E274D3584ddf5 PERMIT3=0xabaefb5ae495Dcbce40d1e057346f31A500668a8 LENS=0xF9e905EdCC376FDaBF62Ca0966624611721C5206 AGGREGATOR_SOLVER=0x48dbdC43507767BD51ec0AF2cb9bfa5E35B332F1

ANVIL_PID=""
trap '[ -n "$ANVIL_PID" ] && kill $ANVIL_PID 2>/dev/null || true' EXIT
for url in ${FORK_URL:-} https://public-node.rsk.co https://rpc-gateway.1delta.io/30 https://mycrypto.rsk.co; do
  FORK_BLOCK="$(cast block-number --rpc-url "$url" 2>/dev/null || true)"
  [ -n "$FORK_BLOCK" ] || continue
  anvil --fork-url "$url" --fork-block-number "$FORK_BLOCK" --port "$PORT" --silent --retries 10 --timeout 120000 \
    --gas-price 26065600 --block-base-fee-per-gas 0 >"$WORK/anvil.log" 2>&1 &
  ANVIL_PID=$!
  for _ in $(seq 1 90); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break 2; sleep 1; done
  kill $ANVIL_PID 2>/dev/null || true; ANVIL_PID=""
done
[ "$(cast chain-id --rpc-url "$RPC" 2>/dev/null)" = 30 ] || { echo "no fork"; exit 1; }
echo ">> fork at $FORK_BLOCK, operator $OPERATOR (work dir $WORK)"

deal() { # token holder to amount
  cast rpc anvil_impersonateAccount "$2" --rpc-url "$RPC" >/dev/null
  cast rpc anvil_setBalance "$2" 0xDE0B6B3A7640000 --rpc-url "$RPC" >/dev/null
  cast send "$1" "transfer(address,uint256)" "$3" "$4" --from "$2" --unlocked --rpc-url "$RPC" >/dev/null
  cast rpc anvil_stopImpersonatingAccount "$2" --rpc-url "$RPC" >/dev/null
}
cast rpc anvil_setBalance "$OPERATOR" 0xDE0B6B3A7640000 --rpc-url "$RPC" >/dev/null
deal $USDT0 0xaef6fabf3b0c9e5f9d6d5170afc703a633479bbd "$OPERATOR" 200000000          # 200 USDT0
deal $RIF 0x57079b2d3071eb06cce6dbafb9b0306bcc49b020 "$OPERATOR" 8000000000000000000000 # 8000 RIF (the float)
# anvil checks the sender's balance on an eth_call with a gas price (the lens previews run from 0x0).
cast rpc anvil_setBalance 0x0000000000000000000000000000000000000000 0xDE0B6B3A7640000 --rpc-url "$RPC" >/dev/null

FILLER_ENV=(PRIVATE_KEY=$OPERATOR_KEY RPC_URL=$RPC ORDERBOOK_URL=http://unused.invalid DRY_RUN=0 STATE_FILE="$WORK/state.json"
  RPC_TIMEOUT_MS=300000 MAX_GAS_PRICE_GWEI=2 ROUTE_ENABLED=0 INVENTORY_ENABLED=1 SELL_RIF=1
  RIF_FLOAT_TARGET=10000 RIF_REFILL_BELOW=1500 USDT0_RESERVE=50 SUSHI_ENABLED=0 NORDSTERN_ENABLED=0)
bal() { cast call "$1" "balanceOf(address)(uint256)" "$OPERATOR" --rpc-url "$RPC" | awk '{print $1}'; }

echo ">> 1. refill 60 USDT0 (swap, then redeemTP)"
ops0=$(cast call $QUEUE "operIdCount()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
(cd "$PKG" && env "${FILLER_ENV[@]}" npx tsx src/bin.ts refill 60) | tee "$WORK/refill.out" | grep -E "rebalance|sent" || true
ops1=$(cast call $QUEUE "operIdCount()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
echo "   USDT0 $(bal $USDT0)  USDRIF $(bal $USDRIF)  RIF $(bal $RIF)  MoC ops $ops0 → $ops1"
[ "$ops1" -gt "$ops0" ] || { echo "!! no MoC redemption queued"; exit 1; }

echo ">> 2. maker signs USDT0 → RIF (pull) for 500 USDT0 at ${PRICE_PCT:-90} % of the RIF pool's quote"
MAKER_KEY=0x$(printf 'c0de%060x' 9)
cast rpc anvil_setBalance "$(cast wallet address $MAKER_KEY)" 0xDE0B6B3A7640000 --rpc-url "$RPC" >/dev/null
(cd "$PKG" && env RPC_URL=$RPC MAKER_KEY=$MAKER_KEY MODE=pull TOKEN_IN=USDT0 TOKEN_OUT=RIF FUNDING=direct AMOUNT=500 NONCE=256 \
  PRICE_PCT=${PRICE_PCT:-90} OUT="$WORK/rail.json" npx tsx e2e/sim-order.ts | tail -1)

echo ">> 3. fill it from the float (operator RBTC $(cast balance $OPERATOR --rpc-url "$RPC"), MoC exec fee $(cast call $QUEUE "getExecFee(uint8)(uint256)" 4 --rpc-url "$RPC"))"
rif0=$(bal $RIF)
(cd "$PKG" && env "${FILLER_ENV[@]}" npx tsx src/bin.ts fill-json "$WORK/rail.json") >"$WORK/fill.out" 2>&1 || true
grep -E "inventory|outcome" "$WORK/fill.out" | tail -5
grep -q '"status":"filled"' "$WORK/fill.out" || { echo "!! not filled (see $WORK/fill.out)"; exit 1; }
echo "   RIF float $rif0 → $(bal $RIF), USDT0 $(bal $USDT0)"
echo "OK"
