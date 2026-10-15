import { describe, expect, it } from "vitest";
import { getAddress, toFunctionSelector, zeroAddress, type Address } from "viem";

import {
  AGGREGATOR_FILL_SOLVER_ABI,
  NATIVE_BALANCE,
  OrderSide,
  hashOrderStruct,
  isNativeOutOrder,
  nativeBalanceMisuse,
  nativeBalanceOf,
  nativeOutLeg,
  packOrder,
  packTiming,
  withDeltaVerifyOutputs,
  withFillOnce,
  type Order,
} from "../src";

/**
 * NATIVE DELIVERY THROUGH A BALANCE VIEW (task 30): a DIRECT order whose `legsOut[0]`
 * is the `NativeBalance` view receives the raw native coin. The golden vector pins
 * the packed wire shape and the order hash of exactly the order the app signs
 * (USD₮0 → RBTC market ticket on Rootstock, fill-once, delta-verify, the solver as
 * `exclusiveFiller`), so a drift in `nativeOutLeg` or `packOrder` shows here.
 *
 * The struct hash itself is cross-checked against Solidity by `GOLDEN_ORDER_HASH`
 * (eip712.test.ts ↔ HashGolden.t.sol); this vector pins the SHAPE on top of it.
 */
const A = (n: string): Address => getAddress(n);
const NB = A("0x00000000000000000000000000000000000a7b01"); // placeholder: NativeBalance is not deployed yet
const USD0 = A("0x779ded0c9e1022225f8e0630b35a9b54be713736");
const SOLVER = A("0x00000000000000000000000000000000000050a1");
const MAKER = A("0x00000000000000000000000000000000000000aa");

function nativeOrder(over: Partial<Order> = {}): Order {
  return {
    maker: MAKER,
    side: OrderSide.SELL,
    nonce: 7n,
    expiry: 1_800_000_300n,
    legsIn: [{ token: USD0, start: 50_000_000n, end: 0n }],
    legsOut: [nativeOutLeg({ nativeBalance: NB, start: 600_000_000_000_000n, end: 590_000_000_000_000n })],
    timing: withDeltaVerifyOutputs(withFillOnce(packTiming(1_800_000_000, 60, 0))),
    exclusiveFiller: SOLVER,
    minFillAnchor: 0n,
    exclusivityOverrideBps: 0n,
    curve: [],
    gasBumpBps: 0n,
    gasPriceRef: 0n,
    priorityScale: 0n,
    items: [],
    validators: [],
    invariants: [],
    fillModule: zeroAddress,
    fillTotal: 0n,
    pricingModule: zeroAddress,
    ...over,
  };
}

/** The pinned wire form — regenerate deliberately, never to make a red test green. */
const GOLDEN_NATIVE_OUT = {
  legsOut: "0x0100000000000000000000000000000000000a7b01000000000000000000000000000000000000000000000000000221b262dd80000000000000000000000000000000000000000000000000000002189a146ae0000000000000000000000000000000000000000000",
  timing: 2630703385646116452037508181544819454145484299840015421952n,
  hash: "0x1a7a70a48acb065c7d9f12a11a1b538c8412f7a689e738c8cc5f47aaade8425b",
};

describe("nativeOutLeg + golden vector", () => {
  it("is { NativeBalance, start, end, recipient 0x0 = the maker }", () => {
    expect(nativeOutLeg({ nativeBalance: NB, start: 5n })).toEqual({ token: NB, start: 5n, end: 0n, recipient: zeroAddress });
    expect(() => nativeOutLeg({ nativeBalance: zeroAddress, start: 5n })).toThrow(/not deployed/);
    expect(() => nativeOutLeg({ nativeBalance: NB, start: 0n })).toThrow(/start/);
    expect(() => nativeOutLeg({ nativeBalance: NB, start: 5n, end: 6n })).toThrow(/falls/);
  });

  it("pins the packed legsOut, the timing word and the order hash of the DIRECT NativeBalance-out order", () => {
    const o = nativeOrder();
    const w = packOrder(o);
    expect(w.legsOut).toBe(GOLDEN_NATIVE_OUT.legsOut);
    expect(w.timing).toBe(GOLDEN_NATIVE_OUT.timing);
    expect(w.exclusiveFiller.toLowerCase()).toBe(SOLVER.toLowerCase());
    expect(w.items).toBe("0x00"); // no item: native delivery is not an item
    expect(hashOrderStruct(o)).toBe(GOLDEN_NATIVE_OUT.hash);
    // The leg blob carries the view's address where a token sits — nothing else changes.
    expect(w.legsOut.toLowerCase()).toContain(NB.slice(2).toLowerCase());
    expect((w.timing >> 104n) & 1n).toBe(1n);
  });
});

describe("NATIVE_BALANCE per chain", () => {
  it("is the deployed Rootstock view (2026-10-15); unknown chains are off", () => {
    expect(NATIVE_BALANCE[30]).toBe("0xA45ec37619C9F9B2f9d54692d578D1b1246c854c");
    expect(nativeBalanceOf(30)).toBe("0xA45ec37619C9F9B2f9d54692d578D1b1246c854c");
    expect(nativeBalanceOf(1)).toBeUndefined();
    expect(nativeBalanceOf(1)).toBeUndefined();
  });
});

describe("nativeBalanceMisuse: the view is only ever a delta-verified output", () => {
  it("accepts the shape, and ignores orders that do not name it", () => {
    expect(nativeBalanceMisuse(nativeOrder(), NB)).toBeNull();
    expect(isNativeOutOrder(nativeOrder(), NB)).toBe(true);
    expect(isNativeOutOrder(nativeOrder(), undefined)).toBe(false);
    const plain = nativeOrder({ legsOut: [{ token: USD0, start: 1n, end: 0n, recipient: zeroAddress }] });
    expect(nativeBalanceMisuse(plain, NB)).toBeNull();
    expect(nativeBalanceMisuse(nativeOrder(), undefined)).toBeNull();
  });

  it.each([
    ["an input leg", { legsIn: [{ token: NB, start: 1n, end: 0n }] }, /input/],
    ["a pull output", { timing: packTiming(0, 0, 0) }, /DIRECT/],
    ["a second leg", { legsOut: [nativeOutLeg({ nativeBalance: NB, start: 1n }), nativeOutLeg({ nativeBalance: NB, start: 1n })] }, /once/],
    ["leg 1", { legsOut: [{ token: USD0, start: 1n, end: 0n, recipient: zeroAddress }, nativeOutLeg({ nativeBalance: NB, start: 1n })] }, /legsOut\[0\]/],
    ["no named filler", { exclusiveFiller: zeroAddress }, /exclusiveFiller/],
  ] as const)("refuses %s", (_n, over, why) => {
    expect(nativeBalanceMisuse(nativeOrder(over as Partial<Order>), NB)).toMatch(why);
  });
});

describe("AggregatorFillSolver ABI (solver v3)", () => {
  it("carries the native views and errors", () => {
    const names = AGGREGATOR_FILL_SOLVER_ABI.map((x) => ("name" in x ? x.name : ""));
    for (const n of ["nativeDelivery", "NativeLegShape", "NativeSendFailed", "NotWNative", "BadNative", "ItemFillUnsupported"]) expect(names).toContain(n);
    for (const n of ["NATIVE_BALANCE", "WNATIVE"]) expect(names).not.toContain(n); // private immutables, one getter
    expect(toFunctionSelector("nativeDelivery()")).toBe(toFunctionSelector(AGGREGATOR_FILL_SOLVER_ABI.find((x) => "name" in x && x.name === "nativeDelivery") as never));
  });
});
