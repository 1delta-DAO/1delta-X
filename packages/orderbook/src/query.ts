import { isProportional, OrderSide, proportionalBps, type Order } from "@1delta-x/sdk";
import type { Address, Hex } from "viem";

import type { BookEntry } from "./book";
import { OrderStatus } from "./verify";

/**
 * The read layer over a book.
 *
 * It lives in the library rather than in the server because every consumer of a
 * book asks the same questions — a REST backend, a Waku filler keeping its own
 * book, a market-maker's dashboard. Putting the filters behind the HTTP route
 * would mean a P2P filler re-implements them, and the two would drift.
 *
 * Everything here is pure: entries in, entries out. No RPC, no clock except the
 * one passed in.
 */

/**
 * Anchor leg amounts — what the order gives and what it wants, at `start`.
 *
 * `amountIn` is `null` for a {Proportional} SELL input: its `start` is a marker
 * (~1.15e77), not an amount, and the real figure is the maker's balance at fill
 * time, which a book cannot know without a chain read (audit 2026-09-30
 * X-ARITH-1.v5 — it used to be served raw, so such orders priced at ~0).
 */
export function anchorAmounts(order: Order): { amountIn: bigint | null; amountOut: bigint } {
  const start = order.legsIn[0]?.start ?? 0n;
  return {
    amountIn: isProportional(start) ? null : start,
    amountOut: order.legsOut[0]?.start ?? 0n,
  };
}

/**
 * Raw price of the anchor pair: output wei per input wei, or `null` when it has
 * none — a {Proportional} input (no fixed amount) or an empty input leg.
 *
 * Deliberately NOT decimal-adjusted. The book does not know token decimals and
 * has no business fetching them to sort a list; the ratio is monotone within a
 * pair, which is all an ordering needs. Comparing it ACROSS pairs is
 * meaningless, so callers that mix pairs should not sort by price. Orders with
 * no price sort LAST in either direction.
 */
export function orderPrice(order: Order): number | null {
  const { amountIn, amountOut } = anchorAmounts(order);
  if (amountIn === null || amountIn === 0n) return null;
  return Number(amountOut) / Number(amountIn);
}

export function tokensIn(order: Order): Address[] {
  return order.legsIn.map((l) => l.token);
}

export function tokensOut(order: Order): Address[] {
  return order.legsOut.map((l) => l.token);
}

export type SortKey = "created" | "deadline" | "fillable" | "price";
export type SortDirection = "asc" | "desc";

export interface OrderQuery {
  /** Orders this account signed. */
  maker?: Address;
  /**
   * Orders touching this token on EITHER side — the "everything against X"
   * view. A taker holding X wants both the orders selling X and the orders
   * buying it, and asking for that should not take two calls.
   */
  token?: Address;
  /** Orders the maker is giving this token. */
  tokenIn?: Address;
  /** Orders the maker wants this token. */
  tokenOut?: Address;
  /**
   * Both tokens, in either orientation — the market view for a pair. An order
   * qualifies when one of its input tokens and one of its output tokens are the
   * two named, whichever way round.
   */
  pair?: readonly [Address, Address];
  side?: OrderSide;
  /** Keep only orders in these on-chain states. Default: any known state. */
  status?: readonly OrderStatus[];
  /**
   * Only orders the book believes a filler could take right now: on-chain
   * Fillable, signature valid, and a non-zero live fillable amount. This is the
   * solvency filter — it is `state.ok`, which the lens computes from the maker's
   * real balance and Permit3 allowance.
   */
  fillableOnly?: boolean;
  /**
   * Also require the order's validators to pass for the book's configured
   * filler. Off by default and deliberately separate from `fillableOnly`: a
   * filler-conditional order (whitelist, attestation) fails validation for
   * everyone except its target and is still perfectly book-worthy.
   */
  validatorsPass?: boolean;
  /** Live fillable amount at or above this, in anchor units. */
  minFillable?: bigint;
  /** Unix seconds — orders that survive at least this long. */
  expiresAfter?: bigint;
  /** Unix seconds — orders first admitted at or after this. */
  addedAfter?: number;
  sort?: SortKey;
  direction?: SortDirection;
  /** Page size. Clamped by the caller; the library imposes no policy. */
  limit?: number;
  /** Opaque cursor from a previous page's `nextCursor`. */
  cursor?: string;
}

export interface QueryResult {
  items: BookEntry[];
  /** How many entries matched the filters, before paging. */
  total: number;
  /** Pass back as `cursor` for the next page; absent when the page is the last. */
  nextCursor?: string;
}

function eq(a: string | undefined, b: string | undefined): boolean {
  return !!a && !!b && a.toLowerCase() === b.toLowerCase();
}

function matches(entry: BookEntry, q: OrderQuery): boolean {
  const order = entry.announce.order;
  const ins = tokensIn(order);
  const outs = tokensOut(order);

  if (q.maker && !eq(order.maker, q.maker)) return false;
  if (q.side !== undefined && order.side !== q.side) return false;
  if (q.tokenIn && !ins.some((t) => eq(t, q.tokenIn))) return false;
  if (q.tokenOut && !outs.some((t) => eq(t, q.tokenOut))) return false;
  if (q.token && !ins.some((t) => eq(t, q.token)) && !outs.some((t) => eq(t, q.token))) return false;
  if (q.pair) {
    const [a, b] = q.pair;
    const forward = ins.some((t) => eq(t, a)) && outs.some((t) => eq(t, b));
    const reverse = ins.some((t) => eq(t, b)) && outs.some((t) => eq(t, a));
    if (!forward && !reverse) return false;
  }
  if (q.expiresAfter !== undefined && order.expiry < q.expiresAfter) return false;
  if (q.addedAfter !== undefined && entry.addedAt < q.addedAfter) return false;

  const state = entry.state;
  if (q.status && !(state && q.status.includes(state.status))) return false;
  if (q.fillableOnly && !state?.ok) return false;
  if (q.validatorsPass && !state?.validatorsPass) return false;
  if (q.minFillable !== undefined && (state?.fillableAmount ?? 0n) < q.minFillable) return false;
  return true;
}

/** The value an entry sorts on, as a number so one comparator serves all keys; `null` = none (sorts last). */
function sortValue(entry: BookEntry, key: SortKey): number | null {
  switch (key) {
    case "deadline":
      return Number(entry.announce.order.expiry);
    case "fillable":
      return Number(entry.state?.fillableAmount ?? 0n);
    case "price":
      return orderPrice(entry.announce.order);
    case "created":
    default:
      return entry.addedAt;
  }
}

// Plain text rather than base64: this library also runs in a browser and in a
// Waku node, and `Buffer` exists in neither. The cursor is a pagination token,
// not a secret, so there is nothing to obscure — and a readable one is far
// easier to reason about when a page comes back wrong.
function encodeCursor(value: number | null, hash: Hex): string {
  return `${value === null ? "none" : value}~${hash}`;
}

function decodeCursor(cursor: string): { value: number | null; hash: Hex } | undefined {
  const at = cursor.indexOf("~");
  if (at < 0) return undefined;
  const raw = cursor.slice(0, at);
  const value = raw === "none" ? null : Number(raw);
  const hash = cursor.slice(at + 1);
  return (value === null || Number.isFinite(value)) && hash.startsWith("0x") ? { value, hash: hash as Hex } : undefined;
}

/**
 * Total order on `(value, hash)`: valued rows in `direction`, then value-less rows
 * (always last, whatever the direction), ties broken by hash.
 */
function compareKeys(
  a: { value: number | null; hash: Hex },
  b: { value: number | null; hash: Hex },
  descending: boolean,
): number {
  if (a.value !== b.value) {
    if (a.value === null) return 1;
    if (b.value === null) return -1;
    return descending ? b.value - a.value : a.value - b.value;
  }
  return a.hash < b.hash ? -1 : a.hash > b.hash ? 1 : 0;
}

/**
 * Filter, sort and page a book.
 *
 * Paging is KEYSET, not offset. A book is not a table: orders are admitted and
 * evicted between requests, so an offset silently skips or repeats rows exactly
 * when the book is busiest. The cursor carries the last row's sort value and
 * hash, and the next page resumes strictly after that pair — which stays correct
 * even when the row the cursor names has since been filled and evicted.
 */
export function queryOrders(entries: readonly BookEntry[], q: OrderQuery = {}): QueryResult {
  const key: SortKey = q.sort ?? "created";
  const descending = (q.direction ?? (key === "created" ? "desc" : "asc")) === "desc";

  const matched = entries.filter((e) => matches(e, q));
  const decorated = matched.map((entry) => ({ entry, value: sortValue(entry, key) }));
  // Ties break on hash so the order is total, and therefore so is the cursor.
  decorated.sort((a, b) =>
    compareKeys({ value: a.value, hash: a.entry.orderHash }, { value: b.value, hash: b.entry.orderHash }, descending),
  );

  let start = 0;
  if (q.cursor) {
    const after = decodeCursor(q.cursor);
    if (after) {
      start = decorated.findIndex(({ entry, value }) => compareKeys({ value, hash: entry.orderHash }, after, descending) > 0);
      if (start < 0) start = decorated.length;
    }
  }

  const limit = q.limit && q.limit > 0 ? q.limit : decorated.length;
  const page = decorated.slice(start, start + limit);
  const last = page[page.length - 1];
  const more = start + page.length < decorated.length;

  return {
    items: page.map((d) => d.entry),
    total: matched.length,
    ...(more && last ? { nextCursor: encodeCursor(last.value, last.entry.orderHash) } : {}),
  };
}

/** A book entry flattened for JSON — the shape the status and list routes serve. */
export interface OrderSummary {
  orderHash: Hex;
  maker: Address;
  side: "SELL" | "BUY";
  nonce: string;
  deadline: string;
  addedAt: number;
  tokensIn: Address[];
  tokensOut: Address[];
  /** Anchor input at `start`; `null` for a {Proportional} input (see `proportionalBps`). */
  amountIn: string | null;
  amountOut: string;
  /** Share of the maker's live balance a {Proportional} input sells, in bps; `null` otherwise. */
  proportionalBps: number | null;
  /** Raw output-per-input ratio; `null` when the order has no fixed input amount. */
  price: number | null;
  status: keyof typeof OrderStatus | "Unknown";
  /**
   * What a filler can take RIGHT NOW, in anchor units: the unfilled remainder
   * capped by the maker's live balance + allowance. A CAPACITY, not progress — an
   * under-funded maker reads low here with nothing filled.
   */
  fillableAmount: string | null;
  /**
   * Anchor amount already filled ON-CHAIN, from the settlement's `filled` counter
   * when the caller supplies it (the server does from its fill index). Without it,
   * `"0"` only when the lens's fillable equals the whole anchor (nothing can have
   * filled), else `null` — it is NOT `anchor − fillableAmount`, which counted a
   * funding shortfall as fills and read ~1.15e77 on every untouched
   * {Proportional} order (audit 2026-09-30 X-ARITH-1.v5).
   */
  filledAmount: string | null;
  isSignatureValid: boolean | null;
  validatorsPass: boolean | null;
  /** Whether the book would serve this to a filler right now. */
  fillable: boolean;
}

const STATUS_NAME: Record<number, keyof typeof OrderStatus> = {
  [OrderStatus.Invalid]: "Invalid",
  [OrderStatus.Fillable]: "Fillable",
  [OrderStatus.Filled]: "Filled",
  [OrderStatus.Cancelled]: "Cancelled",
  [OrderStatus.Expired]: "Expired",
};

/**
 * @param progress the settlement's `filled(orderHash)` counter, when known. The
 *        lens's `fillableAmount` alone cannot tell fills from a funding shortfall.
 */
export function summarize(entry: BookEntry, progress?: bigint): OrderSummary {
  const order = entry.announce.order;
  const { amountIn, amountOut } = anchorAmounts(order);
  const state = entry.state;
  const in0 = order.legsIn[0]?.start ?? 0n;
  const proportional = order.side === OrderSide.SELL && order.fillTotal === 0n && isProportional(in0);
  // The fill denominator, when it is a fixed number (a Proportional anchor is not).
  const anchor =
    order.fillTotal > 0n ? order.fillTotal : order.side === OrderSide.SELL ? amountIn : amountOut;
  const CANCELLED = (1n << 256n) - 1n;
  let filled: bigint | null = null;
  if (progress !== undefined && progress !== CANCELLED) filled = progress;
  else if (state && anchor !== null && !proportional && state.fillableAmount === anchor) filled = 0n;

  return {
    orderHash: entry.orderHash,
    maker: order.maker,
    side: order.side === OrderSide.SELL ? "SELL" : "BUY",
    nonce: order.nonce.toString(),
    deadline: order.expiry.toString(),
    addedAt: entry.addedAt,
    tokensIn: tokensIn(order),
    tokensOut: tokensOut(order),
    amountIn: amountIn === null ? null : amountIn.toString(),
    amountOut: amountOut.toString(),
    proportionalBps: isProportional(in0) ? Number(proportionalBps(in0)) : null,
    price: orderPrice(order),
    status: state ? (STATUS_NAME[state.status] ?? "Unknown") : "Unknown",
    fillableAmount: state ? state.fillableAmount.toString() : null,
    filledAmount: filled === null ? null : filled.toString(),
    isSignatureValid: state ? state.isSignatureValid : null,
    validatorsPass: state ? state.validatorsPass : null,
    fillable: state?.ok ?? false,
  };
}
