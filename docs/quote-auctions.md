# Quote auctions — format, measurement, and band width

The cosigned-quote modules ([pricing-modes.md](pricing-modes.md)) verify a signature
and bound the result; they do not care **how** the cosigner picked the number it
signed. That makes the auction *format* an off-chain policy — changeable with a
service deploy, no redeploy, no migration, no re-signed orders — and this note is
where that policy lives, alongside the measurement that should decide it.

Three claims, in the order they matter:

1. You cannot choose a format without knowing your **clearing depth**. Measure first.
2. The **band width** a maker signs is worth roughly an order of magnitude more than
   the format. Optimise that first.
3. The format debate itself (first-price vs. second-price) is real but second-order,
   and cheap to settle empirically once (1) is in place.

## 1. Clearing depth — where fills actually land

Every fill prices at a bump in `[0, 10000]`: `0` is the maker's `start`, `10000` its
`end`. That number decides everything, and it is **not on chain**. The settler
resolves it once per fill (`DutchAuction.resolveBump` → `FillCtx.bump`), uses it for
every leg, and discards it; `filled[orderHash]` tracks the *anchored* side, which is
precisely the side that does not decay.

It does not need to be on chain, because for the two on-chain modes it is a
deterministic function of block context and can be **replayed**:

| Mode | Recoverable? | From |
|---|---|---|
| Clock (default) | exactly | the order's `timing` + the fill block's timestamp (or number, under bit 102) |
| Priority (bit 103) | exactly | the receipt's `effectiveGasPrice` and the block's basefee |
| Price module | **no** | depends on the filler's `takerData`, which lives in the fill tx's calldata and is opaque behind a solver's own contract |

`FillIndex.resolveBumps()` in [`@1delta-x/orderbook`](../packages/orderbook/src/fills.ts)
does the replay and populates `FillRecord.realizedBump`, with a `bumpSource` that
keeps a **blind spot distinguishable from a real zero** — the distinction a plain
`number | null` destroys, and the one that decides whether your data means anything.

Deliberately NOT done: adding the bump to `OrderFilled`. A non-indexed word costs
~256 gas of log data on every fill forever, which hands back a tenth of the 2026-08
core gas pass to publish a number that is already derivable. `matchSettle` /
`batchSettle` rows stay unresolvable either way — netting through the pool with a
surplus pre-send makes per-order attribution ambiguous.

**What the distribution tells you**, once you have it:

- bumps clustered near `0` — the clock is disciplining solvers; the solver set is
  thick enough that waiting gets you sniped. Do not build a sealed-bid venue.
- bumps piled at `10000` — solvers are running the clock to the floor. The set is
  too thin, or coordinating. A quote channel is worth its infrastructure, and the
  band is doing no work.

## 2. Band width — where the money actually is

Format choice moves the outcome by the routing-quality gap between the best and
second-best filler: a few bps. Band width moves it by the entire unused tail: tens.
A maker who signs a sloppy band loses more to decay than any format switch could
recover.

`adviseBand` in [`@1delta-x/sdk`](../packages/sdk/src/band.ts) turns a realized-bump
distribution into the one sentence a maker can act on:

> 95% of 100 observed fills cleared within 10 bps of start — the last 9990 bps of the
> band never got used. Moving end there raises the floor by 999 and would have missed
> 0.0% of fills.

It reports `missedFraction` alongside every suggestion because tightening `end` is a
**trade**, not a free win: the tail you cut may be exactly the volatile moments the
floor existed for. The advice is descriptive, not causal — the observed depths were
produced *under the current band*, and changing the band changes filler behaviour.
Treat `missedFraction` as a lower bound on what tightening costs.

## 3. Format — first-price or second-price

A bid is a **bump**: how much concession the filler needs. So the winner is the
**lowest** bid, and "second price" means charging the runner-up's bump — slightly
more generous to the winner than its own bid.

`selectQuote` in [`@1delta-x/sdk`](../packages/sdk/src/auction.ts) implements both.
The trade-offs that actually apply here:

- **First-price / dutch encourages shading.** Note these are the *same* mechanism —
  a descending-clock dutch auction is strategically isomorphic to a first-price
  sealed bid (Vickrey 1961). Choosing "dutch instead of first-price" is not a choice.
  What a UniswapX-style clock adds is not the removal of shading but a **race**: with
  enough independent solvers, waiting to shade means losing the order.
- **Second-price is truthful** under private values, and with the *affiliated* values
  solver competition actually has (everyone prices the same liquidity), the linkage
  principle ranks its expected revenue **above** first-price. Both arguments favour it.
- **Second-price rings are self-enforcing.** Designate one bidder, everyone else bids
  the reserve, winner pays the reserve. A first-price ring must agree on a level and
  trust nobody defects. With a small, professional, mutually-known solver set — the
  textbook collusion environment — this is the strongest argument against it.
- **Second-price needs an honest auctioneer.** The classic attack is the auctioneer
  inserting a phantom bid just under the winner's and pocketing the spread. This is
  the main reason Vickrey is rare in the wild.

Three things blunt the last two, all of them already present:

**The reserve is cryptographically enforced.** `end` bounds every mechanism: the core
clamps whatever a price module returns and maps it through the maker's own signed
band. A reserve nobody can forge is unusual, and it is what makes second-price
survivable with a thin solver set.

**The clock is a second, tighter bound.** Under
[`ClockFlooredQuoteModule`](../packages/core/src/modules/ClockFlooredQuoteModule.sol)
the result is `min(quotedBump, clockBump)`, so a hostile or colluding cosigner cannot
do worse than plain dutch — not merely "no worse than the floor". A broken selection
rule in `selectQuote` cannot price outside either bound.

**Thin rounds grant nothing.** `selectQuote`'s `minBidders` (default 2 for
second-price) returns `bumpBps: 0` rather than a concession when too few distinct
bidders show up. A ring that arrives alone gets the maker's ambition. Note this is a
policy, not a guarantee — it counts submitters, and one operator can be several.

`verifyOutcome` re-runs the selection over the opened bid set. Publishing the
commitments plus the openings makes a cosigner **accountable with no proving system
at all**: anyone can recompute the winner and compare. A zero-knowledge proof of the
same statement is only worth its complexity when the losing bids must stay secret
*permanently* — a real market-maker demand, but not the first rung.

## Order of operations

1. Wire `orderFor` into `FillIndex`, run `resolveBumps()`, look at the distribution.
2. Feed it to `adviseBand` and tighten the bands that history says are decorative.
3. Only then argue about first-price vs. second-price — and settle it by A/B, since
   switching is a quoting-service deploy.
