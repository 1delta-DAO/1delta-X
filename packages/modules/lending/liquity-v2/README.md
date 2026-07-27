# @1delta-x/modules-liquity-v2

Liquity V2 CDP adapters for `Settlement` (covers forks: Felix, Quill, Nerite,
USDaf, …). Troves are ERC-721 sub-accounts under a per-branch
`BorrowerOperations`. Depends on `@core`.

## Why Liquity V2 fits — per-trove managers map onto MAKE/TAKE

- `setAddManager(troveId, module)` authorises the **MAKE** legs (addColl,
  repayBold).
- `setRemoveManagerWithReceiver(troveId, module, module)` authorises the **TAKE**
  legs (withdrawColl, withdrawBold) and routes the proceeds to the module, which
  forwards them to the order `receiver`.

The value-out ops carry no receiver, so the taker module **measures** what landed
(reverting cleanly if the remove-manager grant is missing) and forwards exactly
`amount`, sweeping any excess to the maker.

## Modules (`src/`)

| Contract | Op | Action | `data` |
|---|---|---|---|
| `LiquityV2AddCollModule` | MAKE | pull collateral → `addColl` | `abi.encode(borrowerOps, troveId, coll[, permit])` |
| `LiquityV2RepayModule` | MAKE | read debt → `repayBold(min(amount,debt))`; sweep residual | `abi.encode(borrowerOps, troveManager, troveId, bold)` |
| `LiquityV2TakerModule` (op 0) | TAKE | `withdrawBold` → forward → receiver | `abi.encode(uint8(0), borrowerOps, troveId, bold, maxUpfrontFee)` |
| `LiquityV2TakerModule` (op 1) | TAKE | `withdrawColl` → forward → receiver | `abi.encode(uint8(1), borrowerOps, troveId, coll)` |

## Authorization (per leg)

| Leg | Protocol grant | Permit3 |
|---|---|---|
| addColl | `setAddManager(troveId, module)` | token allowance on collateral (module) |
| repay | `setAddManager(troveId, module)` | token allowance on BOLD (module) |
| borrow / withdraw | `setRemoveManagerWithReceiver(troveId, module, module)` | taker allowance (Settlement, `keccak256(data)`) |

The taker module enforces `msg.sender == permit3`; the MAKE modules enforce
`msg.sender == settlement`.

## Caveats

- **Never open troves through the official zappers** — they salt the id *and*
  install themselves as add/remove manager, capturing the trove. Open with a
  plain `openTrove(..., addManager=module, removeManager=module, receiver=module)`
  (a Level-B open module is a planned addition; the collateral-side gas
  compensation needs dedicated handling).
- Partial repay only; a full close is `closeTrove` (repay-all + withdraw-all + gas
  comp refund), wired as a dedicated flow.
- Gas compensation is collateral/WETH-side (pulled at open, refunded at close);
  the upfront borrow fee applies on open and every debt increase
  (`maxUpfrontFee` guard on `withdrawBold`).

## Tests

Fork Ethereum where Liquity V2 (or a fork) is deployed (set an RPC endpoint). The
`security/` auth check runs without a fork.

```
FOUNDRY_PROFILE=modules-liquity-v2 forge test --root ../../../..
```
