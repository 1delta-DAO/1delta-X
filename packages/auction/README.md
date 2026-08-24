# @1delta-x/auction

Solver quote auctions for UniversalSettlement. A permissionless bid round, a
deterministic selection rule, and one cosigned quote as the only artifact that
reaches the chain.

```
signed bids (anyone)  →  AuctionRound  →  selectQuote  →  signQuote  →  takerData  →  fill
                                              │
                                              └→ SettledRound.bids  →  checkRound (anyone)
```

## What it is not

Not a venue. It holds no funds, sequences no fills, and cannot stop anyone
filling the order at its dutch price while a round is open. Losing a round costs
a filler **nothing** — no gas, no locked capital — because a losing bid never
reaches the chain.

## The four APIs

| | |
|---|---|
| `AuctionRound` | one round's state machine: `submit` (permissionless, signature-checked) → `settle` |
| `Auctioneer` | many rounds + the cosigner: `open` / `submit` / `settle` / `settleDue` / `prune` |
| `checkRound` | check the round's policy against the caller's, authenticate every published bid, then re-run the selection over them |
| SDK `quote.ts` | `quoteDigest` / `signQuote` / `encodeQuoteTakerData` / `verifyQuote` |
| SDK `bid.ts` | `bidDigest` / `signBid` / `verifyBid` — bids are signed, always |
| `QuoteSolver` | the solver side: price an order across `RouteSource`s, bid the smallest bump it can honour |

## Operator

```ts
const auctioneer = new Auctioneer({
  binding: { module: CLOCK_FLOORED_QUOTE_MODULE, chainId: 31 },
  signer: cosignerAccount,          // must equal the module's COSIGNER immutable
  quoteTtlSeconds: 60,
});

auctioneer.open({ orderHash, closesAt: now + 5, rule: "second-price" });
// ... bids arrive from anywhere ...
const { round, quote } = await auctioneer.settle(orderHash);
// `quote.takerData` is what the winner passes to fill(); publish `round` for audit.
```

## Filler

```ts
const bid = await signBid(myAccount, { orderHash, filler: me, bumpBps: 1_200, closesAt }, binding);
await auctioneer.submit(orderHash, bid);
// on win:
await settlement.write.fill([order, sig, amount, quote.takerData]);
```

**Every bid must be signed by the filler it names — there is no flag to turn
that off.** An unsigned bid set is forgeable from two sides: a rival can bid in
your name, win, and never fill (displacing you and costing the maker the
improvement); and an *operator* can fabricate a runner-up to justify a worse
Vickrey price — the classic shill attack, which an outcome check alone cannot
see. The bid digest binds `orderHash` and `closesAt`, so a bid is pinned to one
round and cannot be lifted into a later one.

A bid is a **bump**: how much concession you need, `0` = the maker's `start`,
`10000` = its `end`. **Lowest bid wins** — the filler that needs the least. Under
`second-price` (the default) the winner is charged the *runner-up's* bump, so
bidding your true break-even is the dominant strategy.

## What bounds a dishonest operator

Not this package — the settlement. A quote can only move the price **inside the
band the maker signed**, and under
[`ClockFlooredQuoteModule`](../modules/pricing/quotes/src/ClockFlooredQuoteModule.sol) no
further than the **dutch clock**. So a rigged, broken or offline round degrades
to a plain dutch fill. That is the property that makes it safe to point an order
at a cosigner nobody fully trusts.

On top of that, `checkRound(round, expected)` runs **three** independent checks
over a published round: it was settled under the rule and quorum the *caller*
expected (policy), every bid's signature recovers to the filler it names
(authenticity), and the winner and price follow from that set (arithmetic). All
three are needed — without the second, a fabricated runner-up passes the third
perfectly; and without the first, the third is run under a rule the operator
chose *after* seeing the bids.

```ts
await checkRound(round, { rule: "second-price", minBidders: 2 });
```

What it **cannot** detect: a bid the operator received and did not publish, and a
sybil — signatures prove a bid is not *impersonated*, not that the filler is a
real participant. Censorship and identity are the residual trust; the fixes are a
public commitment log and a filler registry, not a bigger receipt. See
[docs/quote-auctions.md](../../docs/quote-auctions.md).

## Thin rounds

Below `minBidders` (default 2 for Vickrey) a round grants **no** concession: a
ring that shows up alone gets the maker's ambition. Such a round settles with
`bumpBps: 0` and **no quote is signed** — signing a zero-bump quote would pin the
price and throw away the decay ramp, whereas signing nothing leaves the order on
its clock, which is the correct "the auction found nothing" outcome.

## Solving

`QuoteSolver` turns a route quote into an honest bid. The economics are the
whole of it: at bump `b` a SELL order's maker must receive
`start − (start−end)·b/BPS`, so the smallest bump a solver can concede is where
that meets what its route yields. `minimumBump` solves for it (and mirrors for a
BUY order's rising input band), always **rounding up** so a rounding error can
never leave the solver short of what it committed to deliver.

```ts
const solver = new QuoteSolver({ account, binding, routes: [sushi, nordstern] });
const result = await solver.bidFor(order, { orderHash, closesAt });
if (result) await post(result.bid);      // and keep result.quote to execute with
```

### Gas

A solver pays gas but can only express cost through the bump, so gas is carried
into whichever token the band prices in and folded in **directionally**:

| order | band | effect of gas |
|---|---|---|
| SELL | falling output | the solver **provides less** — gas comes off what its route left it to deliver with |
| BUY | rising input | the solver **takes more** — gas adds to what the maker must pay it |

Both push the bump up, which is the only honest way to say "this costs me more".

```ts
const solver = new QuoteSolver({
  account, binding, routes: defaultRouteSources(),
  gas: {
    gasPriceWei,                     // yours to keep fresh; this package does no chain reads
    settlementGasUnits: 200_000n,    // MEASURE this — see below
    nativePriceInToken: rate,        // band-token units per 1e18 wei; omit to resolve live
  },
});
```

Route gas comes from the source when it reports one (Sushi returns `tx.gas`),
else `routeGasUnits`; `settlementGasUnits` is added on top since the solver pays
for both in one transaction. Its 200k default is a *placeholder* — a fill with
items or a callback costs more, and an understated overhead is a bid the solver
cannot profitably honour.

Omit `nativePriceInToken` and the rate is resolved through the solver's own route
sources. That quotes a **whole** native token rather than the gas amount itself,
because aggregators routinely fail to route dust and a few hundred thousand wei
is dust. If no source can price native, `bidFor` returns `null` — it will **not**
fall back to pricing gas as free, which would be a bid that loses money.

Everything rounds toward the solver being able to honour the bid: gas is ceiled,
and it is applied *before* `minProfitBps`, since margin is profit on the net.

Two behaviours worth knowing:

- **Not bidding is a first-class outcome.** No route, an unpriceable order shape,
  an unpriceable gas rate, or a route that cannot clear the maker's floor *after
  gas* all return `null` rather than a desperate `10000`. Winning a round you
  cannot fill costs the maker the improvement it would otherwise have had.
- **Bid your break-even.** Under the default Vickrey rule you are charged the
  *runner-up's* bump, not your own, so `minProfitBps: 0` is the dominant
  strategy. Shading up only loses rounds you would have been paid for.

`QuoteSolver` does **not** execute. The winning fill is yours — you hold the
route payload, the key and the gas policy.

⚠ **The route's amount can go stale.** What the maker actually pays is resolved
*during* the fill — it rises with the clock on a BUY order, comes from the live
balance on a proportional leg, and shrinks on a partial fill sized after the
quote. The aggregator baked its own figure into the calldata. Executing through
[`AggregatorFillSolver`](../solvers/src/aggregator/AggregatorFillSolver.sol),
pass `RoutePlan.amountInOffset` so the contract rewrites the amount to what
arrived; leave it `NO_PATCH` for a fixed-input SELL filled in full, where the
quote is already exact.

⚠ **Set `recipient` to whatever will actually execute.** Aggregators bake the
recipient into the calldata they return, so a route quoted for your EOA sends the
swap output to your EOA. Filling through a callback solver
([`AggregatorFillSolver`](../solvers/src/aggregator/AggregatorFillSolver.sol))
then reverts `InsufficientOutput` — funds are safe, the round is lost. The
default is the bidding account, which is correct only for an inventory solver
filling from its own balance.

### Route sources

`RouteSource` is the seam:

```ts
interface RouteSource {
  name: string;
  quote(req: RouteRequest): Promise<RouteQuote | null>;   // null = cannot serve
}
```

**`defaultRouteSources()` ships Sushi + Nordstern** — the floor a competing
solver has to beat. `QuoteSolver` queries both in parallel and bids off the
better number, so nobody wins a round just by being the only participant; they
win by routing better than the best public aggregator.

```ts
const solver = new QuoteSolver({ account, binding, routes: defaultRouteSources() });
```

Both adapters are deliberately thin — one GET, a timeout, and a number. No
proxy, no flash-loan or margin machinery. Add your own source for private
inventory or a venue we do not cover; a source that fails is skipped, not fatal,
so the default degrades to whichever aggregator is up rather than to nothing.

**Three API differences that misprice silently if crossed**, all pinned by tests:

| | Sushi | Nordstern |
|---|---|---|
| slippage | decimal (`0.5%` → `0.005`) | percent (`0.5%` → `0.5`) |
| native | `0xEeee…EEeE` placeholder | zero address |
| no recipient | `quote/v6` (takes none) | `/aggregator` with a dummy `from` |

That last row is normalised so the two behave **equivalently**: pass a zero or
malformed `recipient` and both return a price-only quote — a number with **no
`route`**. Dropping the route there is the safety property, not an omission: the
calldata would be built to deliver the output to the placeholder, so it must
never reach a caller that might execute it. Pass a real recipient and both
return an executable route.

And one precision note: Nordstern returns `toAmount` as a **JSON number** that
can carry a fractional part. It is **floored**, never rounded — these are amounts
the solver promises to deliver against, so rounding has to land on the side it
can honour. Above 2^53 the value has already lost precision upstream, so carry a
non-zero `minProfitBps` when quoting 18-decimal tokens from it.
