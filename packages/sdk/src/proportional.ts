import { type Order, OrderSide } from "./types";

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

/**
 * Client-side mirror of `Proportional.sol` — the BALANCE-RELATIVE amount
 * encoding that lets a maker sign "sell 100% of whatever I hold" without
 * knowing the amount at signing time.
 *
 * The bps live in the TOP of the existing `legsIn[0].start` word, in a range no
 * real token amount can reach:
 *
 *     start = MAX_UINT256 - (BPS - bps)      for bps in 1..BPS
 *
 * so nothing about the EIP-712 typehash changes — this is a value encoding
 * inside a field that already exists. Anything at or below {SENTINEL_FLOOR}
 * (~1.15e77) is an ordinary absolute amount and is untouched by all of this.
 *
 * ⚠ The marker is only valid on `legsIn[0]` of a SELL order with no `fillTotal`
 * and no `fillModule`, and such an order is FULL-FILL ONLY — its denominator is
 * a live balance, which cannot measure progress across fills. See the contract
 * for the full rationale; {validateProportional} mirrors the on-chain checks.
 */

export const BPS = 10_000n;
const MAX_UINT256 = (1n << 256n) - 1n;

/** A `start` STRICTLY ABOVE this is a proportional marker. */
export const SENTINEL_FLOOR = MAX_UINT256 - BPS;

/** Is this leg amount a proportional marker rather than an absolute amount? */
export function isProportional(start: bigint): boolean {
  return start > SENTINEL_FLOOR;
}

/** The bps (1..{BPS}) carried by a marker. Caller must have checked {isProportional}. */
export function proportionalBps(start: bigint): bigint {
  return BPS - (MAX_UINT256 - start);
}

/** Build the marker for `bps` (1..{BPS}). Mirrors `Proportional.encode`. */
export function encodeProportional(bps: bigint): bigint {
  if (bps <= 0n || bps > BPS) throw new Error(`proportional bps out of range: ${bps}`);
  return MAX_UINT256 - (BPS - bps);
}

/**
 * Resolve a marker against a live balance, capped at `cap` (`0n` = uncapped).
 * Mirrors `Proportional.resolve`.
 */
export function resolveProportional(balance: bigint, start: bigint, cap: bigint): bigint {
  const amount = (balance * proportionalBps(start)) / BPS;
  return cap !== 0n && amount > cap ? cap : amount;
}

/**
 * Mirror of the settler's position rules. Returns `null` when the order is fine,
 * else the reason it would revert `InvalidProportionalLeg`.
 *
 * Deliberately as permissive as the contract and no more — a preflight that is
 * stricter drops fillable orders, one that is looser passes orders that revert
 * on-chain. Note an UNCAPPED marker (`end === 0n`) is accepted here because the
 * settler accepts it; it is a footgun, not an invalid order (see {orderCapWarning}).
 */
export function validateProportional(order: Order): string | null {
  for (let i = 0; i < order.legsIn.length; i++) {
    if (!isProportional(order.legsIn[i]!.start)) continue;
    if (i !== 0) return "proportional marker must be on legsIn[0]";
    if (order.side === OrderSide.BUY) return "proportional marker requires a SELL order";
    if (order.fillTotal !== 0n) return "proportional marker cannot combine with fillTotal";
    if (order.fillModule.toLowerCase() !== ZERO_ADDRESS) {
      return "proportional marker cannot combine with a fillModule";
    }
  }
  for (const leg of order.legsOut) {
    if (isProportional(leg.start)) return "proportional marker is not valid on an output leg";
  }
  return null;
}

/**
 * The one thing the contract cannot warn about. A proportional order always
 * fills fully, so every output leg pays its full signed amount regardless of
 * what the anchor resolved to — a balance that came in LARGER than quoted means
 * the maker sells more for the same money. `end` on the marker leg is the cap
 * that prevents it, and omitting it is almost always a mistake.
 */
export function orderCapWarning(order: Order): string | null {
  const leg = order.legsIn[0];
  if (!leg || !isProportional(leg.start) || leg.end !== 0n) return null;
  return "proportional legsIn[0] has no cap (end === 0n): a balance larger than quoted will be sold at the same output";
}

/**
 * Return a copy of `order` with a proportional `legsIn[0]` marker replaced by
 * its resolved absolute amount, so the rest of the SDK's pricing helpers — which
 * are pure functions of the order and know nothing about balances — work on it
 * unchanged. Orders with no marker are returned as-is.
 *
 * @param makerBalance the maker's live balance of `legsIn[0].token`.
 */
export function resolveProportionalOrder(order: Order, makerBalance: bigint): Order {
  const leg = order.legsIn[0];
  if (!leg || !isProportional(leg.start)) return order;

  const reason = validateProportional(order);
  if (reason !== null) throw new Error(`invalid proportional order: ${reason}`);

  const resolved = resolveProportional(makerBalance, leg.start, leg.end);
  // `end` was the cap, not a ramp endpoint — the resolved leg is a plain fixed leg.
  const legsIn = [{ ...leg, start: resolved, end: 0n }, ...order.legsIn.slice(1)];
  return { ...order, legsIn };
}
