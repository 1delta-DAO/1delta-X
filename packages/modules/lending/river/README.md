# @1delta-x/modules-river

River (Satoshi Protocol) CDP adapters for `Settlement`. River mints satUSD behind
one SatoshiXApp **diamond** per chain; every borrower op targets the diamond and
takes the per-collateral `troveManager` + `account`. Depends on `@core`.

## Why River fits — and the CDP twist

Delegation is a single diamond-wide boolean: the maker calls
`setDelegateApproval(module, true)` once and the module drives the full borrower
surface for `account`. Troves are address-keyed (≤1 per user per TroveManager, no
id/discovery) — the cleanest of the CDPs.

The twist: CDP value-out carries **no receiver** — `withdrawDebt` mints satUSD to
`account` and `withdrawColl` returns collateral to `account`. So the taker modules
run the op and then **Permit3-sweep** the proceeds from the maker to the order's
`receiver` (the same mechanism the Aave withdraw module uses to pull the aToken).

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
| addColl / open | — | token allowance on collateral (module) |
| repay | — | token allowance on satUSD (module) |
| borrow (withdrawDebt) | `xapp.setDelegateApproval(module, true)` | taker allowance + token allowance on satUSD (for the sweep) |
| withdraw (withdrawColl) | `xapp.setDelegateApproval(module, true)` | taker allowance + token allowance on collateral (for the sweep) |

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
