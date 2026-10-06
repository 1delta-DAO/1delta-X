# 03. e2e: sign the app's real market shape against the production gates

- **Status:** done (2026-10-06)
- **Package:** `packages/beta-filler` / `packages/filler-worker` (e2e), `packages/app`
- **Severity:** test gap; the one check that would have caught a ship-blocking misconfiguration
- **Source:** [REVIEW-2026-10-05-amount-mismatch.md](../../REVIEW-2026-10-05-amount-mismatch.md), §5 and §9.4
- **Opened:** 2026-10-06

## Problem

The TTL triangle — app `MARKET_TTL_SECONDS` 60 < book `MIN_TTL_SECONDS` 120, and
below the filler's `EXPIRY_MARGIN_SECONDS` 90 — made every app market order
unbookable, and nothing caught it: both e2e harnesses sign 3,600 s fixed-leg orders
([make-order.ts:94](../../packages/beta-filler/e2e/make-order.ts#L94),
[load.ts:205](../../packages/filler-worker/e2e/load.ts#L205)) and staging inverts the
gates (`MIN_TTL_SECONDS=15`, `EXPIRY_MARGIN_SECONDS=6`,
[staging.sh:40](../../packages/filler-worker/e2e/staging.sh#L40)). The unit test added in
[crossComponent.audit.test.ts](../../packages/app/test/crossComponent.audit.test.ts) pins
the three numbers, not the flow.

## Change

One scripted run that signs exactly what [order.ts](../../packages/app/src/lib/order.ts)
+ [plan.ts](../../packages/app/src/lib/plan.ts) produce for a market ticket — a decaying
SELL leg with `packTiming(now, 60, 0)` (and a BUY with a rising input), `expiry = now +
MARKET_TTL_SECONDS`, timing bit 104 + `exclusiveFiller = solver` on a direct market,
`exclusiveFiller = 0` on the USDRIF pull market — posts it to a book running the
PRODUCTION `MIN_TTL_SECONDS`, and drives the filler with the PRODUCTION
`EXPIRY_MARGIN_SECONDS` / `TICK_SECONDS` on an anvil fork.

## Acceptance

- The book answers 202 for market, limit and TWAP tickets built by the app's code.
- The filler quotes and fills the market order within the first tick after its
  auction reaches the floor (≤ 300 − 90 s); the direct market lands as `direct`,
  USDRIF as `pull`.
- The run fails when any one of the three constants is changed inconsistently.

## Resolution (2026-10-06)

Built `packages/filler-worker/e2e/app-shape.ts`, run by
`packages/filler-worker/e2e/staging.sh app-shape` (or
`pnpm --filter @1delta-x/filler-worker e2e:app-shape`). Local only, not in CI. It is
documented in the filler-worker README under "The app's real shapes against the
production gates".

- **Harness:** a new `GATES=production` mode in `staging.sh`, which `app-shape` always
  uses. It reads `MIN_TTL_SECONDS` from `orderbook-worker/wrangler.toml` and
  `EXPIRY_MARGIN_SECONDS` from `filler-worker/wrangler.toml` with `toml_var`.
  `TICK_SECONDS` is the committed value and is never overridden. The staging default
  (15 / 6) is unchanged. `app-shape` runs its own stack (`up`, then the script, then
  `down`), and an EXIT trap tears it down on failure too.
- **Uses the app's own code, imported directly:**
  - `planTicket` and `MARKET_TTL_SECONDS`;
  - `buildOrder`;
  - `parseDeployments` and `solverForMarket`, with the production `VITE_DEPLOYMENTS`
    shape: the gated solver deployment-wide and `rsk-30-usdrif-usd0` set to `"pull"`;
  - `planFunding` and `fundingCalls`;
  - `ladder.quote` and `priceFromSqrt`;
  - `postOrder`, sent through the app's Pages worker.

  The script reads the three constants from the files and re-checks every shape the
  task names: decaying SELL with bit 104 and `exclusiveFiller` = solver, rising-input
  BUY, and USDRIF pull with `exclusiveFiller` = 0.
- **Two pure pieces factored out of the app so node can import them (app behaviour
  unchanged, app tests 106/106):**
  - `src/config/deploymentConfig.ts`: the parsing and solver choice, without
    `import.meta.env`. `deployments.ts` re-exports it.
  - `MARKET_SLIPPAGE_BPS` (50): moved from `App.tsx` into `lib/plan.ts`.
- **Simplification:** the ladder is one fee-less rung at the pool's on-chain mid,
  because the Oku tick feed is not on the fork.

### Run results (anvil fork of public-node.rsk.co, 2 s blocks, current contracts deployed by `make deploy-core` + `deploy-aggregator-fill`)

| run | constants | book | market fills | exit |
| --- | --- | --- | --- | --- |
| 1, all production (app floor 50 bps) | 300 / 120 / 90 / tick 5 | 5 × 202 | **none**: unprofitable for the filler (below) | 1 |
| 2, production gates, `MARKET_SLIPPAGE_BPS=100` | 300 / 120 / 90 / tick 5 | 5 × 202 | buy t+70 s, sell t+78 s, usdrif t+78 s (10–18 s after the floor) | **0, PASSED** |
| 3, `EXPIRY_MARGIN_SECONDS=250` | 300 / 120 / **250** | 5 × 202 | none ("last send at t+50 s", before the t+60 floor) | 1 |
| 4, `APP_MARKET_TTL_SECONDS=60` | **60** / 120 / 90 | 3 markets `422 expires in 60s (min 120s)`; limit and TWAP 202 | — | 1 |
| 5, `MIN_TTL_SECONDS=400` | 300 / **400** / 90 | markets `422 expires in 300s (min 400s)` (one transient wrangler `500 Network connection lost`); TWAP 422; limit 202 | — | 1 |

Run 2 in detail:

- **market-sell:** delivered as `direct` (route strategy, tx to the solver). The maker
  got exactly its floor, 844,960,763.
- **market-buy:** delivered as `direct`. The maker got its fixed 9.279e15 WRBTC and paid
  the 800 USDT0 ceiling.
- **market-usdrif:** delivered as `pull` (inventory EOA, tx to Settlement). The maker got
  its floor, 296,423,030.
- **Timing:** every fill came at the filler's first re-quote after the floor. That
  re-quote waits for the 30 s `AUCTION_RECHECK_MS` hold, so it is not literally the
  first 5 s tick. Every fill landed well inside 300 − 90 = 210 s.
- **Perturbations:** each run used an env override only; nothing was changed in a file.

**Finding: the economics block market fills, independently of the TTL triangle.**
With every production value, the filler never fills an app market order on the fork.

- **WRBTC/USD0:** the 50 bps floor is below the 0.3 % pool fee + `ROUTE_SLIPPAGE_BPS`
  30 + gas. Logged at the floor: `quote 850322620 −30bps = 847771652 < owed 849228242 +
  gas 709714 + profit 85088`. The BUY fails the same way.
- **USDRIF:** at its floor the price passes `MAX_BUY_PRICE`, but the inventory reports
  `exit edge 16 bps < 30` (`MIN_EXIT_EDGE_BPS`), and the route is unprofitable as well.

So the timing gates are consistent and verified, but app market orders need a wider
floor, fee-aware ladder prices, or a lower filler haircut / exit edge before the beta.
That needs its own task or decision; it is not filed here.
