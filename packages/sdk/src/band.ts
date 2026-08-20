/**
 * Band advice from observed CLEARING DEPTH.
 *
 * Every order signs a band — `start` (the maker's ambition) to `end` (its floor)
 * — and every fill lands somewhere inside it, at a bump in [0, 10000]. The
 * distribution of where fills actually land is the single most decision-relevant
 * statistic a maker has, and it is worth far more than the choice of auction
 * format: format moves the outcome by the routing-quality gap between the best
 * and second-best filler (a few bps), while band width moves it by the whole
 * unused tail (tens of bps).
 *
 * Nothing here does I/O. Feed it realized bumps — `realizedBump` from the
 * orderbook's fill index, or `bumpBps()` replayed over historical fills — and it
 * reports what the band is costing and where `end` could sit instead.
 */

const BPS = 10_000;

/** Observed clearing depths, in bps. Held sorted; build with {@link bumpDistribution}. */
export interface BumpDistribution {
  readonly sorted: readonly number[];
}

/** Collect realized bumps into a distribution. Non-finite and out-of-range samples
 *  are dropped — a `null` realizedBump (an unobservable module fill) is not a zero. */
export function bumpDistribution(samples: Iterable<number | null | undefined>): BumpDistribution {
  const kept: number[] = [];
  for (const s of samples) {
    if (s === null || s === undefined || !Number.isFinite(s)) continue;
    if (s < 0 || s > BPS) continue;
    kept.push(s);
  }
  kept.sort((a, b) => a - b);
  return { sorted: kept };
}

/** Nearest-rank percentile, `p` in [0, 1]. `p = 0.9` is the 90th percentile bump —
 *  a bad-but-plausible clearing depth, not a typical one. */
export function bumpPercentile(d: BumpDistribution, p: number): number {
  const n = d.sorted.length;
  if (n === 0) return NaN;
  const clamped = p <= 0 ? 0 : p >= 1 ? 1 : p;
  const rank = Math.ceil(clamped * n);
  return d.sorted[Math.min(n - 1, Math.max(0, rank - 1))]!;
}

export function bumpMean(d: BumpDistribution): number {
  const n = d.sorted.length;
  if (n === 0) return NaN;
  let sum = 0;
  for (const s of d.sorted) sum += s;
  return sum / n;
}

/** One leg's signed band. `rising` marks an INPUT leg (`start <= end`, the maker
 *  pays more as the bump grows); the default is an OUTPUT leg (`start >= end`). */
export interface Band {
  start: bigint;
  end: bigint;
  rising?: boolean;
}

/** The amount this band prices at `bumpBps`. Mirrors `DutchAuction.outTick`/`inTick`
 *  (floor division; the on-chain delivery path rounds in the maker's favour, so
 *  treat this as advisory rather than as a fill quote). */
export function amountAtBump(band: Band, bumpBps: number): bigint {
  const b = BigInt(Math.max(0, Math.min(BPS, Math.round(bumpBps))));
  if (band.rising) {
    if (band.start > band.end) throw new Error("rising band with start > end");
    return band.start + ((band.end - band.start) * b) / BigInt(BPS);
  }
  if (band.start < band.end) throw new Error("falling band with start < end");
  return band.start - ((band.start - band.end) * b) / BigInt(BPS);
}

export interface BandAdvice {
  samples: number;
  meanBumpBps: number;
  p50BumpBps: number;
  p90BumpBps: number;
  maxBumpBps: number;
  /** Coverage percentile the suggestion was built at (echoed back). */
  coverage: number;
  /** Band beyond the coverage percentile, in bps — the part you sign but never use. */
  unusedBandBps: number;
  /** The amount an average fill realizes under the CURRENT band. */
  expected: bigint;
  /** The amount at the 90th-percentile bump — the bad-but-plausible case. */
  p90Amount: bigint;
  /** `end` tightened to just cover `coverage` of observed fills. */
  suggestedEnd: bigint;
  /** Improvement in the maker's WORST case from adopting `suggestedEnd`. Never negative. */
  floorGain: bigint;
  /** Fraction of observed fills (0..1) that would have priced outside `suggestedEnd`
   *  and so might not have filled at all. The honest cost of tightening. */
  missedFraction: number;
}

export interface AdviseOptions {
  /** Share of observed fills the suggested `end` should still admit. Default 0.95. */
  coverage?: number;
}

/**
 * What this band is costing, and where `end` could sit instead.
 *
 * Returns `null` for an empty distribution — advice from no observations is worse
 * than none, because it reads as a recommendation.
 *
 * ⚠ This is descriptive, not causal. The observed depths were produced UNDER the
 * current band; tightening `end` changes what fillers will do, and the tail you
 * cut may be exactly the volatile moments the floor existed for. Treat
 * `missedFraction` as a lower bound on what tightening costs.
 */
export function adviseBand(band: Band, d: BumpDistribution, opts: AdviseOptions = {}): BandAdvice | null {
  const n = d.sorted.length;
  if (n === 0) return null;

  const coverage = opts.coverage ?? 0.95;
  const coverBump = bumpPercentile(d, coverage);
  const suggestedEnd = amountAtBump(band, coverBump);

  let sum = 0n;
  for (const s of d.sorted) sum += amountAtBump(band, s);

  // Fills strictly beyond the coverage point would have priced outside the
  // tightened band.
  let missed = 0;
  for (const s of d.sorted) if (s > coverBump) missed++;

  const floorGain = band.rising ? band.end - suggestedEnd : suggestedEnd - band.end;

  return {
    samples: n,
    meanBumpBps: bumpMean(d),
    p50BumpBps: bumpPercentile(d, 0.5),
    p90BumpBps: bumpPercentile(d, 0.9),
    maxBumpBps: d.sorted[n - 1]!,
    coverage,
    unusedBandBps: BPS - coverBump,
    expected: sum / BigInt(n),
    p90Amount: amountAtBump(band, bumpPercentile(d, 0.9)),
    suggestedEnd,
    floorGain: floorGain > 0n ? floorGain : 0n,
    missedFraction: missed / n,
  };
}

/** The advice as one sentence, for a UI or a CLI. */
export function summarizeBand(a: BandAdvice): string {
  const pct = Math.round(a.coverage * 100);
  const usedBps = BPS - a.unusedBandBps;
  if (a.unusedBandBps <= 0) {
    return `Fills have reached the floor of this band (${a.samples} observed); it is not too wide.`;
  }
  return (
    `${pct}% of ${a.samples} observed fills cleared within ${usedBps} bps of start — ` +
    `the last ${a.unusedBandBps} bps of the band never got used. Moving end there raises ` +
    `the floor by ${a.floorGain} and would have missed ${(a.missedFraction * 100).toFixed(1)}% of fills.`
  );
}
