import { describe, expect, it } from "vitest";
import { decodeFunctionData, encodeAbiParameters, getAddress, type Address } from "viem";

import {
  OrderSide,
  SETTLEMENT_ABI,
  decodeFillUpToResult,
  encodeFillUpTo,
  fillAmountFromBudget,
  previewFillLocal,
  packTiming,
  type Order,
} from "../src";
import { CANONICAL_ORDER } from "./canonicalOrder";

const SIG = ("0x" + "11".repeat(65)) as `0x${string}`;
const ZERO = "0x0000000000000000000000000000000000000000" as Address;
const A = (n: string): Address => getAddress(n);
/** An ordinary filler: the orders below name no exclusive filler, so it pays no premium. */
const FILLER = { filler: A("0x0000000000000000000000000000000000000f11") };

/** Plain 1-in/1-out SELL: 1000 tA fixed in, 2e18 tB decaying 2 → 1 out. */
function plainSell(): Order {
  return {
    ...CANONICAL_ORDER,
    side: OrderSide.SELL,
    legsIn: [{ token: A("0x00000000000000000000000000000000000000aa"), start: 1_000n * 10n ** 18n, end: 0n }],
    legsOut: [
      { token: A("0x00000000000000000000000000000000000000bb"), start: 2n * 10n ** 18n, end: 1n * 10n ** 18n, recipient: ZERO },
    ],
    timing: 0n, // decay clocks set per test
    exclusiveFiller: ZERO,
    exclusivityOverrideBps: 0n,
    minFillAnchor: 0n,
    curve: [],
    gasBumpBps: 0n,
    gasPriceRef: 0n,
    items: [],
    fillModule: ZERO,
    fillTotal: 0n,
    priorityScale: 0n,
    pricingModule: ZERO,
  };
}

describe("fillUpTo calldata", () => {
  it("encodes and decodes with defaults", () => {
    const data = encodeFillUpTo({ order: CANONICAL_ORDER, sig: SIG, fillAmount: 42n });
    const { functionName, args } = decodeFunctionData({ abi: SETTLEMENT_ABI, data });
    expect(functionName).toBe("fillUpTo");
    expect((args as any)[2]).toBe(42n);
    expect((args as any)[3]).toBe(ZERO);
    expect((args as any)[4]).toBe(0n); // minBumpBps defaults to 0 = no price floor
    expect((args as any)[5]).toBe("0x");
  });

  it("round-trips the (delta, received, paid) result", () => {
    const encoded = encodeAbiParameters(
      [{ type: "uint256" }, { type: "uint256[]" }, { type: "uint256[]" }],
      [7n, [1n, 2n], [3n]],
    );
    const out = decodeFillUpToResult(encoded);
    expect(out.delta).toBe(7n);
    expect(out.received).toEqual([1n, 2n]);
    expect(out.paid).toEqual([3n]);
  });
});

describe("fillAmountFromBudget", () => {
  it("BUY without fillTotal: the budget IS the fill amount", () => {
    const order: Order = { ...plainSell(), side: OrderSide.BUY };
    expect(fillAmountFromBudget(order, 123n, 0n, FILLER)).toBe(123n);
  });

  it("SELL: converts through the current tick and stays within budget at that tick", () => {
    const order = plainSell(); // no decay clocks ⇒ fixed at start (2e18 per 1000e18)
    const budget = 1n * 10n ** 18n; // half the full output
    const fillAmount = fillAmountFromBudget(order, budget, 0n, FILLER);
    expect(fillAmount).toBe(500n * 10n ** 18n);
    // ceil-priced delivery at that fill stays within budget
    const { paid } = previewFillLocal(order, fillAmount, 0n, 0n, FILLER);
    expect(paid[0]! <= budget).toBe(true);
  });

  it("pre-clamps to remaining when provided", () => {
    const order = plainSell();
    expect(fillAmountFromBudget(order, 10n ** 30n, 0n, { ...FILLER, remaining: 77n })).toBe(77n);
  });
});

describe("previewFillLocal", () => {
  it("clamps to remaining and prices both sides", () => {
    const order = plainSell();
    const total = 1_000n * 10n ** 18n;
    const prev = (total * 60n) / 100n;
    const { delta, received, paid } = previewFillLocal(order, total, prev, 0n, FILLER);
    expect(delta).toBe(total - prev);
    expect(received[0]).toBe(total - prev); // fixed anchor leg: receipt == delta
    expect(paid[0]).toBe((2n * 10n ** 18n * 40n) / 100n); // pro-rata at the fixed tick
  });

  it("throws FillTooSmall when the clamp lands under the maker floor", () => {
    const order = plainSell();
    const total = 1_000n * 10n ** 18n;
    order.minFillAnchor = (total * 30n) / 100n;
    expect(() => previewFillLocal(order, total, (total * 80n) / 100n, 0n, FILLER)).toThrow("FillTooSmall");
  });

  it("refuses fill-module orders (lens territory)", () => {
    const order = plainSell();
    order.fillModule = A("0x000000000000000000000000000000000000f111");
    expect(() => previewFillLocal(order, 1n, 0n, 0n, FILLER)).toThrow(/fill-module/);
  });
});

describe("previewFillLocal mirrors the re-audit 2026-09-29 core rules", () => {
  const MAX = (1n << 256n) - 1n;

  it("a soft window with no leg to carry the premium refuses the outsider", () => {
    const o = plainSell();
    // Soft window (100 bps) for someone else, open until t = 1000.
    o.exclusiveFiller = A("0x000000000000000000000000000000000000e0e0");
    o.exclusivityOverrideBps = 100n;
    o.timing = packTiming(0, 0, 1_000);
    // Fixed input, sole output to a THIRD party: nothing can carry the override.
    o.legsOut = [{ ...o.legsOut[0]!, end: 0n, recipient: A("0x0000000000000000000000000000000000000b0b") }];
    expect(() => previewFillLocal(o, 1n * 10n ** 18n, 0n, 0n, FILLER)).toThrow("NotExclusiveFiller");
    // A maker-addressed output carries it again.
    o.legsOut = [{ ...o.legsOut[0]!, recipient: ZERO }];
    expect(() => previewFillLocal(o, 1n * 10n ** 18n, 0n, 0n, FILLER)).not.toThrow();
  });

  it("a proportional request is not trimmed down unless it is the MAX sentinel", () => {
    const o = plainSell(); // anchor = legsIn[0].start (the resolved balance)
    const anchor = o.legsIn[0]!.start;
    expect(() => previewFillLocal(o, anchor * 2n, 0n, 0n, { ...FILLER, proportional: true })).toThrow("OverFill");
    expect(previewFillLocal(o, MAX, 0n, 0n, { ...FILLER, proportional: true }).delta).toBe(anchor);
    // An absolute order keeps the ordinary clamp.
    expect(previewFillLocal(o, anchor * 2n, 0n, 0n, FILLER).delta).toBe(anchor);
  });
});
