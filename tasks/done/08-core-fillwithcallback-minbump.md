# 08. Core: a `minBumpBps` floor on `fillWithCallback`

- **Status:** done (2026-10-06)
- **Package:** `packages/core`, `packages/solvers`, `packages/sdk`, `packages/beta-filler`
- **Severity:** filler protection; today handled by refusing three order shapes off-chain
- **Source:** [REVIEW-2026-10-05-amount-mismatch.md](../REVIEW-2026-10-05-amount-mismatch.md), §4
- **Opened:** 2026-10-06

## Problem

Only `fillUpTo`, `fillWithPermit*` and `batchFill` carry the filler's price floor
(`FillCtx.minBump` → `OrderState.BumpTooLow`). `fillWithCallback` — the aggregator
solver's entry — has none, so the route filler's floor is the previewed `maxPay` /
`amountOut`, and any order whose tick can move maker-ward after the preview is refused
off-chain ([route.ts:107](../packages/beta-filler/src/route.ts#L107): priority auctions,
`gasBumpBps`, custom `curve`). The inventory path keeps them because `fillUpTo` has
the floor. The lens preview is also quoted at gasPrice 0 — the no-bid tick.

## Change

- A `fillWithCallback` overload (or a field on the typed entry from task 06) that sets
  `ctx.minBump` before `_openFill`, as `fillUpTo` does.
- `AggregatorFillSolver.executeFill` passes a new `RoutePlan.minBumpBps` through
  (ABI change — bundle with task 06).
- `classifyRoute` drops the three refusals; `previewFill` / `previewBump` are called
  with the send `gasPrice`.

## Acceptance

- A priority order previewed at a bid and included at a lower bid reverts
  `BumpTooLow` inside the solver's fill (no silent direct-BUY margin erosion).
- Settlement size measured (memory `pendle-limit-gap-analysis`: the `fillUpTo` floor
  cost +0 on the hot path — expect the same shape).

## Resolution (2026-10-06)

- Core: the 7-arg `fillWithCallback(…, mode, takerData)` overload is REPLACED by an
  8-arg `(…, mode, takerData, minBumpBps)` (BREAKING, same trade as `fillWithPermit`);
  `_fillCallback` sets `ctx.minBump` before `_fillCore`, checked by `OrderState._openFill`.
  The prologue moved into `_openSigned` (legacy-profile stack). A third overload next
  to the 7-arg one measured +307 B (24,618 — over EIP-170); widening it measured +43 B.
  No in-repo Solidity caller used the 7-arg form. New selector 0x3d4a8695.
- Solver: `executeFill` forwards `RoutePlan.minBumpBps` (bundled with task 06's ABI change).
- SDK: `SETTLEMENT_ABI` 8-arg entry; `encodeFillWithCallback({ …, takerData?, minBumpBps? })`.
- beta-filler: `classifyRoute` no longer refuses priority auctions, gas-bump orders or
  custom curves; `RouteFiller` previews `previewFill` AND `previewBump` as the solver at
  the SEND gas price (`chain.ts` forwards `gasPrice` to `eth_call`) and puts the bump in
  the plan. The inventory path's previews now pass the send gas price too.
- Test: `AggregatorLivePricingTest.test_minBump_priorityDirectBuy_makerWardMoveRevertsBumpTooLow`
  — quoted at a 1 gwei bid (bump 5000), included at a 1.5 gwei effective bid reverts
  `BumpTooLow`; unfloored the same inclusion silently pays 96.25 instead of 97.5;
  at the quoted bid or a lower one it fills. NOTE: the Acceptance bullet's "included at
  a LOWER bid" is the filler-ward direction (it passes the floor); the maker-ward move
  is a HIGHER effective bid (e.g. basefee dropping under a legacy `gasPrice`), which is
  what reverts. Plus SDK `callback.test.ts` and beta-filler `audit.test.ts` "task 08"
  (previews at send gas price, plan carries previewBump).
- Size: Settlement 24,311 → 24,354 B for this task alone (clean `core-deploy`); with
  task 07: 24,480 / 24,576.
