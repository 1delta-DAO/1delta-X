import { describe, expect, it } from "vitest";
import { decodeFunctionData, encodeFunctionData, type Address, type Hex } from "viem";

import { SETTLEMENT_ABI, SETTLEMENT_CALLBACK_ABI } from "../src/abi";
import {
  CallbackMode,
  decodeSettlementCallback,
  encodeFillWithCallback,
  fillDelta,
  isPostInputs,
  isTypedMode,
  totalPricedIn,
  totalPricedOut,
} from "../src/callback";
import { CANONICAL_ORDER } from "./canonicalOrder";

const TARGET = "0x00000000000000000000000000000000000000cc" as Address;
const SIG = `0x${"ab".repeat(65)}` as Hex;

describe("CallbackMode", () => {
  it("encodes ordering in bit 0 and typed in bit 1", () => {
    // The settler dispatches with bit math; these values are load-bearing.
    expect(CallbackMode.PreDelivery).toBe(0);
    expect(CallbackMode.PostInputs).toBe(1);
    expect(CallbackMode.PreDeliveryTyped).toBe(2);
    expect(CallbackMode.PostInputsTyped).toBe(3);
  });

  it("classifies every mode", () => {
    expect(isTypedMode(CallbackMode.PreDelivery)).toBe(false);
    expect(isTypedMode(CallbackMode.PostInputs)).toBe(false);
    expect(isTypedMode(CallbackMode.PreDeliveryTyped)).toBe(true);
    expect(isTypedMode(CallbackMode.PostInputsTyped)).toBe(true);

    expect(isPostInputs(CallbackMode.PreDelivery)).toBe(false);
    expect(isPostInputs(CallbackMode.PostInputs)).toBe(true);
    expect(isPostInputs(CallbackMode.PreDeliveryTyped)).toBe(false);
    expect(isPostInputs(CallbackMode.PostInputsTyped)).toBe(true);
  });
});

describe("encodeFillWithCallback", () => {
  const base = {
    order: CANONICAL_ORDER,
    sig: SIG,
    fillAmount: 1_000n,
    callbackTarget: TARGET,
    callbackData: "0xdeadbeef" as Hex,
  };

  it("round-trips through the ABI", () => {
    const data = encodeFillWithCallback({ ...base, mode: CallbackMode.PostInputs });
    const { functionName, args } = decodeFunctionData({ abi: SETTLEMENT_ABI, data });
    expect(functionName).toBe("fillWithCallback");
    expect(args[3]).toBe(TARGET);
    expect(args[4]).toBe("0xdeadbeef");
    expect(args[5]).toBe(CallbackMode.PostInputs);
  });

  it("selects the takerData overload only when one is given", () => {
    const without = encodeFillWithCallback({ ...base, mode: CallbackMode.PreDelivery });
    const with_ = encodeFillWithCallback({ ...base, mode: CallbackMode.PreDelivery, takerData: "0x1234" });
    // Distinct selectors — the overloads are different functions on-chain.
    expect(without.slice(0, 10)).not.toBe(with_.slice(0, 10));
    expect((decodeFunctionData({ abi: SETTLEMENT_ABI, data: with_ }).args as readonly unknown[])[6]).toBe("0x1234");
  });

  it("carries the typed modes through as plain uint8", () => {
    const data = encodeFillWithCallback({ ...base, mode: CallbackMode.PreDeliveryTyped });
    expect((decodeFunctionData({ abi: SETTLEMENT_ABI, data }).args as readonly unknown[])[5]).toBe(2);
  });
});

describe("decodeSettlementCallback", () => {
  const ctx = {
    orderHash: `0x${"11".repeat(32)}` as Hex,
    prevFilled: 250n,
    newFilled: 1_000n,
    anchor: 4_000n,
    pricedIn: [750n] as const,
    pricedOut: [900n, 50n] as const,
    userData: "0xc0ffee" as Hex,
  };

  const encoded = encodeFunctionData({
    abi: SETTLEMENT_CALLBACK_ABI,
    functionName: "onSettlementFill",
    args: [
      ctx.orderHash,
      ctx.prevFilled,
      ctx.newFilled,
      ctx.anchor,
      ctx.pricedIn,
      ctx.pricedOut,
      ctx.userData,
    ],
  });

  it("decodes what the settler hands a typed callback", () => {
    expect(decodeSettlementCallback(encoded)).toEqual({ ...ctx, pricedIn: [750n], pricedOut: [900n, 50n] });
  });

  it("derives the delta from the counters, NOT from a requested amount", () => {
    // A fill-module order's delta is whatever the module accepted; the request is
    // not it. Subtracting `fillAmount` would mis-price such a fill.
    expect(fillDelta(decodeSettlementCallback(encoded))).toBe(750n);
  });

  it("totals every output leg — a fee leg is a leg", () => {
    expect(totalPricedOut(decodeSettlementCallback(encoded))).toBe(950n);
  });

  // The BUY / exact-output half: on such an order the outputs are the fixed basket
  // the maker signed and the INPUT is the auctioned side, so this is the number a
  // filler cannot read off the order.
  it("carries the input side the filler is paid", () => {
    expect(totalPricedIn(decodeSettlementCallback(encoded))).toBe(750n);
  });

  it("keeps the two sides indexed against their own leg arrays", () => {
    const ctx_ = decodeSettlementCallback(encoded);
    expect(ctx_.pricedIn).toHaveLength(1);
    expect(ctx_.pricedOut).toHaveLength(2);
  });
});
