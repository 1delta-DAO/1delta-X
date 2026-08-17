import { useCallback, useEffect, useMemo, useState } from "react";

import { orderbook } from "./backend/mock";
import { Header } from "./components/Header";
import { MarketPicker } from "./components/MarketPicker";
import { OrderBook } from "./components/OrderBook";
import { OrderForm, type Gate, type Receipt } from "./components/OrderForm";
import { Orders } from "./components/Orders";
import { Stats } from "./components/Stats";
import { chainLabel } from "./config/chains";
import { symbolsOn } from "./config/markets";
import { useChainPools } from "./hooks/useChainPools";
import { useFills, useRestingOrders } from "./hooks/useOrderbook";
import { usePoolBook } from "./hooks/usePoolBook";
import { useTheme } from "./hooks/useTheme";
import { useTicket, type TicketDeps } from "./hooks/useTicket";
import { useTokenIndex } from "./hooks/useTokenIndex";
import { fmtAmt, fmtPrice } from "./lib/format";
import { randomHash } from "./lib/hash";
import { depth, mergeLadder, quote as quoteOrder, restingLabel } from "./lib/ladder";
import { useBalances } from "./wallet/useBalances";
import { useWallet } from "./wallet/useWallet";

/** Slippage floor quoted on market orders. */
const SLIPPAGE_BPS = 50;

const DAY_MS = 24 * 3600_000;

/** Past this the pool ladder is old enough to say so rather than imply it is live. */
const STALE_MS = 30_000;

const EMPTY_DEPS: TicketDeps = { bids: [], asks: [], tick: 4, balances: {} };

export default function App() {
  const [theme, toggleTheme] = useTheme();
  const wallet = useWallet();

  // The ticket sizes its automatic limit price against the merged ladder and its
  // default amount against wallet balances — both of which are fetched for
  // whatever the ticket currently points at. Feeding them back through state
  // breaks the cycle: the ticket reads them one render behind.
  const [deps, setDeps] = useState<TicketDeps>(EMPTY_DEPS);
  const ticket = useTicket(deps);
  const chainId = ticket.chainId;

  const pools = useChainPools(chainId);
  const tokens = useTokenIndex(chainId, pools.metas);
  const pool = usePoolBook(ticket.market, pools.metas[ticket.marketId]);

  const onChain = wallet.chainId === chainId;
  const rawBalances = useBalances({
    provider: wallet.provider,
    address: wallet.address,
    chainId,
    onChain,
    tokens: tokens.tokens,
  });

  const balances = useMemo(() => {
    const out: Record<string, number | undefined> = {};
    for (const symbol of symbolsOn(chainId)) {
      const address = tokens.view(symbol).address;
      out[symbol] = address ? rawBalances[address.toLowerCase()] : undefined;
    }
    return out;
  }, [chainId, tokens, rawBalances]);

  const resting = useRestingOrders(ticket.marketId);
  const fills = useFills();
  const allOrders = useRestingOrders();

  const merged = useMemo(
    () => (pool.book ? mergeLadder(pool.book, resting) : { bids: [], asks: [] }),
    [pool.book, resting],
  );
  const tick = pool.book?.tick ?? 4;

  useEffect(() => {
    setDeps({ bids: merged.bids, asks: merged.asks, tick, balances });
  }, [merged, tick, balances]);

  // Your activity spans every market, so the grid each one prices on has to
  // outlive the ladder currently on screen — otherwise an order on another
  // market renders at the precision of whatever you happen to be looking at.
  const [ticks, setTicks] = useState<Record<string, number>>({});

  // Feed the live mid back into the book: resting orders fill as the real market
  // moves through their price, rather than drifting on a timer of their own.
  useEffect(() => {
    const book = pool.book;
    if (!book) return;
    setTicks((t) => (t[ticket.marketId] === book.tick ? t : { ...t, [ticket.marketId]: book.tick }));
    orderbook.observe({
      marketId: ticket.marketId,
      mid: book.mid,
      tick: book.tick,
      step: book.step,
      depth: depth(book.bids).total,
    });
  }, [pool.book, ticket.marketId]);

  const ready = merged.bids.length > 0 && merged.asks.length > 0;

  const q = useMemo(() => {
    if (!ready || ticket.amount <= 0) return null;
    return quoteOrder({
      bids: merged.bids,
      asks: merged.asks,
      side: ticket.side,
      amountIn: ticket.amount,
      limit: ticket.mode === "market" ? null : ticket.limit,
      slippageBps: SLIPPAGE_BPS,
    });
  }, [ready, merged, ticket.side, ticket.amount, ticket.mode, ticket.limit]);

  const [signing, setSigning] = useState(false);
  const [receipt, setReceipt] = useState<Receipt | null>(null);
  const [connectRequest, setConnectRequest] = useState(0);

  // A receipt describes one ticket; switching market, side or type makes it stale.
  useEffect(() => setReceipt(null), [ticket.marketId, ticket.side, ticket.mode]);

  const sign = useCallback(async () => {
    if (!q || !pool.book) return;
    setSigning(true);
    try {
      const { marketId, side, mode, payToken, recvToken, amount } = ticket;
      const price = ticket.limit ?? pool.book.mid;

      if (mode === "twap") {
        const size = side === "sell" ? amount : amount / price;
        const order = await orderbook.place({
          marketId,
          side,
          type: "twap",
          size,
          price,
          ttlMs: ticket.slices * ticket.everyMin * 60_000 + 60_000,
          slices: { total: ticket.slices, everyMin: ticket.everyMin },
        });
        setReceipt({
          hash: order.id,
          headline: `${fmtAmt(amount)} ${payToken} in ${ticket.slices} slices, ${ticket.everyMin} min apart`,
          detail: `first slice at ${fmtPrice(price, tick)} ${ticket.market.quote}/${ticket.market.base}`,
          note: "scheduled · 0 gas",
        });
        ticket.clearAmount();
        return;
      }

      // The crossing part settles now; only the remainder rests. Placing the
      // whole size as a resting order instead would hide the fill the taker
      // just got, and quoting it as fully filled would invent one.
      if (q.crossedBase > 0) {
        orderbook.recordTake({ marketId, side, size: q.crossedBase, price: q.avg, bySource: q.bySource });
      }

      let hash = randomHash();
      if (mode === "limit" && q.resting && ticket.limit) {
        const order = await orderbook.place({
          marketId,
          side,
          type: "limit",
          size: q.resting.size,
          price: ticket.limit,
          ttlMs: DAY_MS,
        });
        hash = order.id;
      } else {
        await new Promise((r) => setTimeout(r, 650));
      }

      setReceipt({
        hash,
        headline: `${fmtAmt(q.totalIn)} ${payToken} → at least ${fmtAmt(q.minReceived)} ${recvToken}`,
        detail: q.resting
          ? `${restingLabel(q.resting).toLowerCase()} at ${fmtPrice(q.resting.price, tick)}`
          : undefined,
        note: q.resting ? "resting · free to cancel" : "settled · 0 gas",
      });
      ticket.clearAmount();
    } finally {
      setSigning(false);
    }
  }, [pool.book, q, tick, ticket]);

  const cancel = useCallback((orderHash: string) => {
    void orderbook.cancel(orderHash);
  }, []);

  const tickOf = useCallback((marketId: string) => ticks[marketId] ?? 4, [ticks]);

  // Signing is gated on the wallet being connected and on the right chain — the
  // order is chain-bound, so a signature from the wrong one is not a near miss.
  const gate: Gate | null = !wallet.address
    ? { label: "Connect wallet", action: () => setConnectRequest((n) => n + 1) }
    : !onChain
      ? { label: `Switch to ${chainLabel(chainId)}`, action: () => void wallet.switchChain(chainId) }
      : null;

  const live: "live" | "stale" | "down" = pool.error
    ? "down"
    : pool.age !== null && pool.age > STALE_MS
      ? "stale"
      : "live";

  return (
    <>
      <Header
        chainId={chainId}
        onChainChange={ticket.setChain}
        wallet={wallet}
        block={pool.book?.block ?? null}
        live={live}
        theme={theme}
        onToggleTheme={toggleTheme}
        requestConnect={connectRequest}
      />

      <main>
        <div className="toolbar">
          <MarketPicker
            chainId={chainId}
            selected={ticket.marketId}
            tokens={tokens}
            onSelect={ticket.selectMarket}
          />
        </div>

        <Stats bids={merged.bids} asks={merged.asks} base={ticket.market.base} venue={ticket.market.venue} />

        <div className="deck">
          <OrderForm
            ticket={ticket}
            quote={q}
            tokens={tokens}
            balances={balances}
            tick={tick}
            mid={pool.book?.mid ?? null}
            ready={ready}
            signing={signing}
            receipt={receipt}
            gate={gate}
            onSign={sign}
          />
          <OrderBook
            bids={merged.bids}
            asks={merged.asks}
            base={ticket.market.base}
            quote={ticket.market.quote}
            tick={tick}
            side={ticket.side}
            preview={q?.resting ?? null}
            onPickPrice={ticket.takePriceFromLadder}
            loading={pool.loading || pools.loading}
            error={pool.error}
            block={pool.book?.block ?? null}
            onRetry={pool.refresh}
          />
        </div>

        <Orders orders={allOrders} fills={fills} tickOf={tickOf} tokens={tokens} onCancel={cancel} />
      </main>

      <footer>
        <p>1delta X · reference interface for UniversalSettlement</p>
        <p>
          Pool rungs are built from live Uniswap v3 tick liquidity via the{" "}
          <a href="https://oku.trade/api" target="_blank" rel="noreferrer">
            Oku API
          </a>
          ; token metadata and icons come from{" "}
          <a href="https://github.com/1delta-DAO/token-lists" target="_blank" rel="noreferrer">
            1delta-DAO/token-lists
          </a>
          . Order distribution runs against an in-browser mock of the orderbook backend, so signing, resting
          and cancelling are simulated locally and nothing is broadcast.
        </p>
      </footer>
    </>
  );
}
