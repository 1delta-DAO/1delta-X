/**
 * Receipt/estimate gas ratios, LEARNED per fill shape from the filler's own receipts
 * (2026-10-07).
 *
 * `eth_estimateGas` is the GROSS gas a tx needs before refunds (the gas limit it must
 * be sent with); the receipt charges less. e2e on a fresh solver: 362,894 → 317,478
 * (0.875), 368,300 → 322,884 (0.877), 403,523 → 341,007 (0.845) — and less again once
 * the solver's 1-wei balance floors are seeded (no zero→non-zero SSTOREs). Pricing the
 * gate and the plan's on-chain floor at the raw estimate over-charged every fill by
 * ~12–20 %, which on a $20 ticket is most of its floor.
 *
 * So the economics are priced at `estimate × r`, where r is, per shape (strategy,
 * delivery, tokenIn, tokenOut):
 *
 *   • before any receipt of that shape: the configured default
 *     (`DEFAULT_GAS_RECEIPT_RATIO`, 0.88 — the top of the fresh-solver e2e range);
 *   • after: the MAX of receipt/estimate over the last {@link WINDOW} successful
 *     receipts of that shape — conservative: one heavy fill holds r up for 20 fills;
 *   • always clamped to [{@link MIN_PPM}, {@link MAX_PPM}] = [0.6, 1.0].
 *
 * The tx gas LIMIT is NOT scaled: it stays max(priced, estimate × 1.25).
 *
 * Risk (bounded): a fill that burns more than r × estimate is under-priced by at
 * most `(receipt − r × estimate) × gasPrice` — with r ≥ 0.6 and receipt ≤ the 1.25×
 * limit, at most 0.65 × estimate × price, ≈ $0.60 at 400k gas, 24 Mwei, $95k RBTC;
 * in practice r is the max of recent receipts, so the miss is the spread between
 * fills of one shape (a few %). Only successful receipts are learned from: a revert
 * burns less and would drag r down.
 *
 * Bounded memory: {@link WINDOW} samples per shape, at most {@link MAX_SHAPES} shapes
 * (the least recently updated one is evicted). Persisted with the engine's state
 * (`FillerState.gasRatios`, the same StateStore — the Worker's DO storage).
 */
export const PPM = 1_000_000n;
/** Receipts kept per shape. */
export const WINDOW = 20;
/** Shapes kept (least recently updated evicted first). */
export const MAX_SHAPES = 64;
/** Clamp: r never goes below 0.6 … */
export const MIN_PPM = 600_000n;
/** … nor above 1.0 (a receipt above its estimate is still priced at the estimate; the limit's 1.25× covers the burn). */
export const MAX_PPM = 1_000_000n;
/** Estimates above this are not learned (a block's gas limit is far below; a bogus figure must not stick). */
export const MAX_ESTIMATE = 30_000_000;
/** The default before any receipt of a shape: 0.88. */
export const DEFAULT_RATIO_PPM = 880_000n;

/**
 * Persisted form: shape → recent ratios (ppm, oldest first), the matching
 * `eth_estimateGas` figures (`e`, same window — what an indicative quote prices a fill
 * of that shape at before any order exists, ./quote.ts) and when it last changed (ms).
 */
export type GasRatioState = Record<string, { s: number[]; e?: number[]; at: number }>;

/** What a fill sends along to be learned from once its receipt is read (PendingTx.gasMeter). */
export interface GasMeter {
  shape: string;
  /** `eth_estimateGas` of the sent calldata (decimal). */
  estimate: string;
}

/** The shape key: strategy, delivery (direct / pull / inventory), tokenIn, tokenOut — lower-case. */
export function gasShape(strategy: string, delivery: "direct" | "pull" | "inventory", tokenIn: string, tokenOut: string): string {
  return `${strategy}:${delivery}:${tokenIn.toLowerCase()}:${tokenOut.toLowerCase()}`;
}

const clamp = (v: bigint) => (v < MIN_PPM ? MIN_PPM : v > MAX_PPM ? MAX_PPM : v);

export class GasRatios {
  private readonly shapes: Map<string, { s: number[]; e: number[]; at: number }>;
  readonly defaultPpm: bigint;

  constructor(
    defaultPpm: bigint = DEFAULT_RATIO_PPM,
    state: GasRatioState = {},
    private readonly persist: () => void = () => {},
  ) {
    this.defaultPpm = clamp(defaultPpm);
    this.shapes = new Map();
    // Load defensively: the state file is ours, but a hand-edited one must not poison r.
    for (const [k, v] of Object.entries(state ?? {})) {
      const s = Array.isArray(v?.s) ? v.s.filter((x) => Number.isSafeInteger(x) && x > 0).slice(-WINDOW) : [];
      const e = Array.isArray(v?.e) ? v.e.filter((x) => Number.isSafeInteger(x) && x > 0 && x <= MAX_ESTIMATE).slice(-WINDOW) : [];
      if (s.length) this.shapes.set(k, { s, e, at: Number.isFinite(v.at) ? v.at : 0 });
    }
    this.evict();
  }

  /** r for `shape`, ppm: max of the recent receipts (clamped), else the default. */
  ratioPpm(shape: string): bigint {
    const e = this.shapes.get(shape);
    if (!e || e.s.length === 0) return this.defaultPpm;
    let m = 0;
    for (const x of e.s) if (x > m) m = x;
    return clamp(BigInt(m));
  }

  /**
   * The largest `eth_estimateGas` among the recent successful fills of `shape` —
   * conservative, like r — or `undefined` before any. An indicative quote has no order
   * to simulate, so it prices a fill at max(this, a configured default) × r.
   */
  typicalEstimate(shape: string): bigint | undefined {
    const e = this.shapes.get(shape)?.e;
    if (!e || e.length === 0) return undefined;
    let m = 0;
    for (const x of e) if (x > m) m = x;
    return BigInt(m);
  }

  /** The gas the economics are priced at: ⌈estimate × r⌉. */
  priced(shape: string, estimate: bigint): bigint {
    return (estimate * this.ratioPpm(shape) + PPM - 1n) / PPM;
  }

  /** Learn from one SUCCESSFUL receipt of `shape` (gasUsed vs the estimate recorded at send). */
  record(shape: string, estimate: bigint, gasUsed: bigint, now: number): void {
    if (estimate <= 0n || gasUsed <= 0n) return;
    // Stored raw (a ratio above 1.0 is kept as such; the clamp applies when read).
    const raw = (gasUsed * PPM + estimate - 1n) / estimate;
    const ppm = Number(raw > 10n * PPM ? 10n * PPM : raw);
    const e = this.shapes.get(shape) ?? { s: [], e: [], at: now };
    e.s.push(ppm);
    if (e.s.length > WINDOW) e.s.splice(0, e.s.length - WINDOW);
    if (estimate <= BigInt(MAX_ESTIMATE)) {
      e.e.push(Number(estimate));
      if (e.e.length > WINDOW) e.e.splice(0, e.e.length - WINDOW);
    }
    e.at = now;
    this.shapes.delete(shape); // re-insert: Map order = least recently updated first
    this.shapes.set(shape, e);
    this.evict();
    this.persist();
  }

  private evict(): void {
    if (this.shapes.size <= MAX_SHAPES) return;
    const byAge = [...this.shapes.entries()].sort((a, b) => a[1].at - b[1].at);
    for (const [k] of byAge.slice(0, this.shapes.size - MAX_SHAPES)) this.shapes.delete(k);
  }

  /** Status: every shape's r and sample count. */
  summary(): Array<{ shape: string; ratio: number; samples: number; maxEstimate?: number }> {
    return [...this.shapes.keys()].map((k) => {
      const est = this.typicalEstimate(k);
      return { shape: k, ratio: Number(this.ratioPpm(k)) / 1e6, samples: this.shapes.get(k)!.s.length, ...(est !== undefined ? { maxEstimate: Number(est) } : {}) };
    });
  }

  toJSON(): GasRatioState {
    const out: GasRatioState = {};
    for (const [k, v] of this.shapes) out[k] = { s: [...v.s], ...(v.e.length ? { e: [...v.e] } : {}), at: v.at };
    return out;
  }
}
