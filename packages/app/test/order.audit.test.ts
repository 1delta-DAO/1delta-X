import { afterEach, describe, expect, it, vi } from "vitest";
import { formatUnits, getAddress, zeroAddress } from "viem";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { buildOrder, decimalString, inputWei, randomNonce, randomOrderNonce, toWei } from "../src/lib/order";
import { clearingPrice } from "../src/lib/ladder";
import { priceSizingAmount } from "../src/lib/ticket";
import type { Level } from "../src/lib/types";

const MAKER = getAddress("0x00000000000000000000000000000000000000aa");
const USDRIF = { address: getAddress("0x3a15461d8ae0f0fb5fa2629e9da7d66a794a6e37"), decimals: 18 };
const USD0 = { address: getAddress("0x779ded0c9e1022225f8e0630b35a9b54be713736"), decimals: 6 };
const SPACE = 1n << 255n;

const src = (p: string) => readFileSync(resolve(__dirname, "..", p), "utf8");

afterEach(() => {
  vi.restoreAllMocks();
});

/** Make the CSPRNG return all-0xff — the draw that used to set bit 255. */
function maxEntropy() {
  vi.spyOn(globalThis.crypto, "getRandomValues").mockImplementation(<T extends ArrayBufferView | null>(a: T): T => {
    new Uint8Array((a as unknown as Uint8Array).buffer).fill(0xff);
    return a;
  });
}

const sellArgs = {
  maker: MAKER,
  side: "sell" as const,
  pay: USDRIF,
  recv: USD0,
  amountIn: 100,
  targetOut: 99.5,
  minOut: 99.5,
  ttlSeconds: 3600,
  decaySeconds: 0,
  now: 1_700_000_000,
};

describe("G-TS_SIGN-3 — order nonces stay below 2^255", () => {
  it("test_audit_G_TS_SIGN_3_randomNonceNeverSetsBit255", () => {
    maxEntropy();
    expect(randomNonce() < SPACE).toBe(true);
    expect(randomOrderNonce() < SPACE).toBe(true);
  });

  it("test_audit_G_TS_SIGN_3_buildOrderDoesNotThrowOnHighDraw", () => {
    maxEntropy();
    // Before the fix this threw `order nonce … has bit 255 set` from
    // hashOrderStruct → assertOrderNonce, for about half of all tickets.
    const draft = buildOrder(sellArgs);
    expect(draft.order.nonce < SPACE).toBe(true);
  });

  it("test_audit_G_TS_SIGN_3_drawLandsAboveMinValidNonce", () => {
    maxEntropy();
    const floor = SPACE - 1000n;
    for (const minValid of [0n, 1n, 12345n, floor]) {
      const n = randomOrderNonce(minValid);
      expect(n >= minValid && n < SPACE).toBe(true);
    }
    const draft = buildOrder({ ...sellArgs, minValidNonce: floor });
    expect(draft.order.nonce >= floor).toBe(true);
  });

  it("test_audit_G_TS_SIGN_3_noFillRecordedBeforeSignature", () => {
    // A failed or declined signature must not leave a phantom fill behind:
    // the crossing part is recorded only after signDraft resolved.
    const app = src("src/App.tsx");
    const signedAt = app.indexOf("const signed = await signDraft({ ...spec, marketId, side });");
    const recordAt = app.indexOf("orderbook.recordTake(");
    expect(signedAt).toBeGreaterThan(0);
    expect(recordAt).toBeGreaterThan(signedAt);
  });
});

describe("G-TS_SIGN-6 — wei conversion is locale-independent", () => {
  it("test_audit_G_TS_SIGN_6_commaLocaleDoesNotBreakToWei", () => {
    // Simulate a de-DE / pt-BR browser: whatever locale is asked for, ICU
    // answers with the host's comma-decimal format. ("fullwide" resolved to
    // the host default, which is exactly this.)
    const original = Number.prototype.toLocaleString;
    vi.spyOn(Number.prototype, "toLocaleString").mockImplementation(function (this: number, _l?: unknown, o?: object) {
      return original.call(this, "de-DE", o as Intl.NumberFormatOptions);
    });
    expect((1.5).toLocaleString("fullwide", { useGrouping: false })).toBe("1,5");
    expect(toWei(1.5, 18)).toBe(1_500_000_000_000_000_000n);
    expect(toWei(25.123, 6)).toBe(25_123_000n);
    expect(() => buildOrder({ ...sellArgs, amountIn: 0.5, targetOut: 0.4975, minOut: 0.4975 })).not.toThrow();
  });

  it("test_audit_G_TS_SIGN_6_exponentNotationExpands", () => {
    expect(decimalString(1e21)).toBe("1000000000000000000000");
    expect(decimalString(1.5e-7)).toBe("0.00000015");
    expect(decimalString(123.456)).toBe("123.456");
    expect(toWei(1e21, 0)).toBe(10n ** 21n);
    expect(toWei(1.5e-7, 18)).toBe(150_000_000_000n);
    expect(toWei("1.123456789", 6)).toBe(1_123_456n); // truncated, never rounded up
    expect(toWei("1,5", 18)).toBe(0n); // a non-decimal string is rejected, not mis-parsed
  });

  it("test_audit_G_TS_SIGN_6_errorBoundaryWrapsApp", () => {
    const main = src("src/main.tsx");
    expect(main).toMatch(/<ErrorBoundary>\s*<App \/>\s*<\/ErrorBoundary>/);
  });
});

describe("G-TS_SIGN-7 — max never signs more than the wallet holds", () => {
  const balance = 123_456_789_012_345_678_901n;

  it("test_audit_G_TS_SIGN_7_floatRoundTripExceedsBalance", () => {
    // The precondition the fix exists for: the double rounds ABOVE the balance.
    expect(toWei(Number(formatUnits(balance, 18)), 18) > balance).toBe(true);
    // ...while the exact string does not.
    expect(toWei(formatUnits(balance, 18), 18)).toBe(balance);
  });

  it("test_audit_G_TS_SIGN_7_sellInputClampedAtBalance", () => {
    const amount = Number(formatUnits(balance, 18));
    const draft = buildOrder({ ...sellArgs, amountIn: amount, targetOut: amount, minOut: amount, maxIn: balance });
    expect(draft.order.legsIn[0]!.start <= balance).toBe(true);
    expect(draft.order.legsIn[0]!.start).toBe(balance);
  });

  it("test_audit_G_TS_SIGN_7_buyCeilingClampedAtBalance", () => {
    const quoteBal = 1_000_000_000_000_000_000_001n;
    const amount = Number(formatUnits(quoteBal, 18));
    const draft = buildOrder({
      ...sellArgs,
      side: "buy",
      pay: USDRIF,
      recv: USD0,
      amountIn: amount,
      targetOut: 10,
      minOut: 9,
      decaySeconds: 60,
      maxIn: quoteBal,
    });
    const leg = draft.order.legsIn[0]!;
    expect(leg.start <= quoteBal).toBe(true);
    expect(leg.end <= quoteBal).toBe(true);
    expect(inputWei(amount, 18, quoteBal) <= quoteBal).toBe(true);
  });

  it("test_audit_G_TS_SIGN_7_maxButtonUsesExactBalance", () => {
    const form = src("src/components/OrderForm.tsx");
    expect(form).not.toContain("ticket.setAmount(String(payBalance");
    expect(form).toContain("ticket.setAmount(maxAmount)");
  });
});

describe("G-TS_SIGN-9 — TWAP default limit is sized per slice", () => {
  // A thin sell-side ladder: one unit at 100, then the price falls fast.
  const bids: Level[] = [
    { price: 100, size: 1, source: "UNI" },
    { price: 97, size: 1, source: "UNI" },
    { price: 90, size: 10, source: "UNI" },
  ];

  it("test_audit_G_TS_SIGN_9_twapSizesToOneSlice", () => {
    expect(priceSizingAmount("twap", 12, 12)).toBe(1);
    expect(priceSizingAmount("limit", 12, 12)).toBe(12);
    // Whole notional clears at 90 — baking a 10% impact into every 1-unit slice.
    expect(clearingPrice(bids, 12, "sell")).toBe(90);
    // One slice clears at the top of the book.
    expect(clearingPrice(bids, priceSizingAmount("twap", 12, 12), "sell")).toBe(100);
  });

  it("test_audit_G_TS_SIGN_9_hookUsesSliceSizing", () => {
    const hook = src("src/hooks/useTicket.ts");
    expect(hook).toContain("priceSizingAmount(mode, amount, slices)");
    expect(hook).toContain("clearingPrice(levels, sizedTo, side)");
  });
});

describe("sanity", () => {
  it("plain sell order shape unchanged", () => {
    const draft = buildOrder({ ...sellArgs, nonce: 7n });
    expect(draft.order.legsIn[0]!.start).toBe(100n * 10n ** 18n);
    expect(draft.order.legsOut[0]!.start).toBe(99_500_000n);
    expect(draft.order.exclusiveFiller).toBe(zeroAddress);
  });
});
