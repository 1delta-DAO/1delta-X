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


/** Uniswap's tick bounds. Outside these a tick has no representable price. */
export const MIN_TICK = -887272;
export const MAX_TICK = 887272;

const MAX_UINT256 = 2n ** 256n - 1n;

/**
 * Q128.128 multipliers for each bit of |tick|, from Uniswap's `TickMath`.
 * Each is 1.0001^(-2^i) in Q128.128 — multiplying the set selected by the bits
 * of |tick| reconstructs 1.0001^(-|tick|) exactly in integer arithmetic.
 */
const TICK_MULTIPLIERS: readonly [bigint, bigint][] = [
  [0x1n, 0xfffcb933bd6fad37aa2d162d1a594001n],
  [0x2n, 0xfff97272373d413259a46990580e213an],
  [0x4n, 0xfff2e50f5f656932ef12357cf3c7fdccn],
  [0x8n, 0xffe5caca7e10e4e61c3624eaa0941cd0n],
  [0x10n, 0xffcb9843d60f6159c9db58835c926644n],
  [0x20n, 0xff973b41fa98c081472e6896dfb254c0n],
  [0x40n, 0xff2ea16466c96a3843ec78b326b52861n],
  [0x80n, 0xfe5dee046a99a2a811c461f1969c3053n],
  [0x100n, 0xfcbe86c7900a88aedcffc83b479aa3a4n],
  [0x200n, 0xf987a7253ac413176f2b074cf7815e54n],
  [0x400n, 0xf3392b0822b70005940c7a398e4b70f3n],
  [0x800n, 0xe7159475a2c29b7443b29c7fa6e889d9n],
  [0x1000n, 0xd097f3bdfd2022b8845ad8f792aa5825n],
  [0x2000n, 0xa9f746462d870fdf8a65dc1f90e061e5n],
  [0x4000n, 0x70d869a156d2a1b890bb3df62baf32f7n],
  [0x8000n, 0x31be135f97d08fd981231505542fcfa6n],
  [0x10000n, 0x9aa508b5b7a84e1c677de54f3e99bc9n],
  [0x20000n, 0x5d6af8dedb81196699c329225ee604n],
  [0x40000n, 0x2216e584f5fa1ea926041bedfe98n],
  [0x80000n, 0x48a170391f7dc42444e8fa2n],
];

/**
 * sqrt(1.0001^tick) in Q96 — Uniswap's `TickMath.getSqrtRatioAtTick`, ported.
 *
 * Needed because a subgraph reports a tick INDEX where Oku reports the sqrt
 * price directly. Reconstructing it in floating point would be a quiet disaster:
 * the ladder differences adjacent sqrt prices, so a relative error of 1e-16 in
 * each becomes an arbitrary error in a rung's size. This is the integer routine
 * the pool itself uses, so the two sources agree to the wei.
 */
export function getSqrtRatioAtTick(tick: number): bigint {
  const absTick = BigInt(Math.abs(tick));
  if (absTick > BigInt(MAX_TICK)) throw new Error(`tick ${tick} out of range`);

  let ratio = (absTick & 0x1n) !== 0n ? TICK_MULTIPLIERS[0][1] : 0x100000000000000000000000000000000n;
  for (let i = 1; i < TICK_MULTIPLIERS.length; i++) {
    const [bit, multiplier] = TICK_MULTIPLIERS[i];
    if ((absTick & bit) !== 0n) ratio = (ratio * multiplier) >> 128n;
  }
  // The table is built for negative ticks; a positive one is the reciprocal.
  if (tick > 0) ratio = MAX_UINT256 / ratio;

  // Q128.128 → Q128.96, rounding up so the result never understates the price.
  return (ratio >> 32n) + (ratio % (1n << 32n) === 0n ? 0n : 1n);
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
