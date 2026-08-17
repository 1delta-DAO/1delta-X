import type { Level, PoolBook, RestingOrder, Side, Source } from "./types";

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
      if (o.side !== side) continue;
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

/**
 * Walk the ladder for `amountIn` of the PAY token.
 *
 * Selling base spends BASE and walks the bids; buying base spends QUOTE and
 * walks the asks. Ladder sizes are BASE on both sides, so the buy path converts
 * per rung rather than pretending the input is already in base units — the
 * shortcut is what makes a "buy 5,000 USDC of ETH" quote silently wrong.
 */
export function walk(levels: Level[], amountIn: number, side: Side, limit: number | null): Simulation {
  const bySource: Record<Source, number> = { DEX: 0, LMT: 0 };
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
      crossedOut += takeBase * l.price;
      bySource[l.source] += takeBase;
    } else {
      const levelCost = l.size * l.price;
      const spend = Math.min(rem, levelCost);
      const takeBase = spend / l.price;
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
  const sim = walk(levels, amountIn, side, limit);

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
  const bySource: Record<Source, number> = { DEX: 0, LMT: 0 };
  let total = 0;
  for (const l of levels) {
    bySource[l.source] += l.size;
    total += l.size;
  }
  return { total, bySource };
}
