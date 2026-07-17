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

const BPS = 10_000n;

/**
 * Shared normalized decay in [0, 10000] at time `now`, given a basefee. Mirrors
 * `DutchAuction.bumpBps`: a piecewise-linear curve if `curve` is set, else a
 * single linear segment; then the optional gas bump is added and clamped.
 */
export function bumpBps(order: Order, now: bigint, baseFee: bigint = 0n): bigint {
  let bps = 0n;
  const n = order.curve.length;
  const decayStart = BigInt(order.decayStartTime);

  if (n === 0) {
    if (order.decayDuration !== 0) {
      if (now < decayStart) throw new Error("AuctionNotStarted");
      const elapsed = now - decayStart;
      const duration = BigInt(order.decayDuration);
      bps = elapsed >= duration ? BPS : (BPS * elapsed) / duration;
    }
  } else {
    if (now < decayStart) throw new Error("AuctionNotStarted");
    const elapsed = now - decayStart;
    const c = order.curve;
    if (elapsed <= BigInt(c[0]!.timeDelta)) {
      bps = BigInt(c[0]!.bumpBps);
    } else if (elapsed >= BigInt(c[n - 1]!.timeDelta)) {
      bps = BigInt(c[n - 1]!.bumpBps);
    } else {
      for (let k = 0; k < n - 1; k++) {
        const t1 = BigInt(c[k + 1]!.timeDelta);
        if (elapsed < t1) {
          const t0 = BigInt(c[k]!.timeDelta);
          const b0 = BigInt(c[k]!.bumpBps);
          const b1 = BigInt(c[k + 1]!.bumpBps);
          const span = t1 - t0;
          bps = b1 >= b0 ? b0 + ((b1 - b0) * (elapsed - t0)) / span : b0 - ((b0 - b1) * (elapsed - t0)) / span;
          break;
        }
      }
    }
  }

  if (order.gasBumpBps !== 0n && order.gasPriceRef !== 0n) {
    let gasAdd = (order.gasBumpBps * baseFee) / order.gasPriceRef;
    if (gasAdd > order.gasBumpBps) gasAdd = order.gasBumpBps;
    bps += gasAdd;
  }
  return bps > BPS ? BPS : bps;
}

/** Current output tick for leg `j` — the SELL auction price, or the fixed BUY output. */
export function currentAmountOutAt(order: Order, j: number, now: bigint, baseFee: bigint = 0n): bigint {
  const startOut = order.startAmountOut[j]!;
  const endOut = order.endAmountOut[j]!;
  if (startOut < endOut) throw new Error("InvalidAuctionParams: startAmountOut < endAmountOut");
  if (startOut === endOut) return startOut;
  return startOut - ((startOut - endOut) * bumpBps(order, now, baseFee)) / BPS;
}

/** Current output tick for every leg. Mirrors `previewAmountOut`. */
export function currentAmountOut(order: Order, now: bigint, baseFee: bigint = 0n): bigint[] {
  return order.tokenOut.map((_, j) => currentAmountOutAt(order, j, now, baseFee));
}

/** Current input tick for leg `i` — the rising BUY auction price, or the fixed SELL input. */
export function currentAmountInAt(order: Order, i: number, now: bigint, baseFee: bigint = 0n): bigint {
  const startIn = order.startAmountIn[i]!;
  const endIn = order.endAmountIn[i]!;
  if (startIn > endIn) throw new Error("InvalidAuctionParams: startAmountIn > endAmountIn");
  if (startIn === endIn) return startIn;
  return startIn + ((endIn - startIn) * bumpBps(order, now, baseFee)) / BPS;
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
 *   • Fixed leg (`start == end` on SELL) — cumulative floor slice, exact-input.
 *   • Auctioned leg (any BUY input; a rising SELL relayer-fee leg) —
 *     auction-priced per fill (floor; total never exceeds `endAmountIn`).
 */
export function inputOwed(
  order: Order,
  i: number,
  prevFilled: bigint,
  newFilled: bigint,
  now: bigint,
  baseFee: bigint = 0n,
): bigint {
  const anchor = anchorTotal(order);
  const auctioned = order.side === OrderSide.BUY || order.startAmountIn[i]! !== order.endAmountIn[i]!;
  if (auctioned) {
    const fillAmount = newFilled - prevFilled;
    return (fillAmount * currentAmountInAt(order, i, now, baseFee)) / anchor;
  }
  const amt = order.startAmountIn[i]!;
  return (amt * newFilled) / anchor - (amt * prevFilled) / anchor;
}
