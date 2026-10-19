import { describe, expect, it } from "vitest";

import { refine, topOfBook, walk } from "../src/lib/ladder";
import { BAND_BPS, composeBook, routeTokens, type HopBook } from "../src/lib/synthetic";
import type { Level } from "../src/lib/types";

/**
 * A constant-liquidity pool around `mid` (quote per base), fee-net like fetchVenue's
 * output: bids start at mid × (1 − fee), asks at mid / (1 − fee); rungs 30 bps wide.
 */
function pool(mid: number, L: number, feeBps: number, rungs = 60): { bids: Level[]; asks: Level[] } {
  const f = 1 - feeBps / 10_000;
  const step = 1.003;
  const bids: Level[] = [];
  const asks: Level[] = [];
  for (let i = 0; i < rungs; i++) {
    const bs = (mid * f) / step ** i;
    const be = (mid * f) / step ** (i + 1);
    bids.push({ price: Math.sqrt(bs * be), size: L * Math.abs(1 / Math.sqrt(be) - 1 / Math.sqrt(bs)), start: bs, end: be, source: "UNI" });
    const as = (mid / f) * step ** i;
    const ae = (mid / f) * step ** (i + 1);
    asks.push({ price: Math.sqrt(as * ae), size: L * Math.abs(1 / Math.sqrt(as) - 1 / Math.sqrt(ae)), start: as, end: ae, source: "UNI" });
  }
  return { bids, asks };
}

// WRBTC/USD0 ~83,000 (0.3 %), USDRIF/USD0 ~0.998 (0.05 %): the live shape of the route.
const wrbtcUsd0: HopBook = { base: "WRBTC", quote: "USD₮0", ...pool(83_000, 9e3, 30) };
const usdrifUsd0: HopBook = { base: "USDRIF", quote: "USD₮0", ...pool(0.998, 3e5, 5) };
const HOPS = [wrbtcUsd0, usdrifUsd0];

const seqSell = (wrbtc: number) => {
  const usd0 = walk(refine(wrbtcUsd0.bids, true), wrbtc, "sell", null).crossedOut;
  return walk(refine(usdrifUsd0.asks, false), usd0, "buy", null).crossedOut; // USD0 → USDRIF
};
const seqBuy = (usdrif: number) => {
  const usd0 = walk(refine(usdrifUsd0.bids, true), usdrif, "sell", null).crossedOut; // USDRIF → USD0
  return walk(refine(wrbtcUsd0.asks, false), usd0, "buy", null).crossedOut; // USD0 → WRBTC
};
const bps = (a: number, b: number) => Math.abs(a / b - 1) * 10_000;

describe("synthetic books: composed from the hops a route walks", () => {
  const book = composeBook(HOPS, "WRBTC", "USDRIF");

  it("the route: WRBTC → USD₮0 → USDRIF; a hop that does not connect is refused", () => {
    expect(routeTokens(HOPS, "WRBTC")).toEqual(["WRBTC", "USD₮0", "USDRIF"]);
    expect(() => routeTokens([usdrifUsd0, wrbtcUsd0], "WRBTC")).toThrow(/does not connect/);
    expect(() => composeBook(HOPS, "WRBTC", "USD₮0")).toThrow(/does not end at USD₮0/);
  });

  it("touch and mid: the product of the hops' fee-net touches (fees compound), mid ≈ 83,000 / 0.998", () => {
    const top = topOfBook(book.bids, book.asks);
    // Bid: sell WRBTC at 83,000 × 0.997, buy USDRIF at 0.998 / 0.9995.
    expect(bps(top.bid!, (83_000 * 0.997) / (0.998 / 0.9995))).toBeLessThan(1);
    // Ask: sell USDRIF at 0.998 × 0.9995, buy WRBTC at 83,000 / 0.997.
    expect(bps(top.ask!, 83_000 / 0.997 / (0.998 * 0.9995))).toBeLessThan(1);
    expect(bps(top.mid!, 83_000 / 0.998)).toBeLessThan(2);
    // The spread is the route fee: 2 × (30 + 5) bps, compounded.
    expect(Math.log(top.ask! / top.bid!) * 10_000).toBeCloseTo(-2 * Math.log(0.997 * 0.9995) * 10_000, 0);
  });

  it("rungs are ROUTE-tagged, ordered like a pool ladder and at most one band wide", () => {
    expect(book.bids.length).toBeGreaterThan(20);
    expect(book.asks.length).toBeGreaterThan(20);
    for (const side of [book.bids, book.asks]) {
      for (const l of side) {
        expect(l.source).toBe("ROUTE");
        expect(l.size).toBeGreaterThan(0);
      }
    }
    for (let i = 1; i < book.bids.length; i++) expect(book.bids[i]!.price).toBeLessThan(book.bids[i - 1]!.price);
    for (let i = 1; i < book.asks.length; i++) expect(book.asks[i]!.price).toBeGreaterThan(book.asks[i - 1]!.price);
    // Near the touch the grid is fine enough that every rung is within the band.
    for (const l of book.bids.slice(0, 10)) expect(Math.abs(Math.log(l.end! / l.start!)) * 10_000).toBeLessThanOrEqual(BAND_BPS + 1e-9);
  });

  it("walking the composed book = walking the hops in sequence, at every size (within 2 bps)", () => {
    for (const wrbtc of [0.0002, 0.001, 0.01, 0.05, 0.2]) {
      const composed = walk(refine(book.bids, true), wrbtc, "sell", null);
      expect(composed.unfilledIn).toBe(0);
      expect(bps(composed.crossedOut, seqSell(wrbtc))).toBeLessThan(2);
    }
    for (const usdrif of [15, 100, 1_000, 5_000]) {
      const composed = walk(refine(book.asks, false), usdrif, "buy", null);
      expect(composed.unfilledIn).toBe(0);
      expect(bps(composed.crossedOut, seqBuy(usdrif))).toBeLessThan(2);
    }
  });

  it("a thin hop caps the route: the composed depth stops where that hop runs out", () => {
    const thin: HopBook = { base: "USDRIF", quote: "USD₮0", ...pool(0.998, 2e3, 5, 10) };
    const capped = composeBook([wrbtcUsd0, thin], "WRBTC", "USDRIF");
    const depthUsdrif = capped.bids.reduce((n, l) => n + l.size * l.price, 0);
    const thinAsk = thin.asks.reduce((n, l) => n + l.size, 0);
    expect(depthUsdrif).toBeLessThanOrEqual(thinAsk * 1.0001);
    expect(depthUsdrif).toBeGreaterThan(thinAsk * 0.95);
  });

  it("an empty hop side gives an empty composed side (no route), never a throw", () => {
    const oneSided: HopBook = { ...usdrifUsd0, asks: [] };
    const b = composeBook([wrbtcUsd0, oneSided], "WRBTC", "USDRIF");
    expect(b.bids).toEqual([]); // selling WRBTC needs USD0 → USDRIF (the empty asks)
    expect(b.asks.length).toBeGreaterThan(0);
  });

  it("composes fast enough to run on every venue update (< 150 ms)", () => {
    const t = performance.now();
    composeBook(HOPS, "WRBTC", "USDRIF");
    expect(performance.now() - t).toBeLessThan(150);
  });
});
