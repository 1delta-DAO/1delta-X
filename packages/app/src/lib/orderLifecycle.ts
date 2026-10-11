/**
 * What an order IS, at every moment, as the UI says it — pure, so the labels on
 * the order card and in the orders table are pinned by tests rather than
 * assembled inline in JSX.
 *
 * 2026-10-11: a filled market order showed as type "Limit", status "PARTIAL"
 * with its bar at 100 %, then vanished when its 300 s life ran out — and Recent
 * fills stayed empty, because the fill row waited on the fill index and the
 * expiry dropped the order (and its pending fill) first. The rules here:
 *
 *   • type: a market ticket's order says "Market" (it is a short Dutch auction
 *     from the filler's quote), a limit "Limit", a TWAP "TWAP".
 *   • status: "filled" once filled ≥ size, "partial" only for 0 < filled < size.
 *   • an order LEAVES the open orders when it is done — filled, expired or
 *     cancelled on-chain — and always leaves a row in Recent fills saying which
 *     ({@link outcomeOf}); with a transaction link when one is known.
 */
import type { Fill, RestingOrder } from "./types";

/** Fraction of `size` treated as "all of it" (float dust from wei → human). */
const FULL = 1 - 1e-6;

export function orderTypeLabel(o: Pick<RestingOrder, "type">): "Market" | "Limit" | "TWAP" {
  return o.type === "market" ? "Market" : o.type === "twap" ? "TWAP" : "Limit";
}

/** Whether `filled` covers `size` (to float dust). */
export function isFull(filled: number, size: number): boolean {
  return size > 0 && filled >= size * FULL;
}

export type RowStatus =
  | "open"
  | "partial"
  | "filling"
  | "fill-pending"
  | "filled"
  | "expired"
  | "soft-cancelled"
  | "off-book";

/**
 * The open-orders status column. Order of precedence: what the maker did (soft
 * cancel), then what the chain did (filled), then what is in flight (a filler's
 * submitted fill), then what the book did (off book), then the clock.
 */
export function rowStatus(o: RestingOrder, now: number = Date.now()): RowStatus {
  if (o.cancelled === "soft") return "soft-cancelled";
  if (isFull(o.filled, o.size)) return "filled";
  if (o.pendingFill) return "fill-pending";
  if (o.offBook) return "off-book";
  if (o.expiresAt <= now) return "expired";
  if (o.slices && o.slices.done > 0) return "filling";
  return o.filled > 0 ? "partial" : "open";
}

export function rowStatusLabel(s: RowStatus): string {
  switch (s) {
    case "soft-cancelled":
      return "hidden · still fillable";
    case "off-book":
      return "off book · still fillable";
    case "fill-pending":
      return "fill submitted";
    default:
      return s;
  }
}

/** How a finished order ended. */
export type Outcome = "filled" | "partially-filled" | "expired" | "cancelled";

/** `Settlement.filled(hash)` == this means cancelled on-chain (OrderState.sol). */
export const CANCELLED_SENTINEL = (1n << 256n) - 1n;

/**
 * The outcome of an order that left the book, from its on-chain fill state in
 * ANCHOR wei (`Settlement.filled(hash)`).
 */
export function outcomeOf(a: { filledWei: bigint; anchor: bigint; cancelled?: boolean }): Outcome {
  if (a.filledWei === CANCELLED_SENTINEL) return "cancelled";
  if (a.anchor > 0n && a.filledWei >= a.anchor) return "filled";
  if (a.cancelled) return "cancelled";
  return a.filledWei > 0n ? "partially-filled" : "expired";
}

export function outcomeLabel(o: Outcome): string {
  return o === "partially-filled" ? "partially filled" : o;
}

/**
 * Whether an open row is done and must move to Recent fills now.
 * `pendingIndex`: the chain moved further than any fill row explains yet.
 */
export function retireReason(
  o: Pick<RestingOrder, "size" | "filled" | "expiresAt">,
  a: { now: number; cancelledOnChain?: boolean },
): Outcome | null {
  if (isFull(o.filled, o.size)) return "filled";
  if (a.cancelledOnChain) return "cancelled";
  if (o.expiresAt <= a.now) return o.filled > 0 ? "partially-filled" : "expired";
  return null;
}

/** The row an order leaves in Recent fills when it finishes with nothing (more) to show as a fill. */
export function outcomeEntry(
  o: Pick<RestingOrder, "id" | "marketId" | "side" | "type" | "size" | "filled" | "price">,
  outcome: Outcome,
  at: number,
): Fill {
  return {
    id: `${o.id}-${outcome}`,
    orderHash: o.id,
    orderType: o.type,
    marketId: o.marketId,
    side: o.side,
    size: 0,
    orderSize: o.size,
    filledPct: o.size > 0 ? Math.min(100, (o.filled / o.size) * 100) : 0,
    price: o.price,
    source: "LMT",
    filler: "—",
    tx: "",
    at,
    mine: true,
    simulated: false,
    status: outcome,
  };
}

/** The Recent-fills status cell for one entry. */
export function fillStatusLabel(f: Pick<Fill, "status" | "filledPct" | "size">): string {
  const s = f.status ?? "filled";
  if ((s === "expired" || s === "cancelled") && f.filledPct !== undefined && f.filledPct > 0) {
    return `${s} · ${f.filledPct.toFixed(0)}% filled`;
  }
  return s === "partial" ? "partial fill" : outcomeLabel(s);
}

// ---------------------------------------------------------------- the order card

/**
 * The one status line under a signed ticket:
 *   Signing… → Posted to the orderbook → Fill submitted · tx ↗ → Filled · tx ↗
 *   (or Partially filled / Expired / Cancelled / Off book).
 */
export type OrderPhase =
  | { kind: "signing" }
  | { kind: "posting" }
  | { kind: "posted"; simulated: boolean }
  | { kind: "fill-pending"; tx: string }
  | { kind: "partial"; pct: number; tx: string }
  | { kind: "filled"; tx: string }
  | { kind: "expired"; pct: number }
  | { kind: "cancelled"; pct: number }
  | { kind: "off-book"; reason: string }
  | { kind: "unknown" };

/**
 * Where the order behind `hash` stands, from the live rows and the fills list.
 * A row still open wins; a finished order is read from its Recent-fills entries.
 */
export function orderPhase(hash: string, orders: readonly RestingOrder[], fills: readonly Fill[], now: number = Date.now()): OrderPhase {
  const h = hash.toLowerCase();
  const row = orders.find((o) => o.id.toLowerCase() === h || o.signedOrders?.some((s) => s.hash.toLowerCase() === h));
  const mine = fills.filter((f) => f.orderHash?.toLowerCase() === h || f.id.toLowerCase().includes(h));
  const lastTx = mine.find((f) => f.tx)?.tx ?? "";
  if (row) {
    const s = rowStatus(row, now);
    const pct = row.size > 0 ? Math.min(100, (row.filled / row.size) * 100) : 0;
    if (s === "filled") return { kind: "filled", tx: lastTx };
    if (s === "fill-pending") return { kind: "fill-pending", tx: row.pendingFill!.txHash };
    if (s === "off-book") return { kind: "off-book", reason: row.offBook ?? "" };
    if (s === "expired") return { kind: "expired", pct };
    if (row.filled > 0) return { kind: "partial", pct, tx: lastTx };
    return { kind: "posted", simulated: row.book !== "remote" };
  }
  if (!mine.length) return { kind: "unknown" };
  // fills() is newest first: the newest entry carries the final word.
  const final = mine.find((f) => f.status === "expired" || f.status === "cancelled");
  if (final) return { kind: final.status as "expired" | "cancelled", pct: final.filledPct ?? 0 };
  if (mine.some((f) => f.status === "filled")) return { kind: "filled", tx: lastTx };
  const pct = mine.reduce((p, f) => p + (f.orderSize ? (f.size / f.orderSize) * 100 : 0), 0);
  return { kind: "partial", pct: Math.min(100, pct), tx: lastTx };
}

export interface PhaseLine {
  text: string;
  tone: "busy" | "ok" | "done" | "warn" | "dim";
  tx?: string;
}

export function phaseLine(p: OrderPhase): PhaseLine {
  switch (p.kind) {
    case "signing":
      return { text: "Signing… confirm in your wallet", tone: "busy" };
    case "posting":
      return { text: "Posting to the orderbook…", tone: "busy" };
    case "posted":
      return p.simulated
        ? { text: "Signed · in the simulated book (nothing broadcast)", tone: "dim" }
        : { text: "Posted to the orderbook · waiting for a filler", tone: "busy" };
    case "fill-pending":
      return { text: "Fill submitted", tone: "busy", tx: p.tx };
    case "partial":
      return { text: `Partially filled · ${p.pct.toFixed(0)}%`, tone: "ok", tx: p.tx || undefined };
    case "filled":
      return { text: "Filled ✓", tone: "done", tx: p.tx || undefined };
    case "expired":
      return { text: p.pct > 0 ? `Expired · ${p.pct.toFixed(0)}% filled` : "Expired · not filled", tone: "dim" };
    case "cancelled":
      return { text: p.pct > 0 ? `Cancelled · ${p.pct.toFixed(0)}% filled` : "Cancelled", tone: "dim" };
    case "off-book":
      return { text: "Off the book · still fillable until expiry", tone: "warn" };
    case "unknown":
      return { text: "Signed", tone: "dim" };
  }
}
