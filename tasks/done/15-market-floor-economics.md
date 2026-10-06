# 15. App market orders are unprofitable to fill at the 50 bps floor

- **Status:** done (2026-10-06): all three market orders fill at production settings
- **Package:** `packages/app` (`lib/plan.ts` `MARKET_SLIPPAGE_BPS`, price ladder) or `packages/beta-filler` (slippage haircut / exit-edge gate)
- **Severity:** liveness: every app market order expires unfilled at production settings
- **Source:** task 03 e2e run, [done/03-e2e-app-market-shape.md](03-e2e-app-market-shape.md) Resolution
- **Opened:** 2026-10-06

## Problem

`staging.sh app-shape` with every production value (app TTL 300, book min TTL 120,
filler margin 90, tick 5, `MARKET_SLIPPAGE_BPS = 50`) books all five tickets (202) but
fills no market order:

- **WRBTC/USD0 SELL and BUY (route path):** the 50 bps floor sits below pool fee (0.3 %) +
  the filler's 30 bps slippage haircut + gas + min profit. At the floor:
  `quote 850322620 −30bps = 847771652 < owed 849228242 + gas 709714 + profit 85088`.
- **USDRIF (inventory pull):** price passes, but `exit edge 16 bps < 30`.

With `MARKET_SLIPPAGE_BPS=100` and production timing, all three market orders fill
10–18 s after the auction floor (direct SELL/BUY as `direct`, USDRIF as `pull`).

## Options

Each moves who carries the cost:

1. Widen the app's market floor (e.g. 100 bps, maker pays more slippage).
2. Build the app's price ladder net of the pool fee, so the floor is relative to an
   executable price rather than the mid.
3. Lower the filler's slippage haircut / exit-edge threshold (filler carries more risk).

## Acceptance

- A decision recorded here.
- `pnpm --filter @1delta-x/filler-worker e2e:app-shape` with no money override fills
  all three market orders.

## Decision / Resolution (2026-10-06)

**Option 2**: the app's pool ladder is priced at what the pool executes.
`MARKET_SLIPPAGE_BPS` stays 50.

- `app/src/lib/univ3.ts`: `feeFraction(fee)` (fee tier in hundredths of a bip, 3000 = 0.30 %)
  and `applyPoolFee(ladder, fee)`: bids `p × (1 − f)` absorbing `size / (1 − f)` base, asks
  `p / (1 − f)` (≈ `p × (1 + f)`, the exact form since a v3 pool takes its fee from the input),
  quote side of each rung unchanged, `mid` = the true mid. `buildLadder` takes `fee` and
  applies it; `poolbook.fetchVenue` passes the pinned `ref.feeBps` (or the indexer's `meta.fee`
  if higher). Resting LMT orders (`mergeLadder`) are not fee-adjusted. `plan.ts` comment.
- e2e `app-shape.ts` runs its one-rung mid ladder through the app's `applyPoolFee` with the
  primary pool's tier, and now decodes the direct plan's `amountOutOffset` and reports the
  decay kept (task 05).
- Tests: `app/test/poolFee.test.ts` (10): units, per-side fee, sizes, identity at 0,
  buildLadder in both orientations, 0.3 % pool SELL quote = −30 bps vs mid and floor 50 bps
  below that, BUY ≈ +30 bps, LMT untouched. App 116/116, typecheck clean.

### e2e re-run (production values, no override; fork block 9,301,815, 2 s blocks)

| order | delivery | filled | maker got (floor) | maker paid (cap) | plan |
| --- | --- | --- | --- | --- | --- |
| market-sell 0.01 WRBTC | direct (route → solver) | t+71 s (11 s after floor) | 849,131,612 USDT0 (849,131,612) | 1e16 WRBTC | NO_PATCH (after decay), decay kept 0 |
| market-buy 800 USDT0 | direct | t+73 s (13 s after floor) | 9,271,531,017,045,602 WRBTC (fixed) | 800,000,000 (800,000,000) | NO_PATCH |
| market-usdrif 300 USDRIF | — | **not filled** | — | — | — |

The fee-net quote now matches the pool: USDRIF app start 299,228,890 vs the filler's Oku
quote 299,228,774 (0.04 bps); WRBTC SELL start 853,398,605 vs 852,783,341 (7 bps, depth).
Before this change the start sat ~30 bps above the 0.3 % pool's executable price.

### USDRIF: not resolved — numbers

- **Inventory (`MIN_EXIT_EDGE_BPS` 30, `beta-filler/src/policy.ts` `exitOk`):** the edge of the
  live exit — redeem USDRIF at the MoC oracle (`pACtp` 0.083397, −`MOC_FEE_BPS` 20) and sell the
  RIF on the RIF/USDT0 0.3 % pool — over what we pay. The 30 bps covers the RIF price risk while
  inventory waits for a batched redemption (`REDEEM_MIN_USDRIF` 1000, ~2.5 min queue) and the
  larger impact of the batched RIF sale (`RIF_SELL_SLIPPAGE_BPS` 50 tolerance). Measured edge:
  −52 bps mid-auction, **−30 bps at the floor** (paid 297.73 USDT0 ⇒ exit ≈ 296.84). The exit
  is ≈ 105 bps under $1: MoC 20 + RIF pool fee 30 + the RIF pool trading ≈ 55 bps under the
  MoC oracle (market basis + impact). Lowering the threshold — even to 0 — would not fill it;
  meeting 30 bps needs a floor ≈ 110 bps under the USDRIF/USD0 price. That gap is the RIF exit
  venue's basis, not the USDRIF/USD0 pool's fee (5 bps), so a 110 bps per-market floor would
  charge makers > 1 % where the route venue is almost there. Not changed.
- **Route pull (USDRIF/USDT0 0.05 % pool):** at the floor `quote 299,228,774 −30 bps =
  298,331,087 < owed 297,732,746 + gas 711,771 + profit 85,334` — short by 198,764 (6.7 bps).
  The cost stack is haircut `ROUTE_SLIPPAGE_BPS` 30 + gas 23.9 bps (a fixed ≈ 0.71 USDT0 at
  320k gas, 300 USDT0 notional) + profit 2.9 bps = 56.8 bps > 50. It is GAS-driven, so
  size-dependent: the 50 bps floor clears from ≈ 400 USDT0 notional; a flat per-market
  slippage would be arbitrary.
- Open choices (each moves the cost): (a) a size-aware market floor in the app (50 bps + the
  gas at the ticket's notional); (b) a lower route haircut on the stable 0.05 % pool (≤ 23 bps
  fills this ticket; the pull path's on-chain `minOut` already bounds loss to a revert's gas);
  (c) a minimum USDRIF market ticket ≈ 400 USDT0; (d) accept 100 bps for USDRIF (run 2 of task 03).

### USDRIF: resolved (2026-10-06): option (b) + zero min profit

Operator decision: the filler can take much less on a stable pair, and its infra cost
is essentially nothing (cheap infra, external aggregators). So:

- `beta-filler`: new `ROUTE_STABLE_SLIPPAGE_BPS` (default **5**), applied by
  `route.ts` `haircutBps` when both tokens are in `USD_TOKENS`; other pairs keep
  `ROUTE_SLIPPAGE_BPS` 30. A miss costs a revert's gas only (same-block quote, on-chain
  floor). `MIN_PROFIT_RBTC` default **0**. Both set in `filler-worker/wrangler.toml`;
  README knob table updated. App `MARKET_SLIPPAGE_BPS` stays 50.
- Tests: `route.test.ts`: config defaults/override/bounds, `haircutBps` per pair, and
  the e2e's USDRIF numbers (30 bps: short 198,764; 5 bps + 0 profit: margin 634,642).
  beta-filler 201/201, filler-worker 38/38.
- Gas remains the only real cost (~0.71 USDT0 / route fill on Rootstock), so with a
  50 bps floor the route fills down to ≈ 160 USDT0 notional.
- The inventory exit for USDRIF is still ≈ 105 bps under $1, so USDRIF market orders go
  through the route (pull) path, not inventory.

**e2e re-run, all production values, no override (fork block 9,302,112): PASSED.**

| order | delivery | filled | maker got (floor) |
| --- | --- | --- | --- |
| market-sell 0.01 WRBTC | direct | t+74 s (14 s after floor) | 850,563,648 (850,563,648) |
| market-buy 800 USDT0 | direct | t+74 s | 9,255,921,166,288,733 WRBTC (fixed), paid 800,000,000 (cap) |
| market-usdrif 300 USDRIF | pull via route | t+74 s | 297,717,354 (297,717,354) |

5 tickets booked (202); 3 market fills inside the window.
