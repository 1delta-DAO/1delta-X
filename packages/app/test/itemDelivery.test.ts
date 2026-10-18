/**
 * Review 2026-10-18 C-3: DIRECT (delta-verify) + items has no zero-capital fill anywhere
 * (`matchSettle` refuses delta-verify orders, `PostInputs` refuses items), so the app
 * signs PULL for EVERY item-bearing ticket — the rule it already applied to the
 * NativeUnwrapModule shape — and every item-bearing order signs ItemPolicy ORDERED,
 * never CANONICAL (forward-only = needs capital).
 */
import { DELTA_VERIFY_OUTPUTS_BIT, ItemOp, ItemPolicy, itemPolicyOf, type Item } from "@1delta-x/sdk";
import { encodeAbiParameters, getAddress, zeroAddress } from "viem";
import { describe, expect, it } from "vitest";

import { buildOrder, ticketDelivery } from "../src/lib/order";

const MAKER = getAddress("0x00000000000000000000000000000000000000aa");
const MODULE = getAddress("0xB6107a1DEa7Ae04129aBc27ce607249049f3C735");
const LENDING = getAddress("0x00000000000000000000000000000000000000d1");
const WRBTC = { address: getAddress("0x542fda317318ebf1d3deaf76e0b632741a7e677d"), decimals: 18 };
const USD0 = { address: getAddress("0x779ded0c9e1022225f8e0630b35a9b54be713736"), decimals: 6 };
const SOLVER = getAddress("0x5987A4AFE1b680DAC657506B69C56b06FFe86cD1");
const WINDOW = { filler: SOLVER, seconds: 60, overrideBps: 5 };
const base = { maker: MAKER, pay: USD0, recv: WRBTC, amountIn: 50, targetOut: 0.0006, minOut: 0.00059, ttlSeconds: 300, decaySeconds: 60, now: 1_800_000_000, side: "buy" as const };
const deposit: Item = { op: ItemOp.MAKE, module: LENDING, amount: 1n, recipient: zeroAddress, data: encodeAbiParameters([{ type: "uint256" }], [7n]) };
const direct = (timing: bigint) => ((timing >> BigInt(DELTA_VERIFY_OUTPUTS_BIT)) & 1n) === 1n;

describe("ticketDelivery (C-3)", () => {
  it("an item-bearing ticket is PULL whatever the market's default; the module shape also drops the window", () => {
    expect(ticketDelivery({ solver: SOLVER, exclusivity: WINDOW, itemBearing: true })).toEqual({ solver: zeroAddress, exclusivity: WINDOW });
    expect(ticketDelivery({ solver: SOLVER, exclusivity: WINDOW, itemBearing: true, nativeModule: true })).toEqual({ solver: zeroAddress });
  });

  it("an item-free ticket keeps the market's DIRECT solver / pull window; `pull` (an inventory quote) forces pull with no window", () => {
    expect(ticketDelivery({ solver: SOLVER, itemBearing: false })).toEqual({ solver: SOLVER });
    expect(ticketDelivery({ solver: zeroAddress, exclusivity: WINDOW, itemBearing: false })).toEqual({ solver: zeroAddress, exclusivity: WINDOW });
    expect(ticketDelivery({ solver: SOLVER, exclusivity: WINDOW, itemBearing: false, pull: true })).toEqual({ solver: zeroAddress });
  });
});

describe("buildOrder: item-bearing orders", () => {
  it("sign PULL + ORDERED (the general item, not only the native-out module)", () => {
    const d = ticketDelivery({ solver: SOLVER, itemBearing: true });
    const { order } = buildOrder({ ...base, ...d, items: [deposit] });
    expect(order.items).toEqual([deposit]);
    expect(direct(order.timing)).toBe(false);
    expect(order.exclusiveFiller).toBe(zeroAddress);
    expect(itemPolicyOf(order.timing)).toBe(ItemPolicy.ORDERED);
  });

  it("refuse DIRECT: a solver on an item-bearing order is unfillable without capital", () => {
    expect(() => buildOrder({ ...base, solver: SOLVER, items: [deposit] })).toThrow(/item-bearing order is pull delivery/);
  });

  it("no path signs CANONICAL: the native-out module shape is ORDERED, an item-free order carries no policy", () => {
    const native = buildOrder({ ...base, nativeOut: { module: MODULE } }).order;
    expect(itemPolicyOf(native.timing)).toBe(ItemPolicy.ORDERED);
    const both = buildOrder({ ...base, nativeOut: { module: MODULE }, items: [deposit] }).order;
    expect([both.items.length, itemPolicyOf(both.timing)]).toEqual([2, ItemPolicy.ORDERED]);
    expect(itemPolicyOf(buildOrder({ ...base }).order.timing)).toBe(ItemPolicy.ANY);
    expect(itemPolicyOf(buildOrder({ ...base, solver: SOLVER }).order.timing)).toBe(ItemPolicy.ANY);
  });
});
