#!/usr/bin/env bash
# Deploy native RBTC delivery on Rootstock (task 30): a `NativeBalance` view and an
# `AggregatorFillSolver` v3 wired to it, in ONE `forge script` run (DeployAggregatorFill
# with DEPLOY_NATIVE_BALANCE=true), signed with a Foundry keystore.
#
#   packages/solvers/script/deploy-native-delivery.sh            # preflight + simulation only
#   packages/solvers/script/deploy-native-delivery.sh --broadcast  # … then broadcast after "yes"
#
# What it does:
#   1. preflight: chain id, Settlement code, the deployer's balance and nonce, the
#      predicted addresses (NativeBalance at nonce n, the solver at n+1), and the send gas
#      price = the latest block's `minimumGasPrice` × 1.03 (the filler's own pricing);
#   2. simulation against the live chain (`forge script` without --broadcast): runs the
#      constructor and every read-back check the script makes (Settlement / executor /
#      sandbox / operator / venues re-derive the live pools / the NativeBalance probe),
#      and compares forge's "Estimated amount required" with the deployer's balance;
#   3. with --broadcast and a typed "yes": the same run, broadcast (`--slow`: one tx at a
#      time) — forge asks for the keystore password itself;
#   4. reads both contracts back on chain and prints the lines for
#      docs/deployment-rootstock-beta.md; VERIFY=1 (default) then verifies both on
#      Sourcify (Blockscout imports from it; its own verify API rate-limits).
#
# Why the explicit gas flags: forge's defaults price at `eth_gasPrice` (min + 10 %) and
# reserve the gas estimate × 1.3 UP FRONT, which asks the deployer to hold ~0.000187 RBTC
# for a ~0.000137 RBTC deploy. `--with-gas-price` (min × 1.03) and
# `--gas-estimate-multiplier 110` bring the up-front reserve to ~0.000149 RBTC.
#
# Env (defaults = the live Rootstock beta):
#   RPC_URL      https://public-node.rsk.co
#   ACCOUNT      deployer       keystore name in ~/.foundry/keystores (or KEYSTORE=<file>)
#   SENDER       0x00001d4754680958E7f8fe42D60842Ebde4Cb30D (must be the keystore's address)
#   SETTLEMENT   0xe6EDbb5c49Fb4CFb313476e3B78E274D3584ddf5
#   OPERATORS    0xcafe35944e3195d59b4a354Ea23D60a0445c083a
#   GAS_MULT_BPS 10300          send gas price = minimumGasPrice × this / 10000
#   VERIFY       1              0 = skip the Sourcify verification
#   CHAIN_ID     30             the chain the RPC must answer (a local fork test sets it too)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
BROADCAST=0
for a in "$@"; do
  case "$a" in
    --broadcast) BROADCAST=1 ;;
    -h | --help) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; /^set -euo/d'; exit 0 ;;
    *) echo "unknown flag $a (use --broadcast)" >&2; exit 2 ;;
  esac
done

RPC="${RPC_URL:-https://public-node.rsk.co}"
SENDER="${SENDER:-0x00001d4754680958E7f8fe42D60842Ebde4Cb30D}"
export SETTLEMENT="${SETTLEMENT:-0xe6EDbb5c49Fb4CFb313476e3B78E274D3584ddf5}"
export OPERATORS="${OPERATORS:-0xcafe35944e3195d59b4a354Ea23D60a0445c083a}"
export DEPLOY_NATIVE_BALANCE=true
unset NATIVE_BALANCE
GAS_MULT_BPS="${GAS_MULT_BPS:-10300}"
CHAIN_ID="${CHAIN_ID:-30}"
if [ -n "${KEYSTORE:-}" ]; then SIGNER=(--keystore "$KEYSTORE"); else SIGNER=(--account "${ACCOUNT:-deployer}"); fi
# Foundry reads ETH_PASSWORD (a password FILE) for every cast/forge call and then demands a
# keystore even for reads, so take it out of the environment and hand it to the broadcast
# only. Unset (the normal case), forge prompts for the password.
if [ -n "${ETH_PASSWORD:-}" ]; then SIGNER+=(--password-file "$ETH_PASSWORD"); unset ETH_PASSWORD; fi
SCRIPT=packages/solvers/script/DeployAggregatorFill.s.sol:DeployAggregatorFill
WORK="$(mktemp -d)"

echo ">> 1. preflight"
[ "$(cast chain-id --rpc-url "$RPC")" = "$CHAIN_ID" ] || { echo "RPC is not chain $CHAIN_ID" >&2; exit 1; }
[ "$(cast codesize "$SETTLEMENT" --rpc-url "$RPC")" -gt 0 ] || { echo "no Settlement at $SETTLEMENT" >&2; exit 1; }
BAL=$(cast balance "$SENDER" --rpc-url "$RPC")
NONCE=$(cast nonce "$SENDER" --rpc-url "$RPC")
NB_AT=$(cast compute-address "$SENDER" --nonce "$NONCE" | awk '{print $NF}')
AGG_AT=$(cast compute-address "$SENDER" --nonce $((NONCE + 1)) | awk '{print $NF}')
MIN=$(cast rpc eth_getBlockByNumber latest false --rpc-url "$RPC" | jq -r '.minimumGasPrice // empty')
if [ -n "$MIN" ]; then GP=$(echo "($(cast to-dec "$MIN") * $GAS_MULT_BPS + 9999) / 10000" | bc); else GP=$(cast gas-price --rpc-url "$RPC"); fi
echo "   deployer $SENDER  balance $(cast from-wei "$BAL") RBTC  nonce $NONCE"
echo "   predicted NativeBalance $NB_AT  AggregatorFillSolver $AGG_AT"
echo "   gas price $GP wei  ($( [ -n "$MIN" ] && echo "minimumGasPrice $(cast to-dec "$MIN") × $GAS_MULT_BPS/10000" || echo "eth_gasPrice: no minimumGasPrice on this chain"))"
echo "   settlement $SETTLEMENT  operators $OPERATORS"

FLAGS=(--rpc-url "$RPC" --sender "$SENDER" --legacy --with-gas-price "$GP" --gas-estimate-multiplier 110)

echo ">> 2. simulation (nothing is sent)"
(cd "$ROOT" && FOUNDRY_PROFILE=solvers-deploy forge script "$SCRIPT" "${FLAGS[@]}") >"$WORK/sim.log" 2>&1 || {
  tail -30 "$WORK/sim.log"; echo "simulation FAILED (full log $WORK/sim.log)" >&2; exit 1; }
grep -q "immutables verified" "$WORK/sim.log" || { tail -30 "$WORK/sim.log"; echo "simulation did not verify" >&2; exit 1; }
SIM_NB=$(awk '$1=="NativeBalance" && $2 ~ /^0x/ {print $2; exit}' "$WORK/sim.log")
SIM_AGG=$(awk '$1=="AggregatorFillSolver" && $2 ~ /^0x/ {print $2; exit}' "$WORK/sim.log")
NEED=$(grep -oE "Estimated amount required: [0-9.]+" "$WORK/sim.log" | awk '{print $4}')
GAS_TOTAL=$(grep -oE "Estimated total gas used for script: [0-9]+" "$WORK/sim.log" | awk '{print $NF}')
grep -E "^\s+(settlement|operators|pool venues|native balance|wnative|operator|venue factory|probe pool)" "$WORK/sim.log" | sed 's/^ */   /'
echo "   simulated NativeBalance $SIM_NB  solver $SIM_AGG"
echo "   estimated gas $GAS_TOTAL (× 1.1 reserved) · up-front reserve $NEED RBTC · balance $(cast from-wei "$BAL") RBTC"
[ "$(echo "$SIM_NB" | tr A-F a-f)" = "$(echo "$NB_AT" | tr A-F a-f)" ] && [ "$(echo "$SIM_AGG" | tr A-F a-f)" = "$(echo "$AGG_AT" | tr A-F a-f)" ] ||
  { echo "the simulated addresses differ from the nonce prediction" >&2; exit 1; }
[ "$(echo "$(cast to-wei "$NEED") <= $BAL" | bc)" = 1 ] || { echo "the deployer cannot cover the up-front reserve ($NEED RBTC): top it up" >&2; exit 1; }

if [ "$BROADCAST" = 0 ]; then
  echo
  echo "Simulation OK. Re-run with --broadcast to deploy (forge will ask for the keystore password)."
  exit 0
fi

echo
read -r -p "Deploy NativeBalance + AggregatorFillSolver v3 from $SENDER on chain $CHAIN_ID? Type yes: " ok
[ "$ok" = "yes" ] || { echo "aborted"; exit 1; }

echo ">> 3. broadcast"
(cd "$ROOT" && FOUNDRY_PROFILE=solvers-deploy forge script "$SCRIPT" "${FLAGS[@]}" "${SIGNER[@]}" --broadcast --slow) 2>&1 | tee "$WORK/deploy.log"
grep -q "ONCHAIN EXECUTION COMPLETE & SUCCESSFUL" "$WORK/deploy.log" || { echo "broadcast did not complete (log $WORK/deploy.log)" >&2; exit 1; }
NB=$(awk '$1=="NativeBalance" && $2 ~ /^0x/ {print $2; exit}' "$WORK/deploy.log")
AGG=$(awk '$1=="AggregatorFillSolver" && $2 ~ /^0x/ {print $2; exit}' "$WORK/deploy.log")
SANDBOX=$(cast call "$AGG" 'SANDBOX()(address)' --rpc-url "$RPC")

echo ">> 4. read back"
[ "$(cast codesize "$NB" --rpc-url "$RPC")" -gt 0 ] && [ "$(cast codesize "$AGG" --rpc-url "$RPC")" -gt 0 ] || { echo "no code at the deployed addresses" >&2; exit 1; }
echo "   NativeBalance.decimals() = $(cast call "$NB" 'decimals()(uint8)' --rpc-url "$RPC")"
echo "   solver.nativeDelivery()  = $(cast call "$AGG" 'nativeDelivery()(address,address)' --rpc-url "$RPC" | tr '\n' ' ')"
echo "   solver.isOperator(${OPERATORS%%,*}) = $(cast call "$AGG" 'isOperator(address)(bool)' "${OPERATORS%%,*}" --rpc-url "$RPC")"
RUN_JSON="$ROOT/broadcast/DeployAggregatorFill.s.sol/$CHAIN_ID/run-latest.json"
echo
echo "Record (docs/deployment-rootstock-beta.md):"
echo "  commit      $(cd "$ROOT" && git rev-parse --short HEAD)$(cd "$ROOT" && [ -n "$(git status --porcelain)" ] && echo ' (+ uncommitted changes)')"
echo "  NativeBalance        $NB"
echo "  AggregatorFillSolver $AGG"
echo "  RouteSandbox (child) $SANDBOX"
[ -f "$RUN_JSON" ] && jq -r '.receipts[] | "  tx \(.transactionHash) block \(.blockNumber) gas \(.gasUsed)"' "$RUN_JSON" | while read -r _ h _ b _ g; do
  echo "  tx $h  block $(cast to-dec "$b")  gas $(cast to-dec "$g")"; done

if [ "${VERIFY:-1}" = 1 ] && [ "$CHAIN_ID" = 30 ]; then
  echo ">> 5. Sourcify verification"
  ARGS=$(cast abi-encode "f(address,address[],(uint32,uint32,address),(address,bytes32)[],address,address)" \
    "$SETTLEMENT" "[$OPERATORS]" "(0,0,0x0000000000000000000000000000000000000000)" \
    "[(0xaF37EC98A00FD63689CF3060BF3B6784E00caD82,0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54),(0x46B3fDF7b5CDe91Ac049936bF0bDb12c5d22202e,0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54)]" \
    "$NB" 0x542fDA317318eBF1d3DEAf76E0b632741A7e677d)
  (cd "$ROOT" && FOUNDRY_PROFILE=solvers-deploy forge verify-contract "$NB" packages/periphery/src/NativeBalance.sol:NativeBalance \
    --verifier sourcify --chain 30) || echo "   NativeBalance verification failed (retry by hand)"
  (cd "$ROOT" && FOUNDRY_PROFILE=solvers-deploy forge verify-contract "$AGG" packages/solvers/src/aggregator/AggregatorFillSolver.sol:AggregatorFillSolver \
    --verifier sourcify --chain 30 --constructor-args "$ARGS") || echo "   solver verification failed (retry by hand)"
fi
echo "done"
