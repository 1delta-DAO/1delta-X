import type { Order } from "./types";

/**
 * Client-side mirror of the contract's dutch pricing + fill math, for off-chain
 * previews. Reverts on the same malformed inputs the contract rejects.
 */

/** Current auction tick for output leg `j` at unix time `now`. Mirrors `_currentAmountOutAt`. */
export function currentAmountOutAt(order: Order, j: number, now: bigint): bigint {
  const startOut = order.startAmountOut[j]!;
  const endOut = order.endAmountOut[j]!;
  if (startOut < endOut) throw new Error("InvalidAuctionParams: startAmountOut < endAmountOut");

  if (order.decayDuration === 0 || startOut === endOut) return startOut;

  const decayStart = BigInt(order.decayStartTime);
  if (now < decayStart) throw new Error("AuctionNotStarted");

  const elapsed = now - decayStart;
  const duration = BigInt(order.decayDuration);
  if (elapsed >= duration) return endOut;

  const decay = ((startOut - endOut) * elapsed) / duration;
  return startOut - decay;
}

/** Current auction tick for every output leg. Mirrors `previewAmountOut`. */
export function currentAmountOut(order: Order, now: bigint): bigint[] {
  return order.tokenOut.map((_, j) => currentAmountOutAt(order, j, now));
}

/**
 * Output amounts a fill of `fillAmountIn` delivers, per leg, at time `now`.
 * ceil-rounded exactly like `_deliverOutputs` (maker never underpaid).
 */
export function fillAmountsOut(order: Order, fillAmountIn: bigint, now: bigint): bigint[] {
  const denom = order.amountIn[0]!;
  return order.tokenOut.map((_, j) => {
    const price = currentAmountOutAt(order, j, now);
    return (fillAmountIn * price + denom - 1n) / denom; // ceilDiv
  });
}

/** Cumulative pro-rata input owed for `tokenIn[i]` over `[prevFilled, newFilled]`. Mirrors `_payInputsToSolver`. */
export function inputOwed(order: Order, i: number, prevFilled: bigint, newFilled: bigint): bigint {
  const denom = order.amountIn[0]!;
  const amt = order.amountIn[i]!;
  return (amt * newFilled) / denom - (amt * prevFilled) / denom;
}
