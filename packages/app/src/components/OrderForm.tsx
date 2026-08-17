import { useEffect, useState } from "react";

import { pairsWith, symbolsOn } from "../config/markets";
import type { Ticket } from "../hooks/useTicket";
import type { TokenIndex } from "../hooks/useTokenIndex";
import { fmtAmt, fmtPrice, shortHex } from "../lib/format";
import { restingLabel, type Quote } from "../lib/ladder";
import { SOURCE_NAME, SOURCE_VAR, type Source } from "../lib/types";
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

export function OrderForm(props: OrderFormProps) {
  const { ticket, quote, tokens, balances, tick, mid, ready, signing, receipt, gate, onSign } = props;
  const [approved, setApproved] = useState(false);
  const [approving, setApproving] = useState(false);

  const { amount, payToken, recvToken, mode, side, market, payBalance } = ticket;

  // An allowance is per token and per chain, so either changing invalidates it.
  useEffect(() => {
    setApproved(false);
    setApproving(false);
  }, [payToken, ticket.chainId]);

  const resting = quote?.resting ?? null;
  const overBalance = payBalance !== undefined && amount > payBalance;
  const twapMinutes = ticket.slices * ticket.everyMin;

  const approve = () => {
    setApproving(true);
    // Stands in for the allowance transaction; the sign step stays gated on it
    // so the two-step shape of a first trade is visible.
    setTimeout(() => {
      setApproving(false);
      setApproved(true);
    }, 800);
  };

  const bar: Array<{ key: string; pct: number; color: string; label: string }> = [];
  if (quote && amount > 0 && quote.filledIn > 0) {
    for (const src of ["DEX", "LMT"] as Source[]) {
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
    rows.push(["Minimum received", `${fmtAmt(quote.minReceived)} ${recvToken}`, "good"]);
    rows.push(["Expires", mode === "market" ? "60 seconds" : mode === "twap" ? "on completion" : "24 hours", ""]);
  }

  const canSign = ready && approved && !signing && amount > 0 && !overBalance && !!quote && quote.totalIn > 0;

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
                disabled={payBalance === undefined || payBalance <= 0}
                onClick={() => ticket.setAmount(String(payBalance ?? 0))}
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
              value={quote && quote.totalOut > 0 ? fmtAmt(quote.totalOut) : ""}
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
                ) : (
                  `sized to fill ${fmtAmt(amount)} ${payToken}`
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

        <div style={{ display: "flex", flexDirection: "column", gap: 9 }}>
          {gate ? (
            <button type="button" className="cta" onClick={gate.action}>
              {gate.label}
            </button>
          ) : (
            <>
              <button
                type="button"
                className={approved ? "cta ok" : "cta line"}
                disabled={approved || approving}
                onClick={approve}
              >
                {approved
                  ? "✓ Permission granted"
                  : approving
                    ? "Granting permission…"
                    : `Approve ${payToken} · one time`}
              </button>
              <button type="button" className="cta" disabled={!canSign} onClick={onSign}>
                {signing ? "Waiting for signature…" : "Sign order"}
              </button>
            </>
          )}
          <div className="gas">
            Network fee <b>0</b> — the filler pays
          </div>
        </div>

        {receipt && (
          <div className="receipt">
            <span className="lbl" style={{ color: "var(--lime)" }}>
              Order signed · broadcast
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
