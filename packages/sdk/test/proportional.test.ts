import { describe, expect, it } from "vitest";
import { getAddress, type Address } from "viem";

import {
  OrderSide,
  BPS,
  SENTINEL_FLOOR,
  isProportional,
  proportionalBps,
  encodeProportional,
  resolveProportional,
  validateProportional,
  orderCapWarning,
  resolveProportionalOrder,
  anchorTotal,
  type Order,
} from "../src";

const A = (n: string): Address => getAddress(n);
const USDC = A("0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48");
const WETH = A("0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2");
const ZERO = A("0x0000000000000000000000000000000000000000");
const MAX_UINT256 = (1n << 256n) - 1n;

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
    ...partial,
  };
}

/** A SELL order whose input anchor is `bps` of the maker's balance, capped at `cap`. */
function propOrder(bps: bigint, cap: bigint, partial: Partial<Order> = {}): Order {
  return order({ legsIn: [{ token: USDC, start: encodeProportional(bps), end: cap }], ...partial });
}

describe("Proportional encoding", () => {
  // These constants are the whole contract between the SDK and Proportional.sol.
  // If either side moves, orders encode to amounts the settler reads as absolute.
  it("pins the sentinel boundary exactly where Solidity puts it", () => {
    expect(SENTINEL_FLOOR).toBe(MAX_UINT256 - BPS);
    expect(BPS).toBe(10_000n);
    expect(isProportional(0n)).toBe(false);
    expect(isProportional(2n ** 128n)).toBe(false);
    expect(isProportional(SENTINEL_FLOOR)).toBe(false); // the floor itself is absolute
    expect(isProportional(SENTINEL_FLOOR + 1n)).toBe(true); // one above is 1bp
    expect(proportionalBps(SENTINEL_FLOOR + 1n)).toBe(1n);
    expect(isProportional(MAX_UINT256)).toBe(true);
    expect(proportionalBps(MAX_UINT256)).toBe(BPS); // max is the 100% marker
  });

  it("round-trips every bps in range and rejects those out of it", () => {
    for (const bps of [1n, 2n, 100n, 5_000n, 9_999n, 10_000n]) {
      const marker = encodeProportional(bps);
      expect(isProportional(marker)).toBe(true);
      expect(proportionalBps(marker)).toBe(bps);
    }
    expect(() => encodeProportional(0n)).toThrow();
    expect(() => encodeProportional(BPS + 1n)).toThrow();
  });

  it("resolves against a balance and honours the cap", () => {
    const full = encodeProportional(10_000n);
    expect(resolveProportional(2_000_000_000n, full, 0n)).toBe(2_000_000_000n); // uncapped
    expect(resolveProportional(3_000_000_000n, full, 2_000_000_000n)).toBe(2_000_000_000n); // clamped
    expect(resolveProportional(1_500_000_000n, full, 2_000_000_000n)).toBe(1_500_000_000n); // under cap
    expect(resolveProportional(2_000_000_000n, encodeProportional(5_000n), 0n)).toBe(1_000_000_000n); // 50%
    expect(resolveProportional(0n, full, 0n)).toBe(0n);
  });
});

describe("resolveProportionalOrder", () => {
  it("replaces the marker with the resolved amount and clears the cap", () => {
    const resolved = resolveProportionalOrder(propOrder(10_000n, 2_000_000_000n), 1_500_000_000n);
    expect(resolved.legsIn[0]!.start).toBe(1_500_000_000n);
    expect(resolved.legsIn[0]!.end).toBe(0n); // `end` was the cap, not a ramp
    expect(anchorTotal(resolved)).toBe(1_500_000_000n);
  });

  it("leaves an ordinary absolute order untouched", () => {
    const plain = order({});
    expect(resolveProportionalOrder(plain, 999n)).toBe(plain);
  });

  it("refuses to resolve an order the settler would reject", () => {
    expect(() => resolveProportionalOrder(propOrder(10_000n, 0n, { fillTotal: 5n }), 1n)).toThrow(/fillTotal/);
  });
});

describe("pricing refuses unresolved markers", () => {
  // The failure mode this prevents: pricing a ~1.15e77 "amount" and returning a
  // preview that silently means nothing.
  it("throws rather than pricing the raw marker", () => {
    expect(() => anchorTotal(propOrder(10_000n, 2_000_000_000n))).toThrow(/resolveProportionalOrder/);
  });
});

describe("validateProportional mirrors the settler", () => {
  it("accepts the one legal position", () => {
    expect(validateProportional(propOrder(10_000n, 2_000_000_000n))).toBeNull();
  });

  it("accepts an uncapped marker, because the settler does", () => {
    // Looser than ideal, but a preflight that is STRICTER than the settler drops
    // orders that would have filled. The cap is surfaced as a warning instead.
    expect(validateProportional(propOrder(10_000n, 0n))).toBeNull();
    expect(orderCapWarning(propOrder(10_000n, 0n))).toMatch(/no cap/);
    expect(orderCapWarning(propOrder(10_000n, 2_000_000_000n))).toBeNull();
  });

  it("rejects every position the settler rejects", () => {
    const onLeg1 = order({
      legsIn: [
        { token: USDC, start: 2_000_000_000n, end: 0n },
        { token: WETH, start: encodeProportional(10_000n), end: 0n },
      ],
    });
    expect(validateProportional(onLeg1)).toMatch(/legsIn\[0\]/);
    expect(validateProportional(propOrder(10_000n, 0n, { side: OrderSide.BUY }))).toMatch(/SELL/);
    expect(validateProportional(propOrder(10_000n, 0n, { fillTotal: 1n }))).toMatch(/fillTotal/);
    expect(validateProportional(propOrder(10_000n, 0n, { fillModule: USDC }))).toMatch(/fillModule/);

    const onOutput = order({
      legsOut: [{ token: WETH, start: encodeProportional(10_000n), end: 0n, recipient: ZERO }],
    });
    expect(validateProportional(onOutput)).toMatch(/output leg/);
  });
});
