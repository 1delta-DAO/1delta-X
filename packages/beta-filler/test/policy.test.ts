import { OrderSide, withDeltaVerifyOutputs, type Order } from "@1delta-x/sdk";
import { zeroAddress, type Address } from "viem";
import { describe, expect, it } from "vitest";

import { loadConfig, parseFixed, ROOTSTOCK } from "../src/config";
import { Guard } from "../src/guard";
import { Budget, capFillAmount, classify, exitOk, fillPrice, priceOk } from "../src/policy";

const ME = "0x00000000000000000000000000000000000000Aa" as Address;
const MAKER = "0x00000000000000000000000000000000000000bB" as Address;
const OTHER = "0x00000000000000000000000000000000000000cC" as Address;
const ENV = {
  PRIVATE_KEY: "0x" + "11".repeat(32),
  SETTLEMENT: "0x0000000000000000000000000000000000000001",
  PERMIT3: "0x0000000000000000000000000000000000000002",
  LENS: "0x0000000000000000000000000000000000000003",
  ORDERBOOK_URL: "http://localhost:8080/",
};
const cfg = loadConfig(ENV);
const both = { ...cfg, policy: { ...cfg.policy, buyUsdrif: true, sellUsdrif: true } };

/** Maker sells 100 USDRIF for 99.4 USDT0 — the beta's exit order. */
function exitOrder(over: Partial<Order> = {}): Order {
  return {
    maker: MAKER,
    side: OrderSide.SELL,
    nonce: 1n,
    expiry: 2_000_000_000n,
    legsIn: [{ token: ROOTSTOCK.usdrif, start: 100n * 10n ** 18n, end: 0n }],
    legsOut: [{ token: ROOTSTOCK.usdt0, start: 99_400_000n, end: 0n, recipient: zeroAddress }],
    timing: 0n,
    exclusiveFiller: zeroAddress,
    minFillAnchor: 0n,
    exclusivityOverrideBps: 0n,
    curve: [],
    gasBumpBps: 0n,
    gasPriceRef: 0n,
    priorityScale: 0n,
    items: [],
    validators: [],
    invariants: [],
    fillModule: zeroAddress,
    fillTotal: 0n,
    pricingModule: zeroAddress,
    ...over,
  };
}

describe("config", () => {
  it("defaults to dry-run and Rootstock addresses", () => {
    expect(cfg.dryRun).toBe(true);
    expect(cfg.tokens.usdrif).toBe(ROOTSTOCK.usdrif);
    expect(cfg.orderbookUrl).toBe("http://localhost:8080");
    expect(loadConfig({ ...ENV, DRY_RUN: "0" }).dryRun).toBe(false);
  });
  it("refuses a buy price at or above par", () => {
    expect(() => loadConfig({ ...ENV, MAX_BUY_PRICE: "1.0" })).toThrow(/below 1.0/);
  });
  it("parses fixed-point decimals exactly", () => {
    expect(parseFixed("0.995", 18)).toBe(995n * 10n ** 15n);
    expect(parseFixed("500", 6)).toBe(500_000_000n);
    expect(() => parseFixed("1.2345678", 6)).toThrow();
  });
});

describe("classify", () => {
  it("takes the plain exit order as a USDRIF buy", () => {
    expect(classify(exitOrder(), cfg, ME)).toEqual({ ok: true, direction: "buyUsdrif" });
  });
  it("takes the reverse pair only when the sell side is enabled", () => {
    const o = exitOrder({
      legsIn: [{ token: ROOTSTOCK.usdt0, start: 100_000_000n, end: 0n }],
      legsOut: [{ token: ROOTSTOCK.usdrif, start: 99n * 10n ** 18n, end: 0n, recipient: zeroAddress }],
    });
    expect(classify(o, cfg, ME).ok).toBe(false);
    expect(classify(o, both, ME)).toEqual({ ok: true, direction: "sellUsdrif" });
  });
  it.each([
    ["delta-verify (EOA cannot fill)", { timing: withDeltaVerifyOutputs(0n) }, /delta-verify/],
    ["another exclusive filler", { exclusiveFiller: OTHER }, /exclusive/],
    ["fee leg", { legsOut: [exitOrder().legsOut[0]!, { ...exitOrder().legsOut[0]!, recipient: OTHER }] }, /one-in/],
    ["third-party recipient", { legsOut: [{ ...exitOrder().legsOut[0]!, recipient: OTHER }] }, /third party/],
    ["pricing module", { pricingModule: OTHER }, /modules/],
    ["validator", { validators: [{ target: OTHER, data: "0x" as const }] }, /validators/],
    ["proportional leg", { legsIn: [{ token: ROOTSTOCK.usdrif, start: 2n ** 256n - 1n, end: 0n }] }, /proportional/],
    ["wrong pair", { legsOut: [{ ...exitOrder().legsOut[0]!, token: ROOTSTOCK.rif }] }, /pair/],
  ] as const)("refuses %s", (_name, over, reason) => {
    const v = classify(exitOrder(over as Partial<Order>), both, ME);
    expect(v.ok).toBe(false);
    if (!v.ok) expect(v.reason).toMatch(reason);
  });
  it("accepts an order that names us as exclusive filler", () => {
    expect(classify(exitOrder({ exclusiveFiller: ME }), cfg, ME).ok).toBe(true);
  });
  it("refuses permit-batch and sigless announces", () => {
    expect(classify(exitOrder(), cfg, ME, { hasPermitBatch: true }).ok).toBe(false);
    expect(classify(exitOrder(), cfg, ME, { sigless: true }).ok).toBe(false);
  });
});

describe("price", () => {
  it("prices USDT0 per USDRIF across 6/18 decimals", () => {
    expect(fillPrice("buyUsdrif", 99_400_000n, 100n * 10n ** 18n)).toBe(994n * 10n ** 15n);
    expect(fillPrice("sellUsdrif", 100n * 10n ** 18n, 100_500_000n)).toBe(1005n * 10n ** 15n);
  });
  it("enforces the buy cap and the sell floor", () => {
    const p = { ...cfg.policy, maxBuyPrice: parseFixed("0.995", 18), minSellPrice: parseFixed("1.003", 18) };
    expect(priceOk("buyUsdrif", 99_400_000n, 100n * 10n ** 18n, p).ok).toBe(true);
    expect(priceOk("buyUsdrif", 99_600_000n, 100n * 10n ** 18n, p).ok).toBe(false);
    expect(priceOk("sellUsdrif", 100n * 10n ** 18n, 100_200_000n, p).ok).toBe(false);
    expect(priceOk("sellUsdrif", 100n * 10n ** 18n, 100_400_000n, p).ok).toBe(true);
    expect(priceOk("buyUsdrif", 0n, 1n, p).ok).toBe(false);
  });
  it("requires the live exit to beat the payment by the configured edge", () => {
    const p = { ...cfg.policy, minExitEdgeBps: 30n };
    expect(exitOk(1_000_000n, 1_003_000n, p).ok).toBe(true);
    expect(exitOk(1_000_000n, 1_002_000n, p).ok).toBe(false);
    expect(exitOk(1_000_000n, 990_000n, p).ok).toBe(false);
  });
});

describe("sizing", () => {
  it("scales a fill down to the payment cap", () => {
    expect(capFillAmount(100n, 50n, 80n)).toBe(100n);
    const scaled = capFillAmount(100n * 10n ** 18n, 100_000_000n, 40_000_000n);
    expect(scaled).toBeLessThan(40n * 10n ** 18n);
    expect(scaled).toBeGreaterThan(39n * 10n ** 18n);
    expect(capFillAmount(100n, 50n, 0n)).toBe(0n);
  });
  it("tracks a rolling hourly budget per token", () => {
    const usdt0 = ROOTSTOCK.usdt0 as Address;
    const b = new Budget({ [usdt0.toLowerCase()]: 1_000n });
    b.spend(usdt0, 600n, 0);
    expect(b.remaining(usdt0, 1_000)).toBe(400n);
    expect(b.remaining(usdt0, 3_600_001)).toBe(1_000n);
    expect(b.remaining(ROOTSTOCK.usdrif as Address, 0)).toBe(0n);
  });
});

describe("Budget reservations (review 2026-10-05, L1)", () => {
  it("a re-send with the same ref replaces the reservation instead of stacking a second one", () => {
    const usdt0 = ROOTSTOCK.usdt0 as Address;
    const b = new Budget({ [usdt0.toLowerCase()]: 1_000n });
    b.spend(usdt0, 600n, 0, "0xhash");
    // Dropped after 15 min and re-sent with identical bytes → same hash, same ref.
    b.spend(usdt0, 600n, 900_000, "0xhash");
    expect(b.remaining(usdt0, 900_001)).toBe(400n);
    // The receipt settles the one entry to the real cost.
    b.settle("0xhash", usdt0, 100n);
    expect(b.remaining(usdt0, 900_002)).toBe(900n);
    // Distinct refs still stack.
    b.spend(usdt0, 50n, 900_003, "0xother");
    expect(b.remaining(usdt0, 900_004)).toBe(850n);
    // The replaced entry carries the later time: it expires an hour after the re-send.
    expect(b.remaining(usdt0, 3_600_001)).toBe(850n);
    expect(b.remaining(usdt0, 4_500_010)).toBe(1_000n);
  });
});

describe("backoff horizon (review 2026-10-05, L6)", () => {
  it("a 5th strike on an order with an absurd expiry blacklists to the largest Date, not past it", () => {
    const g = new Guard(loadConfig(ENV).gas);
    const key = "0xabc";
    const absurd = 10n ** 20n; // seconds — far past what `Date` can represent in ms
    let now = 1_000;
    for (let i = 0; i < 5; i++) {
      g.onRevert(key, now, absurd, "boom");
      now = g.entry(key)!.until + 1;
    }
    const until = g.entry(key)!.until;
    expect(until).toBe(8_640_000_000_000_000);
    expect(() => new Date(until).toISOString()).not.toThrow();
  });
});
