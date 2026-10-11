/**
 * 2026-10-11: the ladder priced a PARTIAL fill of a pool rung at the rung's
 * whole-range average. On Rootstock's sparse WRBTC/USD0 pools one rung spans
 * ~11 %, so 0.1 WRBTC walked to 78,202 while the pool's touch was 83,056 and the
 * filler quoted 82,460 — the form showed both. Rungs now carry their marginal
 * `start`/`end`, the walk prices a partial rung on the constant-liquidity curve,
 * and the book's mid is the midpoint of the marginal touch, not of two averages.
 */
import { describe, expect, it } from "vitest";

import { buyOnRung, quote, refine, sellOnRung, topOfBook, walk } from "../src/lib/ladder";
import { assembleBook, type ResolvedMarket, type VenueResult } from "../src/lib/poolbook";
import { marketById } from "../src/config/markets";
import type { Level } from "../src/lib/types";
import { buildLadder, getSqrtRatioAtTick, type PoolLiquidity } from "../src/lib/univ3";

/** 18/18 pool at tick 0 (price 1), one range [-6000, 6000) of L = 1e24 (1e6 in human units). */
function wide(): PoolLiquidity {
  const L = 10n ** 24n;
  return {
    block: 1,
    currentTick: 0,
    tickSpacing: 60,
    sqrtPriceX96: getSqrtRatioAtTick(0),
    decimals0: 18,
    decimals1: 18,
    ticks: [
      { index: -6000, sqrtPrice: getSqrtRatioAtTick(-6000), liquidityNet: L },
      { index: 6000, sqrtPrice: getSqrtRatioAtTick(6000), liquidityNet: -L },
    ],
  };
}

/** The live WRBTC/USD0 Uniswap bid rung of 2026-10-11 (fee-net): touch 83,055.9, far end 73,632.2. */
const LIVE_BID: Level = { price: Math.sqrt(83055.9 * 73632.2), size: 0.871955, source: "UNI", start: 83055.9, end: 73632.2 };

describe("rungs carry their marginal ends", () => {
  it("bid starts at spot and ends at the lower tick; the average is √(start·end)", () => {
    const l = buildLadder(wide(), { baseIsToken0: true, maxRungs: 5, maxSpread: 1 });
    const bid = l.bids[0]!;
    expect(bid.start).toBeCloseTo(1, 12);
    expect(bid.end).toBeCloseTo(1.0001 ** -6000, 9);
    expect(bid.price).toBeCloseTo(Math.sqrt(bid.start! * bid.end!), 9);
    const ask = l.asks[0]!;
    expect(ask.start).toBeCloseTo(1, 12);
    expect(ask.end).toBeCloseTo(1.0001 ** 6000, 9);
  });

  it("the pool fee moves start / end exactly like the average", () => {
    const l = buildLadder(wide(), { baseIsToken0: true, maxRungs: 5, maxSpread: 1, fee: 3000 });
    expect(l.bids[0]!.start).toBeCloseTo(0.997, 12);
    expect(l.asks[0]!.start).toBeCloseTo(1 / 0.997, 12);
  });

  it("inverted orientation (base = token1): start is still the touch", () => {
    const l = buildLadder(wide(), { baseIsToken0: false, maxRungs: 5, maxSpread: 1 });
    expect(l.bids[0]!.start).toBeCloseTo(1, 12);
    expect(l.bids[0]!.end!).toBeLessThan(1);
    expect(l.asks[0]!.end!).toBeGreaterThan(1);
  });
});

describe("a partial rung is priced on the curve", () => {
  const l = buildLadder(wide(), { baseIsToken0: true, maxRungs: 5, maxSpread: 1 });

  it("matches the v3 swap maths exactly: sell x token0 → L·(√P − √P′), 1/√P′ = 1/√P + x/L", () => {
    const q = quote({ bids: l.bids, asks: l.asks, side: "sell", amountIn: 1000, limit: null, slippageBps: 30 });
    expect(q.crossedOut).toBeCloseTo(1e6 * (1 - 1 / 1.001), 6); // 999.000999…
  });

  it("buy spending y token1 → L·(1/√P − 1/√P′), √P′ = √P + y/L", () => {
    const q = quote({ bids: l.bids, asks: l.asks, side: "buy", amountIn: 1000, limit: null, slippageBps: 30 });
    expect(q.crossedOut).toBeCloseTo(1e6 * (1 - 1 / 1.001), 6);
  });

  it("consuming the whole rung still pays exactly its average", () => {
    const r = LIVE_BID;
    expect(sellOnRung(r, r.size)).toBeCloseTo(r.size * r.price, 9);
    expect(buyOnRung({ ...r, start: r.end, end: r.start }, r.size * r.price)).toBeCloseTo(r.size, 9);
  });

  it("flat rungs (signed LMT orders) are unchanged", () => {
    const flat: Level = { price: 100, size: 2, source: "LMT" };
    expect(sellOnRung(flat, 1)).toBe(100);
    expect(buyOnRung(flat, 100)).toBe(1);
  });

  it("the regression: 0.1 WRBTC into the live 11 %-wide bid rung", () => {
    const old = walk([{ ...LIVE_BID, start: undefined, end: undefined }], 0.1, "sell", null);
    const now = quote({ bids: [LIVE_BID], asks: [], side: "sell", amountIn: 0.1, limit: null, slippageBps: 30 });
    expect(old.avg).toBeCloseTo(78202, 0); // −5.8 % under the touch
    expect(now.avg).toBeGreaterThan(82_400); // 82,469: ~0.7 % under the touch, where the filler quoted (82,460 net)
    expect(now.avg).toBeLessThan(83_055.9);
  });
});

describe("refine", () => {
  it("cuts a wide rung into pieces whose sizes sum to the rung and whose ends chain", () => {
    const pieces = refine([LIVE_BID], true);
    expect(pieces.length).toBeGreaterThan(10);
    expect(pieces.length).toBeLessThanOrEqual(32);
    expect(pieces.reduce((n, p) => n + p.size, 0)).toBeCloseTo(LIVE_BID.size, 12);
    expect(pieces[0]!.start).toBe(LIVE_BID.start);
    expect(pieces.at(-1)!.end).toBe(LIVE_BID.end);
    for (let i = 1; i < pieces.length; i++) expect(pieces[i]!.price).toBeLessThan(pieces[i - 1]!.price);
  });

  it("interleaves venues by what each slice costs: a wide rung's touch is taken before a narrow worse one", () => {
    const narrow: Level = { price: 80_000, size: 1, source: "SUSHI", start: 80_100, end: 79_900 };
    // Sorted by AVERAGE the narrow Sushi rung (80,000) came first and 0.1 sold at ~80,000.
    const q = quote({ bids: [narrow, LIVE_BID], asks: [], side: "sell", amountIn: 0.1, limit: null, slippageBps: 30 });
    expect(q.avg).toBeGreaterThan(82_400);
    expect(q.bySource.UNI).toBeCloseTo(0.1, 9);
  });

  it("leaves flat and narrow rungs alone", () => {
    const flat: Level[] = [{ price: 100, size: 1, source: "LMT" }];
    expect(refine(flat, true)).toEqual(flat);
  });
});

describe("the book's mid is the marginal touch", () => {
  it("topOfBook uses each rung's start, falling back to price for LMT", () => {
    const asks: Level[] = [{ price: 84546.6, size: 0.164, source: "UNI", start: 83556.4, end: 85548.6 }];
    const t = topOfBook([LIVE_BID], asks);
    expect(t.bid).toBe(83055.9);
    expect(t.ask).toBe(83556.4);
    expect(t.mid).toBeCloseTo(83306.15, 6); // the pool's spot (83,305.78), not 81,374 (midpoint of averages)
    expect(topOfBook([{ price: 99, size: 1, source: "LMT" }], [{ price: 101, size: 1, source: "LMT" }]).mid).toBe(100);
    expect(topOfBook([], []).mid).toBeNull();
  });

  it("assembleBook's mid is that touch midpoint", () => {
    const market = marketById("rsk-30-wrbtc-usd0");
    const asks: Level[] = [{ price: 84546.6, size: 0.164, source: "UNI", start: 83556.4, end: 85548.6 }];
    const r: VenueResult = {
      venue: { source: "UNI", dex: "uniswap-v3", pool: "0xaef6fabf3b0c9e5f9d6d5170afc703a633479bbd", feeBps: 3000, block: 1, rungs: 2 },
      bids: [LIVE_BID],
      asks,
    };
    const book = assembleBook(market, {} as ResolvedMarket, [r])!;
    expect(book.mid).toBeCloseTo(83306.15, 6);
  });
});
