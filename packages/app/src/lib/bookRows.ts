/**
 * The DISPLAYED ladder: the ~20 bps curve slices the walk prices against
 * (lib/ladder `refine`) grouped into a handful of price buckets per side.
 *
 * One row per slice was honest but long — a two-pool market drew 14–26 rows per
 * side, most of them 20 bps apart, alternating UNI / SUSHI tags (2026-10-11).
 * Buckets keep the information and drop the noise:
 *
 *   • bucket width W (bps) — the smallest "nice" step (10, 20, 25, 50, 100, 200)
 *     such that {@link BUCKETS_TARGET} buckets cover the pool depth the old
 *     slice view showed (its first {@link COVER_SLICES} slices per side), never
 *     finer than the price grid. ONE width for both sides, so the two halves of
 *     the ladder read on the same scale.
 *   • buckets are anchored at each side's touch (best pool slice) and laid out
 *     away from it: slice k joins bucket ⌊|ln(p/touch)| / ln(1 + W)⌋.
 *   • a bucket's PRICE is the size-weighted average of its slices — total QUOTE
 *     over total BASE, i.e. what consuming the whole bucket costs per unit, the
 *     same figure the walk would charge. Not the best edge (it overstates what
 *     the bucket's size trades at) and not the boundary (a number no slice traded
 *     at). Size and cumulative are plain sums, so they are preserved exactly.
 *   • sources merge: the chip is the single source, or "UNI+SUSHI" ordered by
 *     size share; the tooltip keeps the per-pool breakdown.
 *   • signed limit orders (LMT) NEVER merge: each stays its own row at its own
 *     signed price, interleaved by price — a resting order is something a filler
 *     takes whole, at that price, so it is not averaged into curve depth.
 *
 * Clicking a bucket picks its `pick` price — the WORST slice in it (the deepest
 * average), so a limit there fills through the whole row, which is what the row's
 * cumulative promises. LMT rows pick their own price.
 */
import type { Level, Source } from "./types";

/** Rows per side the ladder aims for. */
export const BUCKETS_TARGET = 8;
/** Hard cap when the ladder is stretched to keep a preview / own order visible. */
export const BUCKETS_MAX = 14;
/** Pool slices per side the buckets must cover (what the slice view used to show). */
export const COVER_SLICES = 26;
/** Bucket widths, bps. */
export const NICE_BPS = [10, 20, 25, 50, 100, 200] as const;

export interface PoolPart {
  source: Source;
  pool?: `0x${string}`;
  feeBps?: number;
  size: number;
}

/** One displayed row: a pool bucket, or one signed limit order level. */
export interface BookRow {
  kind: "bucket" | "lmt";
  /** Display price: the bucket's size-weighted average, or the LMT price. */
  price: number;
  /** BASE. */
  size: number;
  /** The dominant source (largest share). */
  source: Source;
  /** Every source in the row, largest share first. */
  sources: Source[];
  /** The price a click sets as the limit (see module doc). */
  pick: number;
  /** Best and worst slice prices in the row (equal for LMT). */
  best: number;
  worst: number;
  /** Refined slices merged into this row. */
  slices: number;
  /** Per-pool size, largest first — the tooltip's breakdown. */
  parts: PoolPart[];
  /** The connected account's own resting size (LMT rows only). */
  mine?: number;
}

/** The chip text: "UNI", "UNI+SUSHI". */
export function sourceTag(r: Pick<BookRow, "sources">): string {
  return r.sources.join("+");
}

/** Distance of `p` from `touch` in bps (log), always ≥ 0. */
function bpsFrom(touch: number, p: number): number {
  return Math.abs(Math.log(p / touch)) * 10_000;
}

/**
 * The bucket width, bps, for both sides of a ladder.
 * `gridBps` = one step of the display price grid, as bps of mid.
 */
export function bucketWidthBps(sides: ReadonlyArray<readonly Level[]>, gridBps = 0): number {
  let span = 0;
  for (const levels of sides) {
    const pool = levels.filter((l) => l.source !== "LMT" && l.price > 0);
    if (pool.length < 2) continue;
    const last = pool[Math.min(pool.length, COVER_SLICES) - 1]!;
    span = Math.max(span, bpsFrom(pool[0]!.price, last.price));
  }
  // A bucket boundary sits AT the far edge of the covered span, so `target` buckets
  // of width W cover W·target − ε: ask for a hair more than span / target.
  const need = Math.max(NICE_BPS[0], gridBps, span / BUCKETS_TARGET + 1e-9);
  return NICE_BPS.find((w) => w >= need) ?? NICE_BPS[NICE_BPS.length - 1]!;
}

function finish(kind: BookRow["kind"], members: Level[], descending: boolean): BookRow {
  let size = 0;
  let notional = 0;
  const bySource = new Map<Source, number>();
  const byPool = new Map<string, PoolPart>();
  let mine = 0;
  for (const l of members) {
    size += l.size;
    notional += l.size * l.price;
    bySource.set(l.source, (bySource.get(l.source) ?? 0) + l.size);
    const key = `${l.source}:${l.pool ?? ""}`;
    const part = byPool.get(key) ?? { source: l.source, pool: l.pool, feeBps: l.feeBps, size: 0 };
    part.size += l.size;
    byPool.set(key, part);
    mine += l.mine ?? 0;
  }
  const sources = [...bySource.entries()].sort((a, b) => b[1] - a[1]).map(([s]) => s);
  const prices = members.map((l) => l.price);
  // best-first input: first is best, last is worst
  const best = descending ? Math.max(...prices) : Math.min(...prices);
  const worst = descending ? Math.min(...prices) : Math.max(...prices);
  const price = size > 0 ? notional / size : members[0]!.price;
  return {
    kind,
    price: kind === "lmt" ? members[0]!.price : price,
    size,
    source: sources[0]!,
    sources,
    pick: kind === "lmt" ? members[0]!.price : worst,
    best,
    worst,
    slices: members.length,
    parts: [...byPool.values()].sort((a, b) => b.size - a.size),
    mine: mine > 0 ? mine : undefined,
  };
}

/**
 * Group one side's best-first levels (refined pool slices + LMT rungs) into rows,
 * best first. Every input level lands in exactly one row, so sizes are preserved.
 */
export function bucketize(levels: readonly Level[], descending: boolean, widthBps: number): BookRow[] {
  const pool = levels.filter((l) => l.source !== "LMT");
  const lmt = levels.filter((l) => l.source === "LMT");
  const rows: BookRow[] = [];

  if (pool.length) {
    const touch = pool[0]!.price;
    const step = Math.log1p(widthBps / 10_000);
    const groups = new Map<number, Level[]>();
    for (const l of pool) {
      const k = Math.floor(Math.abs(Math.log(l.price / touch)) / step + 1e-12);
      const g = groups.get(k);
      if (g) g.push(l);
      else groups.set(k, [l]);
    }
    for (const k of [...groups.keys()].sort((a, b) => a - b)) rows.push(finish("bucket", groups.get(k)!, descending));
  }
  for (const l of lmt) rows.push(finish("lmt", [l], descending));

  // Interleave by display price, best first; at a tie the signed order goes first
  // (it is a flat rung at exactly that price, the bucket only averages to it).
  rows.sort((a, b) => {
    const d = descending ? b.price - a.price : a.price - b.price;
    if (d !== 0) return d;
    return a.kind === b.kind ? 0 : a.kind === "lmt" ? -1 : 1;
  });
  return rows;
}
