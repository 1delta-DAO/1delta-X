/**
 * Task 15: the pool ladder is priced at what the pool EXECUTES — net of its fee tier —
 * so a market quote and its MARKET_SLIPPAGE_BPS floor are relative to an executable
 * price, not the raw tick mid (which the pool never pays).
 */
import { describe, expect, it } from "vitest";

import { mergeLadder, quote } from "../src/lib/ladder";
import { MARKET_SLIPPAGE_BPS } from "../src/lib/plan";
import type { PoolBook, RestingOrder } from "../src/lib/types";
import { applyPoolFee, buildLadder, feeFraction, getSqrtRatioAtTick, type PoolLiquidity } from "../src/lib/univ3";

/** A symmetric 18/18 pool at tick 0 (price 1) with one liquidity range [-600, 600). */
function pool(): PoolLiquidity {
  const L = 10n ** 24n;
  return {
    block: 1,
    currentTick: 0,
    tickSpacing: 60,
    sqrtPriceX96: getSqrtRatioAtTick(0),
    decimals0: 18,
    decimals1: 18,
    ticks: [
      { index: -600, sqrtPrice: getSqrtRatioAtTick(-600), liquidityNet: L },
      { index: 600, sqrtPrice: getSqrtRatioAtTick(600), liquidityNet: -L },
    ],
  };
}

const bps = (a: number, b: number) => (a / b - 1) * 10_000;

describe("pool fee units (hundredths of a bip)", () => {
  it("3000 = 0.30 %, 500 = 0.05 %, 100 = 0.01 %", () => {
    expect(feeFraction(3000)).toBe(0.003);
    expect(feeFraction(500)).toBe(0.0005);
    expect(feeFraction(100)).toBe(0.0001);
    expect(feeFraction(0)).toBe(0);
  });

  it("refuses a value that cannot be a fee tier", () => {
    expect(() => feeFraction(-1)).toThrow();
    expect(() => feeFraction(1_000_000)).toThrow();
    expect(() => feeFraction(Number.NaN)).toThrow();
  });
});

describe("applyPoolFee", () => {
  const raw = { bids: [{ price: 100, size: 2 }], asks: [{ price: 100, size: 2 }], mid: 100 };

  it("bids priced × (1 − f), asks / (1 − f) ≈ × (1 + f); mid stays the true mid", () => {
    const l = applyPoolFee(raw, 3000);
    expect(l.bids[0]!.price).toBeCloseTo(99.7, 10);
    expect(l.asks[0]!.price).toBeCloseTo(100 / 0.997, 10);
    expect(bps(l.asks[0]!.price, 100)).toBeGreaterThan(30);
    expect(bps(l.asks[0]!.price, 100)).toBeLessThan(30.1);
    expect(l.mid).toBe(100);
  });

  it("keeps each rung's QUOTE side: a bid absorbs size / (1 − f) base gross of the fee; an ask supplies the same base", () => {
    const l = applyPoolFee(raw, 3000);
    expect(l.bids[0]!.price * l.bids[0]!.size).toBeCloseTo(200, 9);
    expect(l.asks[0]!.size).toBe(2);
  });

  it("fee 0 is the identity", () => {
    expect(applyPoolFee(raw, 0)).toBe(raw);
  });
});

describe("buildLadder with the pool's fee tier", () => {
  it("every rung moves by exactly the fee, per side; mid unchanged", () => {
    const plain = buildLadder(pool(), { baseIsToken0: true, maxRungs: 10, maxSpread: 0.2 });
    const fee = buildLadder(pool(), { baseIsToken0: true, maxRungs: 10, maxSpread: 0.2, fee: 3000 });
    expect(fee.mid).toBe(plain.mid);
    expect(fee.bids.length).toBe(plain.bids.length);
    expect(fee.bids.length).toBeGreaterThan(0);
    fee.bids.forEach((r, i) => expect(r.price / plain.bids[i]!.price).toBeCloseTo(0.997, 12));
    fee.asks.forEach((r, i) => expect(r.price * 0.997).toBeCloseTo(plain.asks[i]!.price, 12));
  });

  it("the inverted orientation (base = token1) is fee-adjusted the same way", () => {
    const plain = buildLadder(pool(), { baseIsToken0: false, maxRungs: 10, maxSpread: 0.2 });
    const fee = buildLadder(pool(), { baseIsToken0: false, maxRungs: 10, maxSpread: 0.2, fee: 500 });
    fee.bids.forEach((r, i) => expect(r.price / plain.bids[i]!.price).toBeCloseTo(0.9995, 12));
    fee.asks.forEach((r, i) => expect(r.price * 0.9995).toBeCloseTo(plain.asks[i]!.price, 12));
  });
});

describe("a market quote on a 0.3 % pool", () => {
  // One deep rung at the true mid, as the tick maths gives it, then the pool fee.
  const mid = 100_000;
  const l = applyPoolFee({ bids: [{ price: mid, size: 1e9 }], asks: [{ price: mid, size: 1e9 }], mid }, 3000);

  it("a SELL quotes ~30 bps below mid, and its floor is MARKET_SLIPPAGE_BPS below THAT", () => {
    const q = quote({ bids: l.bids, asks: l.asks, side: "sell", amountIn: 0.01, limit: null, slippageBps: MARKET_SLIPPAGE_BPS });
    expect(bps(q.avg, mid)).toBeCloseTo(-30, 6);
    expect(q.crossedOut).toBeCloseTo(0.01 * mid * 0.997, 6);
    expect(q.minReceived).toBeCloseTo(q.crossedOut * (1 - MARKET_SLIPPAGE_BPS / 10_000), 6);
  });

  it("a BUY quotes ~30 bps above mid (gets ~30 bps less base)", () => {
    const q = quote({ bids: l.bids, asks: l.asks, side: "buy", amountIn: 800, limit: null, slippageBps: MARKET_SLIPPAGE_BPS });
    expect(bps(q.avg, mid)).toBeGreaterThan(30);
    expect(bps(q.avg, mid)).toBeLessThan(30.1);
    expect(q.crossedOut).toBeCloseTo((800 / mid) * 0.997, 12);
  });
});

describe("resting LMT orders are NOT fee-adjusted", () => {
  it("mergeLadder keeps the signed price as-is next to fee-adjusted pool rungs", () => {
    const l = applyPoolFee({ bids: [{ price: 100, size: 5 }], asks: [{ price: 100, size: 5 }], mid: 100 }, 3000);
    const book = {
      bids: l.bids.map((r) => ({ ...r, source: "UNI" as const, feeBps: 3000 })),
      asks: l.asks.map((r) => ({ ...r, source: "UNI" as const, feeBps: 3000 })),
      mid: 100,
    } as unknown as PoolBook;
    const resting = [
      { id: "a", marketId: "m", side: "sell", type: "limit", size: 1, filled: 0, price: 100.1, createdAt: 0, expiresAt: 0, mine: false },
      { id: "b", marketId: "m", side: "buy", type: "limit", size: 1, filled: 0, price: 99.9, createdAt: 0, expiresAt: 0, mine: false },
    ] as RestingOrder[];
    const m = mergeLadder(book, resting);
    expect(m.asks.find((x) => x.source === "LMT")!.price).toBe(100.1);
    expect(m.bids.find((x) => x.source === "LMT")!.price).toBe(99.9);
    // …and, being inside the fee-widened pool spread, they are now the top of book.
    expect(m.asks[0]!.source).toBe("LMT");
    expect(m.bids[0]!.source).toBe("LMT");
  });
});
