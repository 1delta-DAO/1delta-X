import { decodeFunctionData, encodeFunctionData, type Address, type Hex } from "viem";

import { SETTLEMENT_ABI, SETTLEMENT_CALLBACK_ABI } from "./abi";
import { packOrder } from "./packed";
import type { Order } from "./types";

/**
 * Where the solver callback runs, and whether it receives the fill's resolved
 * amounts. Mirrors the on-chain `CallbackMode`.
 *
 * The encoding is deliberate: **bit 0 is the ordering, bit 1 opts into the typed
 * payload**, so the settler dispatches with bit math rather than four compares.
 */
export enum CallbackMode {
  /** callback → deliver outputs → items → pay inputs. Works for any order. */
  PreDelivery = 0,
  /** pay inputs → callback → deliver outputs. Item-free orders only. */
  PostInputs = 1,
  /** {@link PreDelivery}, with the fill's resolved context handed to the callback. */
  PreDeliveryTyped = 2,
  /** {@link PostInputs}, with the fill's resolved context handed to the callback. */
  PostInputsTyped = 3,
}

/** True when the mode hands the callback an {@link SettlementFillContext}. */
export function isTypedMode(mode: CallbackMode): boolean {
  return (mode & 2) === 2;
}

/** True when inputs are paid BEFORE the callback runs. */
export function isPostInputs(mode: CallbackMode): boolean {
  return (mode & 1) === 1;
}

/**
 * Encode `Settlement.fillWithCallback`.
 *
 * ⚠ ON A `*Typed` MODE THE TARGET MUST IMPLEMENT `ISettlementCallback`. The
 * settler does NOT pass `callbackData` through verbatim there — it wraps it as
 * the `userData` argument of `onSettlementFill(...)`. A target without that
 * function is called with a selector it does not have and reverts with EMPTY
 * returndata, which is the signal for "wrong callback shape".
 *
 * ⚠ ON AN UNTYPED MODE `callbackData` IS CALLED VERBATIM. That is the more
 * expressive shape — any function on any contract — and it is why both exist.
 * The call runs through the allowance-less `SolverCallbackExecutor`, so the
 * target sees THAT as `msg.sender`, never the settlement.
 */
export function encodeFillWithCallback(args: {
  order: Order;
  sig: Hex;
  fillAmount: bigint;
  callbackTarget: Address;
  callbackData: Hex;
  mode: CallbackMode;
  takerData?: Hex;
}): Hex {
  const base = [
    packOrder(args.order) as never,
    args.sig,
    args.fillAmount,
    args.callbackTarget,
    args.callbackData,
    args.mode,
  ];
  return encodeFunctionData({
    abi: SETTLEMENT_ABI,
    functionName: "fillWithCallback",
    args: (args.takerData === undefined ? base : [...base, args.takerData]) as never,
  });
}

/** The resolved fill state handed to a `*Typed` callback. */
export interface SettlementFillContext {
  orderHash: Hex;
  /** Cumulative progress BEFORE this fill. */
  prevFilled: bigint;
  /** Cumulative progress AFTER it. */
  newFilled: bigint;
  /** Fill denominator, proportional markers already resolved. */
  anchor: bigint;
  /**
   * What this fill must deliver per output leg, indexed 1:1 with `legsOut`.
   *
   * Already sliced for a partial fill and already lifted by any soft-exclusivity
   * override — i.e. the exact numbers the settlement is about to pull. A taker
   * can size its delivery from these alone.
   */
  pricedOut: readonly bigint[];
  /** The taker's own blob, passed through untouched. */
  userData: Hex;
}

/** This fill's own progress — `newFilled - prevFilled`.
 *
 *  ⚠ NOT the `fillAmount` that was requested. For a fill-module order the settler
 *  accepts whatever `IFillModule.resolveFill` returned, which the caller never
 *  chose; subtracting the request would mis-price such a fill. */
export function fillDelta(ctx: SettlementFillContext): bigint {
  return ctx.newFilled - ctx.prevFilled;
}

/** Total across every output leg — what a just-in-time taker must have on hand. */
export function totalPricedOut(ctx: SettlementFillContext): bigint {
  return ctx.pricedOut.reduce((a, b) => a + b, 0n);
}

/**
 * Decode an `onSettlementFill` call — for a taker written in TS (a simulator, a
 * test harness), or to inspect what the settler handed a solver contract.
 */
export function decodeSettlementCallback(data: Hex): SettlementFillContext {
  const { args } = decodeFunctionData({ abi: SETTLEMENT_CALLBACK_ABI, data });
  const [orderHash, prevFilled, newFilled, anchor, pricedOut, userData] = args as readonly [
    Hex,
    bigint,
    bigint,
    bigint,
    readonly bigint[],
    Hex,
  ];
  return { orderHash, prevFilled, newFilled, anchor, pricedOut, userData };
}
