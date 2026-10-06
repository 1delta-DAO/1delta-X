# 05. Direct-path SELL fills forgo the decay since the preview — accept or reclaim

- **Status:** done 2026-10-06 (option 3)
- **Package:** `packages/beta-filler` (and `packages/solvers` for option 3)
- **Severity:** filler economics; no maker exposure (the maker is over-paid)
- **Source:** [REVIEW-2026-10-05-amount-mismatch.md](../REVIEW-2026-10-05-amount-mismatch.md), §4; `packages/beta-filler/README.md` limitations
- **Opened:** 2026-10-06

## Problem

On a delta-verify (direct) order the route is exact-output for the PREVIEWED `owed`
([route.ts:244](../packages/beta-filler/src/route.ts#L244)); at inclusion the core only
requires `outputAt(block.timestamp)`, which on a SELL falls with time. On the app's
60 s / 0.5 % auctions one Rootstock block (~30 s) of decay is ≈ 0.25 % of notional —
2.5 USDT0 on a 1,000 USDT0 fill, more than the whole gas + min-profit margin
(≈ 2 USDT0) and far more than the 27k gas the direct path saves. A direct BUY captures
the rise (the input is measured on-chain); the pull path captures the decay as
surplus. With a 300 s market life (task 04) this only applies to fills inside the
first minute; afterwards the order rests at `end` and the route pays exactly `end`.

## Options

1. Accept for the beta (maker-favourable, bounded by the band). Documented already.
2. Price `amountOut` at an assumed inclusion time `now + Δ` with the SDK's pricing
   mirror. Safe only if the tx is included at `t ≥ now + Δ`; an earlier block reverts
   `DeltaTooLow` and burns the gas. Δ = 1 s is always safe and buys ~nothing; Δ = 30 s
   buys a block of decay and risks the revert.
3. On-chain `amountOut` patch from the live tick — task 06.
4. Stop signing bit 104 for SELL markets in the app (pull path; +27k gas per fill).

## Acceptance

- A decision is recorded here. Default recommendation: 1 for the beta unless fills
  are visibly margin-negative, then 3 if the direct path stays the default.

## Decision / Resolution (2026-10-06)

**Option 3**: reclaim the decay with the solver's on-chain `amountOutOffset` patch (task 06).

- `packages/beta-filler/src/route.ts`: new `patchesLiveOutput(order, direct, nowSec)` — true
  only for a delta-verify (bit 104) SELL whose `legsOut[0]` is a falling auction leg
  (`end != 0`, `end < start`) and, on a wall-clock order, before `decayStart + decayDuration`
  (a block-clock order is assumed to still decay). `buildRoutePlan({ …, liveOut })` then sets
  `amountOutOffset = call.amountOutOffset` (the SDK's `swapRouter02AmountOutOffset`:
  `exactOutputSingle` 132, `exactOutput` tuple + 64). Pull plans ignore `liveOut`.
- `routeFiller.ts`: computes `liveOut` per order; when set, the gas estimate the plan's floor
  is priced at (and the early budget check / re-price baseline) is `ROUTE_GAS_ESTIMATE +
  TYPED_CALLBACK_GAS` (6,000 — the measured +5.9k of the typed path, rounded up). The
  re-price step still works from the measured simulation. Log tag `direct+live`.
- Conservative profit: the gate and `amountInMaximum` stay sized on the PREVIEWED owed; the
  live owed is ≤ the preview on a falling leg (a maker-ward move reverts `BumpTooLow` via
  `minBumpBps`), so the decay is upside only — never counted on.
- NO_PATCH kept for: pull plans (exact-input, Settlement pulls `owed`, the decay is already
  surplus), direct BUY (fixed output — the rise is measured on-chain), an order past its decay
  window (live = preview, the typed gas would buy nothing), and **Sushi** (pull-only; snwap is
  exact-input and its only output word, `amountOutMin`, is a balance-rise floor, not the amount
  paid — there is no word a live `outputAt` could safely replace).
- Tests (beta-filler 199/199): `route.test.ts` — live direct plan carries the offset (single
  132 / multi 100, word = previewed owed, `amountInMaximum` unchanged, SDK encoder accepts it),
  `liveOut` ignored on pull, out-of-bounds offset refused by `encodeAggregatorExecuteFill`,
  `patchesLiveOutput` cases (decaying / past window / pull / fixed / BUY / block clock);
  `audit.test.ts` — RouteFiller end-to-end with a fake chain: decaying direct SELL sends
  offset 132 at gas limit estimate + 6,000; fixed-output direct and pull send NO_PATCH at the
  plain estimate. README limitation note rewritten.
- e2e (`e2e:app-shape`, production values, see task 15): the direct SELL filled 11 s after
  the floor (the filler's 30 s `AUCTION_RECHECK_MS` hold put its first profitable re-quote
  past the 60 s decay), so the plan correctly went out `NO_PATCH` and the decay kept was 0.
  The live patch itself is proven on-chain by the solver test
  `test_live_directSellAfterDecay_paysTheLiveTickAndKeepsTheDecay` (task 06).
