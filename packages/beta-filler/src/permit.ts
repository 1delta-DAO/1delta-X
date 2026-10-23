import { ERC2612_ABI, OrderSide, packOrder, SETTLEMENT_LENS_ABI, type Erc2612Permit, type Order } from "@1delta-x/sdk";
import type { Address } from "viem";

import type { Chain } from "./chain";
import type { Config } from "./config";
import type { BookEntry } from "./intake";

/**
 * GASLESS MAKERS — filling an order funded by the ERC-2612 permit it carries.
 *
 * The app lets a maker who holds a 2612 token (USD₮0) fund an order with a signed
 * `permit(maker, Settlement, value, deadline)` instead of an approval tx. Settlement's
 * pull falls back to a plain `transferFrom` against that DIRECT allowance whenever the
 * Permit3 leg fails (`Base._pullViaPermit3`), so once the permit has run the order
 * fills like any other.
 *
 * The permit runs INSIDE the fill: the route strategy passes it in
 * `AggregatorFillSolver.executeFill`'s `permits` argument (SDK `toSolverPermit`), and
 * the solver calls `token.permit(maker, SETTLEMENT, …)` before the fill — one tx,
 * simulated together, no extra block of latency. The permit's gas
 * (`PERMIT_IN_FILL_GAS`, ./route.ts) is charged to that fill's gate.
 *
 * Front-running is harmless: anyone may submit the same permit first (it is public in
 * the book); the solver then accepts the failed `permit` call because Settlement's
 * allowance from the maker already covers `value`. Once that has happened the lens
 * reports the order funded and we fill WITHOUT the permit (it would only cost gas).
 *
 * The inventory strategy (an EOA `fillUpTo`) cannot carry a permit: it takes such an
 * order only once something else funded it ("funded").
 */

export type PermitStage =
  /** The entry carries no usable permit for this settlement: judge it as any other order. */
  | { kind: "none" }
  /** Something already funds it (a permit someone ran, or the maker's own approval): fill on `fillable`, no permit. */
  | { kind: "funded"; fillable: bigint }
  /** Unfunded, permit live: a fill of up to `fillable` must CARRY `permit` (route strategy only). */
  | { kind: "permit"; fillable: bigint; permit: Erc2612Permit }
  /** Unfunded and the permit cannot fund it (spent, expiring, no balance, permit fills disabled). */
  | { kind: "dead"; reason: string };

/** Seconds a permit must still be valid for a fill carrying it to be worth sending (a ~30 s block, twice). */
export const PERMIT_DEADLINE_MARGIN_S = 60n;

const FILLABLE = 1; // SettlementLens.OrderStatus.Fillable

/** Whether the permit is one a fill may carry for this order at all (else it is ignored). */
export function permitApplies(order: Order, p: Erc2612Permit, settlement: Address): boolean {
  return (
    p.spender.toLowerCase() === settlement.toLowerCase() &&
    order.legsIn.some((l) => l.token.toLowerCase() === p.token.toLowerCase())
  );
}

/**
 * The most a fill could take once the permit runs, in anchor units: the order's
 * remaining amount, and — for a plain fixed-input SELL whose input IS the permit token
 * (anchor units = input units) — no more than the maker holds or the permit allows.
 * Other shapes keep `remaining`; the fill's own simulation (which runs the permit) is
 * what finally sizes them.
 */
export function permitFillable(order: Order, p: Erc2612Permit, remaining: bigint, balance: bigint): bigint {
  const leg = order.legsIn[0];
  const inputAnchored =
    order.side === OrderSide.SELL && order.fillTotal === 0n && leg !== undefined && leg.token.toLowerCase() === p.token.toLowerCase() && leg.end === 0n;
  if (!inputAnchored) return remaining;
  return [remaining, balance, p.value].reduce((a, b) => (a < b ? a : b));
}

/**
 * Four reads (lens state + remaining, token nonce + balance) — only for book entries
 * that carry a permit and that some strategy accepts by shape. The book's fillable is
 * the lens's allowance-capped figure (0 until the permit runs), so it cannot size such
 * an order; this does.
 */
export async function permitStage(c: Chain, cfg: Config, entry: BookEntry, nowS: bigint): Promise<PermitStage> {
  const p = entry.announce.erc2612Permit;
  const order = entry.announce.order;
  if (!p || !permitApplies(order, p, cfg.settlement)) return { kind: "none" };
  const packed = packOrder(order) as never;
  const [state, remaining, nonce, balance] = await Promise.all([
    c.pub.readContract({
      address: cfg.lens,
      abi: SETTLEMENT_LENS_ABI,
      functionName: "getOrderRelevantState",
      args: [packed, entry.announce.sig, c.me, "0x"],
    }) as Promise<readonly [number, bigint, boolean, boolean]>,
    c.pub.readContract({ address: cfg.lens, abi: SETTLEMENT_LENS_ABI, functionName: "remaining", args: [packed] }) as Promise<bigint>,
    c.pub.readContract({ address: p.token, abi: ERC2612_ABI, functionName: "nonces", args: [order.maker] }) as Promise<bigint>,
    c.pub.readContract({ address: p.token, abi: ERC2612_ABI, functionName: "balanceOf", args: [order.maker] }) as Promise<bigint>,
  ]);
  const [status, fillable, sigValid] = state;
  if (Number(status) !== FILLABLE || !sigValid) return { kind: "dead", reason: `order not fillable (lens status ${status}${sigValid ? "" : ", bad signature"})` };
  // An allowance already funds it ALL — the permit ran (front-run, or an earlier fill of
  // ours) or the maker approved: fill without the permit, it would only cost gas.
  if (fillable > 0n && fillable >= remaining) return { kind: "funded", fillable };
  // Partly funded (2026-10-23): a DUST allowance left by an earlier order (exact-approval
  // and permit leftovers, e.g. 0.08 USD₮0) made the lens report a sliver fillable, and the
  // order was treated as funded at that size: never worth a fill, so it never filled. The
  // permit SETS the allowance to its value, so while it is live and funds more, carry it.
  const live = cfg.permitFills && nonce === p.nonce && p.deadline > nowS + PERMIT_DEADLINE_MARGIN_S && balance > 0n;
  const est = live ? permitFillable(order, p, remaining, balance) : 0n;
  if (fillable > 0n) return est > fillable ? { kind: "permit", fillable: est, permit: p } : { kind: "funded", fillable };
  if (!cfg.permitFills) return { kind: "dead", reason: "unfunded; in-fill maker permits disabled (PERMIT_FILLS_ENABLED=0)" };
  if (nonce !== p.nonce) return { kind: "dead", reason: `unfunded; maker permit spent or superseded (token nonce ${nonce}, permit ${p.nonce})` };
  if (p.deadline <= nowS + PERMIT_DEADLINE_MARGIN_S) return { kind: "dead", reason: "unfunded; maker permit expires too soon to land" };
  if (balance === 0n) return { kind: "dead", reason: "unfunded; maker holds none of the permit token" };
  if (est === 0n) return { kind: "dead", reason: "nothing left to fill" };
  return { kind: "permit", fillable: est, permit: p };
}
