#!/usr/bin/env bash
# RIF RAIL fork smoke test (LOCAL ONLY). On an anvil fork of Rootstock mainnet, against the
# LIVE beta contracts (Settlement / Lens), with a fresh operator key:
#   1. the band below 15 %: `rebalance-rif` swaps USDT0 → USDRIF and queues `redeemTP`;
#   2. the band above 25 %: `rebalance-rif` queues `mintTP` for the excess RIF;
#   3. SELL_RIF: a maker's USDT0 → RIF pull order, filled from the wallet's RIF;
#   4. SELL_RIF: a maker's USDRIF → RIF pull order (replaced by one redeemTP of the USDRIF);
#   5. BUY_RIF:  a maker's RIF → USDT0 pull order, bought with the wallet's USDT0.
# MoC's queue never executes on a fork, so each MoC step gets a fresh filler state file. MoC's
# price is valid only ~20 blocks past the fork (then `MissingProviderPrice`; mainnet refreshes it
# every few blocks), and every sequential tx is a block: the band steps (1–2) and the fills (3–5)
# each run on a fresh fork of the latest block (`anvil_reset`).
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
RIF_HOLDER=0x57079b2d3071eb06cce6dbafb9b0306bcc49b020   # the RIF/USD₮0 pool
USDT0_HOLDER=0xaef6fabf3b0c9e5f9d6d5170afc703a633479bbd # the WRBTC/USD₮0 pool
export SETTLEMENT=0xe6EDbb5c49Fb4CFb313476e3B78E274D3584ddf5 PERMIT3=0xabaefb5ae495Dcbce40d1e057346f31A500668a8 LENS=0xF9e905EdCC376FDaBF62Ca0966624611721C5206 AGGREGATOR_SOLVER=0x48dbdC43507767BD51ec0AF2cb9bfa5E35B332F1

ANVIL_PID=""
trap '[ -n "$ANVIL_PID" ] && kill $ANVIL_PID 2>/dev/null || true' EXIT
for url in ${FORK_URL:-} https://public-node.rsk.co https://rpc-gateway.1delta.io/30 https://mycrypto.rsk.co; do
  FORK_BLOCK="$(cast block-number --rpc-url "$url" 2>/dev/null || true)"
  [ -n "$FORK_BLOCK" ] || continue
  # Rootstock's gas price, no 1 gwei priority-fee floor (eth_gasPrice would answer 1 gwei).
  anvil --fork-url "$url" --fork-block-number "$FORK_BLOCK" --port "$PORT" --silent --retries 10 --timeout 120000 \
    --gas-price 26065600 --block-base-fee-per-gas 0 --disable-min-priority-fee >"$WORK/anvil.log" 2>&1 &
  ANVIL_PID=$!
  FORK_FROM=$url
  for _ in $(seq 1 90); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break 2; sleep 1; done
  kill $ANVIL_PID 2>/dev/null || true; ANVIL_PID=""
done
[ "$(cast chain-id --rpc-url "$RPC" 2>/dev/null)" = 30 ] || { echo "no fork"; exit 1; }
echo ">> fork at $FORK_BLOCK, operator $OPERATOR (work dir $WORK), gas price $(cast gas-price --rpc-url "$RPC")"

deal() { # token holder to amount
  cast rpc anvil_impersonateAccount "$2" --rpc-url "$RPC" >/dev/null
  cast rpc anvil_setBalance "$2" 0xDE0B6B3A7640000 --rpc-url "$RPC" >/dev/null
  cast send "$1" "transfer(address,uint256)" "$3" "$4" --from "$2" --unlocked --rpc-url "$RPC" >/dev/null
  cast rpc anvil_stopImpersonatingAccount "$2" --rpc-url "$RPC" >/dev/null
}
bal() { cast call "$1" "balanceOf(address)(uint256)" "$OPERATOR" --rpc-url "$RPC" | awk '{print $1}'; }
ops() { cast call $QUEUE "operIdCount()(uint256)" --rpc-url "$RPC" | awk '{print $1}'; }
show() { echo "   wallet: USDT0 $(bal $USDT0)  USDRIF $(bal $USDRIF)  RIF $(bal $RIF)"; }
setup() {
  cast rpc anvil_setBalance "$OPERATOR" 0xDE0B6B3A7640000 --rpc-url "$RPC" >/dev/null
  # anvil checks the sender's balance on an eth_call with a gas price (the lens previews run from 0x0).
  cast rpc anvil_setBalance 0x0000000000000000000000000000000000000000 0xDE0B6B3A7640000 --rpc-url "$RPC" >/dev/null
}
setup
deal $USDT0 $USDT0_HOLDER "$OPERATOR" 400000000 # 400 USDT0, no RIF

filler() { # state-file label, args…
  local st=$1; shift
  (cd "$PKG" && env PRIVATE_KEY=$OPERATOR_KEY RPC_URL=$RPC ORDERBOOK_URL=http://unused.invalid DRY_RUN=0 STATE_FILE="$WORK/$st.json" \
    RPC_TIMEOUT_MS=300000 MAX_GAS_PRICE_GWEI=2 ROUTE_ENABLED=0 INVENTORY_ENABLED=1 SELL_RIF=1 BUY_RIF=1 USDT0_RESERVE=50 \
    SUSHI_ENABLED=0 NORDSTERN_ENABLED=0 npx tsx src/bin.ts "$@")
}
order() { # label maker-idx tokenIn tokenOut amount
  local key; key=0x$(printf 'c0de%060x' "$2")
  cast rpc anvil_setBalance "$(cast wallet address "$key")" 0xDE0B6B3A7640000 --rpc-url "$RPC" >/dev/null
  (cd "$PKG" && env RPC_URL=$RPC MAKER_KEY=$key MODE=pull TOKEN_IN=$3 TOKEN_OUT=$4 FUNDING=direct AMOUNT=$5 NONCE=256 \
    PRICE_PCT=${PRICE_PCT:-97} OUT="$WORK/$1.json" npx tsx e2e/sim-order.ts | tail -1)
  filler "$1" fill-json "$WORK/$1.json" >"$WORK/$1.out" 2>&1 || true
  grep -E "→ \[inventory\]|outcome" "$WORK/$1.out" | cut -c1-260 | tail -2
  grep -q '"status":"filled"' "$WORK/$1.out" || { echo "!! $1 not filled (see $WORK/$1.out)"; exit 1; }
}

echo ">> 1. RIF at 0 % of the wallet: rebalance-rif → swap + redeemTP"
o0=$(ops); filler band-low rebalance-rif 2>&1 | tee "$WORK/band-low.out" | grep -E "sent|held" | grep -v approval | cut -c1-220 || true
[ "$(ops)" -gt "$o0" ] || { echo "!! no MoC redemption queued"; exit 1; }; show

echo ">> 2. RIF well above 25 % (dealt 3000): rebalance-rif → mintTP of the excess"
deal $RIF $RIF_HOLDER "$OPERATOR" 3000000000000000000000
o1=$(ops); filler band-high rebalance-rif 2>&1 | tee "$WORK/band-high.out" | grep -E "sent|held" | grep -v approval | cut -c1-220 || true
[ "$(ops)" -gt "$o1" ] || { echo "!! no MoC mint queued"; exit 1; }; show
echo ">> fresh fork of the latest block for the fills (400 USDT0 + 1000 RIF)"
cast rpc anvil_reset "{\"forking\":{\"jsonRpcUrl\":\"$FORK_FROM\"}}" --rpc-url "$RPC" >/dev/null
setup
deal $USDT0 $USDT0_HOLDER "$OPERATOR" 400000000
deal $RIF $RIF_HOLDER "$OPERATOR" 1000000000000000000000
echo ">> 3. SELL_RIF: maker buys RIF with 25 USDT0"
order sell-rif 9 USDT0 RIF 25; show

echo ">> 4. SELL_RIF: maker buys RIF with 25 USDRIF (pools quote it via USD₮0; the rail redeems)"
order sell-rif-usdrif 11 USDRIF RIF 25; show

echo ">> 5. BUY_RIF: maker sells 200 RIF for USDT0"
order buy-rif 10 RIF USDT0 200; show

echo "OK"
