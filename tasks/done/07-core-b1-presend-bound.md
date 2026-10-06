# 07. Core: make the PRESEND bound self-sufficient (B-1)

- **Status:** done (2026-10-06) — core change for the NEXT Settlement deployment; the beta keeps the deployed one
- **Package:** `packages/core` (`settlement/Batch.sol`)
- **Severity:** liveness on the netted path only; no funds at risk
- **Source:** [REVIEW-2026-10-05-amount-mismatch.md](../REVIEW-2026-10-05-amount-mismatch.md), §2 S2; `Batch._stepPresend`'s ⚠ note; `docs/audit-2026-09-leads.md` B-1
- **Opened:** 2026-10-06

## Problem

`outstanding[t]` is seeded from output legs and decremented by DELIVER only
([Batch.sol:853](../packages/core/src/settlement/Batch.sol#L853)). It does not include
the Phase-3 refund of `credit − owed` the core owes a maker whose TAKE over-produced,
so PRESEND hands that excess to the solver. On `executeItemFill` the route consumes
it and the refund finds an empty pool ⇒ `TransferFailed`
(`test_S2_nettedPath_overProducingTakeReverts`). The single-order path refunds the
maker.

## Change

In `_creditItemProceeds`, when a credit pushes `credit[i][j]` past `owed[i][j]`, add
the part that crosses the line — `max(0, newCredit − max(oldCredit, owed))` — to
`st.outstanding[t]`. PRESEND then nets the refund out; `_matchReconcileInputs` is
unchanged.

## Acceptance

- The S2 netted test flips to a fill: the maker receives the 5 A refund, the route
  swaps exactly `owed`.
- `make size-check` passes — measure first with a clean `out/core-deploy` (memory
  `settlement-size-clean-build-rule`); expect a few dozen bytes.
- `make gas-check`: netted suite within noise, single-order hot path untouched.

## Resolution (2026-10-06)

- `Batch._creditItemProceeds`: on an input-leg credit, `outstanding[t] += max(0,
  newCredit − max(oldCredit, owed))`. `_matchReconcileInputs` unchanged. `_stepPresend`'s
  ⚠ note and the `MatchCtx.outstanding` comment rewritten; `docs/audit-2026-09-leads.md`
  B-1 marked FIXED.
- Tests: `test_S2_nettedPath_overProducingTakeReverts` → renamed
  `test_S2_nettedPath_overProducingTakeRefundsMaker` and fills (patched and unpatched:
  route swaps exactly `owed`, maker refunded 5 A). Core `MatchSettle.t.sol`
  `test_surplus_cannotBePresentAwayFromMaker` / `test_surplus_presendBeforeDelivery_alsoFails`
  pinned the old revert; they now fill with the solver getting nothing and the maker
  the 500 USDC refund.
- Size (clean `rm -rf out/core-deploy`): +126 B — Settlement 24,311 → 24,480 / 24,576
  together with task 08 (+43). An unchecked/aliased variant measured the same.
- Gas: netted path only; single-order code untouched. `make gas` regenerated (see the
  report: the dispatcher reshuffle from the 08 selector change moves most tests by
  ±tens of gas).
