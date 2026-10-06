# 04. Decide the market order's life (300 s applied; alternative: 60 s with lower gates)

- **Status:** done (2026-10-06): 300 s confirmed
- **Package:** `packages/app` (or `packages/orderbook-worker` + `packages/filler-worker`)
- **Severity:** product decision; the applied default makes the flow work
- **Source:** [REVIEW-2026-10-05-amount-mismatch.md](../../REVIEW-2026-10-05-amount-mismatch.md), §5
- **Opened:** 2026-10-06

## Problem

A market order's life, the book's minimum TTL and the filler's expiry margin are three
numbers in three packages. They must satisfy `life ≥ MIN_TTL` and `life − margin ≥ a
useful fill window`; they did not (60 / 120 / 90).

## Applied

[plan.ts](../../packages/app/src/lib/plan.ts): `MARKET_DECAY_SECONDS = 60` (the auction,
unchanged) and `MARKET_TTL_SECONDS = 300` (the life). A market order decays to its
floor over a minute, then rests at the floor for four more: 300 − 90 = 210 s (≈ 7
Rootstock blocks) of fill window after the book's gate. `OrderForm` shows "5 minutes
(1 minute auction, then rests at the minimum)". Pinned by
`test_audit_APP_TTL1_marketTtlClearsBookMinAndFillerMargin`, which reads both
`wrangler.toml` files.

## Alternative

Keep a 60 s market order: `MIN_TTL_SECONDS = 60`
([orderbook-worker/wrangler.toml](../../packages/orderbook-worker/wrangler.toml)) and
`EXPIRY_MARGIN_SECONDS = 30` ([filler-worker/wrangler.toml](../../packages/filler-worker/wrangler.toml)).
That is one block of margin against a 5 s tick + quote + simulate + send; fills will
often miss, and every missed market order is a signed-and-wasted ticket.

## Acceptance

- Which UX the beta wants is written down: "market = short auction, then a resting
  floor order" (applied) or "market = 60 s or nothing".
- The app test above passes for the chosen numbers.

## Decision (2026-10-06)

**Market = short auction, then a resting floor order.** `MARKET_DECAY_SECONDS = 60`,
`MARKET_TTL_SECONDS = 300`, book `MIN_TTL_SECONDS = 120`, filler
`EXPIRY_MARGIN_SECONDS = 90`, which leaves a 210 s fill window after the book gate. The
60 s alternative was rejected: one block of margin against tick + quote + simulate +
send would waste signed tickets. `test_audit_APP_TTL1_marketTtlClearsBookMinAndFillerMargin`
passes. The task 03 e2e (`e2e:app-shape`) fails when any one of the three constants is
changed inconsistently.
