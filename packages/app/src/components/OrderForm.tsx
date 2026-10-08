import { BOOK_IS_REMOTE } from "../backend/book";
import { pairsWith, symbolsOn } from "../config/markets";
import type { Ticket } from "../hooks/useTicket";
import type { TokenIndex } from "../hooks/useTokenIndex";
import { fmtAmt, fmtPrice, shortHex } from "../lib/format";
import { restingLabel, type Quote } from "../lib/ladder";
import { GAS_NOTE_BPS, type MarketFloor } from "../lib/marketFloor";
import { MAX_SLIPPAGE_BPS, type QuoteView, type SlippageSetting } from "../lib/quote";
import { SOURCE_NAME, SOURCE_VAR, SOURCES, type Source } from "../lib/types";
import { TokenSelect } from "./TokenSelect";

export interface Receipt {
  hash: string;
  headline: string;
  detail?: string;
  note: string;
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
  /** Whether both legs are set to exactly this ticket. */
  covered: boolean;
  /** A standing approval or grant exceeds this ticket and the next step trims it. */
  trims: boolean;
  /** What the next transaction does. */
  nextLabel: string;
  /** Transactions still to send. */
  remaining: number;
  /** Something is left approved or granted that a revoke would clear. */
  leftover: boolean;
  /** Set when the configured Permit3 is not the one Settlement uses. */
  mismatch: string | null;
  approving: boolean;
  error: string | null;
  approve: () => void;
  revoke: () => void;
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
   * A MARKET ticket priced by the filler's indicative quote (lib/quote.ts): what you
   * receive ≈, the gas share, the minimum under your slippage. Null = no quote (the
   * `floor` fallback above, or limit / TWAP).
   */
  rfq: QuoteView | null;
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
  /**
   * Who may fill this market's orders, as signed: `direct` = our solver only, for
   * the order's whole life (delta-verify); otherwise pull delivery, with our solver
   * soft-exclusive for `windowSeconds` (0 = open to every filler from the start).
   */
  delivery: { direct: boolean; windowSeconds: number; overrideBps: number };
  onSign: () => void;
}

/** "~2 blocks" on Rootstock's ~30 s clock. */
function blocksLabel(seconds: number): string {
  const n = Math.max(1, Math.round(seconds / 30));
  return `~${n} block${n === 1 ? "" : "s"}`;
}

/** The "Filled by" line: what the signed order lets each filler do, and when. */
export function deliveryLabel(d: { direct: boolean; windowSeconds: number; overrideBps: number }): string {
  if (d.direct) return "our solver only (direct delivery)";
  if (d.windowSeconds <= 0) return "any filler";
  return `our solver first for ${blocksLabel(d.windowSeconds)} (others pay you +${d.overrideBps} bps), then any filler`;
}

const MODES = [
  { id: "market", label: "Market" },
  { id: "limit", label: "Limit" },
  { id: "twap", label: "TWAP" },
] as const;

function cssVar(name: string): string {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
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
    gate,
    allowance,
    maxAmount,
    overBalance,
    floor,
    rfq,
    quoteStatus,
    quoteError,
    slippage,
    recvAddress,
    signError,
    domain,
    delivery,
    onSign,
  } = props;

  const { amount, payToken, recvToken, mode, side, market, payBalance } = ticket;

  // Nothing deployed means nothing can pull the input, so the approval step is
  // not skipped for convenience — there is genuinely nothing to approve.
  const needsApproval = allowance.spender !== null && !allowance.covered;

  const resting = quote?.resting ?? null;
  const twapMinutes = ticket.slices * ticket.everyMin;

  const bar: Array<{ key: string; pct: number; color: string; label: string }> = [];
  if (quote && amount > 0 && quote.filledIn > 0) {
    for (const src of SOURCES as Source[]) {
      const share = quote.bySource[src];
      if (share <= 0) continue;
      const pct = (share / amount) * 100;
      bar.push({ key: src, pct, color: cssVar(SOURCE_VAR[src]), label: `${SOURCE_NAME[src]} ${pct.toFixed(0)}%` });
    }
  }
  const unfilledPct = quote && amount > 0 ? (quote.unfilledIn / amount) * 100 : 0;

  const rows: Array<[string, string, string]> = [];
  if (quote) {
    // The blended price of everything the order does: what crosses now, and what
    // rests at the price you named. Quoting only the crossing part reports "—"
    // for an order placed inside the spread, which is the normal limit case.
    const avg =
      quote.totalIn > 0 && quote.totalOut > 0
        ? side === "sell"
          ? quote.totalOut / quote.totalIn
          : quote.totalIn / quote.totalOut
        : 0;
    rows.push(["Average price", avg > 0 ? `${fmtPrice(avg, tick)} ${market.quote}` : "—", ""]);
    if (quote.unfilledIn > 0 && amount > 0) {
      rows.push([
        "Fills now",
        quote.filledIn > 0 ? `${fmtAmt(quote.filledIn)} ${payToken}` : "nothing at this price",
        "",
      ]);
      rows.push(
        resting
          ? [
              restingLabel(resting),
              `${fmtAmt(quote.unfilledIn)} ${payToken}`,
              resting.exhausted ? "warn" : "good",
            ]
          : ["Beyond book depth", `${fmtAmt(quote.unfilledIn)} ${payToken}`, "warn"],
      );
    }
    if (mid && avg > 0) {
      const vsMid = (avg / mid - 1) * 100;
      rows.push([
        "Versus mid",
        `${vsMid >= 0 ? "+" : ""}${vsMid.toFixed(2)}%`,
        Math.abs(vsMid) > 2 ? "warn" : "",
      ]);
    }
    if (mode === "market" && rfq) {
      // The FILLER's quote: what it would deliver now, net of its gas (+ margin). The
      // order starts there and only decays toward the minimum if the price moves.
      rows.push(["You receive", `≈ ${fmtAmt(rfq.receive)} ${recvToken}`, "good"]);
      rows.push([
        "Network gas",
        `${fmtAmt(rfq.gas)} ${recvToken} · ${(rfq.gasBps / 100).toFixed(2)}% of the ticket (incl. +${rfq.gasMarginBps / 100}% margin)`,
        rfq.gasBps > GAS_NOTE_BPS ? "warn" : "",
      ]);
      rows.push(["Minimum received", `${fmtAmt(rfq.minOut)} ${recvToken} (slippage ${(rfq.slippageBps / 100).toFixed(2)}%)`, ""]);
      rows.push(["Quoted by", `our filler · ${rfq.source}${rfq.live ? "" : " · DRY RUN (will not fill)"}`, rfq.live ? "" : "warn"]);
    } else if (mode === "market" && floor) {
      // The guaranteed minimum is what the signed order commits — the plan's, not the
      // flat-floor quote's — and the floor % says how far under the book it sits.
      // The filler takes the order once the auction crosses its break-even (haircut +
      // gas), so that — not the floor — is the likely outcome; labelled as an estimate.
      const likely = floor.targetOut * (1 - floor.likelyBps / 10_000);
      if (likely > floor.minOut) rows.push(["Likely received", `≈ ${fmtAmt(likely)} ${recvToken}`, ""]);
      rows.push(["Minimum received", `${fmtAmt(floor.minOut)} ${recvToken}`, "good"]);
      rows.push([
        "Price floor",
        `−${(floor.bps / 100).toFixed(2)}% of the quote${floor.gasBound ? " · raised for network gas" : ""}${floor.approximate ? " · approx." : ""}`,
        floor.bps > GAS_NOTE_BPS ? "warn" : "",
      ]);
    } else {
      rows.push(["Minimum received", `${fmtAmt(quote.minReceived)} ${recvToken}`, "good"]);
    }
    rows.push([
      "Expires",
      mode === "market"
        ? rfq
          ? "5 minutes (starts at the quote, decays to the minimum over 3.5 minutes)"
          : "5 minutes (1 minute auction, then rests at the minimum)"
        : mode === "twap"
          ? "on completion"
          : "24 hours",
      "",
    ]);
    if (domain.deployed) rows.push(["Filled by", deliveryLabel(delivery), ""]);
  }

  const canSign = ready && !needsApproval && !signing && amount > 0 && !overBalance && !!quote && quote.totalIn > 0;

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

        <div className="field">
          <div className="top">
            <span className="lbl">You pay</span>
            <span className="bal">
              bal <span className="m">{payBalance === undefined ? "—" : fmtAmt(payBalance)}</span>
              <button
                type="button"
                disabled={maxAmount === undefined || payBalance === undefined || payBalance <= 0}
                onClick={() => maxAmount !== undefined && ticket.setAmount(maxAmount)}
              >
                max
              </button>
            </span>
          </div>
          <div className="inp">
            <input
              type="number"
              min="0"
              step="any"
              placeholder="0.0"
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
              balance is {fmtAmt(payBalance ?? 0)} {payToken}
            </span>
          )}
          {!overBalance && quote && mode === "market" && quote.unfilledIn > 0 && amount > 0 && (
            <span className="capnote">
              book depth is {fmtAmt(quote.filledIn)} {payToken} — sweeping all of it at{" "}
              {quote.avg > 0 ? fmtPrice(quote.avg, tick) : "—"}
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
            <span className="lbl">You receive</span>
          </div>
          <div className="inp">
            <input
              type="text"
              readOnly
              placeholder="0.0"
              value={mode === "market" && rfq ? fmtAmt(rfq.receive) : quote && quote.totalOut > 0 ? fmtAmt(quote.totalOut) : ""}
            />
            <TokenSelect
              value={recvToken}
              options={pairsWith(ticket.chainId, payToken)}
              tokens={tokens}
              balances={balances}
              onChange={ticket.setRecv}
              label="Token you receive"
            />
          </div>
          {recvAddress && (
            <span className="capnote dim" title={recvAddress}>
              you sign for {recvToken} at <span className="m">{shortHex(recvAddress, 8, 6)}</span>
            </span>
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

        <dl className="sum">
          {rows.map(([k, v, cls]) => (
            <div key={k}>
              <dt>{k}</dt>
              <dd className={cls}>{v}</dd>
            </div>
          ))}
        </dl>
        {mode === "market" && quoteStatus !== "off" && (
          <div className="field">
            <div className="top">
              <span className="lbl">Slippage protection</span>
              <span className="bal">
                <button type="button" disabled={slippage.setting.mode === "auto"} onClick={() => slippage.set({ mode: "auto" })}>
                  auto ({(slippage.autoBps / 100).toFixed(2)}%)
                </button>
              </span>
            </div>
            <div className="inp">
              <input
                type="number"
                min="0.01"
                max={MAX_SLIPPAGE_BPS / 100}
                step="0.01"
                aria-label="Custom slippage, percent"
                placeholder={(slippage.autoBps / 100).toFixed(2)}
                value={slippage.setting.mode === "custom" ? String(slippage.bps / 100) : ""}
                onChange={(e) => {
                  const v = Number(e.target.value);
                  slippage.set(e.target.value === "" || !Number.isFinite(v) || v <= 0 ? { mode: "auto" } : { mode: "custom", bps: Math.round(v * 100) });
                }}
              />
              <span className="unit">%</span>
            </div>
            <span className="capnote dim">
              {quoteStatus === "quoted"
                ? "The order starts at the filler's quote and can only decay to this much below it, over 3.5 minutes."
                : quoteStatus === "loading"
                  ? "Asking the filler for a quote…"
                  : `Filler quote unavailable${quoteError ? ` (${quoteError.slice(0, 80)})` : ""} — the order uses the gas-sized floor below.`}
            </span>
          </div>
        )}

        {mode === "market" && !rfq && floor && quote && amount > 0 && floor.gasBound && (
          <span className={floor.bps > GAS_NOTE_BPS ? "capnote" : "capnote dim"} style={{ lineHeight: 1.5 }}>
            {floor.bps > GAS_NOTE_BPS && (
              <>
                <b>Small order: ~{(floor.gasBps / 100).toFixed(2)}% goes to network gas.</b>{" "}
              </>
            )}
            The filler pays ≈ {fmtAmt(floor.gasCostOut)} {recvToken} of gas per fill whatever the size, so small
            tickets carry a higher floor: {floor.haircutBps} bps quote haircut + {floor.gasBps} bps gas +{" "}
            {floor.bufferBps} bps (vs {floor.baseBps} bps on larger tickets). The auction starts at the quote and is
            usually filled as soon as the gas is covered, before it reaches the floor.
          </span>
        )}

        <div style={{ display: "flex", flexDirection: "column", gap: 9 }}>
          {gate ? (
            <button type="button" className="cta" onClick={gate.action}>
              {gate.label}
            </button>
          ) : (
            <>
              {allowance.spender !== null && (
                <>
                  <button
                    type="button"
                    className={allowance.covered ? "cta ok" : "cta line"}
                    disabled={
                      allowance.covered ||
                      allowance.approving ||
                      allowance.required <= 0 ||
                      allowance.mismatch !== null
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
                            ? `${allowance.trims ? "Reduce: " : ""}${allowance.nextLabel}${
                                allowance.remaining > 1 ? ` (1 of ${allowance.remaining})` : ""
                              }`
                            : `Approve ${payToken}`}
                  </button>
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
                  {allowance.mismatch && <div className="signerr">{allowance.mismatch}</div>}
                  {allowance.error && <div className="signerr">{allowance.error}</div>}
                </>
              )}
              <button type="button" className="cta" disabled={!canSign} onClick={onSign}>
                {signing ? "Waiting for signature…" : "Sign order"}
              </button>
            </>
          )}
          <div className="gas">
            Network fee <b>0</b> — the filler pays
            {allowance.spender !== null && !allowance.covered && (
              <>
                <br />
                the approval and grant above are the only transactions you send
              </>
            )}
          </div>
          <div className="domain" title="EIP-712 verifyingContract — a signature is bound to this address and chain">
            {domain.deployed ? (
              <>
                signing into Settlement <b>{shortHex(domain.settlement, 8, 6)}</b> on {domain.chainLabel}
              </>
            ) : (
              <>
                no Settlement deployed on {domain.chainLabel} — signatures are real but{" "}
                <b className="warn">not fillable</b>
              </>
            )}
          </div>
          {signError && <div className="signerr">{signError}</div>}
        </div>

        {receipt && (
          <div className="receipt">
            <span className="lbl" style={{ color: "var(--lime)" }}>
              {BOOK_IS_REMOTE ? "Order signed · posted to the orderbook, awaiting a filler" : "Order signed · simulated book, nothing broadcast"}
            </span>
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
