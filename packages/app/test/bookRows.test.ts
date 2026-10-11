import { describe, expect, it } from "vitest";

import { assemble } from "../src/components/OrderBook";
import { BUCKETS_MAX, BUCKETS_TARGET, bucketWidthBps, bucketize, sourceTag } from "../src/lib/bookRows";
import { refine } from "../src/lib/ladder";
import { markerIndex } from "../src/lib/ticketView";
import type { Level } from "../src/lib/types";

/** Two interleaved pool ladders, ~20 bps slices, plus signed limit orders. */
function side(descending: boolean, n = 60): Level[] {
  const mid = 83_000;
  const out: Level[] = [];
  for (let i = 0; i < n; i++) {
    const bps = 5 + i * 20;
    const price = descending ? mid * (1 - bps / 1e4) : mid * (1 + bps / 1e4);
    out.push({ price, size: 0.01 + (i % 3) * 0.005, source: i % 2 ? "SUSHI" : "UNI", pool: i % 2 ? "0x00000000000000000000000000000000000000b2" : "0x00000000000000000000000000000000000000a1", feeBps: 3000 });
  }
  // Signed orders: one inside the pool's touch, one deep inside a band.
  out.push({ price: descending ? mid * 0.9999 : mid * 1.0001, size: 0.2, source: "LMT", mine: 0.2 });
  out.push({ price: descending ? mid * (1 - 0.0101) : mid * (1 + 0.0101), size: 0.05, source: "LMT" });
  return out.sort((a, b) => (descending ? b.price - a.price : a.price - b.price));
}

const total = (ls: { size: number }[]) => ls.reduce((s, l) => s + l.size, 0);

describe("book buckets (lib/bookRows)", () => {
  const bids = side(true);
  const asks = side(false);
  const width = bucketWidthBps([asks, bids]);

  it("picks one nice width that brings ~26 slices down to ~8 rows", () => {
    // 26 slices × 20 bps ≈ 500 bps; / 8 rows → 62.5 → 100 bps
    expect([10, 20, 25, 50, 100, 200]).toContain(width);
    expect(width).toBe(100);
    // Never below 10 bps, never below the price grid.
    expect(bucketWidthBps([[{ price: 1, size: 1, source: "UNI" }, { price: 1.0001, size: 1, source: "UNI" }]])).toBe(10);
    expect(bucketWidthBps([[{ price: 1, size: 1, source: "UNI" }, { price: 1.0001, size: 1, source: "UNI" }]], 30)).toBe(50);
  });

  it("preserves every unit of size: rows sum to the slices, LMT rows separate", () => {
    for (const [levels, desc] of [[bids, true], [asks, false]] as const) {
      const rows = bucketize(levels, desc, width);
      expect(total(rows)).toBeCloseTo(total(levels), 12);
      // LMT rows are 1:1 with LMT levels, never merged into a pool bucket.
      const lmt = levels.filter((l) => l.source === "LMT");
      const lmtRows = rows.filter((r) => r.kind === "lmt");
      expect(lmtRows).toHaveLength(lmt.length);
      expect(lmtRows.map((r) => r.price).sort()).toEqual(lmt.map((l) => l.price).sort());
      expect(rows.filter((r) => r.kind === "bucket").every((r) => !r.sources.includes("LMT"))).toBe(true);
      // Pool buckets merge both venues, the chip names them by size share.
      expect(rows.some((r) => r.sources.length === 2 && /^(UNI\+SUSHI|SUSHI\+UNI)$/.test(sourceTag(r)))).toBe(true);
      // best-first and monotone
      for (let i = 1; i < rows.length; i++) expect(desc ? rows[i - 1]!.price >= rows[i]!.price : rows[i - 1]!.price <= rows[i]!.price).toBe(true);
    }
  });

  it("a bucket's price is the size-weighted average; a click picks its far edge", () => {
    const rows = bucketize(bids, true, width).filter((r) => r.kind === "bucket");
    const r = rows[0]!;
    const members = bids.filter((l) => l.source !== "LMT" && l.price <= r.best && l.price >= r.worst);
    expect(members).toHaveLength(r.slices);
    expect(r.price).toBeCloseTo(members.reduce((s, l) => s + l.price * l.size, 0) / total(members), 6);
    expect(r.pick).toBe(r.worst);
    expect(r.price).toBeLessThanOrEqual(r.best);
    expect(r.price).toBeGreaterThanOrEqual(r.worst);
  });

  it("the displayed side holds ~8 rows (≤ 14 when stretched), with the rest counted as hidden", () => {
    for (const [levels, desc] of [[refine(bids, true), true], [refine(asks, false), false]] as const) {
      const rows = bucketize(levels, desc, width);
      const view = assemble(rows, null, desc);
      expect(view.rows.length).toBeLessThanOrEqual(BUCKETS_MAX);
      expect(view.rows.length).toBeGreaterThanOrEqual(Math.min(BUCKETS_TARGET, rows.length));
      expect(view.rows.length + view.hidden).toBe(rows.length);
      // cumulative is the running sum, last = whole side
      expect(view.total).toBeCloseTo(total(levels), 12);
      expect(view.rows[view.rows.length - 1]!.cum).toBeCloseTo(total(rows.slice(0, view.rows.length)), 12);
    }
    // A far-out preview stretches the side, never past the cap.
    const rows = bucketize(bids, true, width);
    const far = assemble(rows, { price: rows[11]!.price - 1, size: 0.1, side: "bid", inside: false, beyond: false, exhausted: false }, true);
    expect(far.rows.some((r) => r.preview)).toBe(true);
    expect(far.rows.length).toBeLessThanOrEqual(BUCKETS_MAX);
  });

  it("a quote marker lands between the right buckets", () => {
    const rows = bucketize(bids, true, width);
    const prices = rows.map((r) => r.price);
    // A price between rows 2 and 3 slots at index 3; better than all → 0; worse than all → end.
    const between = (prices[2]! + prices[3]!) / 2;
    expect(markerIndex(prices, between, true)).toBe(3);
    expect(markerIndex(prices, prices[0]! + 1, true)).toBe(0);
    expect(markerIndex(prices, prices[prices.length - 1]! - 1, true)).toBe(prices.length);
    const askRows = bucketize(asks, false, width).map((r) => r.price);
    expect(markerIndex(askRows, (askRows[1]! + askRows[2]!) / 2, false)).toBe(2);
  });
});
