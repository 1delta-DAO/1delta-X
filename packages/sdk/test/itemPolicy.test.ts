import { describe, expect, it } from "vitest";
import { getAddress, type Address } from "viem";

import {
  ItemPolicy,
  ITEM_POLICY_OFFSET,
  forBalance,
  forBalanceFloorBps,
  itemPolicyOf,
  packTiming,
  withFillOnce,
  withItemPolicy,
} from "../src";

const WETH = getAddress("0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2") as Address;

/// The maker-side controls the settler added for ORDERING and for the balance
/// form's lower bound. Both live in words the maker already signs — `timing` bits
/// [96:100) and the `TAKE_FOR` funding descriptor's bits [160:176) — so these tests
/// pin the packing against the Solidity constants rather than any behaviour of viem.
describe("itemPolicy", () => {
  it("packs into timing bits [96:100) and reads back", () => {
    const timing = packTiming(1_000, 60, 0);
    for (const p of [ItemPolicy.ANY, ItemPolicy.ORDERED, ItemPolicy.ATOMIC, ItemPolicy.CANONICAL]) {
      const t = withItemPolicy(timing, p);
      expect(itemPolicyOf(t)).toBe(p);
      expect((t >> ITEM_POLICY_OFFSET) & 0xfn).toBe(BigInt(p));
    }
  });

  it("leaves the clocks and the other flags alone", () => {
    const timing = withFillOnce(packTiming(1_000, 60, 2_000));
    const t = withItemPolicy(timing, ItemPolicy.CANONICAL);
    expect(t & 0xffff_ffffn).toBe(1_000n);
    expect((t >> 32n) & 0xffff_ffffn).toBe(60n);
    expect((t >> 64n) & 0xffff_ffffn).toBe(2_000n);
    expect((t >> 100n) & 1n).toBe(1n); // fill-once survives
  });

  it("REPLACES a previous policy rather than or-ing into it", () => {
    const t = withItemPolicy(withItemPolicy(packTiming(0, 0, 0), ItemPolicy.CANONICAL), ItemPolicy.ORDERED);
    expect(itemPolicyOf(t)).toBe(ItemPolicy.ORDERED);
  });

  it("defaults to ANY, which is what an unset field means", () => {
    expect(itemPolicyOf(packTiming(1_000, 60, 0))).toBe(ItemPolicy.ANY);
  });

  it("rejects a policy that does not fit the nibble", () => {
    expect(() => withItemPolicy(0n, 16 as ItemPolicy)).toThrow();
  });
});

describe("forBalance floor", () => {
  it("defaults to a FULL-CAP floor — fund the whole cap or do not fill", () => {
    expect(forBalanceFloorBps(forBalance(WETH))).toBe(10_000);
  });

  it("carries the token in the low 160 bits and the floor in [160:176)", () => {
    const desc = forBalance(WETH, 8_000);
    expect(desc & ((1n << 160n) - 1n)).toBe(BigInt(WETH));
    expect(forBalanceFloorBps(desc)).toBe(8_000);
    expect(desc >> 254n).toBe(3n); // the two top bits that select the balance form
  });

  it("allows the settler's legacy zero floor explicitly, and nothing above 10000", () => {
    expect(forBalanceFloorBps(forBalance(WETH, 0))).toBe(0);
    expect(() => forBalance(WETH, 10_001)).toThrow();
    expect(() => forBalance(WETH, -1)).toThrow();
  });
});
