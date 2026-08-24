import { numberToHex, type Hex } from "viem";
import type { Validator } from "./types";

/**
 * Encoder for `ConditionTreeValidator` — `OR` and `NOT` inside one order.
 *
 * `order.validators` is a flat AND-list, so a disjunction needs one entry whose
 * `data` is a whole expression in **disjunctive normal form**: an OR of AND-groups,
 * with per-leaf negation. With negated literals DNF is complete, so nothing is
 * lost against an arbitrary tree — and unlike a node graph with child indices,
 * cycles and dangling children are unrepresentable rather than merely rejected.
 *
 * ⚠ KEEP IN LOCKSTEP WITH
 * `packages/validators/src/ConditionTreeValidator.sol`.
 *
 *   groupCount(1) ‖ group*
 *   group := leafCount(1) ‖ leaf*
 *   leaf  := flags(1) ‖ target(20) ‖ dataLen(2) ‖ data
 *
 * See `docs/condition-trees.md`. Before reaching for this: OR across WHOLE
 * ORDERS is free — sign two orders sharing a nonce, and whichever fills first
 * cancels the other. That covers "limit or stop-loss" with no extra gas and lets
 * each branch carry its own prices.
 */

/** Invert this leaf's result. */
export const FLAG_NEGATE = 1;
/**
 * Treat a REVERTING leaf as `false` instead of aborting the fill.
 *
 * The default is deliberately strict: a leaf that reverts is an error, because
 * folding it into `false` would make `NEGATE(brokenOracle)` pass precisely when
 * the feed is broken. Set this only where fallback really is the intent — e.g.
 * "price ≥ X, or if the feed is down, fall back to the timeout" — so the choice
 * is visible in the signed order.
 */
export const FLAG_TRY = 2;

/** One leaf: another validator, optionally negated and/or revert-tolerant. */
export interface ConditionLeaf extends Validator {
  /** Bitwise OR of {@link FLAG_NEGATE} / {@link FLAG_TRY}. Default `0`. */
  flags?: number;
}

/** One AND-group. Every leaf must hold for the group to be satisfied. */
export type ConditionGroup = readonly ConditionLeaf[];

const MAX = 255;

function u(value: number, bytes: number): string {
  return numberToHex(value, { size: bytes }).slice(2);
}

/**
 * Encode `(g₁₁ AND g₁₂ …) OR (g₂₁ AND g₂₂ …) OR …` for
 * `ConditionTreeValidator`.
 *
 * Rejects the shapes the contract rejects, so a malformed expression fails here
 * rather than at fill time: an empty disjunction is vacuously false, an empty
 * conjunction vacuously **true**, and either would silently turn a broken
 * condition into an unconditional answer.
 */
export function encodeConditions(groups: readonly ConditionGroup[]): Hex {
  if (groups.length === 0) throw new Error("condition expression must have at least one group");
  if (groups.length > MAX) throw new Error(`at most ${MAX} groups, got ${groups.length}`);

  let out = u(groups.length, 1);
  for (const [gi, group] of groups.entries()) {
    if (group.length === 0) throw new Error(`group ${gi} is empty — an empty conjunction is vacuously true`);
    if (group.length > MAX) throw new Error(`at most ${MAX} leaves per group, got ${group.length}`);
    out += u(group.length, 1);
    for (const leaf of group) {
      const flags = leaf.flags ?? 0;
      if ((flags & ~(FLAG_NEGATE | FLAG_TRY)) !== 0) {
        throw new Error(`unknown condition flag bits in 0x${flags.toString(16)}`);
      }
      const target = leaf.target.slice(2);
      if (target.length !== 40) throw new Error(`not a 20-byte address: ${leaf.target}`);
      const body = leaf.data.slice(2);
      if (body.length % 2 !== 0) throw new Error(`odd-length hex in leaf data: ${leaf.data}`);
      out += u(flags, 1) + target.toLowerCase() + u(body.length / 2, 2) + body;
    }
  }
  return `0x${out}`;
}

/**
 * The `Validator` entry to drop into `order.validators` (or `order.invariants`).
 * @param tree address of the deployed `ConditionTreeValidator`.
 */
export function conditionValidator(tree: Hex, groups: readonly ConditionGroup[]): Validator {
  return { target: tree, data: encodeConditions(groups) };
}
