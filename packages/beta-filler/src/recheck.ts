import { BLOCK_CLOCK_BIT, bumpBps, isProportional, PRIORITY_AUCTION_BIT, unpackTiming, type Order } from "@1delta-x/sdk";

import { AUCTION_RECHECK_MS } from "./config";
import { isFixedPrice } from "./policy";

const BPS = 10_000n;

/**
 * When a DECAYING order's gate will pass, so an "unprofitable" verdict is re-quoted
 * at that moment instead of a fixed {@link AUCTION_RECHECK_MS} later.
 *
 * The order's own pricing is deterministic: the bump (bps of the start→end range)
 * at a future second comes from the SDK mirror ({@link bumpBps}), so what we would
 * pay (the order's `legsOut[0]`, falling on a SELL) and receive (its `legsIn[0]`,
 * rising on a BUY) at that second follow from the preview by the ratio of the two
 * leg ticks: `paid(t) = paid · outTick(b(t)) / outTick(bNow)`, likewise `received`.
 * Scaling the preview (rather than re-deriving the fill from scratch) keeps
 * everything the lens priced in it — the partial size, a soft-window premium — and
 * `bNow` is the lens `previewBump` at the same block, so a block that lags the wall
 * clock does not shift the answer.
 *
 * `passes(paid, received)` is the strategy's gate with the MARKET held fixed (the
 * quote, gas, exit — scaled linearly in `received` where they depend on it, which
 * over-estimates a concave pool quote: the bias is EARLY, i.e. at worst one wasted
 * re-quote, never a late one). Rounding is early-biased the same way.
 *
 * Returns the first second in `[nowS, nowS + horizonS]` at which the gate passes;
 * else the auction's floor time if it falls inside the horizon (the price stops
 * moving there: re-quote at once); else `undefined` — the caller keeps its cap.
 * Also `undefined` for any order this mirror cannot price off the clock alone: a
 * price module, a priority auction, a gas bump, a block clock, a proportional leg,
 * or no decay at all.
 */
export function profitableAt(a: {
  order: Order;
  /** The bump (bps) the preview was priced at — the lens `previewBump` at the same block and gas price. */
  bumpNow: bigint;
  /** What the preview says we pay (`paid[0]`) and receive (`received[0]`) at `bumpNow`. */
  paid: bigint;
  received: bigint;
  /** Wall clock, seconds (the order's clock: unix seconds). */
  nowS: bigint;
  /** How far ahead to look, seconds. */
  horizonS: bigint;
  passes: (paid: bigint, received: bigint) => boolean;
}): bigint | undefined {
  const { order } = a;
  if (BigInt(order.pricingModule) !== 0n) return undefined;
  if (((order.timing >> PRIORITY_AUCTION_BIT) & 1n) === 1n) return undefined;
  if (((order.timing >> BLOCK_CLOCK_BIT) & 1n) === 1n) return undefined;
  if (order.gasBumpBps !== 0n) return undefined;
  const legIn = order.legsIn[0];
  const legOut = order.legsOut[0];
  if (!legIn || !legOut || isProportional(legIn.start) || isProportional(legOut.start)) return undefined;
  if (a.paid === 0n || a.received === 0n) return undefined;
  const { decayStartTime, decayDuration } = unpackTiming(order.timing);
  const span = order.curve.length ? BigInt(order.curve[order.curve.length - 1]!.timeDelta) : BigInt(decayDuration);
  if (span === 0n) return undefined;
  const floorAt = BigInt(decayStartTime) + span;

  const outMoves = legOut.end !== 0n && legOut.start > legOut.end;
  const inMoves = legIn.end !== 0n && legIn.end > legIn.start;
  if (!outMoves && !inMoves) return undefined;
  const outTick = (b: bigint) => legOut.start - ((legOut.start - legOut.end) * b) / BPS;
  const inTick = (b: bigint) => legIn.start + ((legIn.end - legIn.start) * b) / BPS;
  const outNow = outMoves ? outTick(a.bumpNow) : 0n;
  const inNow = inMoves ? inTick(a.bumpNow) : 0n;
  if ((outMoves && outNow === 0n) || (inMoves && inNow === 0n)) return undefined;

  for (let t = a.nowS; t <= a.nowS + a.horizonS; t++) {
    let b: bigint;
    try {
      b = bumpBps(order, t);
    } catch {
      continue; // not started at `t` (AuctionNotStarted): nothing to fill yet
    }
    // Early-biased: what we pay rounds DOWN, what we receive rounds UP.
    const paid = outMoves ? (a.paid * outTick(b)) / outNow : a.paid;
    const received = inMoves ? (a.received * inTick(b) + inNow - 1n) / inNow : a.received;
    if (a.passes(paid, received)) return t;
  }
  return floorAt > a.nowS && floorAt <= a.nowS + a.horizonS ? floorAt : undefined;
}

/** `v · num / den`, rounded up (a quote or exit value scaled with what we receive). */
export function scaleUp(v: bigint, num: bigint, den: bigint): bigint {
  return den === 0n ? v : (v * num + den - 1n) / den;
}

/**
 * {@link profitableAt} for a strategy verdict, in ms: `undefined` for a fixed-price
 * order (its resting hold applies) or when no moment within one
 * {@link AUCTION_RECHECK_MS} is predicted.
 */
export function recheckAtMs(
  order: Order,
  bumpNow: bigint,
  paid: bigint,
  received: bigint,
  nowS: bigint,
  passes: (paid: bigint, received: bigint) => boolean,
): number | undefined {
  if (isFixedPrice(order)) return undefined;
  const t = profitableAt({ order, bumpNow, paid, received, nowS, horizonS: BigInt(AUCTION_RECHECK_MS / 1000), passes });
  return t === undefined ? undefined : Number(t) * 1000;
}

/** `AuctionNotStarted()` — the order's decay start is after the block the call ran on. */
const AUCTION_NOT_STARTED = "0xeffaea80";

/** Whether a preview reverted because the auction has not started at the latest block. */
export function isAuctionNotStarted(e: unknown): boolean {
  let cur = e as { name?: unknown; message?: unknown; cause?: unknown; data?: unknown; signature?: unknown } | undefined;
  for (let i = 0; cur && i < 6; i++) {
    if (typeof cur.signature === "string" && cur.signature.toLowerCase() === AUCTION_NOT_STARTED) return true;
    if (typeof cur.data === "string" && cur.data.toLowerCase().startsWith(AUCTION_NOT_STARTED)) return true;
    if (typeof cur.message === "string" && (/AuctionNotStarted/.test(cur.message) || cur.message.toLowerCase().includes(AUCTION_NOT_STARTED))) return true;
    cur = cur.cause as typeof cur;
  }
  return false;
}
