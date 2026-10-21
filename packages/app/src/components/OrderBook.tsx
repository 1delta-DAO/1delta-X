import { Fragment, useMemo } from "react";

import { fmt, fmtAmt, fmtPrice } from "../lib/format";
import { BUCKETS_MAX, BUCKETS_TARGET, bucketWidthBps, bucketize, sourceTag, type BookRow } from "../lib/bookRows";
import { refine, restingLabel, topOfBook, type RestingPreview } from "../lib/ladder";
import { markerIndex } from "../lib/ticketView";
import type { VenueStatus } from "../hooks/usePoolBook";
import { SOURCE_NAME, SOURCE_VAR, type Level, type Side, type Venue } from "../lib/types";

/** Rows shown per side before the ladder is cut off (price buckets, lib/bookRows). */
const ROWS = BUCKETS_TARGET;
/** Hard cap when the ladder is stretched to keep a far-out preview visible. */
const MAX_ROWS = BUCKETS_MAX;

interface Row {
  row: BookRow;
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
  /** Which pools contributed, so a rung's origin is never a mystery. */
  venues: Venue[];
  /** Per-pool load phase, so a venue still in flight says so instead of reading as empty. */
  status: VenueStatus[];
  onRetry: () => void;
  /** A market ticket's active quote, drawn into the side it takes from. */
  marker: BookMarker | null;
  /** Synthetic market: the hubs its route passes through; the book is composed (lib/synthetic). */
  via?: string[];
}

/** The quote line drawn into the ladder. */
export interface BookMarker {
  side: "bid" | "ask";
  price: number;
  /** The slippage minimum's price; ≤ 0 = none. */
  minPrice: number;
  /** "Your quote", or "Book estimate" without a filler quote. */
  label: string;
  /** "via Sushi"… */
  via: string;
  /** "≈ 8,246 USD0". */
  amount: string;
}

/** Marker rows, by insertion index into the side's best-first rows. */
function markersAt(rows: Row[], m: BookMarker | null, side: "bid" | "ask"): Map<number, Array<"quote" | "min">> {
  const at = new Map<number, Array<"quote" | "min">>();
  if (!m || m.side !== side) return at;
  const prices = rows.map((r) => r.row.price);
  const descending = side === "bid";
  const put = (i: number, k: "quote" | "min") => at.set(i, [...(at.get(i) ?? []), k]);
  put(markerIndex(prices, m.price, descending), "quote");
  if (m.minPrice > 0) put(markerIndex(prices, m.minPrice, descending), "min");
  return at;
}

function QuoteLine({ m, kind, tick }: { m: BookMarker; kind: "quote" | "min"; tick: number }) {
  if (kind === "min") {
    return (
      <div className="qmark min" data-side={m.side} title="The order never fills below this price (your slippage protection)">
        <span className="px">{fmt(m.minPrice, tick)}</span>
        <span className="ql">minimum</span>
      </div>
    );
  }
  return (
    <div className="qmark" data-side={m.side} title="Where your market order prices right now">
      <span className="px">{fmt(m.price, tick)}</span>
      <span className="ql">
        {m.label} · <b>{fmt(m.price, tick)}</b> · {m.via}
      </span>
      <span className="qa">{m.amount}</span>
    </div>
  );
}

function previewRow(p: RestingPreview): BookRow {
  return { kind: "lmt", price: p.price, size: p.size, source: "LMT", sources: ["LMT"], pick: p.price, best: p.price, worst: p.price, slices: 1, parts: [] };
}

/** Exported for tests: the displayed rows of one side, with cumulative depth and the cut. */
export function assemble(buckets: BookRow[], preview: RestingPreview | null, descending: boolean, rowsTarget = ROWS, rowsMax = MAX_ROWS) {
  const rows: Row[] = buckets.map((row) => ({ row, cum: 0 }));
  let previewIdx = -1;

  if (preview) {
    // Merge before totalling so the preview's own cumulative is right and every
    // rung past it reflects the depth it adds.
    let i = 0;
    while (i < rows.length && (descending ? rows[i]!.row.price > preview.price : rows[i]!.row.price < preview.price)) i++;
    previewIdx = i;
    rows.splice(i, 0, { row: previewRow(preview), cum: 0, preview });
  }

  let cum = 0;
  let ownIdx = -1;
  for (let i = 0; i < rows.length; i++) {
    cum += rows[i]!.row.size;
    rows[i]!.cum = cum;
    if ((rows[i]!.row.mine ?? 0) > 0) ownIdx = i;
  }

  // Stretch past the default depth for two things the ladder must never hide:
  // the order being composed, and size you already have resting. +2 rather than
  // +1 because both usually sit next to the rung they joined.
  const cut = Math.min(Math.max(rowsTarget, previewIdx + 2, ownIdx + 2), rowsMax);
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

  const r = row.row;
  const own = r.mine ?? 0;
  // The tooltip names the exact pools this size is in — an aggregated ladder is
  // only honest if you can still trace a row back to where it came from.
  const origin =
    r.kind === "lmt"
      ? SOURCE_NAME.LMT
      : r.parts
          .map((p) => `${SOURCE_NAME[p.source]}${p.pool ? ` ${(p.feeBps ?? 0) / 10_000}% ${p.pool.slice(0, 6)}…${p.pool.slice(-4)}` : ""}: ${fmtAmt(p.size)}`)
          .join(" · ");
  const range =
    r.kind === "bucket" && r.slices > 1
      ? ` · avg of ${r.slices} slices ${fmtPrice(r.best, tick)}–${fmtPrice(r.worst, tick)}`
      : "";
  return (
    <button
      type="button"
      className={`lvl${own > 0 ? " owned" : ""}`}
      data-side={rung}
      title={`${origin}${range} · click to set limit ${fmtPrice(r.pick, tick)}${r.kind === "bucket" && r.slices > 1 ? " (fills through this row)" : ""}`}
      onClick={() => onPick(r.pick, rung)}
    >
      <span className="dep" style={{ width }} />
      <span className="px">{fmtPrice(r.price, tick)}</span>
      <span className="sz">{fmtAmt(r.size)}</span>
      <span className="cum">{fmtAmt(row.cum)}</span>
      <span className="sr" data-k={r.sources.length > 1 ? "MIX" : r.source}>
        {own > 0 ? "LMT ·YOU" : sourceTag(r)}
      </span>
    </button>
  );
}

export function OrderBook(props: OrderBookProps) {
  const { bids, asks, base, quote, tick, side, preview, onPickPrice, loading, error, block, venues, status, onRetry, marker, via } =
    props;
  const phaseOf = (pool: string) => status.find((s) => s.pool.toLowerCase() === pool.toLowerCase())?.phase;
  // A pool that has not answered yet has no `Venue` row of its own, so the
  // legend is driven by the configured set — otherwise a slow venue is simply
  // invisible, which reads as "this market has one pool".
  const pending = status.filter((s) => s.phase === "loading" && !venues.some((v) => v.pool.toLowerCase() === s.pool.toLowerCase()));

  const view = useMemo(() => {
    // Rows are the same ~20 bps curve slices the walk prices against (lib/ladder
    // `refine`), not one row per tick range: a sparse pool's single range spans
    // percent, and its AVERAGE drawn as one row sat far below the touch and the
    // quote line. Signed limit orders are flat rungs and pass through unchanged.
    // Then grouped into ~8 price buckets per side (lib/bookRows): one width for
    // both sides, LMT rungs kept as their own rows.
    const a = refine(asks, false);
    const b = refine(bids, true);
    const mid0 = topOfBook(bids, asks).mid;
    const width = bucketWidthBps([a, b], mid0 ? (10 ** -tick / mid0) * 10_000 : 0);
    const askSide = assemble(bucketize(a, false, width), preview?.side === "ask" ? preview : null, false);
    const bidSide = assemble(bucketize(b, true, width), preview?.side === "bid" ? preview : null, true);
    return { askSide, bidSide, width, maxCum: Math.max(askSide.total, bidSide.total, 1) };
  }, [asks, bids, preview, tick]);

  // The TOUCH: marginal prices (a pool rung's `start`), not the rung averages shown
  // per row — on a sparse pool those sit percent away from where the next unit trades.
  const top = topOfBook(bids, asks);
  const mid = top.mid;
  const spreadBps = mid ? ((top.ask! - top.bid!) / mid) * 10_000 : null;
  const askMarks = markersAt(view.askSide.rows, marker, "ask");
  const bidMarks = markersAt(view.bidSide.rows, marker, "bid");

  const lmtDepth = bids.reduce((n, l) => n + (l.source === "LMT" ? l.size : 0), 0);
  const poolDepth = bids.reduce((n, l) => n + (l.source === "LMT" ? 0 : l.size), 0);
  const ratio = poolDepth > 0 ? `${((lmtDepth + poolDepth) / poolDepth).toFixed(2)}× pool depth` : "—";

  const empty = !bids.length || !asks.length;

  return (
    <div className="box">
      <div className="boxhead">
        <div>
          <span className="lbl">{via?.length ? "Routed book · no direct pool" : "Aggregated book"}</span>
          <div className="m" style={{ fontSize: 17, fontWeight: 700, letterSpacing: "-.02em" }}>
            {base} / {quote}
            {via?.length ? (
              <span
                className="viatag"
                title={`No ${base}/${quote} pool exists: this book is composed from the route ${[base, ...via, quote].join(" → ")} over the pools below, net of every hop's fee`}
              >
                via {via.join(" → ")}
              </span>
            ) : null}
          </div>
        </div>
        <span className="pill pill-violet">{ratio}</span>
      </div>

      {empty ? (
        <div className={`bkstate${error ? " err" : ""}`}>
          {loading
            ? `loading depth from ${status.length} ${status.length === 1 ? "pool" : "pools"}…`
            : error
              ? error
              : "no depth for this pool"}
          {!loading && (
            <button type="button" onClick={onRetry}>
              Retry
            </button>
          )}
        </div>
      ) : (
        <>
          <div className={`sh sh-ask${side === "buy" ? " on" : ""}`}>
            <span className="t">Asks: offers to sell {base}</span>
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
            {/* Displayed worst-first: a marker at ascending index i sits just above row i-1. */}
            {(askMarks.get(view.askSide.rows.length) ?? []).slice().reverse().map((k) => (
              <QuoteLine key={`am-end-${k}`} m={marker!} kind={k} tick={tick} />
            ))}
            {view.askSide.rows
              .map((row, i) => ({ row, i }))
              .reverse()
              .map(({ row, i }) => (
                <Fragment key={`a${row.row.price}-${row.row.kind}-${i}`}>
                  <LadderRow row={row} rung="ask" maxCum={view.maxCum} tick={tick} onPick={onPickPrice} />
                  {(askMarks.get(i) ?? []).slice().reverse().map((k) => (
                    <QuoteLine key={`am${i}-${k}`} m={marker!} kind={k} tick={tick} />
                  ))}
                </Fragment>
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
            <span className="t">Bids: offers to buy {base}</span>
            <span className="h">
              click a row to <b>sell</b>
            </span>
          </div>

          <div>
            {view.bidSide.rows.map((row, i) => (
              <Fragment key={`b${row.row.price}-${row.row.kind}-${i}`}>
                {(bidMarks.get(i) ?? []).map((k) => (
                  <QuoteLine key={`bm${i}-${k}`} m={marker!} kind={k} tick={tick} />
                ))}
                <LadderRow row={row} rung="bid" maxCum={view.maxCum} tick={tick} onPick={onPickPrice} />
              </Fragment>
            ))}
            {(bidMarks.get(view.bidSide.rows.length) ?? []).map((k) => (
              <QuoteLine key={`bm-end-${k}`} m={marker!} kind={k} tick={tick} />
            ))}
          </div>

          <div className="bkfoot">
            {venues.map((v) => (
              <span key={v.pool} className={v.error ? "venue-down" : undefined} title={v.pool}>
                <em style={{ background: `var(${SOURCE_VAR[v.source]})` }} />
                {v.hop ? `${v.hop} · ` : ""}
                {SOURCE_NAME[v.source]} {(v.feeBps / 10_000).toFixed(2)}%{" "}
                <b className="m">{v.pool.slice(0, 6)}…{v.pool.slice(-4)}</b>
                {v.error
                  ? `: ${v.error}`
                  : phaseOf(v.pool) === "loading"
                    ? ` · ${v.rungs} rungs · refreshing`
                    : ` · ${v.rungs} rungs`}
              </span>
            ))}
            {pending.map((s) => (
              <span key={s.pool} className="venue-wait" title={s.pool}>
                <em />
                loading <b className="m">{s.pool.slice(0, 6)}…{s.pool.slice(-4)}</b>
              </span>
            ))}
            <span>
              <em style={{ background: "var(--lmt)" }} /> Signed limit orders
            </span>
            {view.bidSide.hidden + view.askSide.hidden > 0 && (
              <span style={{ color: "var(--faint)" }}>
                {view.bidSide.hidden + view.askSide.hidden} deeper rows priced but not shown · rows group{" "}
                {view.width} bps
              </span>
            )}
          </div>
          <p className="bknote">
            A limit order does not have to cross. Name a price the book has not reached and the part that does
            not fill <b>rests where you put it</b>, often inside the spread, marked in the ladder above. Pool
            depth is priced on each pool&rsquo;s curve and grouped into price bands of {view.width} bps from the
            touch: a row&rsquo;s price is what consuming the whole band costs on average, its size and cumulative
            are exact sums, and a band filled from several pools says so (UNI+SUSHI); hover a row for the
            per-pool split. Clicking a band sets your limit at its far edge, so the order fills through it.{" "}
            <b>LMT</b> rows are signed orders a filler can take at any time, each at its own price.
          </p>
        </>
      )}
    </div>
  );
}
