import type { Order } from "@1delta-x/sdk";
import type { Address } from "viem";

/**
 * What a book will accept BEFORE it spends anything to find out.
 *
 * The verification pipeline is the real gate, but it costs an `eth_call` per
 * ingest — so a public write path with no cheap pre-filter in front of it lets
 * anyone convert free requests into RPC spend. These checks are local, O(1) on
 * the order, and run first.
 *
 * They also bound what a book can grow into. An orderbook is a public mutable
 * set that strangers write to; without caps, "hold every valid order forever" is
 * a memory-exhaustion primitive that needs no bug to exploit.
 */
export interface AdmissionPolicy {
  /** Hard cap on live orders. `0` disables. */
  maxOrders: number;
  /** Cap per maker, so one account cannot own the whole book. `0` disables. */
  maxOrdersPerMaker: number;
  /** Structural bounds — each element costs hashing, storage and view gas. */
  maxLegsIn: number;
  maxLegsOut: number;
  maxItems: number;
  maxValidators: number;
  /**
   * Reject orders that expire too soon to be worth verifying. An order with two
   * seconds left costs a full lens call and is dead before a filler sees it.
   */
  minTtlSeconds: number;
  /**
   * Reject orders that outlive any useful book. A ten-year deadline is not a
   * quote, it is a squatting instruction — and it never expires its way out.
   */
  maxTtlSeconds: number;
}

export const DEFAULT_ADMISSION: AdmissionPolicy = {
  maxOrders: 25_000,
  maxOrdersPerMaker: 500,
  maxLegsIn: 8,
  maxLegsOut: 8,
  maxItems: 16,
  maxValidators: 8,
  minTtlSeconds: 15,
  maxTtlSeconds: 90 * 24 * 3600,
};

export interface AdmissionContext {
  /** Live order count. */
  size: number;
  /** Live order count for this order's maker. */
  makerCount: (maker: Address) => number;
  /** Unix seconds. */
  now: number;
  /** True when the book already holds this exact order — a re-announce, not a new one. */
  known?: boolean;
}

export interface AdmissionVerdict {
  ok: boolean;
  reason?: string;
  /** Set when the rejection is the book's own capacity rather than the order's fault. */
  capacity?: boolean;
}

/** Apply {@link AdmissionPolicy}. Cheap, local, and first in the ingest path. */
export function checkAdmission(
  order: Order,
  ctx: AdmissionContext,
  policy: AdmissionPolicy = DEFAULT_ADMISSION,
): AdmissionVerdict {
  if (order.legsIn.length === 0 && order.legsOut.length === 0) {
    return { ok: false, reason: "order has no legs" };
  }
  if (order.legsIn.length > policy.maxLegsIn) {
    return { ok: false, reason: `too many input legs (max ${policy.maxLegsIn})` };
  }
  if (order.legsOut.length > policy.maxLegsOut) {
    return { ok: false, reason: `too many output legs (max ${policy.maxLegsOut})` };
  }
  if (order.items.length > policy.maxItems) {
    return { ok: false, reason: `too many items (max ${policy.maxItems})` };
  }
  if (order.validators.length + order.invariants.length > policy.maxValidators) {
    return { ok: false, reason: `too many validators (max ${policy.maxValidators})` };
  }

  const ttl = Number(order.deadline) - ctx.now;
  if (ttl < policy.minTtlSeconds) {
    return { ok: false, reason: `expires in ${ttl}s (min ${policy.minTtlSeconds}s)` };
  }
  if (ttl > policy.maxTtlSeconds) {
    return { ok: false, reason: `expires in ${ttl}s (max ${policy.maxTtlSeconds}s)` };
  }

  // Capacity is checked last and skipped for an order already held: a re-announce
  // of something the book has must not be refused because the book is full.
  if (!ctx.known) {
    if (policy.maxOrders > 0 && ctx.size >= policy.maxOrders) {
      return { ok: false, reason: "book is at capacity", capacity: true };
    }
    if (policy.maxOrdersPerMaker > 0 && ctx.makerCount(order.maker) >= policy.maxOrdersPerMaker) {
      return { ok: false, reason: `maker is at its order limit (${policy.maxOrdersPerMaker})`, capacity: true };
    }
  }
  return { ok: true };
}
