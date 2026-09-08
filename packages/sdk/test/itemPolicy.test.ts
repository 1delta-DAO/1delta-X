import { describe, expect, it } from "vitest";
import { getAddress, type Address } from "viem";

import {
  ItemPolicy,
  ITEM_POLICY_OFFSET,
  forBalance,
  isPreFundDesc,
  forLegPreFund,
  forLeg,
  forBalanceFloorBps,
  forBalanceFloorBpsRaw,
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

  // An UNSET floor is the FULL CAP, not "no floor". `0` is what an unfilled
  // descriptor field holds, so it must not select the lenient mode — the settler
  // resolves it to 10000 (`Base._forSlice`), and the reader reports what the settler
  // will actually enforce rather than the literal bits.
  it("reads an unset floor as the full cap, matching the settler", () => {
    expect(forBalanceFloorBps(forBalance(WETH, 0))).toBe(10_000);
    expect(forBalanceFloorBpsRaw(forBalance(WETH, 0))).toBe(0);
  });

  it("keeps an explicitly lenient floor lenient — leniency is signed, not inherited", () => {
    expect(forBalanceFloorBps(forBalance(WETH, 1))).toBe(1);
    expect(forBalanceFloorBpsRaw(forBalance(WETH, 1))).toBe(1);
  });

  it("rejects out-of-range floors", () => {
    expect(() => forBalance(WETH, 10_001)).toThrow();
    expect(() => forBalance(WETH, -1)).toThrow();
  });
});

describe("pre-funded funding descriptors", () => {
  // The bit the `*PreFundModule` contracts require and `forLeg` does not set. This
  // gap was a real footgun: a maker following `forLeg`'s old advice ("point the leg
  // at the module and sign the venue's pre-fund variant") produced `>> 253 == 4`,
  // which the module refuses with `PreFundDescriptorRequired`.
  it("sets bits 255 and 253, leaving 254 clear", () => {
    expect(forLegPreFund(0, "0x1111111111111111111111111111111111111111" as `0x${string}`) >> 253n).toBe(5n);
    expect(isPreFundDesc(forLegPreFund(0, "0x1111111111111111111111111111111111111111" as `0x${string}`))).toBe(true);
  });

  it("carries the leg index in the low bits", () => {
    expect(forLegPreFund(7, "0x1111111111111111111111111111111111111111" as `0x${string}`) & 0xffffn).toBe(7n);
    expect(forLegPreFund(0xffff, "0x1111111111111111111111111111111111111111" as `0x${string}`) & 0xffffn).toBe(0xffffn);
  });

  it("is DISTINCT from the pull-shaped forLeg, which the settler treats differently", () => {
    expect(forLegPreFund(3, "0x1111111111111111111111111111111111111111" as `0x${string}`)).not.toBe(forLeg(3));
    expect(isPreFundDesc(forLeg(3))).toBe(false);
  });

  // Word 0 of an ordinary pull-MAKE blob is an address, so `>> 253 == 0`: the two
  // data spaces cannot collide, which is what lets one `MAKE` seam carry both.
  it("does not classify a plain pull-MAKE blob as pre-funded", () => {
    expect(isPreFundDesc(BigInt(WETH))).toBe(false);
    expect(isPreFundDesc(0n)).toBe(false);
  });

  it("rejects an out-of-range leg index", () => {
    expect(() => forLegPreFund(-1, "0x1111111111111111111111111111111111111111" as `0x${string}`)).toThrow();
    expect(() => forLegPreFund(0x10000, "0x1111111111111111111111111111111111111111" as `0x${string}`)).toThrow();
    expect(() => forLegPreFund(1.5, "0x1111111111111111111111111111111111111111" as `0x${string}`)).toThrow();
  });

  // A balance descriptor is bits 255+254 — `>> 253 == 6 or 7`, never 5.
  it("does not classify a balance descriptor as a pre-funded leg reference", () => {
    expect(isPreFundDesc(forBalance(WETH))).toBe(false);
  });
});
