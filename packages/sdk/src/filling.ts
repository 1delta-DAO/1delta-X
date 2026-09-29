import { decodeFunctionResult, encodeFunctionData, type Address, type Hex } from "viem";

import { SETTLEMENT_ABI } from "./abi";
import { anchorTotal, currentAmountOutAt, fillAmountsOut, inputOwed } from "./pricing";
import { OrderSide, type Order } from "./types";
import { packOrder } from "./packed";
import { isProportional } from "./proportional";

const MAX_UINT256 = (1n << 256n) - 1n;

/**
 * Aggregator-side fill helpers: convert a router's spend budget into a
 * `fillAmount`, quote a fill locally with the contract's exact math, and
 * encode/decode the `fillUpTo` entrypoint. The on-chain twin of the local quote
 * is `SettlementLens.previewFill` — use that when you'd rather trust an
 * `eth_call` than a clock.
 */

const BPS = 10_000n;

function ceilDiv(a: bigint, b: bigint): bigint {
  return a === 0n ? 0n : (a - 1n) / b + 1n;
}

/**
 * Convert the filler's spend budget — denominated in the token the filler
 * DELIVERS, i.e. `legsOut[0].token` — into a `fillAmount` in the order's anchor
 * units. Side-aware:
 *   • BUY  — the anchor IS `legsOut[0]`, so the budget already is the fill
 *            amount (exact-input for the filler).
 *   • SELL — the output leg is auction-priced, so the budget converts through
 *            the current tick (exact-output for the filler): the largest
 *            `fillAmount` whose ceil-priced leg-0 delivery stays ≤ budget.
 *            Decay only lowers the price afterwards, so a fill submitted later
 *            never overspends the budget.
 * Pass `remaining` (from the lens) to pre-clamp; `fillUpTo` clamps on-chain
 * regardless, so this only refines the quote. Multi-output orders: the budget
 * covers leg 0 only — check the full basket with {previewFillLocal}.
 */
export function fillAmountFromBudget(
  order: Order,
  budget: bigint,
  now: bigint,
  baseFee: bigint = 0n,
  remaining?: bigint,
  priorityFee: bigint = 0n,
): bigint {
  let fillAmount: bigint;
  if (order.side === OrderSide.BUY) {
    fillAmount = budget;
  } else {
    // Pass the priority-fee bid you will actually send: on a priority-auction SELL
    // the leg-0 tick moves toward `start` as you bid, so a zero-bid quote here would
    // divide the budget by the floor price and OVERSTATE the fill amount.
    const out0 = currentAmountOutAt(order, 0, now, baseFee, priorityFee);
    fillAmount = out0 === 0n ? 0n : (budget * anchorTotal(order)) / out0;
  }
  if (remaining !== undefined && fillAmount > remaining) fillAmount = remaining;
  return fillAmount;
}

/**
 * Local mirror of `Settlement.fillUpTo` / `SettlementLens.previewFill`:
 * clamp the request to the order's remaining size, then price every leg with
 * the contract's exact math. Identity (non-fillModule) orders only — a module
 * order's delta is the module's decision, quote it via the lens.
 *
 * `overrideBps` is the soft-exclusivity improvement a non-exclusive in-window
 * filler owes (0 outside the window or for the exclusive filler): maker-bound
 * SELL outputs are lifted by it, auctioned inputs discounted — byte-for-byte
 * the {Pricing} rules. If NO leg can carry it (fixed inputs, outputs all to third
 * parties) the contract refuses the outsider (`NotExclusiveFiller`), and so does
 * this function.
 *
 * `proportional` must be `true` for a Proportional ("sell my balance") order whose
 * marker you resolved before calling: the contract then does NOT trim an oversized
 * request down to the (shrunk) anchor — it reverts `OverFill` — unless the request
 * is the `MAX_UINT256` "any size" sentinel (re-audit 2026-09-29).
 */
export function previewFillLocal(
  order: Order,
  fillAmount: bigint,
  prevFilled: bigint,
  now: bigint,
  baseFee: bigint = 0n,
  overrideBps: bigint = 0n,
  priorityFee: bigint = 0n,
  proportional: boolean = false,
): { delta: bigint; received: bigint[]; paid: bigint[] } {
  if (order.fillModule !== "0x0000000000000000000000000000000000000000") {
    throw new Error("previewFillLocal: fill-module orders must be quoted via SettlementLens.previewFill");
  }
  if (overrideBps !== 0n && !overrideHasCarrier(order)) throw new Error("NotExclusiveFiller");
  const total = anchorTotal(order);
  let delta = fillAmount;
  if (prevFilled < total) {
    const rem = total - prevFilled;
    // A proportional request is never trimmed down — see the note above.
    if (delta > rem && (!proportional || delta === MAX_UINT256)) delta = rem;
  }
  if (delta < order.minFillAnchor) throw new Error("FillTooSmall");
  const newFilled = prevFilled + delta;
  if (newFilled > total) throw new Error("OverFill");

  const received = order.legsIn.map((leg, i) => {
    let owed = inputOwed(order, i, prevFilled, newFilled, now, baseFee, priorityFee);
    // Override discounts only AUCTIONED legs (any BUY input; a rising SELL leg).
    const auctioned = order.side === OrderSide.BUY || leg.end !== 0n;
    if (owed !== 0n && overrideBps !== 0n && auctioned) owed = (owed * (BPS - overrideBps)) / BPS;
    return owed;
  });
  const paid = fillAmountsOut(order, delta, now, prevFilled, baseFee, priorityFee).map((amt, j) => {
    // Override lifts only the MAKER's SELL legs — never a third-party fee leg.
    const to = order.legsOut[j]!.recipient;
    const makerLeg = to === "0x0000000000000000000000000000000000000000" || to.toLowerCase() === order.maker.toLowerCase();
    if (amt !== 0n && overrideBps !== 0n && order.side === OrderSide.SELL && makerLeg) {
      return ceilDiv(amt * (BPS + overrideBps), BPS);
    }
    return amt;
  });
  return { delta, received, paid };
}

/**
 * Mirror of the contract's `OrderGates._overrideHasCarrier`: can any leg carry a
 * soft-exclusivity premium? A BUY input, an auctioned non-proportional SELL input,
 * or a SELL output addressed to the maker (or to zero).
 */
export function overrideHasCarrier(order: Order): boolean {
  const buy = order.side === OrderSide.BUY;
  if (order.legsIn.some((l) => (buy || l.end !== 0n) && !isProportional(l.start))) return true;
  if (buy) return false;
  return order.legsOut.some(
    (l) =>
      l.recipient === "0x0000000000000000000000000000000000000000" ||
      l.recipient.toLowerCase() === order.maker.toLowerCase(),
  );
}

/**
 * Encode `Settlement.fillUpTo` calldata. `recipient` zero ⇒ pay the caller.
 * `minBumpBps` is the filler's price floor on the resolved decay bump (0 = off):
 * quote it from `previewFill`/the lens and the fill reverts `BumpTooLow` if the
 * included price lands below the quote — only an oracle price module or a
 * falling basefee (gas bump) can move it there.
 */
export function encodeFillUpTo(args: {
  order: Order;
  sig: Hex;
  fillAmount: bigint;
  recipient?: Address;
  minBumpBps?: bigint;
  takerData?: Hex;
}): Hex {
  return encodeFunctionData({
    abi: SETTLEMENT_ABI,
    functionName: "fillUpTo",
    args: [
      packOrder(args.order) as never,
      args.sig,
      args.fillAmount,
      args.recipient ?? "0x0000000000000000000000000000000000000000",
      args.minBumpBps ?? 0n,
      args.takerData ?? "0x",
    ],
  });
}

/** Decode a `fillUpTo` return into the (delta, received, paid) triple. */
export function decodeFillUpToResult(data: Hex): { delta: bigint; received: bigint[]; paid: bigint[] } {
  const [delta, received, paid] = decodeFunctionResult({
    abi: SETTLEMENT_ABI,
    functionName: "fillUpTo",
    data,
  }) as readonly [bigint, readonly bigint[], readonly bigint[]];
  return { delta, received: [...received], paid: [...paid] };
}
