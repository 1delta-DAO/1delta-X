# 06. AggregatorFillSolver: typed-callback `onFill` (same-token netting, live `amountOut`)

- **Status:** done (2026-10-06)
- **Package:** `packages/solvers` (+ `packages/sdk`, `packages/beta-filler` for the ABI change)
- **Severity:** liveness (S1) and filler economics (task 05); not deployed yet, so no migration
- **Source:** [REVIEW-2026-10-05-amount-mismatch.md](../REVIEW-2026-10-05-amount-mismatch.md), §2 S1, §4, §9.2
- **Opened:** 2026-10-06

## Problem

Two gaps share one cause — `onFill` knows nothing the core priced:

1. **S1.** An output leg in `legsIn[0]`'s token (an in-kind fee) makes `executeFill`
   route the WHOLE input (patched ⇒ the fee pull reverts `TransferFromFailed`), while
   `executeItemFill` routes `input − leg` (PRESEND nets `outstanding`). Operators must
   quote `NO_PATCH` at `received − Σ same-token outs` today
   (`test_S1_pullPath_patchedRouteSwapsTheFeeToo`).
2. **Direct-path decay.** The route pays the previewed `owed`, not the live
   `outputAt(block.timestamp)` (task 05).

The core already computes both per fill and hands them to a TYPED callback
(`CallbackMode` bit 1 → `Core._typedPayload`: `orderHash, prevFilled, newFilled,
anchor, pricedIn[], priced[], userData`).

## Change

- Start the fill as `PostInputsDirect | typed`; implement
  `ISettlementCallback.onSettlementFill(...)` with the `FillRoute` in `userData`.
- Routed amount = `delta(tokens[0]) − Σ priced[j]` over output legs in `tokens[0]`
  (never above the delta: a reduction is always safe under the delta discipline).
- New `RoutePlan.amountOutOffset` (`NO_PATCH` default): on a direct order overwrite
  the route's `amountOut` word with `priced[0]`, so the route pays exactly what the
  core verifies and the decay since the quote stays with the filler as input residue.
- Keep the anchor-output / `_floor` semantics from the review's §1.

## Acceptance

- `test_S1_pullPath_patchedRouteSwapsTheFeeToo` flips to a fill (routes 99, fee paid).
- A direct SELL filled N seconds after the quote (`vm.warp`) delivers
  `outputAt(t_incl)` and the solver's residue grows by the decay.
- `AggregatorFillGas.t.sol` two-token benchmarks within +1k gas of today.
- SDK `RoutePlan` + `encodeAggregatorExecuteFill`, `beta-filler/src/route.ts` and
  `sushi.ts` updated (BREAKING ABI for the plan builders); `make test-ts` green.

## Resolution (2026-10-06)

- `AggregatorFillSolver`: new `onSettlementFill` (typed, `ISettlementCallback`) next to
  the untyped `onFill`; both share `_onFill` and the arming. `executeFill` starts
  `PostInputsTypedDirect` ONLY when the plan needs a priced amount — an output leg in
  `tokens[0]` (`FillRoute.sameOut`, bit per leg) or `RoutePlan.amountOutOffset` set —
  because the typed payload costs ~+5.9k gas; every other fill stays `PostInputsDirect`
  / `onFill`. The route is the typed callback's `userData`, read back in place as a
  calldata pointer (`_routeOf`), no decode.
- Routed amount = `delta(tokens[0]) − Σ pricedOut[j]` over same-token output legs,
  saturating at 0 (`_kept`, `_route`). `amountOutOffset` patches the route's output
  word with `pricedOut[0]`; ignored by `executeItemFill`. Anchor-output / `_floor`
  semantics unchanged.
- BREAKING: `RoutePlan` gained `amountOutOffset` and `minBumpBps` (task 08), `FillRoute`
  gained `amountOutOffset` and `sameOut`. `executeFill` selector 0x14db305c → 0x16997a3b.
- SDK: `RoutePlan`, `routePlanComponents`, `encodeAggregatorExecuteFill` (bounds-checks
  both offsets), `RouterCall.amountOutOffset` + `swapRouter02AmountOutOffset`.
  beta-filler `route.ts` / `sushi.ts` build plans with `amountOutOffset = NO_PATCH`
  (whether to reclaim the direct-SELL decay is still task 05) and `minBumpBps`.
- Tests: `test_S1_pullPath_patchedRouteSwapsTheFeeToo` → renamed
  `test_S1_pullPath_patchedRouteKeepsTheFeeBack` and fills (routes 99, fee paid);
  new `AggregatorLivePricingTest.test_live_directSellAfterDecay_paysTheLiveTickAndKeepsTheDecay`
  (warp 50 s: maker gets `outputAt(t_incl)` = 92.5, residue +2.5 = the decay) and
  `test_live_amountOutOffsetOutOfBounds_reverts`; new gas bench
  `test_gas_direct_seeded_liveAmountOut`.
- Gas (`AggregatorFillGas.t.sol`, execution gas, before → after): cold 251,387 →
  252,378 (+991); dust 207,587 → 208,578 (+991); dust/no surplus 197,962 → 198,955
  (+993); direct seeded 172,926 → 173,864 (+938); retain/gated seeded 196,338 → 197,321
  (+983); retain second 158,253 → 159,236 (+983). All within +1k (about half is the
  core's 8-arg `fillWithCallback` entry, half the solver's wider structs). Typed path:
  direct with live `amountOut` 179,773 (+5.9k over untyped).
- Solver size (solvers-deploy): 14,121 → 15,176 B.
