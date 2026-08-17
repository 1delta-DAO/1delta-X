import { useMemo } from "react";

import { fmt, fmtAmt, fmtPrice } from "../lib/format";
import { restingLabel, type RestingPreview } from "../lib/ladder";
import { SOURCE_NAME, type Level, type Side } from "../lib/types";

/** Rungs shown per side before the ladder is cut off. */
const ROWS = 14;
/** Hard cap when the ladder is stretched to keep a far-out preview visible. */
const MAX_ROWS = 26;

interface Row {
  level: Level;
  cum: number;
  preview?: RestingPreview;
}

interface OrderBookProps {
  bids: Level[];
  asks: Level[];
  base: string;
  quote: string;
  tick: number;
  side: Side;
  /** The order being composed, previewed in position before it is signed. */
  preview: RestingPreview | null;
  onPickPrice: (price: number, rung: "bid" | "ask") => void;
  loading: boolean;
  error: string | null;
  block: number | null;
  onRetry: () => void;
}

function assemble(levels: Level[], preview: RestingPreview | null, descending: boolean) {
  const rows: Row[] = levels.map((level) => ({ level, cum: 0 }));
  let previewIdx = -1;

  if (preview) {
    // Merge before totalling so the preview's own cumulative is right and every
    // rung past it reflects the depth it adds.
    let i = 0;
    while (i < rows.length && (descending ? rows[i].level.price > preview.price : rows[i].level.price < preview.price)) i++;
    previewIdx = i;
    rows.splice(i, 0, {
      level: { price: preview.price, size: preview.size, source: "LMT" },
      cum: 0,
      preview,
    });
  }

  let cum = 0;
  let ownIdx = -1;
  for (let i = 0; i < rows.length; i++) {
    cum += rows[i].level.size;
    rows[i].cum = cum;
    if ((rows[i].level.mine ?? 0) > 0) ownIdx = i;
  }

  // Stretch past the default depth for two things the ladder must never hide:
  // the order being composed, and size you already have resting. +2 rather than
  // +1 because both usually sit next to the rung they joined.
  const cut = Math.min(Math.max(ROWS, previewIdx + 2, ownIdx + 2), MAX_ROWS);
  return { rows: rows.slice(0, cut), total: cum, hidden: Math.max(0, rows.length - cut) };
}

function LadderRow({
  row,
  rung,
  maxCum,
  tick,
  onPick,
}: {
  row: Row;
  rung: "bid" | "ask";
  maxCum: number;
  tick: number;
  onPick: (price: number, rung: "bid" | "ask") => void;
}) {
  const width = `${((row.cum / maxCum) * 100).toFixed(1)}%`;

  if (row.preview) {
    const p = row.preview;
    return (
      <div
        className={`lvl mine${p.beyond || p.exhausted ? " far" : ""}${p.inside ? " inside" : ""}`}
        data-side={rung}
        title={restingLabel(p)}
      >
        <span className="dep" style={{ width }} />
        <span className="px">{fmtPrice(p.price, tick)}</span>
        <span className="sz">{fmtAmt(p.size)}</span>
        <span className="cum">
          {p.exhausted ? "past depth" : p.inside ? "new best" : p.beyond ? "beyond book" : "resting"}
        </span>
        <span className="sr">YOU {p.side === "bid" ? "BUY" : "SELL"}</span>
      </div>
    );
  }

  const own = row.level.mine ?? 0;
  return (
    <button
      type="button"
      className={`lvl${own > 0 ? " owned" : ""}`}
      data-side={rung}
      title={`${SOURCE_NAME[row.level.source]} · click to set limit price`}
      onClick={() => onPick(row.level.price, rung)}
    >
      <span className="dep" style={{ width }} />
      <span className="px">{fmtPrice(row.level.price, tick)}</span>
      <span className="sz">{fmtAmt(row.level.size)}</span>
      <span className="cum">{fmtAmt(row.cum)}</span>
      <span className="sr" data-k={row.level.source}>
        {own > 0 ? "LMT ·YOU" : row.level.source}
      </span>
    </button>
  );
}

export function OrderBook(props: OrderBookProps) {
  const { bids, asks, base, quote, tick, side, preview, onPickPrice, loading, error, block, onRetry } = props;

  const view = useMemo(() => {
    const askSide = assemble(asks, preview?.side === "ask" ? preview : null, false);
    const bidSide = assemble(bids, preview?.side === "bid" ? preview : null, true);
    return { askSide, bidSide, maxCum: Math.max(askSide.total, bidSide.total, 1) };
  }, [asks, bids, preview]);

  const bestBid = view.bidSide.rows.find((r) => !r.preview)?.level.price ?? bids[0]?.price;
  const bestAsk = view.askSide.rows.find((r) => !r.preview)?.level.price ?? asks[0]?.price;
  const mid = bestBid !== undefined && bestAsk !== undefined ? (bestBid + bestAsk) / 2 : null;
  const spreadBps = mid ? ((bestAsk! - bestBid!) / mid) * 10_000 : null;

  const lmtDepth = bids.reduce((n, l) => n + (l.source === "LMT" ? l.size : 0), 0);
  const dexDepth = bids.reduce((n, l) => n + (l.source === "DEX" ? l.size : 0), 0);
  const ratio = dexDepth > 0 ? `${((lmtDepth + dexDepth) / dexDepth).toFixed(2)}× pool depth` : "—";

  const empty = !bids.length || !asks.length;

  return (
    <div className="box">
      <div className="boxhead">
        <div>
          <span className="lbl">Aggregated book</span>
          <div className="m" style={{ fontSize: 17, fontWeight: 700, letterSpacing: "-.02em" }}>
            {base} / {quote}
          </div>
        </div>
        <span className="pill pill-violet">{ratio}</span>
      </div>

      {empty ? (
        <div className={`bkstate${error ? " err" : ""}`}>
          {loading ? "loading pool depth…" : error ? error : "no depth for this pool"}
          {!loading && (
            <button type="button" onClick={onRetry}>
              Retry
            </button>
          )}
        </div>
      ) : (
        <>
          <div className={`sh sh-ask${side === "buy" ? " on" : ""}`}>
            <span className="t">Asks — offers to sell {base}</span>
            <span className="h">
              click a row to <b>buy</b>
            </span>
          </div>
          <div className="bkcols">
            <span>Price</span>
            <span>Size</span>
            <span>Cumulative</span>
            <span>Source</span>
          </div>

          <div>
            {[...view.askSide.rows].reverse().map((row, i) => (
              <LadderRow
                key={`a${row.level.price}-${row.level.source}-${i}`}
                row={row}
                rung="ask"
                maxCum={view.maxCum}
                tick={tick}
                onPick={onPickPrice}
              />
            ))}
          </div>

          <div className="spread">
            <div>
              <div className="lbl" style={{ marginBottom: 4 }}>
                Mid
              </div>
              {/* One decimal past the grid: a mid that rounds onto a rung reads
                  as if the spread were zero. */}
              <div className="mid">{mid === null ? "—" : fmtPrice(mid, tick + 1)}</div>
            </div>
            <div className="meta">
              spread {spreadBps === null ? "—" : `${spreadBps.toFixed(1)} bps`}
              <br />
              {fmtAmt(view.bidSide.total)} {base} bid · {fmtAmt(view.askSide.total)} ask
              <br />
              {block === null ? "—" : `block ${fmt(block, 0)}`}
            </div>
          </div>

          <div className={`sh sh-bid${side === "sell" ? " on" : ""}`}>
            <span className="t">Bids — offers to buy {base}</span>
            <span className="h">
              click a row to <b>sell</b>
            </span>
          </div>

          <div>
            {view.bidSide.rows.map((row, i) => (
              <LadderRow
                key={`b${row.level.price}-${row.level.source}-${i}`}
                row={row}
                rung="bid"
                maxCum={view.maxCum}
                tick={tick}
                onPick={onPickPrice}
              />
            ))}
          </div>

          <div className="bkfoot">
            <span>
              <em style={{ background: "var(--dex)" }} /> Uniswap v3 tick liquidity — live
            </span>
            <span>
              <em style={{ background: "var(--lmt)" }} /> Signed limit orders
            </span>
            {view.bidSide.hidden + view.askSide.hidden > 0 && (
              <span style={{ color: "var(--faint)" }}>
                {view.bidSide.hidden + view.askSide.hidden} deeper rungs priced but not shown
              </span>
            )}
          </div>
          <p className="bknote">
            A limit order does not have to cross. Name a price the book has not reached and the part that does
            not fill <b>rests where you put it</b> — often inside the spread, marked in the ladder above. Each
            pool rung is one range between initialized ticks, priced at what it actually costs to consume, so
            a concentrated position shows up as the cliff it is; <b>LMT</b> rungs are signed orders a filler
            can take at any time.
          </p>
        </>
      )}
    </div>
  );
}
