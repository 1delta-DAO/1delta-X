import { describe, expect, it } from "vitest";
import { getAddress, type Address } from "viem";

import {
  OrderSide,
  packTiming,
  unpackTiming,
  anchorTotal,
  bumpBps,
  currentAmountOutAt,
  currentAmountInAt,
  fillAmountsOut,
  inputOwed,
  type Order,
} from "../src";

const A = (n: string): Address => getAddress(n);
const USDC = A("0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48");
const WETH = A("0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2");
const ZERO = A("0x0000000000000000000000000000000000000000");

/// Minimal order skeleton; tests override legsIn/legsOut/timing/side/fillTotal.
function order(partial: Partial<Order>): Order {
  return {
    maker: A("0x00000000000000000000000000000000000000a1"),
    side: OrderSide.SELL,
    nonce: 0n,
    deadline: 10_000_000n,
    legsIn: [{ token: USDC, start: 2_000_000_000n, end: 0n }],
    legsOut: [{ token: WETH, start: 1_000_000_000_000_000_000n, end: 0n, recipient: ZERO }],
    timing: 0n,
    exclusiveFiller: ZERO,
    minFillAnchor: 0n,
    exclusivityOverrideBps: 0n,
    curve: [],
    gasBumpBps: 0n,
    gasPriceRef: 0n,
    items: [],
    validators: [],
    invariants: [],
    fillModule: ZERO,
    fillTotal: 0n,
    priorityScale: 0n,
    pricingModule: ZERO,
    ...partial,
  };
}

describe("packTiming / unpackTiming", () => {
  it("round-trips the three clocks and matches the bit layout", () => {
    const t = packTiming(111, 222, 333);
    expect(t).toBe(111n | (222n << 32n) | (333n << 64n));
    expect(unpackTiming(t)).toEqual({ decayStartTime: 111, decayDuration: 222, exclusivityEndTime: 333 });
  });
  it("rejects a field that exceeds uint32", () => {
    expect(() => packTiming(2 ** 32, 0, 0)).toThrow();
  });
});

describe("anchorTotal", () => {
  it("SELL anchors on legsIn[0].start", () => {
    expect(anchorTotal(order({ side: OrderSide.SELL }))).toBe(2_000_000_000n);
  });
  it("BUY anchors on legsOut[0].start", () => {
    expect(anchorTotal(order({ side: OrderSide.BUY }))).toBe(1_000_000_000_000_000_000n);
  });
  it("fillTotal overrides the leg anchor when set", () => {
    expect(anchorTotal(order({ fillTotal: 42n }))).toBe(42n);
  });
});

describe("bumpBps (single linear segment)", () => {
  // decayStartTime 1000, decayDuration 100.
  const o = order({ timing: packTiming(1000, 100, 0) });
  it("is 0 at/before the start", () => {
    expect(bumpBps(o, 1000n)).toBe(0n);
  });
  it("is 5000 at the midpoint", () => {
    expect(bumpBps(o, 1050n)).toBe(5000n);
  });
  it("saturates to 10000 at/after the end", () => {
    expect(bumpBps(o, 1100n)).toBe(10_000n);
    expect(bumpBps(o, 5000n)).toBe(10_000n);
  });
  it("no decayDuration ⇒ bump stays 0", () => {
    expect(bumpBps(order({ timing: 0n }), 999_999n)).toBe(0n);
  });
});

describe("currentAmountOutAt (falling output)", () => {
  // Mirrors PlainSwap.t.sol: 1 ETH → 0.9 ETH over 100s ⇒ midpoint 0.95 ETH.
  const o = order({
    timing: packTiming(1000, 100, 0),
    legsOut: [{ token: WETH, start: 1_000_000_000_000_000_000n, end: 900_000_000_000_000_000n, recipient: ZERO }],
  });
  it("returns start at t=start", () => {
    expect(currentAmountOutAt(o, 0, 1000n)).toBe(1_000_000_000_000_000_000n);
  });
  it("decays to the midpoint tick", () => {
    expect(currentAmountOutAt(o, 0, 1050n)).toBe(950_000_000_000_000_000n);
  });
  it("fixed leg (end==0) ignores the clock", () => {
    expect(currentAmountOutAt(order({ timing: packTiming(1000, 100, 0) }), 0, 1050n)).toBe(
      1_000_000_000_000_000_000n,
    );
  });
  it("throws on a non-falling output (start < end)", () => {
    const bad = order({
      timing: packTiming(1000, 100, 0),
      legsOut: [{ token: WETH, start: 1n, end: 2n, recipient: ZERO }],
    });
    expect(() => currentAmountOutAt(bad, 0, 1050n)).toThrow();
  });
});

describe("currentAmountInAt (rising input)", () => {
  // Mirrors RisingInputFee.t.sol: 2000e6 → 2200e6 ⇒ midpoint 2100e6.
  const o = order({
    timing: packTiming(1000, 100, 0),
    legsIn: [{ token: USDC, start: 2_000_000_000n, end: 2_200_000_000n }],
  });
  it("rises to the midpoint tick", () => {
    expect(currentAmountInAt(o, 0, 1050n)).toBe(2_100_000_000n);
  });
  it("fixed leg (end==0) ignores the clock", () => {
    expect(currentAmountInAt(order({ timing: packTiming(1000, 100, 0) }), 0, 1050n)).toBe(2_000_000_000n);
  });
  it("throws on a non-rising input (start > end)", () => {
    const bad = order({
      timing: packTiming(1000, 100, 0),
      legsIn: [{ token: USDC, start: 2n, end: 1n }],
    });
    expect(() => currentAmountInAt(bad, 0, 1050n)).toThrow();
  });
});

describe("gas bump widens the band", () => {
  it("adds decay proportional to basefee, capped at gasBumpBps", () => {
    // gasBumpBps 2000, ref 10 gwei, basefee 5 gwei ⇒ +1000 bps (half of 2000).
    const o = order({ timing: 0n, gasBumpBps: 2_000n, gasPriceRef: 10_000_000_000n });
    expect(bumpBps(o, 0n, 5_000_000_000n)).toBe(1_000n);
  });
});

describe("fill slicing", () => {
  it("BUY outputs are the fixed cumulative slice (partials sum exact)", () => {
    // anchor = legsOut[0].start = 1e18; two halves sum to the whole.
    const o = order({ side: OrderSide.BUY });
    const half = 500_000_000_000_000_000n;
    const a = fillAmountsOut(o, half, 0n, 0n)[0]!;
    const b = fillAmountsOut(o, half, 0n, half)[0]!;
    expect(a + b).toBe(1_000_000_000_000_000_000n);
  });
  it("fixed SELL input owed is the exact cumulative slice", () => {
    const o = order({ side: OrderSide.SELL }); // anchor 2000e6, fixed input
    const owed = inputOwed(o, 0, 0n, 2_000_000_000n, 0n);
    expect(owed).toBe(2_000_000_000n);
  });
  it("rising SELL fee leg is auction-priced per fill", () => {
    // anchor = legsIn[0].start (the fixed anchor leg); a second rising leg auctions.
    const o = order({
      timing: packTiming(1000, 100, 0),
      legsIn: [
        { token: USDC, start: 2_000_000_000n, end: 0n }, // fixed anchor
        { token: WETH, start: 1_000_000_000_000_000n, end: 3_000_000_000_000_000n }, // rising fee
      ],
    });
    // Full fill at the midpoint tick (bump 5000): fee leg tick = 2e15; owed = 2e15.
    const owed = inputOwed(o, 1, 0n, 2_000_000_000n, 1050n);
    expect(owed).toBe(2_000_000_000_000_000n);
  });
});
