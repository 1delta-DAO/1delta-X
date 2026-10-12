# Synthetic pairs: an order book for a pair with no direct pool (PLAN)

Status: **plan, nothing built yet** (2026-10-12). This document covers pairs such as
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
