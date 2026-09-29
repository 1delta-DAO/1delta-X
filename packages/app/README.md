# @1delta-x/app

Reference intent-trading interface for UniversalSettlement.

One ladder, several sources of liquidity: **Uniswap v3** and **SushiSwap v3**
tick liquidity, each walked from the pool's own initialized ticks, merged with
**signed resting limit orders** from the order book. Every rung keeps its venue,
so the best bid and the best ask can be in different pools and you can still see
which. The order form quotes against the merged ladder, previews
the part of a limit order that would rest — in position, in the ladder — and
signs.

```bash
pnpm run app                          # http://localhost:5175
pnpm --filter @1delta-x/app build     # typecheck + static bundle in dist/
```

No API key. A wallet is needed to sign; the book renders without one.

## Deploying

The build output carries its own tiny worker, [`public/_worker.js`](public/_worker.js)
→ `dist/_worker.js`, which proxies `/api/oku/*`. **Deploy `dist` as-is** and it
comes along; there is nothing to configure.

It exists because Oku allow-lists CORS origins — `http://localhost:*` and
`https://oku.trade` receive an `access-control-allow-origin` header and every
other origin receives none, so a browser on a deployed domain has its Oku
responses discarded before this app sees them. That is their policy, and no
client-side change can work around it. A worker is server-side, where CORS does
not apply. Vite's dev server proxies the same path, so the request path is
identical in both environments rather than production being the one case never
exercised locally.

It deliberately is **not** a `functions/` directory: Pages reads that only from
the configured project root, so it is silently dropped whenever the root is not
this package — and a dropped proxy fails quietly, with `GET` falling through to
the SPA handler and `POST` returning 405.

After deploying, this should return a block number:

```bash
curl -X POST https://<your-domain>/api/oku/rootstock/cush/liveBlock \
  -H 'content-type: application/json' -d '{"id":1,"params":[]}'
```

## What is real and what is not

| Part | Status |
| --- | --- |
| Uniswap v3 ladder | **Live.** Oku `cush_simulatePoolLiquidity`, polled every 12s |
| SushiSwap v3 ladder | **Live.** The v3 subgraph, same tick maths, same polling |
| Token symbols, decimals, icons | **Live.** [1delta-DAO/token-lists](https://github.com/1delta-DAO/token-lists) |
| Wallet connection, chain switching, balances | **Live.** EIP-6963 + viem, read through the wallet |
| Ladder merge, fill simulation, resting/crossing split | **Real.** `src/lib/univ3.ts`, `src/lib/ladder.ts` |
| Order distribution: signing, resting, cancelling, fills | **Mocked in-browser.** `src/backend/mock.ts` |
| ERC-20 allowances | **Live.** A real `approve`, capped at the exact input of the order being signed |
| Settlement transactions | **Simulated.** Signing is real; nothing is broadcast to a filler |
| Pre-audit disclosure | **Live.** Acknowledgement gate, reopenable from the strip |
| Draw Terms | **Live.** Own page at `/terms.html`, rendered from `TC.md` |

## Pre-audit posture

The Rootstock beta runs on contracts that have not been audited, so the
interface is built to bound what an unaudited contract can reach rather than to
assume it is safe.

**Exact-amount allowances.** `approve` is called with the input of the single
order about to be signed — never `type(uint256).max`, never a rounded-up
headroom. The spender is Permit3, which is what actually pulls the maker's
input. Every trade therefore costs one approval, and an order that is signed but
never filled leaves no standing allowance behind. A TWAP approves one slice at a
time, because one slice is what each signature commits.

The amount approved and the amount signed come from the same `plan` value in
`App.tsx`. Deriving them separately is how an interface ends up approving one
number and signing another, which under this policy is not cosmetic — it is a
fill that cannot happen.

**The prize draw.** `config/promotion.ts` is the single place the draw is
described, and `components/Raffle.tsx` is the only place it is mentioned in the
trading UI. `TC.md` fixes no numbers on purpose — §4.2 leaves the qualifying
criteria to "official channels" and §2.1 does the same for the period — so every
figure there is a display string the promoter writes, not a number the app
computes, and `VITE_PROMOTION` overrides it at deploy time without a code
change. `{"live":false}` removes every mention of the draw, including the bullet
in the acknowledgement gate: with no draw running, describing one is not a
disclosure but an advertisement for something that does not exist.

The copy has one distinction to hold: a draw is not a reward. Trading qualifies
an address for a random selection, it does not earn anything, and more volume
does not improve the odds within a draw. "Draw", "qualify" and "at random" are
load-bearing words there, not decoration.

**Disclosure.** A first visit is gated on reading and accepting the pre-audit
warning; `ACK_VERSION` in `components/PreAudit.tsx` is bumped whenever the text
changes, so nobody inherits consent to wording they never saw. A strip stays
above the chrome for the rest of the session and reopens that same disclosure
read-only — a warning you can only ever see once is one you cannot check back
on. The strip links there and nowhere else: the draw's terms are a marketing
document, and putting them in a risk banner would say the audit status and the
draw are one subject. The promotion terms are rendered
from `TC.md` at the repository root — the site shows that file rather than a
copy of it, because the one text that must not drift is the one people agreed
to.

**The terms are a page, not a dialog.** `terms.html` is a second Vite entry
point, so `/terms.html` is a real URL that can be announced, pasted into a
support reply and unfurled, and it opens in a new tab so reading it never
interrupts a half-built order. Cloudflare Pages serves it at `/terms` too. A
second entry rather than a router: the document has no wallet, feed or order
state, so a route would only buy the ability to ship the 350 KB trading bundle
to someone who came to read a legal page.

That split is why `components/TermsLink.tsx` imports nothing. The trading app
needs the *address* of the document, not the document; exporting the link from
the page that holds the text pulls the whole of `TC.md` into the trading bundle
for the sake of an href, which is exactly what the first version did.

`lib/markdown.tsx` covers only the syntax `TC.md` actually uses and renders
anything else as the literal text it is — for a legal document that is the right
failure, since a paragraph showing its own asterisks is readable and one
silently dropped by a parser is not.

## The ladder

Both venues return every initialized tick in the pool. Oku gives each tick's Q96
sqrt price directly; the subgraph gives a tick *index*, so
[`getSqrtRatioAtTick`](src/lib/univ3.ts) ports Uniswap's integer `TickMath` —
reconstructing it in floating point would corrupt every rung, because the ladder
*differences* adjacent sqrt prices. [`src/lib/univ3.ts`](src/lib/univ3.ts)
accumulates those into per-range liquidity, walks outward from the current
price, and converts each range into one rung:

- **Size** is the base-token amount that range can absorb or supply. A range
  below the current price holds only token1, but pushing the price down through
  it takes exactly the token0 that range *would* hold — so one amount formula
  serves bids and asks alike, and both sides of the ladder are comparable.
- **Price** is the range's average execution price (`quote / base`), which is
  what the fill walk needs. Quoting the marginal price instead would
  systematically over-quote every rung.

This matters. A bucketed price/size feed is a *rendering* of the same tick data,
but every bucket inside one position's range comes out the same size — the
ladder reads as synthetic even though the numbers are real. Walking the ticks
gives one rung per range where liquidity is genuinely constant, so sizes vary by
60–250% across the visible ladder and a concentrated position shows up as a
cliff.

## Two venues, one ladder

A market names its pools in priority order. Each is walked independently, then
the rungs are merged into one sorted ladder with the venue tag intact — hover a
row for the exact pool address, or read the legend under the book.

The first pool listed is the **primary**: its token metadata resolves the pair.
Every other pool is matched to it **by token address, not symbol** — Oku calls
Rootstock's USDT0 `USD0` and the Sushi subgraph calls it `USD₮0`, and they agree
on the address.

## Nothing waits on the slowest thing

Every feed lands on its own. The book renders from whatever has arrived and
fills in as the rest catches up:

- **Per venue.** Each pool is fetched and committed independently, on its own
  poll cycle. One `Promise.all` over the venues is the version that makes a fast
  Uniswap ladder wait on a slow Sushi subgraph — the exact coupling worth
  avoiding, since the whole point of aggregating venues is that they are
  independent. Measured with the subgraph artificially slowed 8s: Uniswap rungs
  are on screen at **2s**, Sushi joins at **10s**, and the network dot reads
  *partial* in between.
- **Per market.** The picker shows each pair the moment its own pool metadata
  resolves, rather than after the slowest market on the chain.
- **Per token.** Balances and token-list logos each settle on their own.

Every venue is also **raced against a 20s deadline**, not merely sent an abort
signal. Aborting only helps if whatever is slow is watching for it; the race is
what guarantees the venue resolves either way. A hung endpoint therefore turns
into `SushiSwap v3 0.30% 0x6d77…fd71 — timed out after 20s` in the legend
instead of a spinner that never stops.

A venue that fails does not fail the market: it is recorded with its reason, the
legend shows it in red with that reason spelled out, and the book renders from
the rest. A failed *refresh* keeps the venue's last good rungs on screen — depth
that was true a moment ago beats a blank book on one bad poll.

**Only Rootstock works out of the box.** Of SushiSwap's v3 subgraphs, the
Goldsky-hosted ones are public and the rest sit behind The Graph's gateway, which
needs an API key. Rootstock is the one chain where both this app trades *and*
Sushi publishes keylessly. Ethereum and BNB Chain carry their gateway URLs and
light up when `VITE_GRAPH_KEY` is set; without it they are reported as absent
rather than tried and 401'd.

```bash
VITE_GRAPH_KEY=… pnpm run app     # enables SushiSwap on the gateway chains
```

## Replacing the mock

Everything the UI needs from order distribution goes through one interface,
[`src/backend/api.ts`](src/backend/api.ts):

```ts
interface OrderbookApi {
  orders(marketId?): RestingOrder[];
  fills(marketId?): Fill[];
  subscribe(listener): () => void;
  place(req): Promise<RestingOrder>;
  cancel(orderHash): Promise<void>;
  recordTake(req): void;
  observe(obs): void;
}
```

That is deliberately the shape `@1delta-x/orderbook`'s `Book` already exposes —
an in-memory map keyed by order hash, with add/remove listeners. A real client
(REST/WS against `@1delta-x/orderbook-server`, or a Waku transport) is an
implementation of this interface plus EIP-712 signing in `place`. No component
changes.

The mock is not a simulation of the settlement contract. It holds orders,
retracts them for free, and advances fills as the *live* pool mid moves through
resting prices — so what you watch reacts to the real market rather than to a
timer of its own.

## Layout

```
src/
  config/chains.ts      chainId ↔ Oku slug ↔ Sushi subgraph ↔ viem chain
  config/markets.ts     pinned pools per chain, one or more venues each
  lib/univ3.ts          tick maths + TickMath — the ladder itself
  lib/oku.ts            Oku JSON-RPC client (Uniswap v3 ticks)
  lib/sushi.ts          SushiSwap v3 subgraph client
  lib/poolbook.ts       every venue → one merged, venue-tagged PoolBook
  lib/ladder.ts         merge, walk, quote, clearing price, depth
  lib/tokens.ts         1delta token lists, lazily loaded and cached
  backend/api.ts        the order-distribution seam
  backend/mock.ts       in-browser stand-in
  lib/markdown.tsx      the markdown subset TC.md uses, rendered dependency-free
  terms.tsx             second entry point — the standalone /terms.html page
  wallet/               EIP-6963 discovery, connection, chain switch, allowances, balances
  hooks/                usePoolBook, useChainPools, useTokenIndex, useTicket, …
  config/promotion.ts   the prize draw, as the UI is allowed to describe it
  components/           Header, MarketPicker, Stats, OrderForm, OrderBook, Orders,
                        PreAudit (banner + acknowledgement gate), Raffle,
                        Terms (the /terms.html page), TermsLink (just the href)
  styles.css            the whole design system, dark + light
```

## Adding a market

Append to `MARKETS` in [`src/config/markets.ts`](src/config/markets.ts) with the
chain id and one or more pools:

```ts
{
  id: "rsk-30-wrbtc-usd0",
  chainId: 30,
  pools: [
    { dex: "uniswap-v3",  address: "0xaef6…", feeBps: 3000 },
    { dex: "sushiswap-v3", address: "0x6d77…", feeBps: 3000 },
  ],
  base: "WRBTC",
  quote: "USD0",
}
```

`base`/`quote` are how you want the pair quoted; which of them is the primary
pool's token0 is resolved from the pool's own metadata, so the orientation
cannot be configured wrong. Symbols, decimals and icons follow from the token
list. A new chain needs one row in [`src/config/chains.ts`](src/config/chains.ts)
— chain id, Oku slug, viem chain, and optionally a SushiSwap subgraph URL.

## Notes on the feeds

- Oku serves a subset of its chain list at any one time. `arbitrum`, `base`,
  `optimism` and `polygon` were all returning `empty non-error response` when
  these markets were picked; the configured chains are ones that answer.
- Very large pools occasionally time out on `simulatePoolLiquidity`. A failed
  poll keeps the last good ladder on screen and marks the network dot rather
  than blanking the book under someone mid-order.
- Token lists are large (Ethereum is ~6 MB). They load off the render path and
  only the tokens actually referenced are persisted, so a reload does not
  re-download megabytes to learn the same six symbols. Until one arrives, tokens
  render as a generated monogram — which is also the fallback when a logo host
  fails.
- Balances are read through the connected wallet's own provider, so the app
  carries no RPC endpoints and no key. They only resolve when the wallet is on
  the market's chain; the sign button becomes "Switch to …" when it is not.
