# 18. Lens: the `ITakeFloor` check rejects valid multi-leg and multi-item orders

- **Status:** open
- **Layer:** contract
- **Package:** `packages/periphery` (`SettlementLensChecks.sol`), `packages/modules/lending/lista`
- **Severity:** medium-low — lens only (no Settlement change); blocks valid orders once a book/UI enforces `validateOrder`
- **Source:** 2026-10-06 pre-merge audit of the working set (four review agents: contracts, modules+tooling, filler, book/app/sdk)
- **Opened:** 2026-10-06

## Problem

`_takeFloored` ([SettlementLensChecks.sol:990](../packages/periphery/src/SettlementLensChecks.sol#L990))
always passes `legsIn[0]` and its FULL `start` to `takeFloored`. Lista's implementation
([ListaSmartModules.sol:194](../packages/modules/lending/lista/src/ListaSmartModules.sol#L194))
returns false when `legToken != coin` and when the item's floor alone does not cover
the whole leg. False positives:
- a valid order whose Lista coin funds `legsIn[1]` (passes `_isInputLegToken`);
- two Lista TAKE items that each fund half of `legsIn[0]`.

## Change

- Pass the input leg whose token equals the module's `proceedsAsset(data)` (fall back
  to "unknown → pass" when none resolves).
- Compare the SUM of the floors of all items funding that leg against its `start`, or
  pass the item's share; pick one and document it in `ITakeFloor`.
- Info, same file: the staticcall forwards 63/64 of gas to a maker-chosen module —
  consider a gas cap like other best-effort probes.

## Acceptance

- Lens tests: Lista coin on `legsIn[1]` passes; two half-items on one leg pass; one
  under-floored item still fails. Existing `Review20261006Lens.t.sol` cases pass.
- Lens redeploy only; Settlement untouched.
