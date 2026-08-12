import { describe, expect, it } from "vitest";
import { decodeAbiParameters, zeroAddress } from "viem";

import {
  anchorOf,
  FILL_ONCE_BIT,
  hashOrderStruct,
  isFillOnce,
  ItemOp,
  ocoGroup,
  ocoGroupItem,
  ocoGroupLeg,
  ocoGroupValidator,
  ocoNonceGroup,
  OrderSide,
  type Order,
} from "../src";
import { CANONICAL_ORDER } from "./canonicalOrder";

const MODULE = "0x00000000000000000000000000000000000c0c00" as const;
const GROUP = 0xb4a6e7n;

function leg(nonce: bigint, out: bigint): Order {
  return {
    ...CANONICAL_ORDER,
    nonce,
    legsOut: [{ ...CANONICAL_ORDER.legsOut[0]!, start: out, end: out - 10n }],
  };
}

describe("ocoNonceGroup — the zero-contract bracket", () => {
  it("stamps one shared nonce and the fill-once bit on every leg", () => {
    const [tp, sl] = ocoNonceGroup([leg(1n, 900n), leg(2n, 800n)], 42n);
    expect(tp!.nonce).toBe(42n);
    expect(sl!.nonce).toBe(42n);
    expect(isFillOnce(tp!)).toBe(true);
    expect(isFillOnce(sl!)).toBe(true);
    expect(FILL_ONCE_BIT).toBe(1n << 100n);
  });

  it("leaves the rest of each leg untouched — the legs still price differently", () => {
    const [tp, sl] = ocoNonceGroup([leg(1n, 900n), leg(2n, 800n)], 42n);
    expect(tp!.legsOut[0]!.start).toBe(900n);
    expect(sl!.legsOut[0]!.start).toBe(800n);
    expect(hashOrderStruct(tp!)).not.toBe(hashOrderStruct(sl!));
  });

  it("refuses a group of mixed makers — nonces are maker-scoped", () => {
    const other: Order = { ...leg(2n, 800n), maker: "0x00000000000000000000000000000000000000aa" };
    expect(() => ocoNonceGroup([leg(1n, 900n), other], 42n)).toThrow(/same maker/);
  });

  it("refuses a group of one", () => {
    expect(() => ocoNonceGroup([leg(1n, 900n)], 42n)).toThrow(/at least two/);
  });
});

describe("ocoGroup — the partial-fill bracket", () => {
  it("attaches a reading validator and a writing item to every leg", () => {
    const legs = ocoGroup([leg(1n, 900n), leg(2n, 800n)], MODULE, GROUP);
    for (const l of legs) {
      expect(l.validators.at(-1)).toEqual(ocoGroupValidator(MODULE, GROUP));
      const item = l.items.at(-1)!;
      expect(item.op).toBe(ItemOp.SETTLE);
      expect(item.module).toBe(MODULE);
      expect(item.recipient).toBe(zeroAddress);
    }
  });

  it("signs each leg's OWN nonce into its claim, so the winner stays fillable", () => {
    const legs = ocoGroup([leg(7n, 900n), leg(9n, 800n)], MODULE, GROUP);
    for (const l of legs) {
      const [groupId, nonce] = decodeAbiParameters([{ type: "uint256" }, { type: "uint256" }], l.items.at(-1)!.data);
      expect(groupId).toBe(GROUP);
      expect(nonce).toBe(l.nonce);
    }
  });

  it("sizes the claim item at the ANCHOR, so its slice never rounds to zero", () => {
    const sell: Order = { ...leg(1n, 900n), fillTotal: 0n };
    const l = ocoGroupLeg(sell, MODULE, GROUP);
    expect(l.items.at(-1)!.amount).toBe(anchorOf(l));
    expect(anchorOf(l)).toBe(l.legsIn[0]!.start);
  });

  it("reads the anchor from the right side of a BUY order", () => {
    const buy: Order = { ...leg(1n, 900n), side: OrderSide.BUY, fillTotal: 0n };
    expect(anchorOf(buy)).toBe(buy.legsOut[0]!.start);
  });

  it("prefers an explicit fillTotal over any leg", () => {
    const nft: Order = { ...leg(1n, 900n), legsIn: [], legsOut: [], fillTotal: 1n };
    expect(anchorOf(nft)).toBe(1n);
    expect(ocoGroupItem(MODULE, GROUP, 1n, anchorOf(nft)).amount).toBe(1n);
  });

  it("APPENDS rather than replaces, so a leg keeps its own trigger validators", () => {
    const withTrigger: Order = {
      ...leg(1n, 900n),
      validators: [{ target: "0x00000000000000000000000000000000000000c1", data: "0xbeef" }],
    };
    const l = ocoGroupLeg(withTrigger, MODULE, GROUP);
    expect(l.validators).toHaveLength(2);
    expect(l.validators[0]!.data).toBe("0xbeef"); // the stop-loss trigger survives
  });

  it("refuses legs that share a nonce — they would share a claim slot", () => {
    expect(() => ocoGroup([leg(1n, 900n), leg(1n, 800n)], MODULE, GROUP)).toThrow(/distinct nonces/);
  });

  it("refuses a zero anchor and an unrepresentable nonce", () => {
    expect(() => ocoGroupItem(MODULE, GROUP, 1n, 0n)).toThrow(/anchor/);
    expect(() => ocoGroupItem(MODULE, GROUP, (1n << 256n) - 1n, 100n)).toThrow(/not representable/);
  });
});
