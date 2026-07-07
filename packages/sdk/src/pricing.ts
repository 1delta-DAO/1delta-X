import { type Order, OrderSide } from "./types";

/**
 * Client-side mirror of the contract's dutch pricing + fill math, for off-chain
 * previews. Reverts on the same malformed inputs the contract rejects.
 *
 * One side of every order is FIXED and the other is a dutch auction; `side`
 * selects which. Fills are denominated in ANCHOR units — `tokenIn[0]` for SELL,
 * `tokenOut[0]` for BUY.
 */

/** Fill denominator in anchor units. Mirrors `_anchorTotal`. */
export function anchorTotal(order: Order): bigint {
  return order.side === OrderSide.BUY ? order.startAmountOut[0]! : order.startAmountIn[0]!;
}

function ceilDiv(a: bigint, b: bigint): bigint {
  return a === 0n ? 0n : (a - 1n) / b + 1n;
}

/** Current output tick for leg `j` — the SELL auction price, or the fixed BUY output. */
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

/** Current output tick for every leg. Mirrors `previewAmountOut`. */
export function currentAmountOut(order: Order, now: bigint): bigint[] {
  return order.tokenOut.map((_, j) => currentAmountOutAt(order, j, now));
}

/** Current input tick for leg `i` — the rising BUY auction price, or the fixed SELL input. */
export function currentAmountInAt(order: Order, i: number, now: bigint): bigint {
  const startIn = order.startAmountIn[i]!;
  const endIn = order.endAmountIn[i]!;
  if (startIn > endIn) throw new Error("InvalidAuctionParams: startAmountIn > endAmountIn");

  if (order.decayDuration === 0 || startIn === endIn) return startIn;

  const decayStart = BigInt(order.decayStartTime);
  if (now < decayStart) throw new Error("AuctionNotStarted");

  const elapsed = now - decayStart;
  const duration = BigInt(order.decayDuration);
  if (elapsed >= duration) return endIn;

  const rise = ((endIn - startIn) * elapsed) / duration;
  return startIn + rise;
}

/** Current input tick for every leg. Mirrors `previewAmountIn`. */
export function currentAmountIn(order: Order, now: bigint): bigint[] {
  return order.tokenIn.map((_, i) => currentAmountInAt(order, i, now));
}

/**
 * Output amounts a fill delivers, per leg. `fillAmount` is in anchor units and
 * `prevFilled` is the cumulative filled anchor before this fill. Mirrors
 * `_deliverOutputs` (ceil-rounded; the maker is never underpaid):
 *   • SELL — auction-priced per fill.
 *   • BUY  — fixed output, cumulative so partials sum exactly to `startAmountOut`.
 */
export function fillAmountsOut(order: Order, fillAmount: bigint, now: bigint, prevFilled: bigint = 0n): bigint[] {
  const anchor = anchorTotal(order);
  const newFilled = prevFilled + fillAmount;
  return order.tokenOut.map((_, j) => {
    if (order.side === OrderSide.BUY) {
      const fixedOut = order.startAmountOut[j]!;
      return ceilDiv(fixedOut * newFilled, anchor) - ceilDiv(fixedOut * prevFilled, anchor);
    }
    return ceilDiv(fillAmount * currentAmountOutAt(order, j, now), anchor);
  });
}

/**
 * Input owed to the solver for `tokenIn[i]` on the fill `[prevFilled, newFilled]`.
 * Mirrors `_payInputsToSolver`:
 *   • SELL — fixed input, cumulative floor slice.
 *   • BUY  — auction-priced per fill (floor; total never exceeds `endAmountIn`).
 */
export function inputOwed(order: Order, i: number, prevFilled: bigint, newFilled: bigint, now: bigint): bigint {
  const anchor = anchorTotal(order);
  if (order.side === OrderSide.BUY) {
    const fillAmount = newFilled - prevFilled;
    return (fillAmount * currentAmountInAt(order, i, now)) / anchor;
  }
  const amt = order.startAmountIn[i]!;
  return (amt * newFilled) / anchor - (amt * prevFilled) / anchor;
}
