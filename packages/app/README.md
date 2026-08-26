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
| Allowances and settlement transactions | **Simulated.** No chain writes |

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
  wallet/               EIP-6963 discovery, connection, chain switch, balances
  hooks/                usePoolBook, useChainPools, useTokenIndex, useTicket, …
  components/           Header, MarketPicker, Stats, OrderForm, OrderBook, Orders
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
