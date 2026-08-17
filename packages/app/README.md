# @1delta-x/app

Reference intent-trading interface for UniversalSettlement.

One ladder, two sources of liquidity: **Uniswap v3 tick liquidity**, walked from
the pool's own initialized ticks, merged with **signed resting limit orders**
from the order book. The order form quotes against the merged ladder, previews
the part of a limit order that would rest — in position, in the ladder — and
signs.

```bash
pnpm --filter @1delta-x/app dev       # http://localhost:5173
pnpm --filter @1delta-x/app build     # typecheck + static bundle in dist/
```

No API key and no backend. A wallet is needed to sign; the book renders without one.

## What is real and what is not

| Part | Status |
| --- | --- |
| Pool ladder, mid, spread, block height | **Live.** Oku `cush_simulatePoolLiquidity`, polled every 12s |
| Token symbols, decimals, icons | **Live.** [1delta-DAO/token-lists](https://github.com/1delta-DAO/token-lists) |
| Wallet connection, chain switching, balances | **Live.** EIP-6963 + viem, read through the wallet |
| Ladder merge, fill simulation, resting/crossing split | **Real.** `src/lib/univ3.ts`, `src/lib/ladder.ts` |
| Order distribution: signing, resting, cancelling, fills | **Mocked in-browser.** `src/backend/mock.ts` |
| Allowances and settlement transactions | **Simulated.** No chain writes |

## The ladder

`cush_simulatePoolLiquidity` returns every initialized tick in the pool, with
`liquidity_net` and its Q96 sqrt price. [`src/lib/univ3.ts`](src/lib/univ3.ts)
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
  config/chains.ts      chainId ↔ Oku slug ↔ viem chain
  config/markets.ts     pinned pools per chain
  lib/univ3.ts          tick maths — the ladder itself
  lib/oku.ts            Oku JSON-RPC client
  lib/poolbook.ts       pool identity + ladder → PoolBook
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
chain id and the Uniswap v3 pool address. `base`/`quote` are how you want the
pair quoted; which of them is the pool's token0 is resolved from the pool's own
metadata, so the orientation cannot be configured wrong. Symbols, decimals and
icons follow from the token list. A new chain needs one row in
[`src/config/chains.ts`](src/config/chains.ts) — chain id, Oku slug, viem chain.

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
