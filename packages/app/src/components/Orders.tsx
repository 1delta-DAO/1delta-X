import { useState } from "react";

import { marketById } from "../config/markets";
import { ago, fmtAmt, fmtPrice, shortHex, until } from "../lib/format";
import { SOURCE_NAME, orderStatus, type Fill, type RestingOrder } from "../lib/types";
import type { TokenIndex } from "../hooks/useTokenIndex";
import { PairIcon } from "./TokenIcon";

interface OrdersProps {
  orders: RestingOrder[];
  fills: Fill[];
  tickOf: (marketId: string) => number;
  /**
   * Logos resolve only for the chain currently loaded, and this table spans
   * every market you have traded — so a row on another chain falls back to the
   * generated mark rather than to a broken image.
   */
  tokens: TokenIndex;
  onCancel: (orderHash: string) => void;
}

function Pair({ marketId, tokens }: { marketId: string; tokens: TokenIndex }) {
  const m = marketById(marketId);
  return (
    <span className="in">
      <PairIcon base={tokens.view(m.base)} quote={tokens.view(m.quote)} small />
      {m.base} / {m.quote}
    </span>
  );
}

export function Orders({ orders, fills, tickOf, tokens, onCancel }: OrdersProps) {
  const [tab, setTab] = useState<"open" | "fills">("open");

  // Only orders this account signed belong under "your activity"; the rest of
  // the book is other makers' resting size and is already visible in the ladder.
  const mine = orders.filter((o) => o.mine);
  const myFills = fills.filter((f) => f.mine);

  return (
    <div className="box">
      <div className="boxhead">
        <div className="otabs">
          <button type="button" aria-selected={tab === "open"} onClick={() => setTab("open")}>
            Open orders <span className="c">{mine.length}</span>
          </button>
          <button type="button" aria-selected={tab === "fills"} onClick={() => setTab("fills")}>
            Recent fills <span className="c">{myFills.length}</span>
          </button>
        </div>
        <span className="lbl">
          {tab === "open"
            ? "signed, not on-chain — cancelling is free"
            : "every fill settles on-chain and is verifiable"}
        </span>
      </div>

      <div className="sx">
        {tab === "open" ? (
          <table className="o">
            {mine.length === 0 ? (
              <tbody>
                <tr>
                  <td className="empty">No open orders. Sign a limit or TWAP order to see it here.</td>
                </tr>
              </tbody>
            ) : (
              <>
                <thead>
                  <tr>
                    <th>Market</th>
                    <th>Type</th>
                    <th>Side</th>
                    <th>Size</th>
                    <th>Limit</th>
                    <th>Filled</th>
                    <th>Status</th>
                    <th>Expires</th>
                    <th />
                  </tr>
                </thead>
                <tbody>
                  {mine.map((o) => {
                    const pct = (o.filled / o.size) * 100;
                    const status = orderStatus(o);
                    return (
                      <tr key={o.id}>
                        <td className="pc">
                          <Pair marketId={o.marketId} tokens={tokens} />
                        </td>
                        <td>
                          <span className="ty">
                            {o.type === "twap" ? "TWAP" : "Limit"}
                            {o.slices ? ` · ${o.slices.done}/${o.slices.total}` : ""}
                          </span>
                        </td>
                        <td>
                          <span className="chip" data-s={o.side}>
                            {o.side}
                          </span>
                        </td>
                        <td>
                          {fmtAmt(o.size)} {marketById(o.marketId).base}
                        </td>
                        <td>{fmtPrice(o.price, tickOf(o.marketId))}</td>
                        <td>
                          <div className="prog">
                            <div className="mini">
                              <i style={{ width: `${pct}%`, background: "var(--lmt)" }} />
                            </div>
                            <div className="t">
                              {fmtAmt(o.filled)} · {pct.toFixed(0)}%
                            </div>
                          </div>
                        </td>
                        <td>
                          <span className="st" data-v={status}>
                            {status}
                          </span>
                        </td>
                        <td>{until(o.expiresAt)}</td>
                        <td>
                          <button type="button" className="x" onClick={() => onCancel(o.id)}>
                            Cancel
                          </button>
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </>
            )}
          </table>
        ) : (
          <table className="o">
            {myFills.length === 0 ? (
              <tbody>
                <tr>
                  <td className="empty">No fills yet. A market order settles immediately.</td>
                </tr>
              </tbody>
            ) : (
              <>
                <thead>
                  <tr>
                    <th>When</th>
                    <th>Market</th>
                    <th>Side</th>
                    <th>Size</th>
                    <th>Price</th>
                    <th>Source</th>
                    <th>Filler</th>
                    <th>Transaction</th>
                  </tr>
                </thead>
                <tbody>
                  {myFills.map((f) => (
                    <tr key={f.id}>
                      <td className="faint">{ago(f.at)}</td>
                      <td className="pc">
                        <Pair marketId={f.marketId} tokens={tokens} />
                      </td>
                      <td>
                        <span className="chip" data-s={f.side}>
                          {f.side}
                        </span>
                      </td>
                      <td>
                        {fmtAmt(f.size)} {marketById(f.marketId).base}
                      </td>
                      <td>{fmtPrice(f.price, tickOf(f.marketId))}</td>
                      <td>
                        <span className="sr" data-k={f.source} style={{ fontSize: 11 }}>
                          {SOURCE_NAME[f.source]}
                        </span>
                      </td>
                      <td className="dim">{f.filler}</td>
                      <td>
                        <span className="txl">{shortHex(f.tx, 10, 6)}</span>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </>
            )}
          </table>
        )}
      </div>
    </div>
  );
}
