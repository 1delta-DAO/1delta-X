# @1delta-x/auction

Solver quote auctions for UniversalSettlement. A permissionless bid round, a
deterministic selection rule, and one cosigned quote as the only artifact that
reaches the chain.

```
bids (anyone)  →  AuctionRound  →  selectQuote  →  signQuote  →  takerData  →  fill
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
| `AuctionRound` | one round's state machine: `submit` (permissionless) → `settle` |
| `Auctioneer` | many rounds + the cosigner: `open` / `submit` / `settle` / `settleDue` / `prune` |
| `checkRound` | re-run a published round's selection over its published bids |
| SDK `quote.ts` | `quoteDigest` / `signQuote` / `encodeQuoteTakerData` / `verifyQuote` |

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
auctioneer.submit(orderHash, { filler: me, bumpBps: 1_200 });
// on win:
await settlement.write.fill([order, sig, amount, quote.takerData]);
```

A bid is a **bump**: how much concession you need, `0` = the maker's `start`,
`10000` = its `end`. **Lowest bid wins** — the filler that needs the least. Under
`second-price` (the default) the winner is charged the *runner-up's* bump, so
bidding your true break-even is the dominant strategy.

## What bounds a dishonest operator

Not this package — the settlement. A quote can only move the price **inside the
band the maker signed**, and under
[`ClockFlooredQuoteModule`](../core/src/modules/ClockFlooredQuoteModule.sol) no
further than the **dutch clock**. So a rigged, broken or offline round degrades
to a plain dutch fill. That is the property that makes it safe to point an order
at a cosigner nobody fully trusts.

On top of that, `checkRound` lets anyone re-run the selection over the published
bids and catch a swapped winner or a shill price. What it **cannot** detect is a
bid that never entered the published set — censorship is the residual trust, and
the fix is a public commitment log, not a bigger receipt. See
[docs/quote-auctions.md](../../docs/quote-auctions.md).

## Thin rounds

Below `minBidders` (default 2 for Vickrey) a round grants **no** concession: a
ring that shows up alone gets the maker's ambition. Such a round settles with
`bumpBps: 0` and **no quote is signed** — signing a zero-bump quote would pin the
price and throw away the decay ramp, whereas signing nothing leaves the order on
its clock, which is the correct "the auction found nothing" outcome.
