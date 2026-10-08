import type { GasRatioState } from "./gasRatio";
import type { GuardState } from "./guard";
import type { QuoteBookState } from "./quote";
import type { RebalanceState } from "./rebalance";

/**
 * Where the filler keeps its durable state: a JSON document store. The Node CLI
 * backs it with a file (`STATE_FILE`, ./fileStore.ts); the Cloudflare Worker with
 * the Durable Object's storage. Values must survive `JSON.stringify` (bigints are
 * kept as decimal strings).
 */
export interface StateStore {
  get<T = unknown>(key: string): Promise<T | undefined>;
  put(key: string, value: unknown): Promise<void>;
}

/** The key the engine keeps its whole state under. */
export const STATE_KEY = "state";

/** One rolling-budget spend (see policy.ts `Budget`). `ref` tags a reservation by tx hash. */
export interface SpendEntry {
  token: string;
  amount: string;
  at: number;
  ref?: string;
}

/** Something the engine did recently (status / admin API). */
export interface RecentEvent {
  at: number;
  type: "filled" | "reverted" | "dropped" | "sent" | "skip" | "dry-run" | "failed" | "timeout" | "rebroadcast";
  strategy?: string;
  kind?: string;
  orderHash?: string;
  tx?: string;
  reason?: string;
}

/**
 * The engine's whole durable state. Field names `spends` / `routeSpends` /
 * `guard` are those of the pre-2026-10 STATE_FILE, so an old file still loads.
 */
export interface FillerState {
  /** Inventory outflow budget (USDT0 / USDRIF). */
  spends?: SpendEntry[];
  /** Route fill counter. */
  routeSpends?: SpendEntry[];
  /** Shared gas budget, per-order backoff and the one outstanding tx. */
  guard?: GuardState;
  rebalance?: RebalanceState;
  /** Round-robin cursor over the book: the last order hash evaluated. */
  cursor?: string;
  recent?: RecentEvent[];
  /** Own-fill holds `[orderHash, until ms, book fillable at send]` (see engine.ts `Hold`). */
  ownFills?: Array<[string, number, string]>;
  /** Learned receipt/estimate gas ratios per fill shape (gasRatio.ts; ≤ 20 samples × 64 shapes). */
  gasRatios?: GasRatioState;
  /** Indicative quotes issued and the orders matched to them (quote.ts; ≤ MAX_QUOTES). */
  quotes?: QuoteBookState;
}

/** An in-memory store (tests, one-shot runs). */
export class MemoryStateStore implements StateStore {
  readonly data = new Map<string, string>();
  async get<T>(key: string): Promise<T | undefined> {
    const v = this.data.get(key);
    return v === undefined ? undefined : (JSON.parse(v) as T);
  }
  async put(key: string, value: unknown): Promise<void> {
    this.data.set(key, JSON.stringify(value));
  }
}
