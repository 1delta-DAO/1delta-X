import type { Market } from "../config/markets";
import { fetchPoolLiquidity, fetchPoolMeta, type PoolMeta } from "./oku";
import { normSymbol as norm } from "./symbols";
import type { Level, PoolBook } from "./types";
import { buildLadder, type PoolLiquidity } from "./univ3";

/** Rungs walked out from mid per side before the ladder is truncated. */
const MAX_RUNGS = 90;

/** Nothing further than this from mid is book, it is scenery. */
const MAX_SPREAD = 0.2;

/**
 * Display precision, in significant figures rather than fixed decimals: the
 * same app quotes ETH at ~1,900 and UNI at ~0.0017, and one decimal count
 * cannot serve both.
 */
function tickFor(mid: number): number {
  if (!(mid > 0)) return 4;
  const magnitude = Math.floor(Math.log10(mid)) + 1;
  return Math.max(0, Math.min(10, 6 - magnitude));
}

/**
 * Typical gap between adjacent rungs, used to place seeded orders on-grid.
 *
 * Clamped, because a thin pool's rungs can be percent apart: unclamped, orders
 * seeded a few "steps" from mid would land tens of percent away and never
 * appear in the ladder at all.
 */
function stepOf(levels: Level[], mid: number): number {
  const gaps: number[] = [];
  for (let i = 1; i < levels.length && gaps.length < 24; i++) {
    const gap = Math.abs(levels[i].price - levels[i - 1].price);
    if (gap > 0) gaps.push(gap);
  }
  gaps.sort((a, b) => a - b);
  const median = gaps.length ? gaps[Math.floor(gaps.length / 2)] : mid * 0.0005;
  return Math.min(Math.max(median, mid * 1e-6), mid * 0.002);
}

export interface FetchBookArgs {
  market: Market;
  /** Oku chain slug. */
  chain: string;
  /** Cached pool identity; fetched on first use and reused after. */
  meta?: PoolMeta;
  signal?: AbortSignal;
}

export interface FetchBookResult {
  book: PoolBook;
  meta: PoolMeta;
}

/**
 * Assemble the pool half of the ladder from the pool's own tick liquidity.
 *
 * Orientation is resolved from the pool's symbols rather than configured, so a
 * pool whose token0/token1 order is the reverse of how the market is quoted
 * still lands the right way up.
 */
export async function fetchPoolBook(args: FetchBookArgs): Promise<FetchBookResult> {
  const { market, chain, signal } = args;
  const meta = args.meta ?? (await fetchPoolMeta(chain, market.pool, signal));

  const wantBase = norm(market.base);
  const wantQuote = norm(market.quote);
  const t0 = norm(meta.token0.symbol);
  const t1 = norm(meta.token1.symbol);

  let baseIsToken0: boolean;
  if (t0 === wantBase && t1 === wantQuote) baseIsToken0 = true;
  else if (t1 === wantBase && t0 === wantQuote) baseIsToken0 = false;
  else {
    throw new Error(
      `pool ${market.pool} holds ${meta.token0.symbol}/${meta.token1.symbol}, not ${market.base}/${market.quote}`,
    );
  }

  const liquidity: PoolLiquidity = await fetchPoolLiquidity(chain, market.pool, signal);
  const ladder = buildLadder(liquidity, { baseIsToken0, maxRungs: MAX_RUNGS, maxSpread: MAX_SPREAD });
  if (!ladder.bids.length || !ladder.asks.length) {
    throw new Error(`pool ${market.pool} has no liquidity around the current price`);
  }

  const bids: Level[] = ladder.bids.map((r) => ({ price: r.price, size: r.size, source: "DEX" }));
  const asks: Level[] = ladder.asks.map((r) => ({ price: r.price, size: r.size, source: "DEX" }));
  // Mid is the midpoint of what a taker can actually get, not the pool's spot:
  // spot ignores the fee tier and the ladder's first rung does not.
  const mid = (bids[0].price + asks[0].price) / 2;

  return {
    meta,
    book: {
      pool: meta.pool,
      chainId: market.chainId,
      block: liquidity.block,
      base: baseIsToken0 ? meta.token0 : meta.token1,
      quote: baseIsToken0 ? meta.token1 : meta.token0,
      fee: meta.fee,
      tick: tickFor(mid),
      step: Math.max(stepOf(asks, mid), stepOf(bids, mid)),
      bids,
      asks,
      mid,
    },
  };
}
