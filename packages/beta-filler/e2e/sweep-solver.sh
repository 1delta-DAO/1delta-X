#!/usr/bin/env bash
# Pull the retained funds out of the live AggregatorFillSolver (Rootstock, chain 30),
# signing with a Foundry keystore account (`cast wallet import <name> --interactive`).
#
#   e2e/sweep-solver.sh                    # DRY RUN: balances + the planned sweeps
#   e2e/sweep-solver.sh --send             # sweep, leaving the 1-wei floors
#   e2e/sweep-solver.sh --send --all       # sweep, emptying every token
#
# Why the SOLVER and not Settlement: Settlement never holds funds between fills and has
# no sweep (anything sent to it is stranded by design). The beta's earnings sit on the
# solver because the filler runs it in retain mode (`ROUTE_PROFIT_RECIPIENT` = the
# solver, docs/deployment-rootstock-beta.md) until an operator calls
# `sweep(token, to, amount)`.
#
# Env:
#   ACCOUNT    keystore name in ~/.foundry/keystores (default: operator). It must be an
#              operator of the solver (0xcafe…083a on the live instances). The password
#              is asked ONCE and kept in a mode-600 temp file that is deleted on exit.
#   KEYSTORE   alternatively, a keystore FILE path (cast --keystore); wins over ACCOUNT.
#   SWEEP_TO   destination (default: the keystore's own address).
#   SOLVER     solver address(es), comma list (default: v3 0x5987…6cD1 and the legacy v2
#              0x48db…32F1, both still filling). Add the superseded v1
#              0x33ccAcb24DA5c7f335819Da877FC03E4bf62E287 to clear its floor.
#   RPC_URL    default https://public-node.rsk.co
#   TOKENS     comma list overriding the default token set below.
#
# Floors: the solver keeps a self-seeded 1-wei balance of each token so the next fill's
# balance write is a warm non-zero → non-zero SSTORE. Without --all that wei stays. Use
# --all only to retire a solver (after the v3 migration, once no open order names it as
# its exclusive filler).
#
# Batching: a solver whose bytecode has `sweepAll(address[],address,uint256)` (solver v3
# on) is paid out in ONE transaction — `sweepAll(tokens, to, keep)` with keep = 1, or 0
# under --all — which saves a 21k-gas transaction base per extra token and reads the
# amounts on-chain at execution. Older solvers (the live v2) get one `sweep` per token.
#
# Safety: nothing is sent without --send and a typed "yes". Before each sweep the
# balance is re-read and the exact call is simulated from the operator (`cast call
# --from`), so NotOperator / Reentrancy / a failed transfer stop the script before
# anything is broadcast. Sends are sequential; each waits for its receipt.
set -euo pipefail

SEND=0
ALL=0
for a in "$@"; do
  case "$a" in
    --send) SEND=1 ;;
    --all) ALL=1 ;;
    -h | --help) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; /^set -euo/d'; exit 0 ;;
    *) echo "unknown flag $a (use --send, --all)" >&2; exit 2 ;;
  esac
done

RPC="${RPC_URL:-https://public-node.rsk.co}"
ACCOUNT="${ACCOUNT:-operator}"
SOLVERS="${SOLVER:-0x5987A4AFE1b680DAC657506B69C56b06FFe86cD1,0x48dbdC43507767BD51ec0AF2cb9bfa5E35B332F1}"
# USD₮0, USDRIF, RIF, WRBTC, WETH, USDT, USDC.e, RIFPro, DOC (packages/beta-filler/src/config.ts).
TOKENS="${TOKENS:-0x779Ded0c9e1022225f8E0630b35a9b54bE713736,0x3A15461d8aE0F0Fb5Fa2629e9DA7D66A794a6e37,0x2AcC95758f8b5F583470ba265EB685a8F45fC9D5,0x542fDA317318eBF1d3DEAf76E0b632741A7e677d,0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590,0xAf368c91793CB22739386DFCbBb2F1A9e4bCBeBf,0x74c9f2b00581F1B11AA7ff05aa9F608B7389De67,0xf4d27c56595Ed59B66cC7F03CFF5193e4bd74a61,0xe700691dA7b9851F2F35f8b8182c69c53CcaD9Db}"

num() { awk '{print $1}'; } # cast prints "123 [1.23e2]" for big numbers
SWEEP_ALL_SEL="85ef1a76" # sweepAll(address[],address,uint256)

FROM=""
PWF=""
cleanup() { [ -n "$PWF" ] && rm -f "$PWF"; }
trap cleanup EXIT

if [ -n "${KEYSTORE:-}" ]; then
  SIGNER=(--keystore "$KEYSTORE")
  ACCOUNT="$KEYSTORE"
else
  SIGNER=(--account "$ACCOUNT")
fi

if [ "$SEND" = 1 ]; then
  if [ -n "${KEYSTORE:-}" ]; then
    [ -f "$KEYSTORE" ] || { echo "no keystore file $KEYSTORE" >&2; exit 1; }
  else
    [ -f "$HOME/.foundry/keystores/$ACCOUNT" ] || { echo "no keystore '$ACCOUNT' in ~/.foundry/keystores (cast wallet import $ACCOUNT --interactive)" >&2; exit 1; }
  fi
  PWF="$(mktemp)"
  chmod 600 "$PWF"
  read -r -s -p "Keystore password for '$ACCOUNT': " pw
  echo
  printf '%s' "$pw" >"$PWF"
  unset pw
  FROM="$(cast wallet address "${SIGNER[@]}" --password-file "$PWF")"
fi
TO="${SWEEP_TO:-$FROM}"

echo "$([ "$SEND" = 1 ] && echo SEND || echo 'DRY RUN') · $([ "$ALL" = 1 ] && echo 'empty every token' || echo 'leave the 1-wei floors') · to ${TO:-<the operator, at --send>} · rpc $RPC"
[ -n "$FROM" ] && echo "signer $FROM (keystore '$ACCOUNT')"

# Plan first (every solver, every token), confirm once, then send.
PLAN=()
IFS=',' read -r -a solver_list <<<"$SOLVERS"
IFS=',' read -r -a token_list <<<"$TOKENS"
for solver in "${solver_list[@]}"; do
  echo
  echo "solver $solver  (native RBTC $(cast balance "$solver" --ether --rpc-url "$RPC"), not sweepable)"
  if [ -n "$FROM" ]; then
    op="$(cast call "$solver" 'isOperator(address)(bool)' "$FROM" --rpc-url "$RPC")"
    echo "  isOperator($FROM) = $op"
    [ "$op" = "true" ] || { echo "the keystore account is not an operator of this solver" >&2; exit 1; }
  fi
  if cast code "$solver" --rpc-url "$RPC" | grep -qi "$SWEEP_ALL_SEL"; then batch=1; else batch=0; fi
  echo "  payout: $([ "$batch" = 1 ] && echo 'one sweepAll transaction' || echo 'one sweep transaction per token (no sweepAll on this solver)')"
  for token in "${token_list[@]}"; do
    bal="$(cast call "$token" 'balanceOf(address)(uint256)' "$solver" --rpc-url "$RPC" | num)"
    [ "$bal" = "0" ] && continue
    sym="$(cast call "$token" 'symbol()(string)' --rpc-url "$RPC" 2>/dev/null | tr -d '"' || echo "${token:0:8}")"
    dec="$(cast call "$token" 'decimals()(uint8)' --rpc-url "$RPC" 2>/dev/null | num || echo 18)"
    if [ "$ALL" = 1 ]; then amt="$bal"; else amt="$(echo "$bal - 1" | bc)"; fi
    if [ "$amt" = "0" ]; then
      printf '  %-7s %s (floor only, kept)\n' "$sym" "$(cast format-units "$bal" "$dec")"
      continue
    fi
    printf '  %-7s %s → sweep %s\n' "$sym" "$(cast format-units "$bal" "$dec")" "$(cast format-units "$amt" "$dec")"
    PLAN+=("$solver $token $sym $dec $batch")
  done
done

if [ "$SEND" = 0 ]; then
  echo
  echo "Dry run only. Re-run with --send to broadcast (ACCOUNT=$ACCOUNT)."
  exit 0
fi
[ "${#PLAN[@]}" -gt 0 ] || { echo "nothing to sweep"; exit 0; }

# Rootstock minimum gas price × 1.03 — the filler's own pricing (src/chain.ts readSendGasPrice).
gas_price() {
  local min
  min="$(cast rpc eth_getBlockByNumber latest false --rpc-url "$RPC" | jq -r '.minimumGasPrice // empty')"
  if [ -n "$min" ]; then echo "($(cast to-dec "$min") * 10300 + 9999) / 10000" | bc; else cast gas-price --rpc-url "$RPC"; fi
}

# send <what> <to> <sig> <args...>: simulate from the operator (set -e stops on a
# revert), broadcast, check the receipt.
send() {
  local what="$1" target="$2" sig="$3"
  shift 3
  cast call "$target" "$sig" "$@" --from "$FROM" --rpc-url "$RPC" >/dev/null
  local rc status hash
  rc="$(cast send "$target" "$sig" "$@" "${SIGNER[@]}" --password-file "$PWF" --legacy --gas-price "$(gas_price)" --rpc-url "$RPC" --json)"
  status="$(jq -r '.status' <<<"$rc")"
  hash="$(jq -r '.transactionHash' <<<"$rc")"
  if [ "$status" != "0x1" ] && [ "$status" != "1" ]; then echo "$what reverted: $hash" >&2; exit 1; fi
  echo "  $what · tx $hash · gas $(cast to-dec "$(jq -r '.gasUsed' <<<"$rc")")"
}

ntx=0
for solver in "${solver_list[@]}"; do
  n=0; b=0
  for entry in "${PLAN[@]}"; do read -r s _ _ _ eb <<<"$entry"; [ "$s" = "$solver" ] && { n=$((n + 1)); b=$eb; }; done
  [ "$n" = 0 ] && continue
  if [ "$b" = 1 ]; then ntx=$((ntx + 1)); else ntx=$((ntx + n)); fi
done
echo
read -r -p "Send ${#PLAN[@]} token payout(s) in $ntx transaction(s) to $TO? Type yes: " ok
[ "$ok" = "yes" ] || { echo "aborted"; exit 1; }

KEEP=$([ "$ALL" = 1 ] && echo 0 || echo 1)
for solver in "${solver_list[@]}"; do
  toks=()
  syms=()
  batch=0
  for entry in "${PLAN[@]}"; do
    read -r s token sym dec eb <<<"$entry"
    [ "$s" = "$solver" ] || continue
    batch="$eb"
    if [ "$batch" = 1 ]; then
      toks+=("$token")
      syms+=("$sym")
      continue
    fi
    # One `sweep` per token. Re-read: a fill landing since the plan only changes the amount.
    bal="$(cast call "$token" 'balanceOf(address)(uint256)' "$solver" --rpc-url "$RPC" | num)"
    amt="$(echo "$bal - $KEEP" | bc)"
    [ "$(echo "$amt > 0" | bc)" = 1 ] || continue
    send "swept $(cast format-units "$amt" "$dec") $sym from $solver" "$solver" 'sweep(address,address,uint256)' "$token" "$TO" "$amt"
  done
  if [ "$batch" = 1 ] && [ "${#toks[@]}" -gt 0 ]; then
    list="[$(IFS=','; echo "${toks[*]}")]"
    send "sweepAll ${syms[*]} (keep $KEEP wei each) from $solver" "$solver" 'sweepAll(address[],address,uint256)' "$list" "$TO" "$KEEP"
  fi
done
echo "done"
