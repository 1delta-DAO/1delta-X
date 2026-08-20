import { describe, expect, it } from "vitest";

import {
  adviseBand,
  amountAtBump,
  bumpDistribution,
  bumpMean,
  bumpPercentile,
  summarizeBand,
  type Band,
} from "../src/band";

/** A falling output band: 2000 → 1000, so 10000 bps of bump costs 1000 units. */
const OUT: Band = { start: 2_000n, end: 1_000n };
/** A rising input band: the maker pays 100 → 300 as the bump grows. */
const IN: Band = { start: 100n, end: 300n, rising: true };

describe("bumpDistribution", () => {
  it("sorts and keeps only in-range finite samples", () => {
    const d = bumpDistribution([500, 100, 9_000]);
    expect(d.sorted).toEqual([100, 500, 9_000]);
  });

  it("drops nulls rather than reading them as zero", () => {
    // A null realizedBump is an UNOBSERVABLE fill (a module-priced one), not a
    // fill that cleared at the maker's ambition. Counting it as 0 would make
    // every band look perfectly tight.
    const d = bumpDistribution([null, 4_000, undefined, 6_000]);
    expect(d.sorted).toEqual([4_000, 6_000]);
  });

  it("drops out-of-range samples", () => {
    expect(bumpDistribution([-1, 10_001, 10_000, 0]).sorted).toEqual([0, 10_000]);
  });
});

describe("percentiles", () => {
  const d = bumpDistribution([0, 1_000, 2_000, 3_000, 4_000, 5_000, 6_000, 7_000, 8_000, 9_000]);

  it("uses nearest-rank", () => {
    expect(bumpPercentile(d, 0.5)).toBe(4_000);
    expect(bumpPercentile(d, 0.9)).toBe(8_000);
    expect(bumpPercentile(d, 1)).toBe(9_000);
    expect(bumpPercentile(d, 0)).toBe(0);
  });

  it("means over the samples", () => {
    expect(bumpMean(d)).toBe(4_500);
  });

  it("is NaN on an empty distribution rather than 0", () => {
    expect(Number.isNaN(bumpPercentile(bumpDistribution([]), 0.5))).toBe(true);
  });
});

describe("amountAtBump", () => {
  it("interpolates a falling output band", () => {
    expect(amountAtBump(OUT, 0)).toBe(2_000n);
    expect(amountAtBump(OUT, 5_000)).toBe(1_500n);
    expect(amountAtBump(OUT, 10_000)).toBe(1_000n);
  });

  it("interpolates a rising input band", () => {
    expect(amountAtBump(IN, 0)).toBe(100n);
    expect(amountAtBump(IN, 5_000)).toBe(200n);
    expect(amountAtBump(IN, 10_000)).toBe(300n);
  });

  it("clamps outside [0, 10000]", () => {
    expect(amountAtBump(OUT, -500)).toBe(2_000n);
    expect(amountAtBump(OUT, 12_000)).toBe(1_000n);
  });

  it("rejects a band signed the wrong way round", () => {
    expect(() => amountAtBump({ start: 1n, end: 2n }, 0)).toThrow();
    expect(() => amountAtBump({ start: 2n, end: 1n, rising: true }, 0)).toThrow();
  });
});

describe("adviseBand", () => {
  it("returns null on no observations rather than inventing advice", () => {
    expect(adviseBand(OUT, bumpDistribution([]))).toBeNull();
  });

  it("reports the unused tail of a band fills never reach", () => {
    // Everything clears within 1000 bps of start; 9000 bps of floor is dead weight.
    const d = bumpDistribution(Array.from({ length: 20 }, (_, i) => i * 50));
    const a = adviseBand(OUT, d, { coverage: 1 })!;
    expect(a.maxBumpBps).toBe(950);
    expect(a.unusedBandBps).toBe(10_000 - 950);
    expect(a.suggestedEnd).toBe(amountAtBump(OUT, 950));
    expect(a.floorGain).toBe(amountAtBump(OUT, 950) - OUT.end);
    expect(a.missedFraction).toBe(0);
  });

  it("prices the honest cost of tightening — coverage below 1 misses the tail", () => {
    const d = bumpDistribution([0, 0, 0, 0, 0, 0, 0, 0, 0, 9_000]);
    const a = adviseBand(OUT, d, { coverage: 0.9 })!;
    expect(a.suggestedEnd).toBe(2_000n); // the 90th-percentile bump is still 0
    expect(a.missedFraction).toBe(0.1); // the lone 9000 fill would have been missed
  });

  it("says the band is not too wide when fills reach the floor", () => {
    const a = adviseBand(OUT, bumpDistribution([0, 5_000, 10_000]), { coverage: 1 })!;
    expect(a.unusedBandBps).toBe(0);
    expect(a.floorGain).toBe(0n);
    expect(summarizeBand(a)).toMatch(/not too wide/);
  });

  it("never reports a negative floor gain", () => {
    const a = adviseBand(OUT, bumpDistribution([10_000]), { coverage: 0.5 })!;
    expect(a.floorGain).toBe(0n);
  });

  it("computes the floor gain in the maker's favour on a RISING input band", () => {
    // On an input leg the maker PAYS more as the bump grows, so a tightened `end`
    // is a LOWER number and the gain is `end - suggestedEnd`.
    const d = bumpDistribution([0, 500, 1_000]);
    const a = adviseBand(IN, d, { coverage: 1 })!;
    expect(a.suggestedEnd).toBe(amountAtBump(IN, 1_000));
    expect(a.suggestedEnd).toBeLessThan(IN.end);
    expect(a.floorGain).toBe(IN.end - a.suggestedEnd);
  });

  it("expected sits between the best and worst observed amount", () => {
    const d = bumpDistribution([1_000, 5_000, 9_000]);
    const a = adviseBand(OUT, d)!;
    expect(a.expected).toBeLessThanOrEqual(amountAtBump(OUT, 1_000));
    expect(a.expected).toBeGreaterThanOrEqual(amountAtBump(OUT, 9_000));
    expect(a.p90Amount).toBe(amountAtBump(OUT, 9_000));
  });

  it("summarizes with the numbers a maker can act on", () => {
    const d = bumpDistribution(Array.from({ length: 100 }, (_, i) => (i < 95 ? 10 : 4_000)));
    const s = summarizeBand(adviseBand(OUT, d, { coverage: 0.95 })!);
    expect(s).toContain("95%");
    expect(s).toContain("100 observed fills");
  });
});
