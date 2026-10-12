/**
 * SYNTHETIC books: the order book of a pair with no pool of its own, composed from
 * the books of the hops a route takes (docs/synthetic-pairs.md).
 *
 * A filler fills such a pair as a multi-hop route (A → hub → C). The app's ladder,
 * though, comes from pool ticks, and there is no A/C pool to read. So each SIDE of
 * the A/C book is built from the hop ladders the route walks:
 *
 *   bids (a taker SELLS base):  out(x) = walkₙ(… walk₁(x))  along base → … → quote
 *   asks (a taker BUYS base):   out(q) = walk₁(… walkₙ(q))  along quote → … → base
 *
 * Each composite curve is sampled on a geometric input grid. Consecutive samples
 * are merged into rungs no wider than {@link BAND_BPS}, carrying the marginal price
 * at both edges (`start` / `end`), so `walk()` prices a partial rung on its curve and
 * `topOfBook()` reads the true touch. The rungs are tagged `ROUTE`. Everything
 * downstream (merge with resting orders, walk / quote, cumulative depth, the quote
 * marker) takes them like any other rung.
 *
 * Every hop ladder is already fee-net (`fetchVenue`), so the composite is net of
 * every hop's fee. Its spread is the compounded route fee, as a router executes it.
 */
import { refine, walk } from "./ladder";
import type { Level } from "./types";

/** One hop's book, all of its pools merged: sizes in the HOP's base, prices hop-quote per hop-base. */
export interface HopBook {
  base: string;
  quote: string;
  bids: Level[];
  asks: Level[];
}

/** Widest rung the composite emits, bps between its edge prices. */
export const BAND_BPS = 5;
/** Grid points per side: the input runs geometrically from capacity × 1e-6 to capacity. */
export const GRID_POINTS = 360;
/** Nothing further than this from the touch is book (the pool books use the same 20 %). */
export const MAX_SPREAD = 0.2;
/** Below this the composite is treated as exhausted (floating dust from the walks). */
const EPS = 1e-12;
/** Smallest grid input, token units: above `walk()`'s 1e-9 dust cut-off. */
const MIN_INPUT = 1e-7;

interface PreparedHop {
  hop: HopBook;
  /** Refined once per compose: walk() expects pieces, sorted best-first. */
  bids: Level[];
  asks: Level[];
}

function prepare(hops: readonly HopBook[]): PreparedHop[] {
  return hops.map((hop) => ({
    hop,
    bids: refine([...hop.bids].sort((a, b) => b.price - a.price), true),
    asks: refine([...hop.asks].sort((a, b) => a.price - b.price), false),
  }));
}

/** Push `amount` of `token` through one hop: what comes out, and whether all of it went in. */
function through(h: PreparedHop, token: string, amount: number): { out: number; full: boolean; next: string } {
  if (token === h.hop.base) {
    const s = walk(h.bids, amount, "sell", null);
    return { out: s.crossedOut, full: s.unfilledIn <= Math.max(amount * 1e-9, 1e-9), next: h.hop.quote };
  }
  if (token === h.hop.quote) {
    const s = walk(h.asks, amount, "buy", null);
    return { out: s.crossedOut, full: s.unfilledIn <= Math.max(amount * 1e-9, 1e-9), next: h.hop.base };
  }
  throw new Error(`hop ${h.hop.base}/${h.hop.quote} does not trade ${token}`);
}

/** The token sequence a route visits, validated hop by hop. */
export function routeTokens(hops: readonly Pick<HopBook, "base" | "quote">[], from: string): string[] {
  const path = [from];
  let cur = from;
  for (const h of hops) {
    if (cur !== h.base && cur !== h.quote) throw new Error(`hop ${h.base}/${h.quote} does not connect to ${cur}`);
    cur = cur === h.base ? h.quote : h.base;
    path.push(cur);
  }
  return path;
}

/** Output of the whole route for `amount` of its first token; `full` when no hop ran out. */
function routeOut(prepared: readonly PreparedHop[], from: string, amount: number): { out: number; full: boolean } {
  let token = from;
  let x = amount;
  for (const h of prepared) {
    const r = through(h, token, x);
    if (!r.full) return { out: r.out, full: false };
    token = r.next;
    x = r.out;
  }
  return { out: x, full: true };
}

/** What the first hop can absorb of `from`, in `from` units: an upper bound for the route. */
function firstHopCapacity(h: PreparedHop, from: string): number {
  if (from === h.hop.base) return h.bids.reduce((n, l) => n + l.size, 0);
  return h.asks.reduce((n, l) => n + l.size * l.price, 0);
}

/** The largest input the WHOLE route fills completely (bisection on `full`, which is monotone). */
function capacity(prepared: readonly PreparedHop[], from: string): number {
  let hi = firstHopCapacity(prepared[0]!, from);
  if (!(hi > 0)) return 0;
  if (routeOut(prepared, from, hi).full) return hi;
  let lo = 0;
  for (let i = 0; i < 48; i++) {
    const mid = (lo + hi) / 2;
    if (routeOut(prepared, from, mid).full) lo = mid;
    else hi = mid;
  }
  return lo;
}

/**
 * One side of the composite book.
 *
 * `sell` (bids): the input is BASE and `out` is QUOTE, so a rung's size is Δin and
 * its price Δout/Δin. `buy` (asks): the input is QUOTE and `out` is BASE, so a
 * rung's size is Δout and its price Δin/Δout. Prices fall along the bids and rise
 * along the asks, as on a pool's ladder.
 */
function composeSide(prepared: readonly PreparedHop[], from: string, side: "sell" | "buy"): Level[] {
  const cap = capacity(prepared, from);
  if (!(cap > 0)) return [];
  const rungs: Level[] = [];
  let prevIn = 0;
  let prevOut = 0;
  let touch: number | null = null;
  // The rung being built: its edges and totals.
  let open: { start: number; end: number; size: number; value: number } | null = null;
  const close = () => {
    if (open && open.size > EPS) {
      rungs.push({ price: open.value / open.size, size: open.size, start: open.start, end: open.end, source: "ROUTE" });
    }
    open = null;
  };

  // `walk()` ignores inputs under its 1e-9 dust threshold, so the grid starts above it
  // (1e-7 of any token is far below one cent for every pair this app lists).
  const lo = Math.max(cap * 1e-6, MIN_INPUT);
  if (!(lo < cap)) return [];
  const span = Math.log10(cap / lo);
  for (let i = 0; i <= GRID_POINTS; i++) {
    const x = i === GRID_POINTS ? cap : lo * 10 ** ((span * i) / GRID_POINTS);
    const r = routeOut(prepared, from, x);
    if (!r.full) break;
    const dIn = x - prevIn;
    const dOut = r.out - prevOut;
    prevIn = x;
    prevOut = r.out;
    if (!(dIn > EPS) || !(dOut > EPS)) continue;
    // Segment in BOOK terms: size in base, value in quote.
    const size = side === "sell" ? dIn : dOut;
    const value = side === "sell" ? dOut : dIn;
    const price = value / size;
    touch ??= price;
    if (Math.abs(price / touch - 1) > MAX_SPREAD) break;
    if (open && Math.abs(Math.log(price / open.start)) * 10_000 > BAND_BPS) close();
    if (!open) open = { start: price, end: price, size: 0, value: 0 };
    open.end = price;
    open.size += size;
    open.value += value;
  }
  close();
  return rungs;
}

/**
 * The composite bids and asks of `base`/`quote` over `hops` (ordered base → quote).
 * Empty sides when a hop has no depth on the side the route needs.
 */
export function composeBook(hops: readonly HopBook[], base: string, quote: string): { bids: Level[]; asks: Level[] } {
  const path = routeTokens(hops, base);
  if (path[path.length - 1] !== quote) throw new Error(`route ${path.join(" → ")} does not end at ${quote}`);
  const forward = prepare(hops);
  const backward = [...forward].reverse();
  return {
    bids: composeSide(forward, base, "sell"),
    asks: composeSide(backward, quote, "buy"),
  };
}
