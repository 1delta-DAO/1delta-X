import type { TokenRef } from "./oku";

/** Which way the maker is going, always expressed against the market's BASE. */
export type Side = "buy" | "sell";

/** Where a level's liquidity comes from. */
export type Source = "DEX" | "LMT";

export const SOURCE_VAR: Record<Source, string> = { DEX: "--dex", LMT: "--lmt" };
export const SOURCE_NAME: Record<Source, string> = { DEX: "Pool", LMT: "Limit orders" };

/**
 * One rung of the merged ladder. `size` is always denominated in the market's
 * BASE token, on both sides — that is what makes pool depth and resting orders
 * addable in the first place.
 */
export interface Level {
  price: number;
  size: number;
  source: Source;
  /** Set when part of this level is the connected account's own resting size. */
  mine?: number;
}

/** The pool side of the book, as fetched and priced. */
export interface PoolBook {
  pool: string;
  chainId: number;
  block: number;
  base: TokenRef;
  quote: TokenRef;
  /** Fee tier in hundredths of a bip. */
  fee: number;
  /** Decimal places prices are displayed to. */
  tick: number;
  /** Typical distance between adjacent rungs — the ladder's price unit. */
  step: number;
  bids: Level[];
  asks: Level[];
  mid: number;
}

export type OrderType = "market" | "limit" | "twap";

/**
 * A signed order the book is holding. `size`/`filled` are in BASE for both
 * sides so a resting order drops into the ladder without a unit conversion.
 */
export interface RestingOrder {
  id: string;
  marketId: string;
  side: Side;
  type: Exclude<OrderType, "market">;
  size: number;
  filled: number;
  price: number;
  createdAt: number;
  expiresAt: number;
  /** True when this account signed it — drives the "you" marker in the ladder. */
  mine: boolean;
  slices?: { done: number; total: number; everyMin: number };
}

export interface Fill {
  id: string;
  marketId: string;
  side: Side;
  /** BASE amount that changed hands. */
  size: number;
  price: number;
  source: Source;
  filler: string;
  tx: string;
  at: number;
  mine: boolean;
}

export function orderStatus(o: RestingOrder): "open" | "partial" | "filling" {
  if (o.slices && o.slices.done > 0) return "filling";
  return o.filled > 0 ? "partial" : "open";
}
