import { useState, type ReactNode } from "react";

import { BOOK_IS_REMOTE } from "../backend/book";
import { pairsWith, symbolsOn } from "../config/markets";
import type { Ticket } from "../hooks/useTicket";
import type { TokenIndex } from "../hooks/useTokenIndex";
import { fmt, fmtAmt, fmtPrice, shortHex } from "../lib/format";
import { restingLabel, type Quote } from "../lib/ladder";
import { GAS_NOTE_BPS, type MarketFloor } from "../lib/marketFloor";
import { EXPIRY_OPTIONS, expiryLabel } from "../lib/plan";
import { MAX_SLIPPAGE_BPS, type SlippageSetting } from "../lib/quote";
import {
  balanceState,
  exclusivityLabel,
  fmtBalance,
  fmtFee,
  readDetailsOpen,
  signButton,
  sourceName,
  writeDetailsOpen,
  type BalanceState,
  type MarketFigures,
} from "../lib/ticketView";
import { SOURCE_NAME, SOURCE_VAR, SOURCES, type Source } from "../lib/types";
import type { PhaseLine } from "../lib/orderLifecycle";
import type { TxState } from "../lib/txFlow";
import { TokenSelect } from "./TokenSelect";
import { MarketFillTrack } from "./MarketFillTrack";
import { OrderStatusLine, TxStatus } from "./TxStatus";
import type { TrackArgs } from "../lib/marketTrack";

export interface Receipt {
  hash: string;
  headline: string;
  detail?: string;
  note: string;
  /** A posted MARKET order: drives the live fill track (lib/marketTrack). */
  market?: { createdAt: number; expiresAt: number; decaySeconds: number };
}

/** Replaces the sign button when something has to happen first. */
export interface Gate {
  label: string;
  action: () => void;
}

/**
 * The funding the order needs, and how to set it up.
 *
 * Two legs (A-IMMUT-1): the ERC-20 approval to Permit3, and the Permit3 book
 * grant to Settlement — the contract that actually pulls the input. Pre-audit
 * both are the exact input of the ticket on screen, never unlimited, so the
 * form states the number it is asking for rather than hiding it.
 */
export interface AllowanceView {
  /** Permit3. Null when nothing is deployed that could pull, so nothing to approve. */
  spender: string | null;
  /** Exactly what this ticket commits, in human units. */
  required: number;
  /** ERC-20 allowance to Permit3 today. `undefined` means not read yet, never zero. */
  current: number | undefined;
  /** Whether both legs are set to exactly this ticket — or a gasless permit will fund it. */
  covered: boolean;
  /**
   * Gasless funding (lib/permit.ts): an ERC-2612 permit signed with the order instead
   * of the approve + grant transactions. Null when the pay token has no permit.
   */
  gasless?: {
    available: boolean;
    /** The ticket will be funded by the permit (the sign button asks for it too). */
    selected: boolean;
    /** Why it is not available here, when the token supports it. */
    reason: string | null;
    select: (on: boolean) => void;
  } | null;
  /** A standing approval or grant exceeds this ticket and the next step trims it. */
  trims: boolean;
  /** The funding button: the next transaction and its place, "Wrap 0.0123 RBTC → WRBTC (1 of 3)". */
  buttonLabel: string;
  /** Transactions still to send. */
  remaining: number;
  /** The next step wraps native coin first (WRBTC tickets funded from RBTC). */
  wrap: { amount: string; reserve: string; nativeSymbol: string } | null;
  /** Why funding cannot proceed (the wrap would eat the gas reserve), or null. */
  blocked: string | null;
  /** Something is left approved or granted that a revoke would clear. */
  leftover: boolean;
  /** Set when the configured Permit3 is not the one Settlement uses. */
  mismatch: string | null;
  approving: boolean;
  error: string | null;
  approve: () => void;
  revoke: () => void;
  /** The funding transaction in flight / last finished (wrap, approve, grant, revoke). */
  tx?: TxState;
}

interface OrderFormProps {
  ticket: Ticket;
  quote: Quote | null;
  tokens: TokenIndex;
  balances: Record<string, number | undefined>;
  tick: number;
  /** Pool mid, for the "versus mid" line. Null until the book loads. */
  mid: number | null;
  ready: boolean;
  signing: boolean;
  receipt: Receipt | null;
  /** The posted market order's live track inputs (App), null otherwise. */
  marketTrack?: Omit<TrackArgs, "now"> | null;
  /** The signed ticket's live status: Signing… → Posted → Fill submitted → Filled / Expired. */
  orderLine?: PhaseLine | null;
  /** For explorer links. */
  chainId: number;
  gate: Gate | null;
  allowance: AllowanceView;
  /** The exact wallet balance as a decimal string, for "max". */
  maxAmount: string | undefined;
  /** The ticket commits more than the wallet holds, compared in wei. */
  overBalance: boolean;
  /**
   * A MARKET ticket's gas-sized floor and the guaranteed minimum it signs
   * (lib/marketFloor.ts). Null for limit / TWAP, or where the flat floor applies.
   */
  floor: (MarketFloor & { minOut: number; targetOut: number }) | null;
  /**
   * A MARKET ticket's figures (lib/ticketView.ts `marketFigures`): from the filler's
   * quote when there is one, else the ladder estimate. Null for limit / TWAP.
   */
  figures: MarketFigures | null;
  /** Where the market quote stands: quoted, being fetched, unavailable (floor fallback), or not applicable. */
  quoteStatus: "quoted" | "loading" | "fallback" | "off";
  quoteError: string | null;
  /** The maker's slippage protection for quoted market tickets. */
  slippage: { setting: SlippageSetting; bps: number; autoBps: number; set: (s: SlippageSetting) => void };
  /** The pinned address of the token you receive — shown, because the wallet only shows the legs as a hex blob. */
  recvAddress: string | null;
  /** Why the last signature attempt failed — a declined wallet prompt, usually. */
  signError: string | null;
  /** The EIP-712 domain orders are signed into, so it is never a mystery. */
  domain: { settlement: string; chainLabel: string; deployed: boolean };
  /** A pull market's opted-in soft exclusivity window (shown in Details only when there is one). */
  delivery: { direct: boolean; windowSeconds: number; overrideBps: number };
  /** The wallet as the balance lines need it. */
  wallet: { connected: boolean; onChain: boolean; native: { symbol: string; balance: number | undefined } };
  /** The pay token is the wrapped native coin: RBTC above the gas reserve counts as spendable (human units). */
  autoWrap?: { symbol: string; value: number } | null;
  /** The wallet holds the wrapped native coin: offer turning it back (behind a confirm). */
  unwrap?: { symbol: string; busy: boolean; error: string | null; tx?: TxState; action: () => void } | null;
  onConnect: () => void;
  onSign: () => void;
}

const MODES = [
  { id: "market", label: "Market" },
  { id: "limit", label: "Limit" },
  { id: "twap", label: "TWAP" },
] as const;

function cssVar(name: string): string {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
}

function storage(): Storage | undefined {
  try {
    return typeof window === "undefined" ? undefined : window.localStorage;
  } catch {
    return undefined;
  }
}

/** One balance readout: a number only when it can be one. */
function Bal({ state, onConnect }: { state: BalanceState; onConnect: () => void }) {
  if (state.kind === "disconnected") {
    return (
      <button type="button" className="balconnect" onClick={onConnect}>
        Connect wallet
      </button>
    );
  }
  return <span className={`m${state.kind === "wrong-network" ? " warn" : ""}`}>{state.text}</span>;
}

export function OrderForm(props: OrderFormProps) {
  const {
    ticket,
    quote,
    tokens,
    balances,
    tick,
    mid,
    ready,
    signing,
    receipt,
    marketTrack,
    orderLine,
    chainId,
    gate,
    allowance,
    maxAmount,
    overBalance,
    floor,
    figures,
    quoteStatus,
    quoteError,
    slippage,
    recvAddress,
    signError,
    domain,
    delivery,
    wallet,
    autoWrap,
    unwrap,
    onConnect,
    onSign,
  } = props;

  const { amount, payToken, recvToken, mode, side, market, payBalance } = ticket;
  const isMarket = mode === "market";

  const [detailsOpen, setDetailsOpen] = useState(() => readDetailsOpen(storage()));
  const toggleDetails = () => {
    setDetailsOpen((o) => {
      writeDetailsOpen(storage(), !o);
      return !o;
    });
  };

  // Nothing deployed means nothing can pull the input, so the approval step is
  // not skipped for convenience — there is genuinely nothing to approve.
  const needsApproval = allowance.spender !== null && !allowance.covered;

  const resting = quote?.resting ?? null;
  const twapMinutes = ticket.slices * ticket.everyMin;

  const balOf = (symbol: string, value: number | undefined, wrappable?: { value: number; symbol: string } | null) =>
    balanceState({ connected: wallet.connected, onChain: wallet.onChain, value, symbol, wrappable });
  // Selling WRBTC: RBTC above the gas reserve is spendable too (auto-wrapped at funding).
  const payBal = balOf(payToken, payBalance, autoWrap);
  const paySpendable = payBal.kind === "ok" ? payBal.value : payBalance;
  const recvBal = balOf(recvToken, balances[recvToken]);

  // ---- the limit / TWAP route bar (a market ticket's source is a chip in Details)
  const bar: Array<{ key: string; pct: number; color: string; label: string }> = [];
  if (!isMarket && quote && amount > 0 && quote.filledIn > 0) {
    for (const src of SOURCES as Source[]) {
      const share = quote.bySource[src];
      if (share <= 0) continue;
      const pct = (share / amount) * 100;
      bar.push({ key: src, pct, color: cssVar(SOURCE_VAR[src]), label: `${SOURCE_NAME[src]} ${pct.toFixed(0)}%` });
    }
  }
  const unfilledPct = quote && amount > 0 ? (quote.unfilledIn / amount) * 100 : 0;

  // ---- what you receive
  const receiveValue = isMarket
    ? figures
      ? fmtAmt(figures.receive)
      : ""
    : quote && quote.totalOut > 0
      ? fmtAmt(quote.totalOut)
      : "";

  // ---- Details rows: everything that is not pay / receive / fee / minimum
  const rows: Array<[string, ReactNode, string]> = [];
  let rate: string | null = null;
  if (isMarket && figures) {
    rate = `1 ${market.base} ≈ ${fmt(figures.price, tick)} ${market.quote}`;
    rows.push(["Price", `${fmt(figures.price, tick)} ${market.quote}`, ""]);
    if (figures.vsMidPct !== null) {
      const v = figures.vsMidPct;
      rows.push(["Versus mid", `${v >= 0 ? "+" : ""}${v.toFixed(2)}%`, Math.abs(v) > 2 ? "warn" : ""]);
    }
    rows.push([
      "Source",
      <span className="srcchip" key="src">
        {figures.basis === "quote" ? `filler quote · via ${sourceName(figures.source)}` : "book estimate (no filler quote)"}
      </span>,
      figures.live ? "" : "warn",
    ]);
    if (!figures.live) rows.push(["Status", "DRY RUN — the filler quotes but will not fill", "warn"]);
    if (figures.networkFeeBps !== null) {
      rows.push([
        "Network fee share",
        `${(figures.networkFeeBps / 100).toFixed(2)}% of the ticket${figures.basis === "quote" && quoteStatus === "quoted" ? "" : " (estimate)"}`,
        figures.networkFeeBps > GAS_NOTE_BPS ? "warn" : "",
      ]);
    }
    if (figures.basis === "ladder" && floor) {
      rows.push([
        "Price floor",
        `−${(floor.bps / 100).toFixed(2)}% of the estimate${floor.gasBound ? " · raised for network gas" : ""}${floor.approximate ? " · approx." : ""}`,
        floor.bps > GAS_NOTE_BPS ? "warn" : "",
      ]);
    }
  } else if (!isMarket && quote) {
    // The blended price of everything the order does: what crosses now, and what
    // rests at the price you named.
    const avg =
      quote.totalIn > 0 && quote.totalOut > 0 ? (side === "sell" ? quote.totalOut / quote.totalIn : quote.totalIn / quote.totalOut) : 0;
    if (avg > 0) rate = `1 ${market.base} ≈ ${fmt(avg, tick)} ${market.quote}`;
    rows.push(["Average price", avg > 0 ? `${fmtPrice(avg, tick)} ${market.quote}` : "—", ""]);
    if (quote.unfilledIn > 0 && amount > 0) {
      rows.push(["Fills now", quote.filledIn > 0 ? `${fmtAmt(quote.filledIn)} ${payToken}` : "nothing at this price", ""]);
      rows.push(
        resting
          ? [restingLabel(resting), `${fmtAmt(quote.unfilledIn)} ${payToken}`, resting.exhausted ? "warn" : "good"]
          : ["Beyond book depth", `${fmtAmt(quote.unfilledIn)} ${payToken}`, "warn"],
      );
    }
    if (mid && avg > 0) {
      const vsMid = (avg / mid - 1) * 100;
      rows.push(["Versus mid", `${vsMid >= 0 ? "+" : ""}${vsMid.toFixed(2)}%`, Math.abs(vsMid) > 2 ? "warn" : ""]);
    }
  }
  if (quote || figures) {
    rows.push([
      "Expires",
      isMarket
        ? figures?.basis === "quote"
          ? "5 minutes (starts at the quote, decays to the minimum over 3.5 minutes)"
          : "5 minutes (1 minute auction, then rests at the minimum)"
        : mode === "twap"
          ? `each slice ${ticket.everyMin + 1} min after it is signed · schedule ${twapMinutes >= 60 ? `${(twapMinutes / 60).toFixed(1)} h` : `${twapMinutes} min`}`
          : `${expiryLabel(ticket.expiry)} (the Permit3 grant lasts as long, +1 h)`,
      "",
    ]);
  }
  const excl = domain.deployed ? exclusivityLabel(delivery) : null;
  if (excl) rows.push(["Exclusivity", excl, ""]);

  // ---- the visible minimum (market: from the figures; limit / TWAP: the limit price's)
  const minLine = isMarket
    ? figures
      ? `${fmtAmt(figures.minOut)} ${recvToken}`
      : null
    : quote && quote.minReceived > 0
      ? `${fmtAmt(quote.minReceived)} ${recvToken}`
      : null;

  const sb = signButton({
    signing,
    amount,
    overBalance,
    payToken,
    ready,
    quoting: quoteStatus === "loading",
    priced: isMarket ? !!figures : !!quote && quote.totalIn > 0,
  });
  const canSign = !sb.disabled && !needsApproval;

  return (
    <div className="box">
      <div className="boxhead">
        <span className="lbl">Place an order</span>
        <span className="lbl">{side === "sell" ? `sell ${market.base}` : `buy ${market.base}`}</span>
      </div>
      <div className="boxbody">
        <div className="seg">
          {MODES.map((m) => (
            <button key={m.id} type="button" aria-selected={mode === m.id} onClick={() => ticket.setMode(m.id)}>
              {m.label}
            </button>
          ))}
        </div>

        <div className="wstrip" aria-label="Wallet balances">
          <span className="lbl">Wallet</span>
          {!wallet.connected ? (
            <button type="button" className="balconnect" onClick={onConnect}>
              Connect wallet
            </button>
          ) : !wallet.onChain ? (
            <span className="m warn">wrong network — switch to {domain.chainLabel}</span>
          ) : (
            <span className="wbals">
              {[market.base, market.quote].map((sym) => (
                <span key={sym} className="m">
                  <b>{balances[sym] === undefined ? "…" : fmtBalance(balances[sym]!)}</b> {sym}
                  {unwrap && unwrap.symbol === sym && (
                    <>
                      {" "}
                      <button
                        type="button"
                        className="linkbtn"
                        disabled={unwrap.busy}
                        title={`Turn all your ${sym} back into ${wallet.native.symbol} (asks to confirm first)`}
                        onClick={unwrap.action}
                      >
                        {unwrap.busy ? "unwrapping…" : "unwrap"}
                      </button>
                    </>
                  )}
                </span>
              ))}
              <span className="m" title="Native coin, pays gas for approvals">
                <b>{wallet.native.balance === undefined ? "…" : fmtBalance(wallet.native.balance)}</b> {wallet.native.symbol}
              </span>
            </span>
          )}
        </div>
        {unwrap?.error && <div className="signerr">{unwrap.error}</div>}
        {unwrap?.tx && <TxStatus state={unwrap.tx} chainId={chainId} onRetry={unwrap.action} />}

        <div className="field">
          <div className="top">
            <span className="lbl">You pay</span>
            <span className="bal">
              {payBal.kind === "ok" ? <>Balance </> : null}
              <Bal state={payBal} onConnect={onConnect} />
              {payBal.kind === "ok" && (
                <button
                  type="button"
                  disabled={maxAmount === undefined || paySpendable === undefined || paySpendable <= 0}
                  onClick={() => maxAmount !== undefined && ticket.setAmount(maxAmount)}
                >
                  Max
                </button>
              )}
            </span>
          </div>
          <div className={`inp${overBalance ? " over" : ""}`}>
            <input
              type="number"
              min="0"
              step="any"
              placeholder="0.0"
              aria-label={`Amount of ${payToken} to pay`}
              value={ticket.amountStr}
              onChange={(e) => ticket.setAmount(e.target.value)}
            />
            <TokenSelect
              value={payToken}
              options={symbolsOn(ticket.chainId)}
              tokens={tokens}
              balances={balances}
              onChange={ticket.setPay}
              label="Token you pay with"
            />
          </div>
          {overBalance && (
            <span className="capnote">
              exceeds your {autoWrap && autoWrap.value > 0 ? "spendable " : ""}balance of {fmtBalance(paySpendable ?? 0)} {payToken}
              {autoWrap && autoWrap.value > 0 ? ` (incl. ${autoWrap.symbol} to wrap)` : ""}
            </span>
          )}
          {!overBalance && quote && isMarket && figures?.basis !== "quote" && quote.unfilledIn > 0 && amount > 0 && (
            <span className="capnote">
              book depth is {fmtAmt(quote.filledIn)} {payToken} — sweeping all of it at {quote.avg > 0 ? fmtPrice(quote.avg, tick) : "—"}
            </span>
          )}
        </div>

        <div className="flip">
          <button type="button" aria-label="Swap direction" onClick={ticket.flip}>
            ⇅
          </button>
        </div>

        <div className="field">
          <div className="top">
            <span className="lbl">You receive{isMarket && figures ? (figures.grossReceive !== null ? " ≈ · after network fee" : " ≈") : ""}</span>
            <span className="bal">
              {recvBal.kind === "ok" ? <>Balance </> : null}
              {recvBal.kind === "disconnected" ? null : <Bal state={recvBal} onConnect={onConnect} />}
            </span>
          </div>
          <div className="inp">
            <input type="text" readOnly placeholder="0.0" aria-label={`Amount of ${recvToken} you receive`} value={receiveValue} />
            <TokenSelect
              value={recvToken}
              options={pairsWith(ticket.chainId, payToken)}
              tokens={tokens}
              balances={balances}
              onChange={ticket.setRecv}
              label="Token you receive"
            />
          </div>
          {isMarket && amount > 0 && (
            <div className="qsum">
              {figures ? (
                <>
                  {figures.grossReceive !== null && figures.networkFee !== null && (
                    <div>
                      <span>Swap output · via {sourceName(figures.source)}</span>
                      <span className="m">
                        {fmtAmt(figures.grossReceive)} {recvToken}
                      </span>
                    </div>
                  )}
                  {figures.grossReceive !== null && figures.networkFee !== null ? (
                    <div>
                      <span>Network fee{figures.permitFee !== null ? " · incl. permit" : ""}</span>
                      <span className="m">
                        − {fmtFee(figures.networkFee)} {recvToken}
                        {quoteStatus === "loading" && <em className="qspin" aria-label="refreshing quote" />}
                      </span>
                    </div>
                  ) : null}
                  {figures.permitFee !== null && (
                    <div className="minor sub">
                      <span>of which your gasless permit</span>
                      <span className="m">
                        {fmtFee(figures.permitFee)} {recvToken}
                      </span>
                    </div>
                  )}
                  {figures.grossReceive !== null && figures.networkFee !== null ? (
                    <div className="total">
                      <span>You receive</span>
                      <span className="m">
                        ≈ {fmtAmt(figures.receive)} {recvToken}
                      </span>
                    </div>
                  ) : (
                  <div>
                    <span>Network fee</span>
                    <span className="m">
                      {figures.networkFee !== null ? `≈ ${fmtFee(figures.networkFee)} ${recvToken}` : "paid by the filler"}
                      {quoteStatus === "loading" && <em className="qspin" aria-label="refreshing quote" />}
                    </span>
                  </div>
                  )}
                  <div className="minor">
                    <span>Minimum received</span>
                    <span className="m">{minLine}</span>
                  </div>
                  {!figures.live && <div className="minor warn">Dry run — this quote will not be filled</div>}
                </>
              ) : (
                <div className="minor">
                  <span>{quoteStatus === "loading" ? "Fetching a quote…" : ready ? "No price for this size" : "Waiting for the book…"}</span>
                </div>
              )}
            </div>
          )}
        </div>

        {mode !== "market" && (
          <div className="field">
            <div className="top">
              <span className="lbl">Limit price</span>
              <span className="bal">
                {ticket.priceTouched ? (
                  <>
                    manual
                    <button type="button" onClick={ticket.resetAutoPrice}>
                      size to book
                    </button>
                  </>
                ) : mode === "twap" ? (
                  `per slice · sized to fill ${fmtAmt(ticket.sizedTo)} ${payToken}`
                ) : (
                  `sized to fill ${fmtAmt(ticket.sizedTo)} ${payToken}`
                )}
              </span>
            </div>
            <div className="inp">
              <input
                type="number"
                step="any"
                min="0"
                placeholder="0.0"
                value={ticket.limitStr}
                onChange={(e) => ticket.setLimit(e.target.value)}
              />
              <span className="unit">
                {market.quote}/{market.base}
              </span>
            </div>
            {minLine && (
              <div className="qsum">
                <div className="minor">
                  <span>Minimum received</span>
                  <span className="m">{minLine}</span>
                </div>
              </div>
            )}
            {mode === "limit" && (
              <div className="expiry" role="radiogroup" aria-label="Order expires after">
                <span className="lbl">Expires</span>
                {EXPIRY_OPTIONS.map((o) => (
                  <button
                    key={o.id}
                    type="button"
                    role="radio"
                    aria-checked={ticket.expiry === o.id}
                    title={`The order and its Permit3 grant live ${o.label}`}
                    onClick={() => ticket.setExpiry(o.id)}
                  >
                    {o.short}
                  </button>
                ))}
              </div>
            )}
          </div>
        )}

        {mode === "twap" && (
          <div className="field">
            <div className="top">
              <span className="lbl">Schedule</span>
            </div>
            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10 }}>
              <div className="inp">
                <input
                  type="number"
                  min={2}
                  max={96}
                  value={ticket.slices}
                  onChange={(e) => ticket.setSlices(Math.max(2, Number(e.target.value) || 2))}
                />
                <span className="unit">slices</span>
              </div>
              <div className="inp">
                <input
                  type="number"
                  min={1}
                  value={ticket.everyMin}
                  onChange={(e) => ticket.setEveryMin(Math.max(1, Number(e.target.value) || 1))}
                />
                <span className="unit">min</span>
              </div>
            </div>
            <p className="m" style={{ fontSize: 11, color: "var(--dim)", lineHeight: 1.7 }}>
              {fmtAmt(amount / ticket.slices)} {payToken} every {ticket.everyMin} min · completes in{" "}
              {twapMinutes >= 60 ? `${(twapMinutes / 60).toFixed(1)} h` : `${twapMinutes} min`}
              <br />
              Each slice is a separate signed order.
            </p>
          </div>
        )}

        {!isMarket && (
          <div className="route">
            <span className="lbl">Filled from</span>
            <div className="rbar">
              {bar.map((b) => (
                <i key={b.key} style={{ width: `${b.pct}%`, background: b.color }} />
              ))}
              {unfilledPct > 0.01 && (
                <i
                  style={{
                    width: `${unfilledPct}%`,
                    background: `repeating-linear-gradient(45deg, ${cssVar("--line")}, ${cssVar("--line")} 3px, transparent 3px, transparent 6px)`,
                  }}
                />
              )}
              {!bar.length && unfilledPct <= 0.01 && <i style={{ width: "100%", background: "var(--line)" }} />}
            </div>
            <div className="rkeys">
              {bar.map((b) => (
                <span key={b.key}>
                  <em style={{ background: b.color }} />
                  {b.label}
                </span>
              ))}
              {unfilledPct > 0.01 && (
                <span style={{ color: resting ? "var(--lime)" : "var(--orange)" }}>
                  {resting ? "rests " : "unfilled "}
                  {unfilledPct.toFixed(0)}%
                </span>
              )}
              {!bar.length && unfilledPct <= 0.01 && (
                <span style={{ color: "var(--faint)" }}>{ready ? "enter an amount" : "waiting for the book"}</span>
              )}
            </div>
          </div>
        )}

        <div className={`details${detailsOpen ? " open" : ""}`}>
          <button type="button" className="dtoggle" aria-expanded={detailsOpen} onClick={toggleDetails}>
            <span className="lbl">Details</span>
            <span className="drate m">{rate ?? ""}</span>
            <span className="car" aria-hidden="true">
              {detailsOpen ? "▴" : "▾"}
            </span>
          </button>
          {detailsOpen && (
            <div className="dbody">
              {rows.length > 0 && (
                <dl className="sum">
                  {rows.map(([k, v, cls]) => (
                    <div key={k}>
                      <dt>{k}</dt>
                      <dd className={cls}>{v}</dd>
                    </div>
                  ))}
                </dl>
              )}
              {isMarket && quoteStatus !== "off" && (
                <div className="slip">
                  <span className="sl">Slippage</span>
                  <div className="slctl">
                    <button
                      type="button"
                      aria-pressed={slippage.setting.mode === "auto"}
                      onClick={() => slippage.set({ mode: "auto" })}
                    >
                      Auto {(slippage.autoBps / 100).toFixed(2)}%
                    </button>
                    <span className="slin">
                      <input
                        type="number"
                        min="0.01"
                        max={MAX_SLIPPAGE_BPS / 100}
                        step="0.01"
                        aria-label="Custom slippage, percent"
                        placeholder="custom"
                        value={slippage.setting.mode === "custom" ? String(slippage.bps / 100) : ""}
                        onChange={(e) => {
                          const v = Number(e.target.value);
                          slippage.set(
                            e.target.value === "" || !Number.isFinite(v) || v <= 0 ? { mode: "auto" } : { mode: "custom", bps: Math.round(v * 100) },
                          );
                        }}
                      />
                      %
                    </span>
                  </div>
                  <span className="capnote dim">
                    {quoteStatus === "quoted"
                      ? `The order starts at the filler's quote and can only decay to this much below it, over 3.5 minutes.${
                          slippage.setting.mode === "auto" && figures?.networkFeeBps && figures.networkFeeBps > 50
                            ? " Auto is wider on small orders: gas is a bigger share, and the band has to absorb a gas estimate that comes in high."
                            : ""
                        }`
                      : quoteStatus === "loading"
                        ? "Asking the filler for a quote…"
                        : `Filler quote unavailable${quoteError ? ` (${quoteError.slice(0, 80)})` : ""} — the order uses the gas-sized floor.`}
                  </span>
                </div>
              )}
              {isMarket && figures?.basis === "ladder" && floor && quote && amount > 0 && floor.gasBound && (
                <span className={floor.bps > GAS_NOTE_BPS ? "capnote" : "capnote dim"} style={{ lineHeight: 1.5 }}>
                  {floor.bps > GAS_NOTE_BPS && (
                    <>
                      <b>Small order: ~{(floor.gasBps / 100).toFixed(2)}% goes to network gas.</b>{" "}
                    </>
                  )}
                  The filler pays ≈ {fmtAmt(floor.gasCostOut)} {recvToken} of gas per fill whatever the size, so small
                  tickets carry a higher floor: {floor.haircutBps} bps quote haircut + {floor.gasBps} bps gas +{" "}
                  {floor.bufferBps} bps (vs {floor.baseBps} bps on larger tickets). The auction starts at the estimate and is
                  usually filled as soon as the gas is covered, before it reaches the floor.
                </span>
              )}
              {recvAddress && (
                <span className="capnote dim" title={recvAddress}>
                  you sign for {recvToken} at <span className="m">{shortHex(recvAddress, 8, 6)}</span>
                </span>
              )}
              {domain.deployed && (
                <div className="domain" title="EIP-712 verifyingContract — a signature is bound to this address and chain">
                  signing into Settlement <b>{shortHex(domain.settlement, 8, 6)}</b> on {domain.chainLabel}
                </div>
              )}
            </div>
          )}
        </div>

        <div style={{ display: "flex", flexDirection: "column", gap: 9 }}>
          {gate ? (
            <button type="button" className="cta" onClick={gate.action}>
              {gate.label}
            </button>
          ) : overBalance ? (
            <button type="button" className="cta" disabled>
              {sb.label}
            </button>
          ) : (
            <>
              {allowance.spender !== null && allowance.gasless?.selected && (
                <>
                  <button type="button" className="cta ok" disabled>
                    {`✓ No gas: sign a permit for exactly ${fmtAmt(allowance.required)} ${payToken}`}
                  </button>
                  <span className="capnote dim">
                    Your wallet asks for two signatures — the order, then an ERC-2612 permit letting Settlement take
                    exactly this order&rsquo;s {payToken} until it expires. The filler submits the permit just before it
                    fills and pays its gas; you send no transaction. A newer gasless {payToken} order replaces this
                    one&rsquo;s allowance ·{" "}
                    <button type="button" className="linkbtn" onClick={() => allowance.gasless?.select(false)}>
                      use approvals instead
                    </button>
                  </span>
                </>
              )}
              {allowance.spender !== null && !allowance.gasless?.selected && (
                <>
                  {allowance.gasless?.available && (
                    <button type="button" className="cta line" onClick={() => allowance.gasless?.select(true)}>
                      Sign permit (no gas)
                    </button>
                  )}
                  {allowance.gasless && !allowance.gasless.available && allowance.gasless.reason && (
                    <span className="capnote dim">No gasless permit: {allowance.gasless.reason}</span>
                  )}
                  <button
                    type="button"
                    className={allowance.covered ? "cta ok" : "cta line"}
                    disabled={
                      allowance.covered ||
                      allowance.approving ||
                      allowance.required <= 0 ||
                      allowance.mismatch !== null ||
                      allowance.blocked !== null
                    }
                    onClick={allowance.approve}
                  >
                    {allowance.mismatch
                      ? "Deployment mismatch — approvals disabled"
                      : allowance.covered
                        ? `✓ exactly ${fmtAmt(allowance.required)} ${payToken} funded`
                        : allowance.approving
                          ? "Confirm in your wallet…"
                          : allowance.required > 0
                            ? allowance.buttonLabel
                            : `Approve ${payToken}`}
                  </button>
                  {allowance.wrap && !allowance.covered && (
                    <span className="capnote dim">
                      You hold too little {payToken}: the first transaction wraps exactly {allowance.wrap.amount}{" "}
                      {allowance.wrap.nativeSymbol} into {payToken} (1:1), keeping at least {allowance.wrap.reserve}{" "}
                      {allowance.wrap.nativeSymbol} for gas
                    </span>
                  )}
                  {allowance.blocked && <div className="signerr">{allowance.blocked}</div>}
                  <span className="capnote dim">
                    Pre-audit: the approval and the Permit3 grant to Settlement are capped at this order&rsquo;s size
                    and stay until a fill uses them or you revoke them — the grant also lapses shortly after the
                    order expires
                    {allowance.current !== undefined && allowance.current > 0 && (
                      <> · currently approved {fmtAmt(allowance.current)} {payToken}</>
                    )}
                    {allowance.leftover && (
                      <>
                        {" "}
                        ·{" "}
                        <button type="button" className="linkbtn" disabled={allowance.approving} onClick={allowance.revoke}>
                          revoke
                        </button>
                      </>
                    )}
                  </span>
                  {allowance.tx && <TxStatus state={allowance.tx} chainId={chainId} onRetry={allowance.approving ? undefined : allowance.approve} />}
                  {allowance.mismatch && <div className="signerr">{allowance.mismatch}</div>}
                  {allowance.error && <div className="signerr">{allowance.error}</div>}
                </>
              )}
              <button type="button" className="cta" disabled={!canSign} onClick={onSign}>
                {sb.label}
              </button>
            </>
          )}
          <div className="gas">
            {isMarket && figures?.networkFee !== null && figures?.networkFee !== undefined ? (
              <>
                Signing is <b>free</b> — the network fee above{allowance.gasless?.selected ? ", your permit included," : ""} is already taken out of what you receive
              </>
            ) : (
              <>
                Network fee <b>0</b> — the filler pays
              </>
            )}
            {allowance.gasless?.selected && !overBalance && (
              <>
                <br />
                no transaction to send — the filler relays your permit
              </>
            )}
            {allowance.spender !== null && !allowance.covered && !overBalance && (
              <>
                <br />
                {allowance.wrap ? "the wrap, approval and grant above are" : "the approval and grant above are"} the only
                transactions you send
              </>
            )}
          </div>
          {!domain.deployed && (
            <div className="domain" title="EIP-712 verifyingContract — a signature is bound to this address and chain">
              no Settlement deployed on {domain.chainLabel} — signatures are real but <b className="warn">not fillable</b>
            </div>
          )}
          {signError && <div className="signerr">{signError}</div>}
        </div>

        {!receipt && orderLine && (
          <div className="receipt">
            <OrderStatusLine line={orderLine} chainId={chainId} />
          </div>
        )}
        {receipt && (
          <div className="receipt">
            <span className="lbl" style={{ color: "var(--lime)" }}>
              {BOOK_IS_REMOTE ? "Order signed · posted to the orderbook" : "Order signed · simulated book, nothing broadcast"}
            </span>
            {marketTrack ? (
              <>
                <MarketFillTrack {...marketTrack} />
                {orderLine?.tx && <OrderStatusLine line={orderLine} chainId={chainId} />}
              </>
            ) : (
              orderLine && <OrderStatusLine line={orderLine} chainId={chainId} />
            )}
            <div>{receipt.headline}</div>
            {receipt.detail && <div className="k">{receipt.detail}</div>}
            <div className="k">{shortHex(receipt.hash, 12, 8)}</div>
            <div className="k" style={{ color: "var(--lime)" }}>
              {receipt.note}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
