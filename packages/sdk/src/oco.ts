import { encodeAbiParameters, type Address } from "viem";

import { ItemOp, type Item, type Order, type Validator } from "./types";

/**
 * One-cancels-other (OCO) and N-way brackets — a group of a maker's own orders
 * of which at most one may ever fill.
 *
 * Two mechanisms, and the choice between them is not a matter of taste:
 *
 * ┌───────────────────────┬──────────────────────┬─────────────────────────┐
 * │                       │ shared nonce         │ OcoGroupModule          │
 * ├───────────────────────┼──────────────────────┼─────────────────────────┤
 * │ contracts needed      │ none                 │ one, deployed per chain │
 * │ gas per fill          │ zero                 │ ~1 CALL + 1 SSTORE      │
 * │ partial fills         │ ✗ whole-fill only    │ ✓                       │
 * │ enforced by           │ the settlement's own │ a maker-signed validator│
 * │                       │ nonce gate           │ + claim item            │
 * └───────────────────────┴──────────────────────┴─────────────────────────┘
 *
 * Use {@link ocoNonceGroup} for a plain take-profit / stop-loss bracket that
 * closes a whole position. Use {@link ocoGroupLeg} when the legs must stay
 * partially fillable, or when they need independent nonces for off-chain
 * book-keeping.
 *
 * See `docs/oco.md` and `packages/modules/strategy/oco/src/OcoGroupModule.sol`.
 */

/** `Order.timing` bit 100 — fill-once (`DutchAuction.useNonceInvalidator`). */
export const FILL_ONCE_BIT = 1n << 100n;

/** Whether an order opted into fill-once. */
export function isFillOnce(order: Order): boolean {
  return (order.timing & FILL_ONCE_BIT) !== 0n;
}

/**
 * The zero-cost bracket: stamp every leg with the SAME nonce and the fill-once
 * bit, so the first full fill consumes the shared nonce and every sibling then
 * reverts `NonceCancelled` on the gate the settlement already runs.
 *
 * ⚠ Whole-fill only. Fill-once rejects a partial outright
 * (`FillOnceMustBeFull`), because a partial would burn the nonce and strand the
 * remainder. A bracket whose legs must be partially fillable needs
 * {@link ocoGroupLeg} instead.
 *
 * ⚠ The shared nonce is also a shared kill switch — `cancelOrders([nonce])`
 * retires the whole group in one transaction, which is usually what you want
 * from a bracket, and is worth knowing before you reuse the nonce for anything
 * else.
 */
export function ocoNonceGroup(legs: readonly Order[], sharedNonce: bigint): Order[] {
  if (legs.length < 2) throw new Error("ocoNonceGroup: a group needs at least two legs");
  const maker = legs[0]!.maker.toLowerCase();
  if (legs.some((l) => l.maker.toLowerCase() !== maker)) {
    throw new Error("ocoNonceGroup: every leg must have the same maker (nonces are maker-scoped)");
  }
  return legs.map((l) => ({ ...l, nonce: sharedNonce, timing: l.timing | FILL_ONCE_BIT }));
}

/** The validator half: reads whether the group is still open. */
export function ocoGroupValidator(module: Address, groupId: bigint): Validator {
  return { target: module, data: encodeAbiParameters([{ type: "uint256" }], [groupId]) };
}

/**
 * The item half: claims the group on this order's first fill.
 *
 * `anchor` MUST be the order's fill denominator — `legsIn[0].start` for SELL,
 * `legsOut[0].start` for BUY, or `fillTotal` when set. Item amounts are sliced
 * pro-rata, and a claim whose slice floors to zero would not retire the
 * siblings; signing the anchor makes the slice exactly this fill's delta, which
 * is non-zero for every admissible fill. The op is SETTLE rather than MAKE
 * precisely because SETTLE *reverts* on a zero slice instead of skipping — a
 * misconfigured bracket then fails loudly rather than quietly opening up.
 */
export function ocoGroupItem(module: Address, groupId: bigint, nonce: bigint, anchor: bigint): Item {
  if (anchor === 0n) throw new Error("ocoGroupItem: anchor must be the order's fill denominator, not 0");
  if (nonce === (1n << 256n) - 1n) throw new Error("ocoGroupItem: nonce 2^256-1 is not representable as a claim");
  return {
    op: ItemOp.SETTLE,
    module,
    amount: anchor,
    recipient: "0x0000000000000000000000000000000000000000",
    data: encodeAbiParameters([{ type: "uint256" }, { type: "uint256" }], [groupId, nonce]),
  };
}

/** The order's fill denominator — what {@link ocoGroupItem} needs as `anchor`. */
export function anchorOf(order: Order): bigint {
  if (order.fillTotal !== 0n) return order.fillTotal;
  const leg = order.side === 1 ? order.legsOut[0] : order.legsIn[0];
  if (!leg) throw new Error("anchorOf: order has no anchor leg and no fillTotal");
  return leg.start;
}

/**
 * Attach both halves of {@link OcoGroupModule} to one leg. Appends rather than
 * replaces, so a bracket leg keeps its own trigger validators (a Chainlink
 * stop-loss gate, a timestamp window) alongside the group gate — they AND
 * together, which is exactly the bracket semantic: *fire when my stop is hit AND
 * my take-profit has not already gone*.
 */
export function ocoGroupLeg(order: Order, module: Address, groupId: bigint): Order {
  return {
    ...order,
    validators: [...order.validators, ocoGroupValidator(module, groupId)],
    items: [...order.items, ocoGroupItem(module, groupId, order.nonce, anchorOf(order))],
  };
}

/** Attach the group to every leg of a bracket. Each leg keeps its own nonce. */
export function ocoGroup(legs: readonly Order[], module: Address, groupId: bigint): Order[] {
  if (legs.length < 2) throw new Error("ocoGroup: a group needs at least two legs");
  const maker = legs[0]!.maker.toLowerCase();
  if (legs.some((l) => l.maker.toLowerCase() !== maker)) {
    throw new Error("ocoGroup: every leg must have the same maker (claims are maker-scoped)");
  }
  const nonces = new Set(legs.map((l) => l.nonce));
  if (nonces.size !== legs.length) {
    // Two legs sharing a nonce would share a claim slot: the second would read
    // the first's claim as its OWN and stay fillable — silently defeating the
    // group. Shared nonces are a valid OCO mechanism, but it is the OTHER one.
    throw new Error("ocoGroup: legs must have distinct nonces (for a shared nonce use ocoNonceGroup)");
  }
  return legs.map((l) => ocoGroupLeg(l, module, groupId));
}
