import type { TokenRef } from "./oku";

/** Which way the maker is going, always expressed against the market's BASE. */
export type Side = "buy" | "sell";

/**
 * Where a level's liquidity comes from. Each AMM venue is its own source rather
 * than a single "DEX" bucket — the whole point of aggregating two pools is being
 * able to see which one a rung is actually in.
 */
export type Source = "UNI" | "SUSHI" | "LMT";

export const SOURCES: readonly Source[] = ["UNI", "SUSHI", "LMT"];

export const SOURCE_VAR: Record<Source, string> = { UNI: "--uni", SUSHI: "--sushi", LMT: "--lmt" };
export const SOURCE_NAME: Record<Source, string> = {
  UNI: "Uniswap v3",
  SUSHI: "SushiSwap v3",
  LMT: "Limit orders",
};

/** The AMM a source refers to, if any. `LMT` is signed orders, not a venue. */
export type Dex = "uniswap-v3" | "sushiswap-v3";

export const DEX_SOURCE: Record<Dex, Source> = { "uniswap-v3": "UNI", "sushiswap-v3": "SUSHI" };

/**
 * One rung of the merged ladder. `size` is always denominated in the market's
 * BASE token, on both sides — that is what makes pool depth and resting orders
 * addable in the first place.
 */
export interface Level {
  price: number;
  size: number;
  source: Source;
  /** The pool this rung sits in. Absent for `LMT`, which has no pool. */
  pool?: `0x${string}`;
  /** Fee tier in hundredths of a bip, for the venue label. */
  feeBps?: number;
  /** Set when part of this level is the connected account's own resting size. */
  mine?: number;
}

/** One AMM pool that contributed rungs to a market's ladder. */
export interface Venue {
  source: Source;
  dex: Dex;
  pool: `0x${string}`;
  feeBps: number;
  /** Block the venue's data was read at. */
  block: number;
  /** Rungs it contributed, bid + ask. */
  rungs: number;
  /** Why it contributed nothing, when it failed. */
  error?: string;
}

/** The pool side of the book, as fetched and priced. */
export interface PoolBook {
  pool: string;
  chainId: number;
  block: number;
  base: TokenRef;
  quote: TokenRef;
  /** Pools that contributed to this ladder, including any that failed. */
  venues: Venue[];
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
  /**
   * The EIP-712 artefact behind this row. Present for orders this account
   * signed; the seeded book has none, because nobody signed those.
   */
  signed?: import("../backend/api").SignedOrder;
  /**
   * A TWAP's schedule. `signed` counts the slices the maker has actually
   * signed: a slice that is due but unsigned does not exist, so it cannot fill
   * (G-TS_SIGN-15). Slice 1 is signed with the ticket; each later one is signed
   * when it comes due.
   */
  slices?: { done: number; total: number; everyMin: number; signed: number };
  /** Every signed order behind this row — one per signed TWAP slice, else just `signed`. */
  signedOrders?: import("../backend/api").SignedOrder[];
  /** What each later TWAP slice signs, so it is the same order as slice 1 on a fresh nonce. */
  sliceSpec?: SliceSpec;
  /**
   * `soft`: retracted by a signed off-chain cancel. Books that honour it stop
   * showing it, but the signature is still valid on-chain until expiry — anyone
   * already holding it can fill it — so the row stays, labelled, until it expires
   * or is hard-cancelled on-chain (G-TS_SIGN-4).
   */
  cancelled?: "soft";
}

/** One TWAP slice's order parameters, in human units. */
export interface SliceSpec {
  amountIn: number;
  targetOut: number;
  minOut: number;
  ttlSeconds: number;
  decaySeconds: number;
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
  /**
   * True for every fill the in-browser mock produces: nothing was broadcast and
   * `tx` is not a transaction hash. The UI must never present one as settled
   * on-chain (G-TS_SIGN-15).
   */
  simulated: boolean;
}

export function orderStatus(o: RestingOrder): "open" | "partial" | "filling" | "soft-cancelled" {
  if (o.cancelled === "soft") return "soft-cancelled";
  if (o.slices && o.slices.done > 0) return "filling";
  return o.filled > 0 ? "partial" : "open";
}

/** How many of a TWAP's slices are due by `now` (slice 1 is due at creation). */
export function dueSlices(o: RestingOrder, now: number): number {
  if (!o.slices) return 0;
  const due = Math.floor((now - o.createdAt) / (o.slices.everyMin * 60_000)) + 1;
  return Math.max(0, Math.min(o.slices.total, due));
}

/** Whether a TWAP has a due slice the maker has not signed yet. */
export function needsSliceSignature(o: RestingOrder, now: number): boolean {
  return !!o.slices && !o.cancelled && o.slices.signed < dueSlices(o, now) && o.expiresAt > now;
}
