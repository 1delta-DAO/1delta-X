import { type Order, OrderSide, PRIORITY_AUCTION_BIT, unpackTiming } from "./types";
import { isProportional } from "./proportional";

/**
 * Client-side mirror of the contract's dutch pricing + fill math, for off-chain
 * previews. Reverts on the same malformed inputs the contract rejects.
 *
 * One side of every order is FIXED and the other is a dutch auction; `side`
 * selects which. Fills are denominated in ANCHOR units — `legsIn[0]` for SELL,
 * `legsOut[0]` for BUY. A leg with `end == 0n` is fixed at `start`; otherwise it
 * auctions (outputs FALL `start >= end`, inputs RISE `start <= end`).
 */

/** Fill denominator. Mirrors the settlement `_openFill`: the maker-signed
 *  `fillTotal` when set (module orders), else the leg anchor. */
export function anchorTotal(order: Order): bigint {
  if (order.fillTotal !== 0n) return order.fillTotal;
  const anchor = order.side === OrderSide.BUY ? order.legsOut[0]!.start : order.legsIn[0]!.start;
  // A balance-relative marker has no meaning to these pure helpers — resolving it
  // needs the maker's live balance. Fail loudly rather than price a ~1.15e77
  // "amount" and hand back a preview that silently means nothing. Callers pass the
  // order through `resolveProportionalOrder(order, balance)` first.
  if (isProportional(anchor)) {
    throw new Error(
      "order carries a Proportional marker; call resolveProportionalOrder(order, makerBalance) before pricing it",
    );
  }
  return anchor;
}

function ceilDiv(a: bigint, b: bigint): bigint {
  return a === 0n ? 0n : (a - 1n) / b + 1n;
}

const BPS = 10_000n;

/**
 * Shared normalized decay in [0, 10000] at time `now`, given a basefee. Mirrors
 * `DutchAuction.bumpBps` plus the two modes the settler resolves once per fill
 * (`DutchAuction.resolveBump`): a piecewise-linear curve if `curve` is set, else
 * a single linear segment, then the optional gas bump, all clamped.
 *
 * `now` is read on the order's OWN clock: seconds by default, or a BLOCK NUMBER
 * when `timing` bit 102 is set (fast L2s, where a one-second tick is eight blocks
 * of resolution). Pass the matching quantity.
 *
 * A PRIORITY auction (bit 103) prices off `priorityFee` instead of `now`, and an
 * order with a `pricingModule` cannot be priced here at all — both are noted
 * below.
 */
export function bumpBps(order: Order, now: bigint, baseFee: bigint = 0n, priorityFee: bigint = 0n): bigint {
  // An EXTERNAL price module cannot be mirrored here: its answer comes from an
  // oracle, the fill progress, or a cosigned quote. Quote such an order through
  // `SettlementLens.previewFill`, which resolves the module the way the fill does.
  if (BigInt(order.pricingModule) !== 0n) {
    throw new Error("order is priced by an IPriceModule; quote it with SettlementLens.previewFill");
  }
  // PRIORITY auction: the bump is BID, not elapsed. No bid ⇒ BPS ⇒ the maker's
  // signed floor; every wei of priority fee moves the tick toward `start`.
  if ((order.timing >> PRIORITY_AUCTION_BIT) & 1n) {
    if (order.priorityScale === 0n) throw new Error("InvalidAuctionParams: priority auction without priorityScale");
    // "Not before" gate — the same as the contract's `priorityBump` (and the clock
    // branches below): a future `decayStartTime` means the order is not yet biddable,
    // so a quote here must fail exactly as the fill would.
    const { decayStartTime } = unpackTiming(order.timing);
    if (decayStartTime !== 0 && now < BigInt(decayStartTime)) throw new Error("AuctionNotStarted");
    const improve = (priorityFee * BPS) / order.priorityScale;
    return improve >= BPS ? 0n : BPS - improve;
  }
  let bps = 0n;
  const n = order.curve.length;
  const { decayStartTime, decayDuration } = unpackTiming(order.timing);
  const decayStart = BigInt(decayStartTime);

  if (n === 0) {
    if (decayDuration !== 0) {
      if (now < decayStart) throw new Error("AuctionNotStarted");
      const elapsed = now - decayStart;
      const duration = BigInt(decayDuration);
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

/**
 * The priority-auction BID, in wei: `tx.gasprice - block.basefee -
 * baselinePriorityFeeWei`, clamped at 0. Mirrors `DutchAuction.priorityBump`.
 *
 * This is what {@link bumpBps}'s `priorityFee` argument expects — the fee bid
 * ABOVE the maker's signed baseline, not the raw effective gas price. The
 * baseline exists so the inclusion tip a chain charges anyway is not read as a
 * bid ({@link Order.baselinePriorityFeeWei}); forgetting to subtract it reads
 * every ordinary transaction as an aggressive bid.
 *
 * `effectiveGasPrice` is the receipt's field, which is exactly the EVM's
 * `tx.gasprice` — not `maxFeePerGas`, which is only a ceiling.
 */
export function priorityBid(effectiveGasPrice: bigint, baseFee: bigint, baselinePriorityFeeWei: bigint = 0n): bigint {
  const overBase = effectiveGasPrice > baseFee ? effectiveGasPrice - baseFee : 0n;
  return overBase > baselinePriorityFeeWei ? overBase - baselinePriorityFeeWei : 0n;
}

/** Current output tick for leg `j` — the SELL auction price, or the fixed BUY output. */
export function currentAmountOutAt(
  order: Order,
  j: number,
  now: bigint,
  baseFee: bigint = 0n,
  priorityFee: bigint = 0n,
): bigint {
  const startOut = order.legsOut[j]!.start;
  const endOut = order.legsOut[j]!.end;
  if (endOut === 0n) return startOut; // fixed leg — no bump
  if (startOut < endOut) throw new Error("InvalidAuctionParams: output start < end");
  return startOut - ((startOut - endOut) * bumpBps(order, now, baseFee, priorityFee)) / BPS;
}

/** Current output tick for every leg. Mirrors `previewAmountOut`. */
export function currentAmountOut(order: Order, now: bigint, baseFee: bigint = 0n, priorityFee: bigint = 0n): bigint[] {
  return order.legsOut.map((_, j) => currentAmountOutAt(order, j, now, baseFee, priorityFee));
}

/** Current input tick for leg `i` — the rising BUY/fee auction price, or the fixed SELL input. */
export function currentAmountInAt(
  order: Order,
  i: number,
  now: bigint,
  baseFee: bigint = 0n,
  priorityFee: bigint = 0n,
): bigint {
  const startIn = order.legsIn[i]!.start;
  const endIn = order.legsIn[i]!.end;
  if (endIn === 0n) return startIn; // fixed leg — no bump
  if (startIn > endIn) throw new Error("InvalidAuctionParams: input start > end");
  return startIn + ((endIn - startIn) * bumpBps(order, now, baseFee, priorityFee)) / BPS;
}

/** Current input tick for every leg. Mirrors `previewAmountIn`. */
export function currentAmountIn(order: Order, now: bigint): bigint[] {
  return order.legsIn.map((_, i) => currentAmountInAt(order, i, now));
}

/**
 * Output amounts a fill delivers, per leg. `fillAmount` is in anchor units and
 * `prevFilled` is the cumulative filled anchor before this fill. Mirrors
 * `_deliverOutputs` (ceil-rounded; the maker is never underpaid):
 *   • SELL — auction-priced per fill.
 *   • BUY  — fixed output, cumulative so partials sum exactly to `legsOut[j].start`.
 */
export function fillAmountsOut(
  order: Order,
  fillAmount: bigint,
  now: bigint,
  prevFilled: bigint = 0n,
  baseFee: bigint = 0n,
  priorityFee: bigint = 0n,
): bigint[] {
  const anchor = anchorTotal(order);
  const newFilled = prevFilled + fillAmount;
  return order.legsOut.map((_, j) => {
    if (order.side === OrderSide.BUY) {
      const fixedOut = order.legsOut[j]!.start;
      return ceilDiv(fixedOut * newFilled, anchor) - ceilDiv(fixedOut * prevFilled, anchor);
    }
    return ceilDiv(fillAmount * currentAmountOutAt(order, j, now, baseFee, priorityFee), anchor);
  });
}

/**
 * Input owed to the solver for `legsIn[i]` on the fill `[prevFilled, newFilled]`.
 * Mirrors `_payInputsToSolver`:
 *   • Fixed leg (`end == 0n` on SELL) — cumulative floor slice, exact-input.
 *   • Auctioned leg (any BUY input; a rising SELL relayer-fee leg, `end != 0n`) —
 *     auction-priced per fill (floor; total never exceeds the leg's `end`).
 */
export function inputOwed(
  order: Order,
  i: number,
  prevFilled: bigint,
  newFilled: bigint,
  now: bigint,
  baseFee: bigint = 0n,
  priorityFee: bigint = 0n,
): bigint {
  const anchor = anchorTotal(order);
  const auctioned = order.side === OrderSide.BUY || order.legsIn[i]!.end !== 0n;
  if (auctioned) {
    const fillAmount = newFilled - prevFilled;
    return (fillAmount * currentAmountInAt(order, i, now, baseFee, priorityFee)) / anchor;
  }
  const amt = order.legsIn[i]!.start;
  return (amt * newFilled) / anchor - (amt * prevFilled) / anchor;
}
