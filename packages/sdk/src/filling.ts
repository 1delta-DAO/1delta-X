import { decodeFunctionResult, encodeFunctionData, type Address, type Hex } from "viem";

import { SETTLEMENT_ABI } from "./abi";
import { anchorTotal, currentAmountOutAt, fillAmountsOut, inputOwed } from "./pricing";
import { OrderSide, type Order } from "./types";

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
): bigint {
  let fillAmount: bigint;
  if (order.side === OrderSide.BUY) {
    fillAmount = budget;
  } else {
    const out0 = currentAmountOutAt(order, 0, now, baseFee);
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
 * the {Pricing} rules.
 */
export function previewFillLocal(
  order: Order,
  fillAmount: bigint,
  prevFilled: bigint,
  now: bigint,
  baseFee: bigint = 0n,
  overrideBps: bigint = 0n,
): { delta: bigint; received: bigint[]; paid: bigint[] } {
  if (order.fillModule !== "0x0000000000000000000000000000000000000000") {
    throw new Error("previewFillLocal: fill-module orders must be quoted via SettlementLens.previewFill");
  }
  const total = anchorTotal(order);
  let delta = fillAmount;
  if (prevFilled < total) {
    const rem = total - prevFilled;
    if (delta > rem) delta = rem;
  }
  if (delta < order.minFillAnchor) throw new Error("FillTooSmall");
  const newFilled = prevFilled + delta;
  if (newFilled > total) throw new Error("OverFill");

  const received = order.legsIn.map((leg, i) => {
    let owed = inputOwed(order, i, prevFilled, newFilled, now, baseFee);
    // Override discounts only AUCTIONED legs (any BUY input; a rising SELL leg).
    const auctioned = order.side === OrderSide.BUY || leg.end !== 0n;
    if (owed !== 0n && overrideBps !== 0n && auctioned) owed = (owed * (BPS - overrideBps)) / BPS;
    return owed;
  });
  const paid = fillAmountsOut(order, delta, now, prevFilled).map((amt, j) => {
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

/** Encode `Settlement.fillUpTo` calldata. `recipient` zero ⇒ pay the caller. */
export function encodeFillUpTo(args: {
  order: Order;
  sig: Hex;
  fillAmount: bigint;
  recipient?: Address;
  takerData?: Hex;
}): Hex {
  return encodeFunctionData({
    abi: SETTLEMENT_ABI,
    functionName: "fillUpTo",
    args: [
      args.order as never,
      args.sig,
      args.fillAmount,
      args.recipient ?? "0x0000000000000000000000000000000000000000",
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
