import { SOURCES, type Level, type PoolBook, type RestingOrder, type Side, type Source } from "./types";

/** A zeroed tally per source — one place that knows the full source set. */
export function emptyBySource(): Record<Source, number> {
  return Object.fromEntries(SOURCES.map((s) => [s, 0])) as Record<Source, number>;
}

/** Rounding floor for "is there anything left" checks, in BASE units. */
const EPS = 1e-9;

/**
 * Merge resting signed orders into the pool ladder.
 *
 * A resting SELL is an offer to sell base, so it joins the asks; a resting BUY
 * joins the bids. Orders at the same price collapse into one rung, because a
 * taker cannot tell them apart and neither should the ladder.
 */
export function mergeLadder(pool: PoolBook, resting: RestingOrder[]): { bids: Level[]; asks: Level[] } {
  const build = (side: Side, poolSide: Level[], descending: boolean): Level[] => {
    const byPrice = new Map<number, Level>();
    for (const o of resting) {
      // A soft-cancelled order is retracted from the book even though its
      // signature still lives; showing it as depth would invite fills on it.
      if (o.side !== side || o.cancelled || o.offBook) continue;
      // A real-book order priced THROUGH the pool mid is marketable and waiting
      // for a filler, not depth: drawing it would cross the ladder and let the
      // next ticket quote against the maker's own pending order.
      if (o.book === "remote" && (side === "buy" ? o.price >= pool.mid : o.price <= pool.mid)) continue;
      const left = o.size - o.filled;
      if (left <= EPS) continue;
      const at = byPrice.get(o.price);
      if (at) {
        at.size += left;
        if (o.mine) at.mine = (at.mine ?? 0) + left;
      } else {
        byPrice.set(o.price, { price: o.price, size: left, source: "LMT", mine: o.mine ? left : undefined });
      }
    }
    const merged = [...poolSide, ...byPrice.values()];
    merged.sort((a, b) => (descending ? b.price - a.price : a.price - b.price));
    return merged;
  };

  return {
    bids: build("buy", pool.bids, true),
    asks: build("sell", pool.asks, false),
  };
}

export interface Simulation {
  /** Amount of the PAY token the ladder can absorb, and what it cannot. */
  filledIn: number;
  unfilledIn: number;
  /** RECEIVE-token amount produced by the part that crosses now. */
  crossedOut: number;
  /** Share of the requested input consumed, split by where it came from. */
  bySource: Record<Source, number>;
  /** Quote per base for the part that crosses. 0 when nothing crosses. */
  avg: number;
  /** BASE amount that crosses — the ladder's own unit, used by the fill record. */
  crossedBase: number;
}

/** The price a taker meets first on a rung: its marginal `start` when it has one. */
export function topPrice(l: Level): number {
  return l.start ?? l.price;
}

/**
 * Best bid / best ask as MARGINAL prices (what the next unit actually trades at),
 * and their midpoint. A pool rung's displayed `price` is the average over the whole
 * range, which on a sparse pool sits far from the touch.
 */
export function topOfBook(bids: readonly Level[], asks: readonly Level[]): { bid: number | null; ask: number | null; mid: number | null } {
  let bid: number | null = null;
  let ask: number | null = null;
  for (const l of bids) {
    const p = topPrice(l);
    if (p > 0 && (bid === null || p > bid)) bid = p;
  }
  for (const l of asks) {
    const p = topPrice(l);
    if (p > 0 && (ask === null || p < ask)) ask = p;
  }
  return { bid, ask, mid: bid !== null && ask !== null ? (bid + ask) / 2 : null };
}

/** Constant liquidity of a curve rung, in human units: size = L·|1/√start − 1/√end|. */
function curveL(l: Level): number | null {
  if (l.start === undefined || l.end === undefined || !(l.start > 0) || !(l.end > 0) || l.start === l.end) return null;
  const d = Math.abs(1 / Math.sqrt(l.start) - 1 / Math.sqrt(l.end));
  return d > 0 ? l.size / d : null;
}

/**
 * QUOTE out for selling `base` (≤ size) into a bid rung from its start: the price
 * falls along the curve, 1/√p' = 1/√start + base/L, out = L·(√start − √p').
 * Flat rungs (no start/end) pay `price`.
 */
export function sellOnRung(l: Level, base: number): number {
  const L = curveL(l);
  if (L === null || base >= l.size) return base * l.price;
  const s0 = Math.sqrt(l.start!);
  const inv = 1 / s0 + base / L;
  return L * (s0 - 1 / inv);
}

/**
 * BASE out for spending `quote` (≤ size·price) on an ask rung from its start: the
 * price rises, √p' = √start + quote/L, base = L·(1/√start − 1/√p').
 */
export function buyOnRung(l: Level, quote: number): number {
  const L = curveL(l);
  if (L === null || quote >= l.size * l.price) return quote / l.price;
  const s0 = Math.sqrt(l.start!);
  return L * (1 / s0 - 1 / (s0 + quote / L));
}

/** Most pieces one curve rung is cut into for the walk. */
const MAX_PIECES = 32;
/** Target width of one piece, as a price fraction (20 bps). */
const PIECE_FRACTION = 0.002;

/**
 * Cut every curve rung into constant-liquidity pieces ~20 bps wide and re-sort.
 *
 * The displayed ladder keeps one rung per tick range, but a greedy walk over those
 * ranges ordered by their AVERAGE price takes the wrong venue first whenever one
 * venue's range is wide (its average is far from its touch) and another's is narrow.
 * Walking pieces instead interleaves venues by what each slice really costs — the
 * order a router would take them in. Piece sizes sum exactly to the rung's size.
 */
export function refine(levels: readonly Level[], descending: boolean): Level[] {
  const out: Level[] = [];
  let cut = false;
  for (const l of levels) {
    const L = curveL(l);
    if (L === null) {
      out.push(l);
      continue;
    }
    const ratio = l.end! / l.start!;
    const k = Math.min(MAX_PIECES, Math.max(1, Math.ceil(Math.abs(Math.log(ratio)) / Math.log1p(PIECE_FRACTION))));
    if (k === 1) {
      out.push(l);
      continue;
    }
    cut = true;
    let prev = l.start!;
    let used = 0;
    for (let i = 1; i <= k; i++) {
      const next = i === k ? l.end! : l.start! * ratio ** (i / k);
      const size = i === k ? l.size - used : L * Math.abs(1 / Math.sqrt(next) - 1 / Math.sqrt(prev));
      used += size;
      if (size > 0) out.push({ ...l, price: Math.sqrt(prev * next), size, start: prev, end: next, mine: undefined });
      prev = next;
    }
  }
  if (!cut) return out;
  return out.sort((a, b) => (descending ? b.price - a.price : a.price - b.price));
}

/**
 * Walk the ladder for `amountIn` of the PAY token.
 *
 * Selling base spends BASE and walks the bids; buying base spends QUOTE and
 * walks the asks. Ladder sizes are BASE on both sides, so the buy path converts
 * per rung rather than pretending the input is already in base units — the
 * shortcut is what makes a "buy 5,000 USDC of ETH" quote silently wrong.
 *
 * A pool rung consumed only in PART is priced on its curve (`sellOnRung` /
 * `buyOnRung`) — not at its whole-range average, which priced 0.1 WRBTC 6 % under
 * the pool's spot on a range 11 % wide (2026-10-11).
 */
export function walk(levels: Level[], amountIn: number, side: Side, limit: number | null): Simulation {
  const bySource = emptyBySource();
  let rem = amountIn;
  let crossedBase = 0;
  let crossedOut = 0;

  for (const l of levels) {
    if (rem <= EPS) break;
    if (limit !== null) {
      // A sell will not go below its limit; a buy will not go above it.
      if (side === "sell" && l.price < limit) break;
      if (side === "buy" && l.price > limit) break;
    }
    if (side === "sell") {
      const takeBase = Math.min(rem, l.size);
      rem -= takeBase;
      crossedBase += takeBase;
      crossedOut += takeBase < l.size ? sellOnRung(l, takeBase) : takeBase * l.price;
      bySource[l.source] += takeBase;
    } else {
      const levelCost = l.size * l.price;
      const spend = Math.min(rem, levelCost);
      const takeBase = spend < levelCost ? buyOnRung(l, spend) : l.size;
      rem -= spend;
      crossedBase += takeBase;
      crossedOut += takeBase;
      bySource[l.source] += spend;
    }
  }

  const filledIn = amountIn - rem;
  return {
    filledIn,
    unfilledIn: rem,
    crossedOut,
    bySource,
    avg: crossedBase > EPS ? (side === "sell" ? crossedOut / crossedBase : filledIn / crossedBase) : 0,
    crossedBase,
  };
}

export interface RestingPreview {
  price: number;
  /** BASE size that would rest. */
  size: number;
  /** Which side of the ladder it lands on. */
  side: "bid" | "ask";
  /** Better than the current best on that side — it becomes the new top. */
  inside: boolean;
  /** Past the last rung the ladder shows. */
  beyond: boolean;
  /**
   * The named price is through the opposite side's best, so a book with more
   * rungs would have taken this size rather than let it rest. The ladder ran
   * out, not the demand — and calling that "the new best bid" would be a lie.
   */
  exhausted: boolean;
}

export interface Quote extends Simulation {
  resting: RestingPreview | null;
  /** Total RECEIVE-token amount: what crosses now plus what rests, at your price. */
  totalOut: number;
  /** Total PAY-token amount that actually goes to work. */
  totalIn: number;
  minReceived: number;
}

export interface QuoteArgs {
  bids: Level[];
  asks: Level[];
  side: Side;
  amountIn: number;
  /** Null for a market order. */
  limit: number | null;
  /** Market orders quote a slippage floor instead of an exact receive. */
  slippageBps: number;
}

/**
 * What the order is actually worth: the part that crosses now, plus the part
 * that rests valued at the price you named. Pricing a limit order off the
 * crossing part alone reports zero for an order that rests in full, which is
 * the normal case for anything placed inside the spread.
 */
export function quote(args: QuoteArgs): Quote {
  const { bids, asks, side, amountIn, limit, slippageBps } = args;
  const levels = side === "sell" ? bids : asks;
  const sim = walk(refine(levels, side === "sell"), amountIn, side, limit);

  let resting: RestingPreview | null = null;
  if (limit !== null && sim.unfilledIn > EPS && limit > 0) {
    // The leftover PAY amount becomes BASE size at the price the maker named.
    const size = side === "sell" ? sim.unfilledIn : sim.unfilledIn / limit;
    const onAsk = side === "sell";
    const own = onAsk ? asks : bids;
    const opposite = onAsk ? bids : asks;
    const best = own[0]?.price;
    const last = own[own.length - 1]?.price;
    const bestOpposite = opposite[0]?.price;
    const exhausted =
      bestOpposite !== undefined && (onAsk ? limit <= bestOpposite : limit >= bestOpposite);
    resting = {
      price: limit,
      size,
      side: onAsk ? "ask" : "bid",
      inside: !exhausted && best !== undefined && (onAsk ? limit < best : limit > best),
      beyond: last !== undefined && (onAsk ? limit > last : limit < last),
      exhausted,
    };
  }

  const restingOut = resting ? (side === "sell" ? resting.size * limit! : resting.size) : 0;
  const totalOut = sim.crossedOut + restingOut;
  const totalIn = resting ? sim.filledIn + sim.unfilledIn : sim.filledIn;

  return {
    ...sim,
    resting,
    totalOut,
    totalIn,
    // A market order can only promise a floor; a limit order's floor IS its price.
    minReceived: limit === null ? sim.crossedOut * (1 - slippageBps / 10_000) : totalOut,
  };
}

/**
 * The price that clears the whole size — walk the ladder until the amount is
 * exhausted and take the last rung touched. Anchoring a limit to the front of
 * the book instead would only ever fill the top level, which is not what
 * someone sizing a large order wants.
 */
export function clearingPrice(levels: Level[], amountIn: number, side: Side): number | null {
  if (!levels.length) return null;
  let rem = amountIn;
  let px = levels[0].price;
  for (const l of levels) {
    if (rem <= EPS) break;
    px = l.price;
    rem -= side === "sell" ? Math.min(rem, l.size) : Math.min(rem, l.size * l.price);
  }
  return px;
}

export function restingLabel(r: RestingPreview): string {
  // A resting buy is an offer to buy, so it joins the bids; a resting sell joins
  // the asks. Saying so avoids the natural misreading that "I am buying" puts
  // the order on the side you bought from.
  if (r.exhausted) return "Past the depth the ladder shows";
  if (r.inside) return `Rests as the new best ${r.side}`;
  if (r.beyond) return `Rests beyond the ${r.side}s`;
  return `Rests among the ${r.side}s`;
}

/** Cumulative BASE depth per side, and the split by source, for the stat row. */
export function depth(levels: Level[]): { total: number; bySource: Record<Source, number> } {
  const bySource = emptyBySource();
  let total = 0;
  for (const l of levels) {
    bySource[l.source] += l.size;
    total += l.size;
  }
  return { total, bySource };
}
