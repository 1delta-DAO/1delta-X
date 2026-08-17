/**
 * Uniswap v3 concentrated-liquidity maths, over the pool's own initialized
 * ticks.
 *
 * This is where the ladder actually comes from. A bucketed price/size feed is a
 * *rendering* of tick liquidity — every rung inside one position's range comes
 * out the same size, which reads as a synthetic ladder even though the numbers
 * are real. Walking the initialized ticks instead gives one rung per range where
 * liquidity is genuinely constant, so a concentrated position shows up as the
 * cliff it is.
 */

const Q96 = 2n ** 96n;
const TWO_256 = 2n ** 256n;
const TWO_255 = 2n ** 255n;

/** `liquidity_net` arrives as an unsigned 256-bit decimal string. */
export function asSigned(unsigned: bigint): bigint {
  return unsigned >= TWO_255 ? unsigned - TWO_256 : unsigned;
}

export interface RawTick {
  index: number;
  /** sqrt(price) in Q96. */
  sqrtPrice: bigint;
  liquidityNet: bigint;
}

export interface PoolLiquidity {
  block: number;
  currentTick: number;
  tickSpacing: number;
  sqrtPriceX96: bigint;
  decimals0: number;
  decimals1: number;
  ticks: RawTick[];
}

/** token0 held by liquidity `L` across [sqrtA, sqrtB], in token0 wei. */
export function amount0(L: bigint, sqrtA: bigint, sqrtB: bigint): bigint {
  if (sqrtA > sqrtB) [sqrtA, sqrtB] = [sqrtB, sqrtA];
  if (L <= 0n || sqrtA <= 0n) return 0n;
  return (L * Q96 * (sqrtB - sqrtA)) / (sqrtA * sqrtB);
}

/** token1 held by liquidity `L` across [sqrtA, sqrtB], in token1 wei. */
export function amount1(L: bigint, sqrtA: bigint, sqrtB: bigint): bigint {
  if (sqrtA > sqrtB) [sqrtA, sqrtB] = [sqrtB, sqrtA];
  if (L <= 0n) return 0n;
  return (L * (sqrtB - sqrtA)) / Q96;
}

/**
 * Exact bigint → number, scaled by `decimals`. Going through `Number(v)` first
 * loses precision above 2^53, which pool reserves clear routinely.
 */
export function toFloat(v: bigint, decimals: number): number {
  if (v === 0n) return 0;
  const neg = v < 0n;
  const digits = (neg ? -v : v).toString();
  let text: string;
  if (decimals <= 0) {
    text = digits + "0".repeat(-decimals);
  } else if (digits.length > decimals) {
    text = `${digits.slice(0, digits.length - decimals)}.${digits.slice(digits.length - decimals)}`;
  } else {
    text = `0.${digits.padStart(decimals, "0")}`;
  }
  const n = Number(text);
  return neg ? -n : n;
}

/** Price of token0 in token1, decimal-adjusted, from a Q96 sqrt price. */
export function priceFromSqrt(sqrtPriceX96: bigint, decimals0: number, decimals1: number): number {
  const ratio = toFloat(sqrtPriceX96, 0) / toFloat(Q96, 0);
  return ratio * ratio * Math.pow(10, decimals0 - decimals1);
}

/** One range where liquidity is constant, priced in the app's own orientation. */
export interface Rung {
  /** Average execution price over the range: quote per base. */
  price: number;
  /** Base-token amount the range can absorb or supply. */
  size: number;
}

export interface LadderOptions {
  /** True when the market's BASE is the pool's token0. */
  baseIsToken0: boolean;
  /** Most rungs to return per side. */
  maxRungs: number;
  /** Stop walking once a rung's price is this far from mid, as a fraction. */
  maxSpread: number;
}

export interface Ladder {
  bids: Rung[];
  asks: Rung[];
  mid: number;
}

/**
 * Walk out from the current price, one initialized-tick range at a time.
 *
 * Both sides are denominated in BASE. A range below the current price holds only
 * token1, but pushing the price down through it takes exactly the token0 that
 * range *would* hold — so one amount formula serves bids and asks alike, which
 * is what makes the two sides of the ladder comparable at all.
 */
export function buildLadder(pool: PoolLiquidity, opts: LadderOptions): Ladder {
  const { baseIsToken0, maxRungs, maxSpread } = opts;
  const ticks = [...pool.ticks].sort((a, b) => a.index - b.index);
  if (ticks.length < 2) return { bids: [], asks: [], mid: 0 };

  // Liquidity in [ticks[i], ticks[i+1]) is the running sum of every net through
  // ticks[i] — the same accumulation the pool performs when a swap crosses one.
  const liquidity: bigint[] = new Array(ticks.length).fill(0n);
  let running = 0n;
  for (let i = 0; i < ticks.length; i++) {
    running += ticks[i].liquidityNet;
    liquidity[i] = running;
  }

  const sqrtP = pool.sqrtPriceX96;
  let at = -1;
  for (let i = 0; i < ticks.length - 1; i++) {
    if (ticks[i].sqrtPrice <= sqrtP && sqrtP < ticks[i + 1].sqrtPrice) {
      at = i;
      break;
    }
  }
  if (at < 0) return { bids: [], asks: [], mid: 0 };

  const priceOf = (lo: bigint, hi: bigint, L: bigint): Rung | null => {
    const a0 = amount0(L, lo, hi);
    const a1 = amount1(L, lo, hi);
    const size = baseIsToken0 ? toFloat(a0, pool.decimals0) : toFloat(a1, pool.decimals1);
    const cost = baseIsToken0 ? toFloat(a1, pool.decimals1) : toFloat(a0, pool.decimals0);
    if (!(size > 0) || !(cost > 0)) return null;
    return { price: cost / size, size };
  };

  // Rungs the price passes through going up, starting from the partial range the
  // current price sits inside.
  const upward: Rung[] = [];
  for (let i = at; i < ticks.length - 1 && upward.length < maxRungs; i++) {
    const lo = i === at ? sqrtP : ticks[i].sqrtPrice;
    const rung = priceOf(lo, ticks[i + 1].sqrtPrice, liquidity[i]);
    if (rung) upward.push(rung);
  }

  const downward: Rung[] = [];
  for (let i = at; i >= 0 && downward.length < maxRungs; i--) {
    const hi = i === at ? sqrtP : ticks[i + 1].sqrtPrice;
    const rung = priceOf(ticks[i].sqrtPrice, hi, liquidity[i]);
    if (rung) downward.push(rung);
  }

  const mid = baseIsToken0
    ? priceFromSqrt(sqrtP, pool.decimals0, pool.decimals1)
    : 1 / priceFromSqrt(sqrtP, pool.decimals0, pool.decimals1);

  // Selling BASE walks the direction that gives BASE to the pool. With base =
  // token0 that is downward; with base = token1 it is upward, because the
  // displayed price is inverted.
  const bids = baseIsToken0 ? downward : upward;
  const asks = baseIsToken0 ? upward : downward;

  const within = (r: Rung) => Math.abs(r.price / mid - 1) <= maxSpread;
  return {
    bids: bids.filter(within).sort((a, b) => b.price - a.price),
    asks: asks.filter(within).sort((a, b) => a.price - b.price),
    mid,
  };
}
