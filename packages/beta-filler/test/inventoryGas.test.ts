import { describe, expect, it } from "vitest";

import { inventoryProfitOk, mintReplaceUsdt0, rebalanceShare } from "../src/policy";

// The inventory strategy's all-in cost gate (audit follow-up 2026-10-05): a fill must
// earn its own gas, its share of the rebalance it causes, and a minimum profit.
describe("inventory all-in gas gate", () => {
  it("passes only when the edge covers gas + rebalance share + min profit", () => {
    expect(inventoryProfitOk(1_000_000n, 600_000n, 20_000n)).toEqual({ ok: true, marginUsdt0: 380_000n });
    const v = inventoryProfitOk(1_000_000n, 990_000n, 20_000n);
    expect(v.ok).toBe(false);
    if (!v.ok) expect(v.reason).toMatch(/unprofitable after gas/);
    expect(inventoryProfitOk(-5n, 0n, 0n).ok).toBe(false); // a negative edge never passes
  });

  it("charges the rebalance pro rata, rounded up, capped at the whole", () => {
    const whole = 1_000_000n;
    const min = 1_000n * 10n ** 18n;
    expect(rebalanceShare(whole, 100n * 10n ** 18n, min)).toBe(100_000n);
    expect(rebalanceShare(whole, 1n, min)).toBe(1n); // rounds up, never 0
    expect(rebalanceShare(whole, 5_000n * 10n ** 18n, min)).toBe(whole);
    expect(rebalanceShare(whole, 1n, 0n)).toBe(whole);
  });

  it("sell side: replacing USDRIF costs $1 each plus the 0.2% MoC mint fee, rounded up to a USDT0 unit", () => {
    expect(mintReplaceUsdt0(100n * 10n ** 18n)).toBe(100_200_000n);
    expect(mintReplaceUsdt0(1n)).toBe(1n); // never 0
    expect(mintReplaceUsdt0(0n)).toBe(0n);
  });

  it("realistic Rootstock numbers: a small fill at a thin spread is skipped", () => {
    // 0.026 gwei, RBTC $85k, fill 260k gas + 10% of a 450k-gas rebalance ≈ $0.67.
    const gasWei = 26_000_000n * (260_000n + 45_000n);
    const costUsdt0 = (gasWei * 85_000n * 10n ** 18n) / 10n ** 30n;
    expect(costUsdt0).toBeGreaterThan(600_000n); // > $0.60
    // $100 fill at 0.4% edge = $0.40 → refused; $500 fill at 0.4% = $2 → taken.
    expect(inventoryProfitOk(400_000n, costUsdt0, 20_000n).ok).toBe(false);
    expect(inventoryProfitOk(2_000_000n, costUsdt0, 20_000n).ok).toBe(true);
  });
});
