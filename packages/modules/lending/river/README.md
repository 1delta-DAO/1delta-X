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
deployed Hemi diamond**: when a delegate drives the op, value-out is delivered
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
| `RiverRepayModule` | MAKE | read debt → `repayDebt(min(amount,debt))`; sweep residual | `abi.encode(xapp, tm, debtToken, upper, lower)` |
| `RiverTakerModule` (op 0) | TAKE | `withdrawDebt` → Permit3-sweep satUSD → receiver | `abi.encode(uint8(0), xapp, tm, debtToken, maxFee, upper, lower)` |
| `RiverTakerModule` (op 1) | TAKE | `withdrawColl` → Permit3-sweep collateral → receiver | `abi.encode(uint8(1), xapp, tm, coll, upper, lower)` |
| `RiverOpenModule` | TAKE (Level B) | pull collateral + `openTrove` → sweep satUSD → receiver | `abi.encode(OpenData{...})` |

## Authorization (per leg)

| Leg | Protocol grant | Permit3 |
|---|---|---|
| addColl / open | `xapp.setDelegateApproval(module, true)` | token allowance on collateral (module) |
| repay | `xapp.setDelegateApproval(module, true)` | token allowance on satUSD (module) |
| borrow (withdrawDebt) | `xapp.setDelegateApproval(module, true)` | taker allowance (+ satUSD token allowance to the module only on `account`-routing deployments) |
| withdraw (withdrawColl) | `xapp.setDelegateApproval(module, true)` | taker allowance (+ collateral token allowance to the module only on `account`-routing deployments) |

✅ **Fork finding:** the deployed Hemi diamond enforces its caller-or-delegate
check on EVERY op — value-in included (`addColl` reverts "Caller not approved"
without the grant). Every module needs `setDelegateApproval`.

The taker modules enforce `msg.sender == permit3`; the MAKE modules enforce
`msg.sender == settlement`.

## Caveats

- **Fund-flow assumption:** value-in is pulled from `msg.sender` (the module,
  funded via Permit3); value-out lands on `account` (the maker) and is swept to
  `receiver`. This follows the Prisma/Liquity-V1 lineage — **validate against the
  deployed diamond on a Hemi/Base fork** before mainnet use.
- Partial repay only; a full close is `closeTrove` (satUSD burned, collateral
  returned) — wire that as a dedicated flow. Recovery Mode (TCR < 150%) blocks
  withdrawals/close.
- Interest is protocol-set (currently 0%); a one-off mint fee applies on open /
  every debt increase (`maxFeePercentage` guard).

## Tests

Fork Hemi / Base / BNB where River is deployed (set an RPC endpoint). The
`security/` auth checks run without a fork.

```
FOUNDRY_PROFILE=modules-river forge test --root ../../../..
```
