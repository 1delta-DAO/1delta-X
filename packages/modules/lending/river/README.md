# @1delta-x/modules-river

River (Satoshi Protocol) CDP adapters for `Settlement`. River mints satUSD behind
one SatoshiXApp **diamond** per chain; every borrower op targets the diamond and
takes the per-collateral `troveManager` + `account`. Depends on `@core`.

## Why River fits — and the CDP twist

Delegation is a single diamond-wide boolean: the maker calls
`setDelegateApproval(module, true)` once and the module drives the full borrower
surface for `account`. Troves are address-keyed (≤1 per user per TroveManager, no
id/discovery) — the cleanest of the CDPs.

The twist: CDP value-out carries **no receiver**. ✅ **Fork-validated on the
deployed diamond** (originally on Hemi, now on BNB Smart Chain — same diamond
address, same behaviour): when a delegate drives the op, value-out is delivered
to **`msg.sender` (the module)** — not to `account` as the Prisma-lineage docs
suggested. The taker modules settle proceeds direction-agnostically
(`RiverProceeds.settle`): pay the order's `receiver` first from the module's own
measured delta, then from the maker's (Permit3 sweep — kept for deployments that
route to `account`), and sweep module-held surplus back to the maker.
Under-delivery reverts `InsufficientProceeds` — never funded from the maker's
pre-existing balance.

## Modules (`src/`)

| Contract | Op | Action | `data` |
|---|---|---|---|
| `RiverAddCollModule` | MAKE | pull collateral → `addColl` | `abi.encode(xapp, tm, coll, upper, lower[, permit])` |
| `RiverRepayModule` | MAKE | read debt → `repayDebt(min(amount,debt))` (reverts `FullCloseNotSupported` if that is the whole debt); sweep residual | `abi.encode(xapp, tm, debtToken, upper, lower)` |
| `RiverTakerModule` (op 0) | TAKE | `withdrawDebt` → settle satUSD (module-held, Permit3 fallback) → receiver | `abi.encode(uint8(0), xapp, tm, debtToken, maxFee, upper, lower)` |
| `RiverTakerModule` (op 1) | TAKE | `withdrawColl` → settle collateral (module-held, Permit3 fallback) → receiver | `abi.encode(uint8(1), xapp, tm, coll, upper, lower)` |
| `RiverOpenModule` | TAKE (Level B) | pull collateral + `openTrove` → settle satUSD → receiver | `abi.encode(OpenData{...})` |
| `RiverPreFundModule` | MAKE (pre-funded) | ONE contract, two ops selected by descriptor bits [244,252): `Op.AddColl` — `addColl` the core-delivered leg from the module's own balance; `Op.Repay` — `repayDebt(forAmount)` from its own balance; a delivery that would retire the whole debt reverts `FullCloseNotSupported`. Rides the MAKE seam (Settlement dispatches directly; `forAmount` is core-sized from the descriptor), not `TAKE_FOR` | `abi.encode(forDesc, xapp, troveManager, collateralToken \| debtToken, upperHint, lowerHint)` — descriptor word first, op in its bits |

The pre-fund modules (`RiverPreFundModules.sol`) are the one-sided "add/repay whatever
the conversion delivered" shape: the maker routes the signed output leg to the
module (`recipient = module`), so the DELIVERED asset needs no ERC20 approval and
no Permit3 token allowance, and no taker allowance is granted or spent (Settlement
dispatches a `MAKE` directly) — only the diamond's
`setDelegateApproval(module, true)` (a venue authorization the deployed diamond
enforces on value-in ops too) remains.

## Authorization (per leg)

| Leg | Protocol grant | Permit3 |
|---|---|---|
| addColl / open | `xapp.setDelegateApproval(module, true)` | token allowance on collateral (module) |
| repay | `xapp.setDelegateApproval(module, true)` | token allowance on satUSD (module) |
| borrow (withdrawDebt) | `xapp.setDelegateApproval(module, true)` | taker allowance (+ satUSD token allowance to the module only on `account`-routing deployments) |
| withdraw (withdrawColl) | `xapp.setDelegateApproval(module, true)` | taker allowance (+ collateral token allowance to the module only on `account`-routing deployments) |

✅ **Fork finding:** the deployed diamond enforces its caller-or-delegate
check on EVERY op — value-in included (`addColl` reverts "Caller not approved"
without the grant). Every module needs `setDelegateApproval`.

The taker modules enforce `msg.sender == permit3`; the MAKE modules enforce
`msg.sender == settlement`.

## Caveats

- **Fund flow (fork-validated on the deployed diamond):** value-in collateral is
  pulled from `msg.sender` (the module); `repayDebt` burns satUSD from
  `msg.sender` with no allowance; value-out lands on `msg.sender` (the module) and
  is forwarded to `receiver` by plain transfer. The Permit3 sweep from the maker
  in `RiverProceeds.settle` is only the fallback for a deployment that routes
  value-out to `account` (the Prisma-lineage documentation). A new chain's
  deployment should still be re-checked on a fork before use.
- Partial repay only, on BOTH repay modules: a repay that would retire the whole
  debt violates the diamond's minimum-net-debt rule, so `RiverRepayModule` and
  `RiverPreFundModule` (`Op.Repay`) revert `FullCloseNotSupported` when the
  live-debt cap saturates (unlike Liquity v2, River does not clamp). A full close
  is `closeTrove` (satUSD burned, collateral returned) — wire that as a dedicated
  flow. Recovery Mode (TCR < 150%) blocks withdrawals/close.
- **Trust premise:** `xapp` and `troveManager` are maker-supplied. The debt-token
  pin (`tm.debtToken()`) relies on the diamond rejecting an unregistered
  TroveManager; `test/fork/RiverVenueFork.t.sol` pins that the deployed diamond
  does.
- Interest is protocol-set (currently 0%); a one-off mint fee applies on open /
  every debt increase (`maxFeePercentage` guard).

## Tests

The `leverage/` suite forks **BNB Smart Chain** (default endpoint
`https://bsc-dataseed1.bnbchain.org`; override with `BSC_RPC_URL`) against the
BTCB TroveManager. It previously forked Hemi and was moved because the public
Hemi endpoint rate-limits at 300 req/60s, which a fork run exceeds — the suite
failed with HTTP 429 rather than on any assertion.

⚠ If you point these at another chain, re-read `collateralToken()` on the
TroveManager first. The diamond and satUSD share an address across chains but
**TroveManagers do not map to the same collateral**: `0xb655…` is WETH on Hemi
and WBTC on BSC, and BSC's WBTC has 8 decimals against BTCB's 18.

`test/fork/RiverVenueFork.t.sol` (same BSC endpoint) pins the venue premises the
modules rely on: the diamond rejects an unregistered TroveManager ("Collateral not
enabled") even when it answers the module's `debtToken()` pin, a repay of the
whole debt reverts inside the diamond, and the pull `RiverRepayModule` works live.

The `unit/` and `security/` checks run without a fork (the unit diamond mocks
burn satUSD from `msg.sender` with no allowance, as the deployed diamond does).

```
FOUNDRY_PROFILE=modules-river forge test --root ../../../..
```
