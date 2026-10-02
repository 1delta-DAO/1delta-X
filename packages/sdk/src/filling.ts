import { decodeFunctionResult, encodeFunctionData, zeroAddress, type Address, type Hex } from "viem";

import { SETTLEMENT_ABI } from "./abi";
import { anchorTotal, currentAmountOutAt, fillAmountsOut, inputOwed } from "./pricing";
import {
  DELTA_VERIFY_OUTPUTS_BIT,
  FILL_ONCE_BIT_INDEX,
  FILLER_SET_SENTINEL,
  OrderSide,
  timingFlags,
  unpackTiming,
  type Order,
} from "./types";
import { packOrder } from "./packed";
import { isProportional } from "./proportional";
import { assertPermit3Nonce, Permit3MessageKind } from "./permit3nonce";
import type { PermitTake } from "./types";

const MAX_UINT256 = (1n << 256n) - 1n;

/**
 * Aggregator-side fill helpers: convert a router's spend budget into a
 * `fillAmount`, quote a fill locally with the contract's exact math, and
 * encode/decode the `fillUpTo` entrypoint. The on-chain twin of the local quote
 * is `SettlementLens.previewFill` — use that when you'd rather trust an
 * `eth_call` than a clock.
 *
 * ⚠ The price of a fill depends on WHO sends it. Inside a soft-exclusivity window
 * every filler that is not the named `exclusiveFiller` (or a member of the signed
 * filler SET) pays the maker-signed `exclusivityOverrideBps` premium on every
 * maker-addressed SELL output — up to 2× at 10,000 bps. Every quote below
 * therefore takes the address that will be `msg.sender` of the fill
 * ({@link FillerContext.filler}); there is deliberately no "anonymous" default,
 * because a router is by construction never the named filler (audit 2026-09-30,
 * CORE-FILLER-1.v2).
 */

const BPS = 10_000n;

function ceilDiv(a: bigint, b: bigint): bigint {
  return a === 0n ? 0n : (a - 1n) / b + 1n;
}

const eqAddr = (a: string, b: string): boolean => a.toLowerCase() === b.toLowerCase();

/** Who fills, and the block context the fill will be priced in. */
export interface FillerContext {
  /** The address that will SEND the fill (`msg.sender` of `fillUpTo` / `fill`). */
  filler: Address;
  /** `block.basefee` the fill is expected to land in (drives the gas bump). Default 0. */
  baseFee?: bigint;
  /**
   * The priority-fee BID above the maker's baseline ({@link priorityBid}). REQUIRED
   * for a priority-auction order (timing bit 103): such an order is priced by the
   * bid, and the helpers throw `PricingNeedsContext` without one. Ignored otherwise.
   */
  priorityFee?: bigint;
  /**
   * The signed filler SET of a {@link FILLER_SET_SENTINEL} order — the addresses
   * packed into its `curve` blob by `packFillerSet`. Required only when such an
   * order is still inside its window.
   */
  fillerSet?: readonly Address[];
}

/**
 * Mirror of `OrderGates.exclusivityOverride` (plus the delta-verify gate of
 * `Core._snapshotOutRecipients`): the soft-exclusivity premium, in bps, that
 * `filler` pays on this order at `now`.
 *
 *   • 0 outside the window, with no `exclusiveFiller`, or for the named filler /
 *     a member of the signed set;
 *   • `exclusivityOverrideBps` for an in-window outsider;
 *   • throws `NotExclusiveFiller` where the settler refuses the outsider — a HARD
 *     window (override 0), a soft window no leg can carry ({@link overrideHasCarrier}),
 *     or any filler other than the named one on a delta-verify order (timing bit 104);
 *   • throws `InvalidOverrideBps` above 10,000 and `MalformedFillerSet` for a set
 *     order whose set is missing or empty.
 *
 * `now` is on the ORDER'S clock — a block number when timing bit 102 is set, else
 * unix seconds — exactly as for the pricing helpers.
 */
export function exclusivityOverrideFor(
  order: Order,
  filler: Address,
  now: bigint,
  fillerSet?: readonly Address[],
): bigint {
  const ex = order.exclusiveFiller;
  // A delta-verify order fills for its named filler only, for its whole life.
  if ((order.timing >> DELTA_VERIFY_OUTPUTS_BIT) & 1n && !eqAddr(filler, ex)) {
    throw new Error("NotExclusiveFiller: a delta-verify order fills only for its named exclusiveFiller");
  }
  if (eqAddr(ex, zeroAddress)) return 0n;
  if (now >= BigInt(unpackTiming(order.timing).exclusivityEndTime)) return 0n;
  let excluded: boolean;
  if (eqAddr(ex, FILLER_SET_SENTINEL)) {
    if (fillerSet === undefined || fillerSet.length === 0) {
      throw new Error("MalformedFillerSet: pass the order's signed filler set (fillerSet) to quote a set order in its window");
    }
    excluded = !fillerSet.some((f) => eqAddr(f, filler));
  } else {
    excluded = !eqAddr(filler, ex);
  }
  if (!excluded) return 0n;
  const bps = order.exclusivityOverrideBps;
  if (bps === 0n || !overrideHasCarrier(order)) throw new Error("NotExclusiveFiller");
  if (bps > BPS) throw new Error("InvalidOverrideBps");
  return bps;
}

/**
 * Convert the filler's spend budget — denominated in the token the filler
 * DELIVERS, i.e. `legsOut[0].token` — into a `fillAmount` in the order's
 * DENOMINATOR units: the maker-signed `fillTotal` when set, else the anchor leg
 * (`legsIn[0]` for SELL, `legsOut[0]` for BUY). Returns the largest `fillAmount`
 * whose leg-0 delivery, priced exactly as the settler prices it FOR `ctx.filler`
 * at `now`, stays ≤ `budget`:
 *   • BUY  — fixed output, cumulative-ceil slices of `legsOut[0].start`. With
 *            `fillTotal == 0` the budget IS the fill amount; with a `fillTotal` it
 *            is converted through `fillTotal / legsOut[0].start` (pass `prevFilled`
 *            for an exact answer on a partially-filled order).
 *   • SELL — the output leg is auction-priced, so the budget converts through the
 *            current tick, LIFTED by the soft-exclusivity premium when `ctx.filler`
 *            is an in-window outsider and leg 0 is maker-addressed.
 *
 * ⚠ The answer is exact for a fill priced at `now`/`baseFee`/`priorityFee`. A fill
 * included LATER never overspends the budget only for an order whose price moves
 * filler-ward with time alone — a fixed order or a monotone-RISING decay (linear, or
 * a curve with no descending segment), with NO price module and NO priority auction
 * (and no gas bump). Otherwise the price can move AGAINST the filler before
 * inclusion — a price module (oracle-, state- or filler-keyed), a priority bid a
 * basefee drop widens, a falling-basefee gas bump, a descending curve segment
 * ({@link needsBumpFloor} names the mover). Submit with `fillUpTo(..., minBumpBps)`
 * quoted from `SettlementLens.previewBump`, or simulate with
 * `SettlementLens.previewFill(order, amount, filler, …)`, and keep the approval you
 * grant the settlement no larger than the budget.
 *
 * Pass `remaining` (from the lens) to pre-clamp; `fillUpTo` clamps on-chain
 * regardless. A FILL-ONCE order (timing bit 100) is whole-or-nothing: if the budget
 * cannot cover the whole remainder this returns 0. Multi-output orders: the budget
 * covers leg 0 only — check the full basket with {@link previewFillLocal}.
 * Fill-module orders are refused: the module, not the budget, decides the delta.
 */
export function fillAmountFromBudget(
  order: Order,
  budget: bigint,
  now: bigint,
  ctx: FillerContext & { remaining?: bigint; prevFilled?: bigint },
): bigint {
  if (!eqAddr(order.fillModule, zeroAddress)) {
    throw new Error("fillAmountFromBudget: fill-module orders must be quoted via SettlementLens.previewFill");
  }
  const total = anchorTotal(order);
  const prevFilled = ctx.prevFilled ?? 0n;
  let fillAmount: bigint;
  if (order.side === OrderSide.BUY) {
    // Delivery = ceil(S·(p+d)/T) − ceil(S·p/T) ≤ budget  ⇔  d ≤ ⌊(budget + c)·T/S⌋ − p.
    const s = order.legsOut[0]!.start;
    if (s === 0n) return 0n;
    const c = ceilDiv(s * prevFilled, total);
    const reach = ((budget + c) * total) / s;
    fillAmount = reach > prevFilled ? reach - prevFilled : 0n;
  } else {
    const out0 = currentAmountOutAt(order, 0, now, ctx.baseFee ?? 0n, ctx.priorityFee);
    const ov = exclusivityOverrideFor(order, ctx.filler, now, ctx.fillerSet);
    const to = order.legsOut[0]!.recipient;
    const lifted = ov !== 0n && (eqAddr(to, zeroAddress) || eqAddr(to, order.maker));
    // paid = ceil(ceil(d·t/A)·(B+ov)/B) ≤ budget  ⇔  ceil(d·t/A) ≤ ⌊budget·B/(B+ov)⌋.
    const effective = lifted ? (budget * BPS) / (BPS + ov) : budget;
    fillAmount = out0 === 0n ? 0n : (effective * total) / out0;
  }
  // `fillUpTo` would trim anything above the remainder anyway.
  if (prevFilled < total && fillAmount > total - prevFilled) fillAmount = total - prevFilled;
  if (ctx.remaining !== undefined && fillAmount > ctx.remaining) fillAmount = ctx.remaining;
  if ((order.timing >> FILL_ONCE_BIT_INDEX) & 1n && prevFilled + fillAmount !== total) return 0n;
  return fillAmount;
}

/**
 * Local mirror of `Settlement.fillUpTo` / `SettlementLens.previewFill` for the
 * fill `ctx.filler` would send: clamp the request to the order's remaining size,
 * then price every leg with the contract's exact math. Identity (non-fillModule)
 * orders only — a module order's delta is the module's decision, quote it via the
 * lens.
 *
 * Reverts where the settler reverts: `ZeroFill`, `FillTooSmall`, `OverFill`,
 * `FillOnceMustBeFull` (timing bit 100), and the exclusivity gates of
 * {@link exclusivityOverrideFor}. The soft-exclusivity premium is DERIVED from
 * `ctx.filler` — maker-bound SELL outputs are lifted by it, auctioned inputs
 * discounted — byte-for-byte the {Pricing} rules.
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
  ctx: FillerContext & { proportional?: boolean },
): { delta: bigint; received: bigint[]; paid: bigint[] } {
  if (!eqAddr(order.fillModule, zeroAddress)) {
    throw new Error("previewFillLocal: fill-module orders must be quoted via SettlementLens.previewFill");
  }
  if (fillAmount === 0n) throw new Error("ZeroFill");
  const baseFee = ctx.baseFee ?? 0n;
  const priorityFee = ctx.priorityFee;
  const total = anchorTotal(order);
  let delta = fillAmount;
  if (prevFilled < total) {
    const rem = total - prevFilled;
    // A proportional request is never trimmed down — see the note above.
    if (delta > rem && (!ctx.proportional || delta === MAX_UINT256)) delta = rem;
  }
  if (delta < order.minFillAnchor) throw new Error("FillTooSmall");
  const newFilled = prevFilled + delta;
  if (newFilled > total) throw new Error("OverFill");
  if ((order.timing >> FILL_ONCE_BIT_INDEX) & 1n && newFilled !== total) throw new Error("FillOnceMustBeFull");
  const overrideBps = exclusivityOverrideFor(order, ctx.filler, now, ctx.fillerSet);

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
    const makerLeg = eqAddr(to, zeroAddress) || eqAddr(to, order.maker);
    if (amt !== 0n && overrideBps !== 0n && order.side === OrderSide.SELL && makerLeg) {
      return ceilDiv(amt * (BPS + overrideBps), BPS);
    }
    return amt;
  });
  return { delta, received, paid };
}

/**
 * Mirror of the contract's `OrderGates._overrideHasCarrier`: can any leg carry a
 * soft-exclusivity premium? AMOUNT-AWARE (audit 2026-09-30 CORE-FILL-1): a
 * non-proportional input with `(BUY && start != 0) || end != 0`, or a SELL output
 * with `start != 0` addressed to the maker (or to zero). A zero placeholder leg
 * prices to 0 whatever the override, so it carries nothing.
 */
export function overrideHasCarrier(order: Order): boolean {
  const buy = order.side === OrderSide.BUY;
  if (order.legsIn.some((l) => ((buy && l.start !== 0n) || l.end !== 0n) && !isProportional(l.start))) return true;
  if (buy) return false;
  return order.legsOut.some(
    (l) => l.start !== 0n && (eqAddr(l.recipient, zeroAddress) || eqAddr(l.recipient, order.maker)),
  );
}

/**
 * Mirror of `SettlementLens.bumpFloorAdvised`: whether a fill of `order` should
 * carry a `minBumpBps` floor because its price can move MAKER-ward between the
 * quote and inclusion. Returns the first mover found, or `null` for an order whose
 * price only moves filler-ward with time (fixed, linear, or a monotone-rising
 * curve). The movers: a price module, a priority auction, a gas bump, and a
 * descending curve segment. Every fill entry takes the floor (`fillUpTo`,
 * `fillWithPermit`, `fillWithPermitTake`, per-order `batchFill`), so a pinned-bump
 * PERMIT order's first fill is floored the same way.
 */
export function needsBumpFloor(
  order: Order,
): "price module" | "priority auction" | "gas bump" | "descending curve segment" | null {
  if (!eqAddr(order.pricingModule, zeroAddress)) return "price module";
  if (timingFlags(order.timing).priorityAuction) return "priority auction";
  if (order.gasBumpBps !== 0n) return "gas bump";
  // A FILLER_SET order's `curve` blob is the filler set, not a curve.
  if (!eqAddr(order.exclusiveFiller, FILLER_SET_SENTINEL)) {
    const pts = order.curve ?? [];
    for (let k = 1; k < pts.length; k++) {
      if (Number(pts[k]!.bumpBps) < Number(pts[k - 1]!.bumpBps)) return "descending curve segment";
    }
  }
  return null;
}

/**
 * Encode `Settlement.fillUpTo` calldata. `recipient` zero ⇒ pay the caller.
 *
 * `minBumpBps` is the filler's price floor on the resolved decay bump and is
 * REQUIRED (audit 2026-09-30 PERIPH-1.v1/v4 — a silent `0` default reproduced
 * unbounded calldata). Quote it from `SettlementLens.previewBump(order, filler,
 * takerData)` (with the gas price you will send, for a priority order) and the fill
 * reverts `BumpTooLow` if the included price lands below the quote. Every maker-ward
 * mover is covered: a price module (oracle-, state- or filler-keyed), a priority bid
 * widened by a basefee drop, a falling-basefee gas bump, and a descending curve
 * segment ({@link needsBumpFloor}). Pass `0n` explicitly only for an order with none
 * of them. It does NOT cover the soft-exclusivity premium, which depends on the
 * sender, not the clock: quote with the address that will send the fill.
 */
export function encodeFillUpTo(args: {
  order: Order;
  sig: Hex;
  fillAmount: bigint;
  recipient?: Address;
  minBumpBps: bigint;
  takerData?: Hex;
}): Hex {
  if (typeof args.minBumpBps !== "bigint") {
    throw new Error("encodeFillUpTo: minBumpBps is required — quote it from SettlementLens.previewBump (0n = no floor)");
  }
  return encodeFunctionData({
    abi: SETTLEMENT_ABI,
    functionName: "fillUpTo",
    args: [
      packOrder(args.order) as never,
      args.sig,
      args.fillAmount,
      args.recipient ?? "0x0000000000000000000000000000000000000000",
      args.minBumpBps,
      args.takerData ?? "0x",
    ],
  });
}

/**
 * Encode `Settlement.fillWithPermitTake(order, permit, sig, fillAmount, minBumpBps)`
 * — the fill whose TAKE item is funded by a single-use signed `PermitTake`. The
 * permit nonce must carry the `Take` kind tag ({@link Permit3MessageKind}).
 * `minBumpBps` is the price floor, exactly as for {@link encodeFillUpTo}.
 */
export function encodeFillWithPermitTake(args: {
  order: Order;
  permit: PermitTake;
  sig: Hex;
  fillAmount: bigint;
  minBumpBps: bigint;
}): Hex {
  return encodeFunctionData({
    abi: SETTLEMENT_ABI,
    functionName: "fillWithPermitTake",
    args: [
      packOrder(args.order) as never,
      { ...args.permit, nonce: assertPermit3Nonce(args.permit.nonce, Permit3MessageKind.Take) } as never,
      args.sig,
      args.fillAmount,
      args.minBumpBps,
    ],
  });
}

/**
 * Encode `Settlement.batchFill`. With `minBumpBps` / `takerDatas` (each aligned 1:1
 * with `orders`) this targets the 6-arg overload that floors every order's price;
 * without either, the legacy 4-arg form with no floor. Throws on a length mismatch
 * (the contract reverts `LengthMismatch`).
 */
export function encodeBatchFill(args: {
  orders: readonly Order[];
  sigs: readonly Hex[];
  fillAmounts: readonly bigint[];
  revertIfIncomplete?: boolean;
  minBumpBps?: readonly bigint[];
  takerDatas?: readonly Hex[];
}): Hex {
  const n = args.orders.length;
  if (args.sigs.length !== n || args.fillAmounts.length !== n) throw new Error("encodeBatchFill: LengthMismatch");
  const packed = args.orders.map((o) => packOrder(o)) as never;
  const rev = args.revertIfIncomplete ?? false;
  if (args.minBumpBps === undefined && args.takerDatas === undefined) {
    return encodeFunctionData({
      abi: SETTLEMENT_ABI,
      functionName: "batchFill",
      args: [packed, args.sigs, args.fillAmounts, rev],
    });
  }
  const floors = args.minBumpBps ?? new Array<bigint>(n).fill(0n);
  const blobs = args.takerDatas ?? new Array<Hex>(n).fill("0x");
  if (floors.length !== n || blobs.length !== n) throw new Error("encodeBatchFill: LengthMismatch");
  return encodeFunctionData({
    abi: SETTLEMENT_ABI,
    functionName: "batchFill",
    args: [packed, args.sigs, args.fillAmounts, rev, floors, blobs],
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
