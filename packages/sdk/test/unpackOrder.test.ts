import { describe, expect, it } from "vitest";

import { hashOrderStruct, OrderSide, packOrder, unpackOrder, withPriorityAuction, type Order } from "../src";
import { CANONICAL_ORDER, GOLDEN_ORDER_HASH } from "./canonicalOrder";

describe("unpackOrder (inverse of packOrder)", () => {
  it("round-trips the golden order and keeps its hash", () => {
    const back = unpackOrder(packOrder(CANONICAL_ORDER));
    const { baselinePriorityFeeWei: _zero, ...rest } = CANONICAL_ORDER;
    expect(back).toEqual(rest);
    expect(hashOrderStruct(back)).toBe(GOLDEN_ORDER_HASH);
  });

  it("brings side, expiry and a non-zero baseline fee back out", () => {
    const o: Order = {
      ...CANONICAL_ORDER,
      side: OrderSide.BUY,
      expiry: (1n << 48n) - 1n,
      timing: withPriorityAuction(CANONICAL_ORDER.timing),
      priorityScale: 7n,
      baselinePriorityFeeWei: 123n,
      curve: [],
      items: [],
    };
    const back = unpackOrder(packOrder(o));
    expect(back).toEqual(o);
    expect(hashOrderStruct(back)).toBe(hashOrderStruct(o));
  });

  it("refuses a truncated or padded blob", () => {
    const w = packOrder(CANONICAL_ORDER);
    expect(() => unpackOrder({ ...w, legsIn: w.legsIn.slice(0, -2) as `0x${string}` })).toThrow(/too short/);
    expect(() => unpackOrder({ ...w, validators: `${w.validators}00` })).toThrow(/trailing/);
  });
});
