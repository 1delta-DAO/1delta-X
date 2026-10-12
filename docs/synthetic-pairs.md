# Synthetic pairs: an order book for a pair with no direct pool (PLAN)

Status: **v1 shipped 2026-10-12, WRBTC/USDRIF.** It is implemented as planned (phases 1–3); the
"Implementation" section at the end describes what landed and where. Path splitting and
more pairs (phase 4) are still open. This document covers pairs such as
USDRIF/WRBTC, which has no pool of its own and only trades through a hub (here
USD₮0). The aim is to show such a pair as a normal market: an aggregated order book
laid over Uniswap/Sushi liquidity, market and limit tickets, and filler quotes.

## Where we start

- **Signing needs nothing new.** An order is "sell A, receive at least C". It does not
  care how a filler gets from A to C.
- **Filling needs nothing new.** The beta filler already discovers pools up to
  `ROUTE_MAX_HOPS` (3), quotes multi-hop paths across both venues, and sends 1–4-hop
  pool plans. `AggregatorFillSolver` handles exact-in and recursive exact-out. Quoting
  needs both tokens in `ROUTE_TOKENS` plus a `marketId` entry.
- **The missing piece is the BOOK.** The app builds a market's ladder from its pools'
  ticks (`poolbook.ts` → `assembleBook` → `Level[]`; `ladder.ts` walks it). A
  synthetic pair has no pool to read, so its ladder has to be composed from the legs.

## Candidate pairs (Rootstock, from today's pools)

| pair | path(s) | notes |
|---|---|---|
| USDRIF / WRBTC | USDRIF →0.05 %→ USD₮0 →0.3 %→ WRBTC | the RIF-ecosystem BTC entry; the filler already has this path (`ROOTSTOCK_PATHS`) |
| RIF / USDRIF | RIF →0.3 %→ USD₮0 →0.05 %→ USDRIF | |
| WETH / USD0 | WETH →0.3 %→ WRBTC →0.3 %→ USD₮0 | |
| RIF / WETH | RIF → WRBTC → WETH | thin; likely not worth listing |

## Design

### 1. Market config: a market can be a path

```ts
interface Market {
  id; chainId; base; quote;
  pools: PoolRef[];                 // direct markets, as today
  via?: { hops: MarketHop[][] };    // synthetic: one or more candidate paths
}
interface MarketHop { from: string; to: string; pools: PoolRef[] }   // symbols pinned in TOKENS
```

Every hop's pools are pinned exactly like a direct market's
(`assertPoolTokens` per hop). No path is discovered at runtime, for the same reason
markets are configuration (audit G-TS_SIGN-1).

### 2. Composing the ladder (the core of the work)

Compose each side of the book separately, because fees and price impact are
direction-dependent:

1. **Per hop:** take each hop's aggregated `Level[]` (every pool of the hop, already
   produced by `fetchVenue`/`assembleBook`), orient it in the direction of travel,
   and make it fee-net per hop.
2. **Per path:** a composite exact-in curve `out(x) = walkₙ(…walk₁(x))`, using the
   existing `walk()` per hop.
3. **Sampled rungs:** step the input until the composite marginal price has moved by
   one band (10 bps, the band the direct books use) and emit a flat rung
   `{price, size}` per band. `curveL` is null for these, so `walk()` fills them flat.
   The error is at most half a band, and step 5 pins it.
4. **Several paths:** per band, take the path with the better marginal price (no
   splitting in v1), and tag the rung `via USD₮0` / `via WRBTC` (a new `Source`
   value, or a `via` field on `Level`).
5. **Mid, spread and fees:** mid = the product of the hop mids. The spread is the
   compounded hop fees, shown as such ("0.35 % route fee").

**Consistency.** Fetch all legs at the same block where the source allows it, and
show the oldest leg's block. If one leg is stale, the whole book is stale: compose
only from legs at most 1 block apart, otherwise show "partial".

### 2b. Fitting the existing book structure

The book shows each pool's ticks. A synthetic pair has no pool, but nothing below the
fetch layer actually needs one:

- **`Level`:** a composed rung is `{price, size, source}` plus `start` / `end`, the
  composite marginal price at each edge of the band. `walk()` already prices between
  `start` and `end`, so partial fills inside a band stay close. `pool` and `feeBps`
  stay unset, as for `LMT` rungs.
- **`PoolBook`:** the composer returns the SAME shape (`bids`, `asks`, `mid`, `tick`,
  `step`, `block`), with `venues` = every hop's pools. So `mergeLadder` (resting
  orders), `walk` / `quote`, the cumulative column, the quote marker and
  click-to-price need no change.
- **What does change:**
  - `fetchPoolBook` gets a synthetic branch that fetches each hop's venues and composes
    them;
  - a new `Source` (`ROUTE`, rendered as "via USD₮0"), with its colour and legend entry;
  - the per-venue depth cards become per-hop cards ("USDRIF→USD₮0 depth");
  - `assertPoolTokens` runs per hop.

### 3. The quote stays the authority

Market tickets already sign at the FILLER's quote (`/api/quote`). The composed
ladder is the book's picture, and the fallback when the quote fails. Since
d044b80 the ladder is never shown in place of a pending quote. The filler quotes a
synthetic market as an ordinary multi-hop route, and its gas includes
`extraHopGas` per hop, so a 2-hop ticket's fee comes out honest without extra work.

### 4. Limit orders

A resting limit on a synthetic pair fills when the composite route crosses it. The
filler already evaluates the route output against what is owed, so it works as on
a direct market. The book marks them `LMT` as usual.

## Validation (before listing any pair)

- **Fork/live check, the gate for listing.** For each candidate pair, at sizes
  $10 / $100 / $1k / $10k on both sides: the composed-ladder `walk()` output vs
  QuoterV2 `quoteExactInput` on the same path at the same block. Accept at most
  5 bps (half a band plus rounding); otherwise the band is too coarse.
- **Unit tests** on synthetic `Level[]` fixtures:
  - composing with an identity hop returns the other hop;
  - fees compound;
  - the ask and bid sides are not mirror images;
  - path choice switches where the curves cross.
- **Filler:** a quote test for the new `marketId`, plus a fork test of a 2-hop
  pool-plan fill per new pair (direct + pull), learning their gas.

## Phases

1. **Library** (`lib/synthetic.ts`): compose, banding, path choice, with tests. No UI.
2. **Market config + book:** USDRIF/WRBTC only, `via` badge in the picker, route-fee
   line, staleness rule. Filler: market entry + `ROUTE_TOKENS`.
3. **Validation run** against QuoterV2 (above), then list it.
4. More pairs (RIF/USDRIF, WETH/USD0) once 3 passes for them; maybe path
   splitting if two paths are close in depth.

## Open questions

- Splitting across paths: the solver can do a single path per plan, and splitting
  would need either two plans or the API route. Deferred to after v1.
- How to show route depth that is actually the hub's depth: a big USDRIF/WRBTC
  order moves the USD₮0/WRBTC pool that the direct market also shows. A note in the
  book ("depth shared with WRBTC/USD0") is the minimum.

## Implementation (v1, 2026-10-12)

- **Composer:** `packages/app/src/lib/synthetic.ts` (`composeBook`).
  - The input runs on a geometric grid: 360 points per side, from capacity × 1e-6 (at
    least 1e-7 token units, above `walk()`'s 1e-9 dust cut-off) up to the largest input
    the whole route fills.
  - Samples merge into `ROUTE` rungs at most 5 bps wide, with `start` / `end` at their
    edges.
  - A side stops 20 % from its touch, or where a hop runs out.
  - Tests: `test/synthetic.test.ts`. They cover the touch as the compounded fee-net
    hop touches, the spread as the route fee, and a composed walk matching a
    sequential hop walk within 2 bps at every size. They also cover the thin-hop cap,
    an empty hop side, and the time budget.
- **Config:** `Market.via` holds the hops (`packages/app/src/config/markets.ts`,
  `synthetic()`); `pools` is derived from the hops.
  - `fetchMarketMeta` names a synthetic market from its pins.
  - `venueTokens` sizes each pool in its hop's base. `fetchVenue` checks the pool's
    OTHER token against the hop's pin, so a hop pool cannot be swapped for another
    pair.
  - `assembleBook` composes the hops once every hop has an answered pool.
- **UI:**
  - the book header reads "Routed book · no direct pool" with a `VIA USD0` badge;
  - every legend entry is prefixed with its hop;
  - a single "Routed bid depth" tile replaces the per-pool tiles;
  - the picker sub-line reads "via USD0 · Uni v3 0.30% + Sushi v3 0.30% → Uni v3 0.05%".
- **Filler:** `ROOTSTOCK_SYNTHETIC_MARKETS` (`packages/beta-filler/src/config.ts`) lets
  `POST /quote` resolve the `marketId`. The route is ROOTSTOCK_PATHS / discovery, a
  2-hop pool plan.
- **Book:** `ALLOWED_TOKENS` (orderbook-worker) gained RIF, which the RIF markets
  needed anyway.
- **Validation (the listing gate):**
  - Command: `LIVE_RSK=1 VITE_OKU_BASE=https://omni.icarus.tools npx vitest run test/synthetic.live.test.ts`.
  - Result on 2026-10-12: the composed book (Uniswap pools only) vs QuoterV2
    `quoteExactInput` on WRBTC →0.3 %→ USD₮0 →0.05 %→ USDRIF stayed within **0.02 bps**
    at $10 / $100 / $1k / $10k, on both sides.

## Derived markets (2026-10-12, follow-up)

The header market picker is gone: the pair is whatever the user picks in the ticket.

- **Lookup:** `marketFor(chainId, a, b)` returns the configured pool market if there is
  one. Otherwise it returns a DERIVED synthetic market over the first hub (Rootstock:
  USD0, WRBTC, RIF) that connects both tokens through configured markets.
  - Orientation: the token higher in `QUOTE_RANK` is the quote.
  - Id: `rsk-30-<base>-<quote>`, so WRBTC/USDRIF keeps its id.
  - Derived markets are cached as stable objects and resolve back from their id.
- **Token menus:** `pairsWith` lists every token reachable that way, directly or over
  one hub.
- **Quotes:** the app sends tokens only, never a `marketId`, so the filler routes any
  pair in `ROUTE_TOKENS`.
- **Limit:** a pair no single hub joins (e.g. USDC.e/RIFP) is not offered. Paths with
  two hubs are future work.
