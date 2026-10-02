import { useCallback, useEffect, useMemo, useState } from "react";

import { buildSoftCancel, encodeCancelOrders, signOrder, signSoftCancel } from "@1delta-x/sdk";
import { createPublicClient, createWalletClient, custom, formatUnits, zeroAddress, type Address } from "viem";

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
import { TermsLink } from "./components/TermsLink";
import { chainById, chainLabel } from "./config/chains";
import { deploymentFor, solverForMarket } from "./config/deployments";
import { marketById, pinnedToken, symbolsOn } from "./config/markets";
import { useChainPools } from "./hooks/useChainPools";
import { useFills, useRestingOrders } from "./hooks/useOrderbook";
import { usePoolBook } from "./hooks/usePoolBook";
import { useTheme } from "./hooks/useTheme";
import { useTicket, type TicketDeps } from "./hooks/useTicket";
import { useTokenIndex } from "./hooks/useTokenIndex";
import { fmtAmt, fmtPrice } from "./lib/format";
import { depth, mergeLadder, quote as quoteOrder, restingLabel } from "./lib/ladder";
import { readMinValidNonce, type Reader } from "./lib/chain";
import { hasLeftover, planFunding, type FundingStep } from "./lib/funding";
import { buildOrder } from "./lib/order";
import { planTicket, requiredInputWei, sliceCap, type TicketPlan } from "./lib/plan";
import type { RestingOrder, Side, SliceSpec } from "./lib/types";
import { useAllowance } from "./wallet/useAllowance";
import { useBalances } from "./wallet/useBalances";
import { useSigner } from "./wallet/useSigner";
import { useWallet } from "./wallet/useWallet";

/** Slippage floor quoted on market orders. */
const SLIPPAGE_BPS = 50;

const DAY_MS = 24 * 3600_000;

/** Past this the pool ladder is old enough to say so rather than imply it is live. */
const STALE_MS = 30_000;

const EMPTY_DEPS: TicketDeps = { bids: [], asks: [], tick: 4, balances: {} };

function stepLabel(step: FundingStep | undefined, amount: string, token: string): string {
  if (!step) return `Approve ${token}`;
  return step.kind === "erc20-approve"
    ? `Approve exactly ${amount} ${token} to Permit3`
    : `Grant Settlement exactly ${amount} ${token} via Permit3`;
}

function errorText(e: unknown): string {
  return e instanceof Error ? e.message.split("\n")[0]! : String(e);
}

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
  const tokens = useTokenIndex(chainId);
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
      out[symbol] = address ? rawBalances.human[address.toLowerCase()] : undefined;
    }
    return out;
  }, [chainId, tokens, rawBalances]);

  /** The exact on-chain balance, in wei, of a pinned token — what "max" and every input cap use. */
  const balanceWei = useCallback(
    (symbol: string): bigint | undefined => {
      const address = tokens.view(symbol).address;
      return address ? rawBalances.raw[address.toLowerCase()] : undefined;
    },
    [tokens, rawBalances],
  );

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

  const plan: TicketPlan | null = useMemo(
    () =>
      q && pool.book
        ? planTicket({
            q,
            mid: pool.book.mid,
            mode: ticket.mode,
            side: ticket.side,
            amount: ticket.amount,
            limit: ticket.limit,
            slices: ticket.slices,
            everyMin: ticket.everyMin,
          })
        : null,
    [q, pool.book, ticket.amount, ticket.everyMin, ticket.limit, ticket.mode, ticket.side, ticket.slices],
  );

  const payWei = balanceWei(ticket.payToken);

  // PRE-AUDIT POLICY: fund exactly this ticket and nothing more — both legs,
  // the ERC-20 approval to Permit3 and the Permit3 book grant to Settlement
  // (A-IMMUT-1), each set to exactly what the ticket signs. Capped at the raw
  // balance so "max" never commits more than the wallet holds (G-TS_SIGN-7).
  const requiredWei = useMemo(
    () => (plan && payMeta.decimals !== undefined ? requiredInputWei(plan, payMeta.decimals, payWei) : 0n),
    [plan, payMeta.decimals, payWei],
  );

  // Exact comparison in wei — a float compare of a number with itself could
  // never see a "max" that rounded above the balance.
  const overBalance = payWei !== undefined && requiredWei > payWei;
  const maxAmount =
    payWei !== undefined && payMeta.decimals !== undefined ? formatUnits(payWei, payMeta.decimals) : undefined;

  const allowanceState = useAllowance({
    provider: wallet.provider,
    owner: wallet.address,
    chainId,
    onChain,
    token: payMeta.address ?? null,
    deployment: deployment ? { permit3: deployment.permit3, settlement: deployment.settlement } : null,
  });

  const nowSec = Math.floor(Date.now() / 1000);
  const funding = allowanceState.funding;
  const fundingPlan =
    funding && plan ? planFunding(funding, requiredWei, plan.fundingTtlSeconds, nowSec) : undefined;
  const requiredHuman = payMeta.decimals !== undefined ? Number(formatUnits(requiredWei, payMeta.decimals)) : 0;

  const allowance: AllowanceView = {
    spender: deployment ? deployment.permit3 : null,
    required: requiredHuman,
    current:
      funding !== undefined && payMeta.decimals !== undefined
        ? Number(formatUnits(funding.erc20Allowance, payMeta.decimals))
        : undefined,
    covered: fundingPlan?.covered ?? false,
    trims: fundingPlan?.trims ?? false,
    nextLabel: stepLabel(fundingPlan?.steps[0], fmtAmt(requiredHuman), ticket.payToken),
    remaining: fundingPlan?.steps.length ?? 0,
    leftover: funding !== undefined && hasLeftover(funding, nowSec),
    mismatch: allowanceState.mismatch,
    approving: allowanceState.busy,
    error: allowanceState.error,
    approve: () => plan && void allowanceState.fund(requiredWei, plan.fundingTtlSeconds),
    revoke: () => void allowanceState.revoke(),
  };

  const [signing, setSigning] = useState(false);
  const [receipt, setReceipt] = useState<Receipt | null>(null);
  const [signError, setSignError] = useState<string | null>(null);
  const [connectRequest, setConnectRequest] = useState(0);
  const [riskOpen, setRiskOpen] = useState(false);
  const { acknowledged, accept } = useAcknowledgement();

  // A receipt describes one ticket; switching market, side or type makes it stale.
  useEffect(() => {
    setReceipt(null);
    setSignError(null);
  }, [ticket.marketId, ticket.side, ticket.mode]);

  /**
   * Build the EIP-712 order for one spec on one market, and have the wallet sign it.
   *
   * Token addresses and decimals come from the PINNED config for that market,
   * never from an indexer or a token list (G-TS_SIGN-1). The domain is the
   * deployment's — chain id plus the Settlement address — so the signature is
   * bound to one deployment. With nothing deployed the zero address stands in:
   * the wallet still signs, the order still hashes to the value the contract
   * would compute, and the receipt says plainly that no filler can use it.
   */
  const signDraft = useCallback(
    async (spec: SliceSpec & { marketId: string; side: Side; orders?: number; signedSlices?: number }): Promise<SignedOrder> => {
      if (!signer || !wallet.address) throw new Error("wallet not connected");
      const market = marketById(spec.marketId);
      const paySymbol = spec.side === "sell" ? market.base : market.quote;
      const recvSymbol = spec.side === "sell" ? market.quote : market.base;
      const pay = pinnedToken(market.chainId, paySymbol);
      const recv = pinnedToken(market.chainId, recvSymbol);
      if (!pay || !recv) throw new Error(`no pinned token for ${paySymbol}/${recvSymbol}`);

      // After a `rollbackNonces`, a nonce below the maker's watermark is dead
      // on arrival; read it so the draw lands above (G-TS_SIGN-3).
      let minValidNonce = 0n;
      if (deployment && wallet.provider) {
        const config = chainById(chainId);
        if (config) {
          const reader = createPublicClient({ chain: config.chain, transport: custom(wallet.provider) }) as unknown as Reader;
          minValidNonce = await readMinValidNonce(reader, deployment.settlement, wallet.address);
        }
      }
      const raw = balanceWei(paySymbol);

      const draft = buildOrder({
        maker: wallet.address,
        side: spec.side,
        pay,
        recv,
        solver: solverForMarket(deployment, spec.marketId),
        amountIn: spec.amountIn,
        targetOut: spec.targetOut,
        minOut: spec.minOut,
        ttlSeconds: spec.ttlSeconds,
        decaySeconds: spec.decaySeconds,
        // Split the LIVE balance over the orders still to be signed, not the
        // ticket's total: slices that already filled have left the wallet.
        // buildOrder scales the outputs if this cap binds (G-TS_SIGN-7).
        maxIn: sliceCap(raw, spec.orders ?? 1, spec.signedSlices ?? 0),
        minValidNonce,
      });

      const domain = deployment ?? { chainId, settlement: zeroAddress, permit3: zeroAddress };
      const sig = await signOrder(signer, draft.order, domain);
      return { order: draft.order, sig, hash: draft.hash, deployment: domain, deployed: deployment !== null };
    },
    [balanceWei, chainId, deployment, signer, wallet.address, wallet.provider],
  );

  const sign = useCallback(async () => {
    if (!q || !plan) return;
    setSigning(true);
    try {
      const { marketId, side, payToken, recvToken, amount } = ticket;
      const undeployed = deployment === null ? " · domain not deployed" : "";
      const spec: SliceSpec = {
        amountIn: plan.amountIn,
        targetOut: plan.targetOut,
        minOut: plan.minOut,
        ttlSeconds: plan.ttlSeconds,
        decaySeconds: plan.decaySeconds,
      };

      if (plan.kind === "twap") {
        // A TWAP is N independent orders on a schedule, so only the slice that
        // is due can be signed now. Each later slice is signed — by the maker,
        // from the Open orders row — when it comes due, and only a signed
        // slice can fill.
        const signed = await signDraft({ ...spec, marketId, side, orders: plan.orders });
        const order = await orderbook.place({
          marketId,
          side,
          type: "twap",
          size: plan.restingBase,
          price: plan.price,
          ttlMs: ticket.slices * ticket.everyMin * 60_000 + 60_000,
          slices: { total: ticket.slices, everyMin: ticket.everyMin },
          sliceSpec: spec,
          signed,
        });
        setReceipt({
          hash: order.id,
          headline: `${fmtAmt(amount)} ${payToken} in ${ticket.slices} slices, ${ticket.everyMin} min apart`,
          detail: `slice 1 signed at ${fmtPrice(plan.price, tick)} ${ticket.market.quote}/${ticket.market.base} — sign each later slice from Open orders when it comes due`,
          note: `slice 1 of ${ticket.slices} signed · simulated book${undeployed}`,
        });
        ticket.clearAmount();
        allowanceState.refresh();
        return;
      }

      // Sign FIRST. Nothing is recorded — no fill, no row — until there is a
      // signature behind it, so a declined or failed signature leaves no
      // phantom trade in the history (G-TS_SIGN-3, G-TS_SIGN-15).
      const signed = await signDraft({ ...spec, marketId, side });
      let hash: string = signed.hash;

      if (plan.kind === "limit" && q.resting && ticket.limit) {
        const order = await orderbook.place({
          marketId,
          side,
          type: "limit",
          size: plan.crossedBase + plan.restingBase,
          filled: plan.crossedBase,
          price: ticket.limit,
          ttlMs: DAY_MS,
          signed,
        });
        hash = order.id;
      }
      // The crossing part of the SIGNED order, as the simulated book fills it.
      if (plan.crossedBase > 0) {
        orderbook.recordTake({ marketId, side, size: plan.crossedBase, price: q.avg, bySource: q.bySource });
      }

      setReceipt({
        hash,
        headline: `${fmtAmt(plan.amountIn)} ${payToken} → at least ${fmtAmt(plan.minOut)} ${recvToken}`,
        detail: q.resting
          ? `${restingLabel(q.resting).toLowerCase()} at ${fmtPrice(q.resting.price, tick)}`
          : undefined,
        note: `${
          plan.kind === "limit"
            ? "signed · resting in the simulated book"
            : "signed · settlement simulated — nothing was broadcast"
        }${undeployed}`,
      });
      ticket.clearAmount();
      allowanceState.refresh();
    } catch (e) {
      // A rejected signature is a normal outcome, not a crash — say what
      // happened and leave the ticket exactly as it was.
      setReceipt(null);
      setSignError(errorText(e));
    } finally {
      setSigning(false);
    }
  }, [allowanceState, deployment, plan, q, signDraft, tick, ticket]);

  const [orderError, setOrderError] = useState<string | null>(null);

  /**
   * SOFT cancel: a signed EIP-712 retraction, free and instant, and ADVISORY —
   * books that honour it stop distributing the order, but the signature stays
   * valid on-chain until expiry, so anyone already holding it can still fill
   * it. Without a signer (wallet disconnected or on another chain) nothing is
   * done: an unsigned eviction would only hide the order from its own maker
   * (G-TS_SIGN-4). The row stays, marked, until expiry or a hard cancel.
   */
  const cancel = useCallback(
    async (o: RestingOrder) => {
      setOrderError(null);
      const domain = o.signed?.deployment ?? deployment;
      if (!signer || !wallet.address || !domain) {
        setOrderError(`Connect a wallet on ${chainLabel(marketById(o.marketId).chainId)} to sign a cancel`);
        return;
      }
      try {
        const hashes = (o.signedOrders ?? (o.signed ? [o.signed] : [])).map((x) => x.hash);
        const message = buildSoftCancel(wallet.address, hashes.length ? hashes : [o.id as `0x${string}`]);
        const sig = await signSoftCancel(signer, message, domain);
        await orderbook.cancel(o.id, { cancel: message, sig });
      } catch (e) {
        // Declining the cancel signature leaves the order where it was.
        setOrderError(errorText(e));
      }
    },
    [deployment, signer, wallet.address],
  );

  /**
   * HARD cancel: `Settlement.cancelOrders(nonces)` for every signed order
   * behind the row — one transaction, after which no filler can settle them.
   */
  const hardCancel = useCallback(
    async (o: RestingOrder) => {
      setOrderError(null);
      const signedOrders = o.signedOrders ?? (o.signed ? [o.signed] : []);
      const settlement = signedOrders[0]?.deployment.settlement;
      if (!wallet.provider || !wallet.address || !onChain || !settlement || !signedOrders[0]?.deployed) {
        setOrderError("On-chain cancel needs a deployed Settlement and a wallet on its chain");
        return;
      }
      const config = chainById(signedOrders[0].deployment.chainId);
      if (!config) return;
      try {
        const client = createWalletClient({ account: wallet.address, chain: config.chain, transport: custom(wallet.provider) });
        const reader = createPublicClient({ chain: config.chain, transport: custom(wallet.provider) });
        const hash = await client.sendTransaction({
          to: settlement as Address,
          data: encodeCancelOrders(signedOrders.map((x) => x.order.nonce)),
          chain: config.chain,
          account: wallet.address,
        });
        const receipt = await reader.waitForTransactionReceipt({ hash });
        if (receipt.status !== "success") throw new Error("cancel transaction reverted");
        orderbook.confirmHardCancel(o.id);
      } catch (e) {
        setOrderError(errorText(e));
      }
    },
    [onChain, wallet.address, wallet.provider],
  );

  /** Sign a TWAP's next due slice — the same order as slice 1, on a fresh nonce. */
  const signSlice = useCallback(
    async (o: RestingOrder) => {
      setOrderError(null);
      if (!o.sliceSpec || !o.slices) return;
      try {
        const signedSlices = o.signedOrders?.length ?? (o.signed ? 1 : 0);
        const signed = await signDraft({
          ...o.sliceSpec,
          marketId: o.marketId,
          side: o.side,
          orders: o.slices.total,
          signedSlices,
        });
        orderbook.addSlice(o.id, signed);
      } catch (e) {
        setOrderError(errorText(e));
      }
    },
    [signDraft],
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

        <RaffleNotice chainId={chainId} />

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
            maxAmount={maxAmount}
            overBalance={overBalance}
            recvAddress={tokens.view(ticket.recvToken).address ?? null}
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

        <Orders
          orders={allOrders}
          fills={fills}
          tickOf={tickOf}
          tokens={tokens}
          onCancel={cancel}
          onHardCancel={hardCancel}
          onSignSlice={signSlice}
          error={orderError}
        />
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
          . Order distribution runs against an in-browser mock of the orderbook backend: signatures are real,
          but resting, fills and soft cancels are simulated locally, nothing is broadcast, and no fill shown
          here happened on-chain.
        </p>
        <p>
          <TermsLink>Prize draw Terms &amp; Conditions</TermsLink>
        </p>
      </footer>

      {(!acknowledged || riskOpen) && (
        <PreAuditGate review={acknowledged} onAccept={accept} onClose={() => setRiskOpen(false)} />
      )}
    </>
  );
}
