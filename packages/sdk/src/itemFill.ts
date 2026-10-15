import type { Address } from "viem";

import { DELTA_VERIFY_OUTPUTS_BIT, ItemOp, ItemPolicy, itemPolicyOf, type Item, type Order } from "./types";

/**
 * WHICH FILL PATH an order takes on the zero-capital route solver
 * (`AggregatorFillSolver`), decided from its items alone — docs/fill-ordering-capital-plan.md
 * §2 / §4.4 (task 31).
 *
 *  • `executeFill` — item-free: `fillWithCallback(PostInputs*)`, the maker pays first.
 *  • `executeItemFill` — a one-order `matchSettle` the solver writes itself:
 *        early ITEMs → PULL → PRESEND → CALL (route) → DELIVER → late ITEMs
 *    `lateItems` bit `k` = item `k` runs after delivery. SOURCES run early (a TAKE —
 *    its proceeds credit the input legs; a SETTLE claim; a wallet-funded `forTotal`
 *    TAKE_FOR), SINKS late (a pull MAKE, a pre-funded MAKE, a leg-reference TAKE_FOR —
 *    they consume what the fill delivered).
 *  • `skip` — no zero-capital schedule exists (or the Settlement cannot run it).
 *
 * A pure function of the order and the Settlement's capabilities; zero RPC.
 */
export type ItemFillPath =
  | { path: "executeFill" }
  | {
      path: "executeItemFill";
      /** `executeItemFill`'s `lateItems`: bit `k` set = item `k` runs after DELIVER. */
      lateItems: bigint;
      /** Per item, in index order: what it is and where it runs. */
      roles: ItemRole[];
    }
  | {
      path: "skip";
      reason: string;
      /**
       * A likely CYCLE: an item that must run after delivery produces what pays for
       * the input (open/close leverage at the LTV edge). Only a flash wrapped around
       * the whole plan — or a counter-order to net against — fills it (plan §4.5).
       */
      needsFlash?: true;
    };

/** What one item does in the dependency chain and the step it is scheduled at. */
export interface ItemRole {
  kind: "take" | "settle" | "take-for-total" | "make-pull" | "make-prefund" | "take-for-leg";
  /** `early` = before PULL (a source), `late` = after DELIVER (a sink). */
  at: "early" | "late";
}

/** What the target Settlement's `matchSettle` admits — and what the filler knows about modules. */
export interface ItemFillCaps {
  /**
   * The Settlement admits DELIVERY-FUNDED items on the netted path — pre-funded MAKE,
   * leg-reference TAKE_FOR — and SETTLE (task 31: `_stepDeliver` writes the delivery
   * ledger, `_assertMatchShape` no longer refuses them). `false` on the LIVE Rootstock
   * Settlement, whose `matchSettle` admits only pull MAKE and TAKE.
   */
  nettedDeliveryFundedItems: boolean;
  /** The Settlement address: a TAKE_FOR whose `recipient` equals it lands where `0x0` does. */
  settlement?: Address;
  /**
   * A TAKE_FOR item's proceeds token (`IProceedsAsset.proceedsAsset(data)` on its
   * module), or `undefined` when unknown. Unknown proceeds routed to Settlement are
   * ASSUMED to fund an input leg — the cycle case — exactly as
   * `takeFundsInputLeg` assumes for a plain TAKE.
   */
  proceedsAsset?: (item: Item) => Address | undefined;
}

/** First 32-byte word of an item's `data` (its funding descriptor, when the op reads one). */
function firstWord(data: string): bigint | undefined {
  if (!/^0x[0-9a-fA-F]*$/.test(data) || data.length < 2 + 64) return undefined;
  return BigInt("0x" + data.slice(2, 66));
}

const ZERO = "0x0000000000000000000000000000000000000000";

/**
 * Classify `order` for the route solver. See {@link ItemFillPath}.
 *
 * Refusals, in order:
 *  • a DIRECT (delta-verify) order with items — `matchSettle` refuses delta-verify
 *    orders and `PostInputs` refuses items (the recipient-delta attribution needs it);
 *  • an op above the enum; a BALANCE-form TAKE_FOR (`forBalance`: resolved from the
 *    maker's wallet at item time — the netted path refuses it on every Settlement);
 *  • SETTLE / pre-funded MAKE / TAKE_FOR while `caps.nettedDeliveryFundedItems` is
 *    false (the live Settlement's `_assertMatchShape`);
 *  • a leg-reference TAKE_FOR whose proceeds go to Settlement in an input-leg token
 *    (or an unknown one): it must run after DELIVER yet funds the PULL — a cycle,
 *    `needsFlash`;
 *  • a maker {@link ItemPolicy} the fixed schedule violates (task-31 core semantics):
 *    `CANONICAL` always (forward-only: items after delivery, pull after everything);
 *    under `ORDERED` / `ATOMIC` the PULL waits for every non-MAKE item, so a
 *    leg-reference TAKE_FOR (it consumes the delivery) is a cycle (`needsFlash`), and so
 *    is a non-MAKE item signed after a MAKE (a borrow-to-wallet behind a deposit);
 *    `ATOMIC` additionally needs every item on one side of the route.
 */
export function classifyItemFill(order: Order, caps: ItemFillCaps): ItemFillPath {
  if (order.items.length === 0) return { path: "executeFill" };
  if (((order.timing >> DELTA_VERIFY_OUTPUTS_BIT) & 1n) === 1n) {
    return { path: "skip", reason: "DIRECT (delta-verify) order with items: matchSettle refuses delta-verify orders and PostInputs refuses items" };
  }
  if (order.items.length > 255) return { path: "skip", reason: "more than 255 items" };
  const ins = new Set(order.legsIn.map((l) => l.token.toLowerCase()));
  const settlement = caps.settlement?.toLowerCase();
  const needsCaps = (what: string): ItemFillPath => ({
    path: "skip",
    reason: `${what}: this Settlement's matchSettle refuses it (needs the task-31 Settlement — nettedDeliveryFundedItems)`,
  });
  const roles: ItemRole[] = [];
  let lateItems = 0n;
  for (let k = 0; k < order.items.length; k++) {
    const it = order.items[k]!;
    const w = firstWord(it.data);
    let role: ItemRole;
    switch (it.op) {
      case ItemOp.TAKE:
        // Always early: a late TAKE whose proceeds are an input-leg token would make
        // the PULL draw the whole leg and the TAKE credit it again (allowance spent twice).
        role = { kind: "take", at: "early" };
        break;
      case ItemOp.SETTLE:
        if (!caps.nettedDeliveryFundedItems) return needsCaps(`item ${k}: SETTLE`);
        // The maker's asset goes to the filler — a source; the core reads no leg reference on it.
        role = { kind: "settle", at: "early" };
        break;
      case ItemOp.MAKE: {
        const preFund = w !== undefined && w >> 253n === 5n; // `isPreFundDesc`
        if (preFund && !caps.nettedDeliveryFundedItems) return needsCaps(`item ${k}: pre-funded MAKE`);
        role = { kind: preFund ? "make-prefund" : "make-pull", at: "late" };
        break;
      }
      case ItemOp.TAKE_FOR: {
        if (w === undefined) return { path: "skip", reason: `item ${k}: TAKE_FOR without a funding descriptor` };
        if (w >> 254n === 3n) return { path: "skip", reason: `item ${k}: BALANCE-form TAKE_FOR (forBalance) — the netted path refuses it on every Settlement` };
        if (!caps.nettedDeliveryFundedItems) return needsCaps(`item ${k}: TAKE_FOR`);
        if (w >> 255n === 0n) {
          // `forTotal`: funded from the maker's wallet, not from the delivery — a source.
          role = { kind: "take-for-total", at: "early" };
          break;
        }
        // A leg reference: it consumes the delivery, so it runs late. If its proceeds
        // also pay the input, the PULL needs them before DELIVER — a cycle.
        const to = it.recipient.toLowerCase();
        if (to === ZERO || to === settlement) {
          const asset = caps.proceedsAsset?.(it);
          if (asset === undefined || ins.has(asset.toLowerCase())) {
            return {
              path: "skip",
              reason: `item ${k}: leg-reference TAKE_FOR whose proceeds fund the input — a cycle (deliver needs the pull, the pull needs the item); needs flash or a counter-order`,
              needsFlash: true,
            };
          }
        }
        role = { kind: "take-for-leg", at: "late" };
        break;
      }
      default:
        return { path: "skip", reason: `item ${k}: unknown op ${String(it.op)}` };
    }
    roles.push(role);
    if (role.at === "late") lateItems |= 1n << BigInt(k);
  }

  // The maker's item policy against the fixed schedule (`Batch._stepItem` / `_stepPull`,
  // task 31): CANONICAL waits for the delivery before the pull — forward only. ORDERED
  // and ATOMIC make the PULL wait for every NON-MAKE item (they may credit an input leg),
  // so those run early and only MAKE items may run late; items still run in signed order.
  const policy = itemPolicyOf(order.timing);
  if (policy >= ItemPolicy.CANONICAL) {
    return { path: "skip", reason: "ItemPolicy CANONICAL is forward-only (items after delivery, pull after everything): needs filler capital" };
  }
  if (policy >= ItemPolicy.ORDERED) {
    const k = roles.findIndex((r) => r.kind === "take-for-leg");
    if (k !== -1) {
      return {
        path: "skip",
        reason: `item ${k}: leg-reference TAKE_FOR under ItemPolicy ${ItemPolicy[policy]} must run before the pull yet consumes the delivery — needs flash`,
        needsFlash: true,
      };
    }
  }
  const firstLate = roles.findIndex((r) => r.at === "late");
  const lastEarly = roles.map((r) => r.at).lastIndexOf("early");
  if (policy >= ItemPolicy.ORDERED && firstLate !== -1 && lastEarly > firstLate) {
    // e.g. swap → deposit (MAKE) → borrow to the wallet (TAKE): the TAKE must follow the
    // delivery-funded MAKE in signed order, yet the pull waits for it.
    return {
      path: "skip",
      reason: `ItemPolicy ${ItemPolicy[policy]}: item ${lastEarly} must run before the pull but follows late item ${firstLate} in signed order — needs flash`,
      needsFlash: true,
    };
  }
  if (policy === ItemPolicy.ATOMIC && firstLate !== -1 && lastEarly !== -1) {
    return { path: "skip", reason: "ItemPolicy ATOMIC: its items would run on both sides of the route, not back to back" };
  }
  return { path: "executeItemFill", lateItems, roles };
}
