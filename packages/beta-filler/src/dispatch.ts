import type { FillOutcome } from "./filler";
import type { BookEntry } from "./intake";

/** A fill strategy: takes one book entry, reports what it did. */
export interface Strategy {
  readonly name: "inventory" | "route";
  consider(entry: BookEntry): Promise<FillOutcome>;
  /** Cheap (no RPC) pre-check: whether `consider` would get past classification. */
  accepts?(entry: BookEntry): boolean;
  /** Called once at the start of every sweep over the book (per-sweep caps). */
  beginSweep?(): void;
}

/** An outcome that means "this strategy took the order" — stop trying others. */
export function took(o: FillOutcome): boolean {
  return o.status === "filled" || o.status === "dry-run" || o.status === "pending";
}

/**
 * Try each enabled strategy in order — INVENTORY first, ROUTE second — and stop at
 * the first that takes the order.
 *
 * Why inventory first: when both can fill, the inventory fill is the cheaper
 * transaction (≈ a raw swap +30%, against ≈ 2.2× for a DEX-routed fill — see the
 * Rootstock gas measurements in the solvers README) and it earns the full spread at
 * a price we chose, with no pool slippage. The route strategy is the fallback that
 * turns everything else on the configured pools into a fill without inventory.
 * In practice the two overlap only on plain pull USDRIF/USDT0 orders: inventory
 * refuses delta-verify orders (an EOA cannot run their callback) and every other
 * pair.
 *
 * A strategy that FAILED BEFORE SENDING (threw after classification) falls through
 * as well: e.g. an inventory fill whose simulation reverts for lack of balance.
 * An outcome marked `final` does NOT: a tx was sent for the order (its receipt is
 * pending) or the order is under the shared per-order backoff (./guard.ts) — no
 * other strategy may spend gas on it this sweep.
 */
export async function dispatch(entry: BookEntry, strategies: readonly Strategy[]): Promise<FillOutcome | undefined> {
  let last: FillOutcome | undefined;
  // `rest` survives only if EVERY strategy passed on the order at its current terms
  // (see FillOutcome.rest): then the engine need not re-quote it until the book's
  // fillable for it changes — or, for a decaying order, until the earliest time a
  // strategy predicts its gate passes.
  let rest = true;
  // The earliest moment any strategy expects its verdict to flip (FillOutcome.recheckAt).
  let recheckAt: number | undefined;
  for (const s of strategies) {
    last = await s.consider(entry);
    if (!(last.status === "skipped" && last.rest)) rest = false;
    else if (last.recheckAt !== undefined) recheckAt = recheckAt === undefined ? last.recheckAt : Math.min(recheckAt, last.recheckAt);
    if (took(last) || last.final) return { ...strip(last), rest: false };
  }
  if (!last) return last;
  return { ...strip(last), rest, ...(rest && recheckAt !== undefined ? { recheckAt } : {}) };
}

function strip(o: FillOutcome): FillOutcome {
  const { recheckAt: _, ...rest } = o;
  return rest;
}
