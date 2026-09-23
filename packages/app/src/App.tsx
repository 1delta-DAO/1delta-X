import { useCallback, useEffect, useMemo, useState } from "react";

import { buildSoftCancel, signOrder, signSoftCancel } from "@1delta-x/sdk";
import { formatUnits, zeroAddress } from "viem";

import { orderbook } from "./backend/mock";
import type { SignedOrder } from "./backend/api";
import { Header } from "./components/Header";
import { MarketPicker } from "./components/MarketPicker";
import { OrderBook } from "./components/OrderBook";
import { OrderForm, type AllowanceView, type Gate, type Receipt } from "./components/OrderForm";
import { Orders } from "./components/Orders";
import { PreAuditGate, PreAuditStrip, useAcknowledgement } from "./components/PreAudit";
import { RaffleNotice } from "./components/Raffle";
import { Stats } from "./components/Stats";
import { TERMS_UPDATED, TermsDialog } from "./components/Terms";
import { chainLabel } from "./config/chains";
import { deploymentFor } from "./config/deployments";
import { symbolsOn } from "./config/markets";
import { useChainPools } from "./hooks/useChainPools";
import { useFills, useRestingOrders } from "./hooks/useOrderbook";
import { usePoolBook } from "./hooks/usePoolBook";
import { useTheme } from "./hooks/useTheme";
import { useTicket, type TicketDeps } from "./hooks/useTicket";
import { useTokenIndex } from "./hooks/useTokenIndex";
import { fmtAmt, fmtPrice } from "./lib/format";
import { depth, mergeLadder, quote as quoteOrder, restingLabel } from "./lib/ladder";
import { buildOrder, toWei } from "./lib/order";
import { useAllowance } from "./wallet/useAllowance";
import { useBalances } from "./wallet/useBalances";
import { useSigner } from "./wallet/useSigner";
import { useWallet } from "./wallet/useWallet";

/** Slippage floor quoted on market orders. */
const SLIPPAGE_BPS = 50;

const DAY_MS = 24 * 3600_000;

/** How long a market order stays live, and how long its auction runs. */
const MARKET_TTL_SECONDS = 60;

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

  const signer = useSigner(wallet.provider, wallet.address, chainId, onChain);
  const deployment = deploymentFor(chainId);

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

  const payMeta = tokens.view(ticket.payToken);

  /**
   * What the next signature actually commits.
   *
   * The approval and the order are both sized from this one value. Deriving
   * them separately is how an interface ends up approving one amount and
   * signing another — which, under an exact-amount allowance policy, is not a
   * cosmetic mismatch but a fill that cannot happen.
   */
  const plan = useMemo(() => {
    if (!q || !pool.book || ticket.amount <= 0 || q.totalIn <= 0) return null;
    const price = ticket.limit ?? pool.book.mid;

    // A TWAP signs one slice at a time, so the slice — not the notional — is
    // what gets committed and what gets approved.
    if (ticket.mode === "twap") {
      const amountIn = ticket.amount / ticket.slices;
      const out = ticket.side === "sell" ? amountIn * price : amountIn / price;
      return {
        kind: "twap" as const,
        price,
        amountIn,
        targetOut: out,
        minOut: out,
        ttlSeconds: ticket.everyMin * 60 + 60,
        decaySeconds: 0,
      };
    }
    // Only the part that does not cross now is signed; the rest settles against
    // the book on screen.
    if (ticket.mode === "limit" && q.resting && ticket.limit) {
      const amountIn = ticket.side === "sell" ? q.resting.size : q.resting.size * ticket.limit;
      const out = ticket.side === "sell" ? q.resting.size * ticket.limit : q.resting.size;
      return {
        kind: "resting" as const,
        price,
        amountIn,
        targetOut: out,
        minOut: out,
        ttlSeconds: DAY_MS / 1000,
        decaySeconds: 0,
      };
    }
    // A market order is a short dutch auction: the maker names the price the
    // book shows now and a floor, and lets fillers compete in between.
    return {
      kind: "market" as const,
      price,
      amountIn: q.totalIn,
      targetOut: q.crossedOut,
      minOut: q.minReceived,
      ttlSeconds: MARKET_TTL_SECONDS,
      decaySeconds: MARKET_TTL_SECONDS,
    };
  }, [q, pool.book, ticket.amount, ticket.everyMin, ticket.limit, ticket.mode, ticket.side, ticket.slices]);

  // Permit3 is what pulls the maker's input, so Permit3 is what gets approved.
  // With nothing deployed nothing can pull, so there is no approval to ask for
  // and the signature is a demonstration either way.
  const spender = deployment && deployment.permit3 !== zeroAddress ? deployment.permit3 : null;

  const allowanceState = useAllowance({
    provider: wallet.provider,
    owner: wallet.address,
    chainId,
    onChain,
    token: payMeta.address ?? null,
    spender,
  });

  // PRE-AUDIT POLICY: approve exactly this order and nothing more. An unaudited
  // contract can then only ever reach the trade the user was looking at when
  // they approved it, and no allowance outlives an order that never fills.
  const requiredWei = useMemo(
    () => (plan && payMeta.decimals !== undefined ? toWei(plan.amountIn, payMeta.decimals) : 0n),
    [plan, payMeta.decimals],
  );

  const allowance: AllowanceView = {
    spender,
    required: plan?.amountIn ?? 0,
    current:
      allowanceState.allowance !== undefined && payMeta.decimals !== undefined
        ? Number(formatUnits(allowanceState.allowance, payMeta.decimals))
        : undefined,
    covered: requiredWei > 0n && allowanceState.allowance !== undefined && allowanceState.allowance >= requiredWei,
    approving: allowanceState.approving,
    error: allowanceState.error,
    approve: () => void allowanceState.approve(requiredWei),
  };

  const [signing, setSigning] = useState(false);
  const [receipt, setReceipt] = useState<Receipt | null>(null);
  const [signError, setSignError] = useState<string | null>(null);
  const [connectRequest, setConnectRequest] = useState(0);
  const [termsOpen, setTermsOpen] = useState(false);
  const [riskOpen, setRiskOpen] = useState(false);
  const { acknowledged, accept } = useAcknowledgement();

  // A receipt describes one ticket; switching market, side or type makes it stale.
  useEffect(() => {
    setReceipt(null);
    setSignError(null);
  }, [ticket.marketId, ticket.side, ticket.mode]);

  /**
   * Build the EIP-712 order this ticket describes and have the wallet sign it.
   *
   * The domain is the deployment's — chain id plus the Settlement address — so
   * the signature is bound to one deployment and cannot be replayed onto
   * another. With nothing deployed the zero address stands in: the wallet still
   * signs, the order still hashes to the value the contract would compute
   * (`hashOrderStruct` is domain-independent), and the receipt says plainly
   * that no filler can use it.
   */
  const signDraft = useCallback(
    async (spec: {
      amountIn: number;
      targetOut: number;
      minOut: number;
      ttlSeconds: number;
      decaySeconds: number;
    }): Promise<SignedOrder> => {
      if (!signer || !wallet.address) throw new Error("wallet not connected");
      const pay = tokens.view(ticket.payToken);
      const recv = tokens.view(ticket.recvToken);
      if (!pay.address || !recv.address || pay.decimals === undefined || recv.decimals === undefined) {
        throw new Error("token metadata still loading");
      }

      const draft = buildOrder({
        maker: wallet.address,
        side: ticket.side,
        pay: { address: pay.address, decimals: pay.decimals },
        recv: { address: recv.address, decimals: recv.decimals },
        ...spec,
      });

      const domain = deployment ?? { chainId, settlement: zeroAddress, permit3: zeroAddress };
      const sig = await signOrder(signer, draft.order, domain);
      return { order: draft.order, sig, hash: draft.hash, deployment: domain, deployed: deployment !== null };
    },
    [chainId, deployment, signer, ticket.payToken, ticket.recvToken, ticket.side, tokens, wallet.address],
  );

  const sign = useCallback(async () => {
    if (!q || !plan) return;
    setSigning(true);
    try {
      const { marketId, side, payToken, recvToken, amount } = ticket;
      const undeployed = deployment === null ? " · domain not deployed" : "";

      if (plan.kind === "twap") {
        // A TWAP is N independent orders on a schedule, so only the slice that
        // is due can be signed now. Signing the whole notional up front would
        // hand a filler the entire size at the first tick.
        const signed = await signDraft(plan);
        const order = await orderbook.place({
          marketId,
          side,
          type: "twap",
          size: side === "sell" ? amount : amount / plan.price,
          price: plan.price,
          ttlMs: ticket.slices * ticket.everyMin * 60_000 + 60_000,
          slices: { total: ticket.slices, everyMin: ticket.everyMin },
          signed,
        });
        setReceipt({
          hash: order.id,
          headline: `${fmtAmt(amount)} ${payToken} in ${ticket.slices} slices, ${ticket.everyMin} min apart`,
          detail: `slice 1 signed at ${fmtPrice(plan.price, tick)} ${ticket.market.quote}/${ticket.market.base} — the rest are signed as they come due`,
          note: `scheduled · 0 gas${undeployed}`,
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

      const signed = await signDraft(plan);
      // A resting order is identified by the book's id, a market one by its
      // own struct hash — so the widened type is the honest one.
      let hash: string = signed.hash;
      if (plan.kind === "resting" && q.resting && ticket.limit) {
        const order = await orderbook.place({
          marketId,
          side,
          type: "limit",
          size: q.resting.size,
          price: ticket.limit,
          ttlMs: DAY_MS,
          signed,
        });
        hash = order.id;
      }

      setReceipt({
        hash,
        headline: `${fmtAmt(q.totalIn)} ${payToken} → at least ${fmtAmt(q.minReceived)} ${recvToken}`,
        detail: q.resting
          ? `${restingLabel(q.resting).toLowerCase()} at ${fmtPrice(q.resting.price, tick)}`
          : undefined,
        note: `${q.resting ? "resting · free to cancel" : "settled · 0 gas"}${undeployed}`,
      });
      ticket.clearAmount();
      // The allowance was sized for exactly this order, so once it is signed
      // what the chain grants is no longer what the next ticket will need.
      allowanceState.refresh();
    } catch (e) {
      // A rejected signature is a normal outcome, not a crash — say what
      // happened and leave the ticket exactly as it was.
      setReceipt(null);
      setSignError(e instanceof Error ? e.message : String(e));
    } finally {
      setSigning(false);
    }
  }, [allowanceState, deployment, plan, q, signDraft, tick, ticket]);

  /**
   * Retraction is a signed EIP-712 message, not a transaction: free, instant,
   * and advisory — it evicts from books that honour it but does not bind a
   * filler already holding the order. The on-chain cancels are the hard ones.
   */
  const cancel = useCallback(
    async (orderHash: string) => {
      const order = allOrders.find((o) => o.id === orderHash);
      const domain = order?.signed?.deployment ?? deployment;
      if (signer && wallet.address && domain) {
        try {
          const message = buildSoftCancel(wallet.address, [orderHash as `0x${string}`]);
          const sig = await signSoftCancel(signer, message, domain);
          await orderbook.cancel(orderHash, { cancel: message, sig });
          return;
        } catch {
          // Declining the cancel signature leaves the order where it was.
          return;
        }
      }
      await orderbook.cancel(orderHash);
    },
    [allOrders, deployment, signer, wallet.address],
  );

  const tickOf = useCallback((marketId: string) => ticks[marketId] ?? 4, [ticks]);

  // Signing is gated on the wallet being connected and on the right chain — the
  // order is chain-bound, so a signature from the wrong one is not a near miss.
  const gate: Gate | null = !wallet.address
    ? { label: "Connect wallet", action: () => setConnectRequest((n) => n + 1) }
    : !onChain
      ? { label: `Switch to ${chainLabel(chainId)}`, action: () => void wallet.switchChain(chainId) }
      : null;

  // `partial` is its own state: the book on screen is real, but one venue has
  // not reported yet — which is not the same as stale data or a dead feed.
  const live: "live" | "stale" | "down" = pool.error
    ? "down"
    : pool.partial || (pool.age !== null && pool.age > STALE_MS)
      ? "stale"
      : "live";

  return (
    <>
      <PreAuditStrip onDetails={() => setRiskOpen(true)} />

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

        <RaffleNotice chainId={chainId} onTerms={() => setTermsOpen(true)} />

        <Stats bids={merged.bids} asks={merged.asks} base={ticket.market.base} venues={pool.book?.venues ?? []} />

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
            allowance={allowance}
            signError={signError}
            domain={{
              settlement: deployment?.settlement ?? zeroAddress,
              chainLabel: chainLabel(chainId),
              deployed: deployment !== null,
            }}
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
            venues={pool.book?.venues ?? []}
            status={pool.venues}
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
        <p>
          <button type="button" className="linkbtn" onClick={() => setTermsOpen(true)}>
            Prize draw Terms &amp; Conditions
          </button>
          {TERMS_UPDATED && <> · last updated {TERMS_UPDATED}</>}
        </p>
      </footer>

      {(!acknowledged || riskOpen) && (
        <PreAuditGate
          review={acknowledged}
          onAccept={accept}
          onClose={() => setRiskOpen(false)}
          onTerms={() => setTermsOpen(true)}
        />
      )}
      {/* Last, so it paints above the disclosure that can open it: the draw's
          terms are reachable from inside the gate, and a dialog that opens
          behind the thing you opened it from reads as a dead link. */}
      <TermsDialog open={termsOpen} onClose={() => setTermsOpen(false)} />
    </>
  );
}
