import { BLOCK_CLOCK_BIT, DELTA_VERIFY_OUTPUTS_BIT, isProportional, overrideHasCarrier, unpackTiming, type Order } from "@1delta-x/sdk";
import { zeroAddress, type Address } from "viem";

import { MOC_FEE_BPS, type Config, type Policy } from "./config";
import type { SpendEntry } from "./state";

/**
 * Pure decision logic: which orders this filler takes, at what size and price.
 * Everything chain-dependent (previews, quotes, balances) is passed in, so the
 * whole policy is unit-testable.
 */

/** `buyUsdrif`: the maker sells USDRIF, we pay USDT0. `sellUsdrif`: the maker buys USDRIF, we deliver it. */
export type Direction = "buyUsdrif" | "sellUsdrif";

export type Verdict<T> = ({ ok: true } & T) | { ok: false; reason: string };

const ONE = 10n ** 18n;
/** USDT0 (6 dec) → 18-dec scale factor. */
const USDT0_TO_18 = 10n ** 12n;

/**
 * The plain one-in/one-out shape the beta app signs, minus the delivery-mode and
 * exclusivity checks (which differ per strategy). Every extra feature (items,
 * validators, modules, fee legs, proportional legs, single-signature permits) is a
 * way for the price we preview to differ from what we pay, so in the beta we
 * simply do not take it. Shared by the inventory and route strategies.
 */
export function plainShape(
  order: Order,
  extras: { hasPermitBatch?: boolean; sigless?: boolean } = {},
): Verdict<{}> {
  if (extras.hasPermitBatch) return { ok: false, reason: "single-signature permit orders not supported" };
  if (extras.sigless) return { ok: false, reason: "on-chain-approved (sigless) orders not supported" };
  if (order.legsIn.length !== 1 || order.legsOut.length !== 1) return { ok: false, reason: "not one-in/one-out" };
  if (order.items.length || order.validators.length || order.invariants.length) {
    return { ok: false, reason: "items/validators/invariants not supported" };
  }
  if (order.fillModule !== zeroAddress || order.pricingModule !== zeroAddress) {
    return { ok: false, reason: "fill/pricing modules not supported" };
  }
  const legIn = order.legsIn[0]!;
  const legOut = order.legsOut[0]!;
  if (isProportional(legIn.start)) return { ok: false, reason: "proportional (balance-relative) leg" };
  if (legOut.recipient !== zeroAddress && legOut.recipient.toLowerCase() !== order.maker.toLowerCase()) {
    return { ok: false, reason: "output goes to a third party" };
  }
  return { ok: true };
}

/** Whether the order carries timing bit 104 (delta-verify / direct delivery). */
export function isDeltaVerify(order: Order): boolean {
  return ((order.timing >> DELTA_VERIFY_OUTPUTS_BIT) & 1n) === 1n;
}

/**
 * How `me` stands against a PULL order's exclusivity at `nowS` (unix seconds) — the
 * off-chain reading of `OrderGates.exclusivityOverride`:
 *   • `open`      — no `exclusiveFiller`, the window is over, or we ARE the named filler;
 *   • `soft`      — another filler's window is still running, but it is SOFT: the
 *                   core lets us fill by paying `exclusivityOverrideBps` to the maker
 *                   (a carrier leg exists, override in (0, 10 000]). The lens previews
 *                   it for `filler = me`, so every price / profit gate downstream sees
 *                   the premium — nothing else has to price it;
 *   • `hard`      — another filler's window is running and the core would refuse us
 *                   (`NotExclusiveFiller`): override 0, nothing to carry it, or a
 *                   block-clocked window we cannot place on the wall clock.
 * Delta-verify orders are NOT read here (their exclusivity is whole-life, Core F30).
 *
 * Why this matters (B13, 2026-10-06): the app's PULL markets name the deployment's
 * SOLVER contract with a ~2-block soft window. The inventory strategy fills as our
 * EOA, so inside that window it is an outsider like any other — it may fill at the
 * premium (the maker is better off, and the preview prices it), or wait the ≤ 2
 * blocks for the window to end; the engine re-quotes a held order the moment its
 * window ends ({@link windowEndMs}).
 */
export function exclusivityFor(
  order: Order,
  me: Address,
  nowS: bigint,
): { kind: "open" } | { kind: "soft"; endsAt: bigint; overrideBps: bigint } | { kind: "hard"; endsAt?: bigint } {
  const ex = order.exclusiveFiller;
  if (ex === zeroAddress || ex.toLowerCase() === me.toLowerCase()) return { kind: "open" };
  const endsAt = BigInt(unpackTiming(order.timing).exclusivityEndTime);
  const blockClock = ((order.timing >> BLOCK_CLOCK_BIT) & 1n) === 1n;
  if (!blockClock && nowS >= endsAt) return { kind: "open" };
  const bps = order.exclusivityOverrideBps;
  if (blockClock) return { kind: "hard" };
  if (bps === 0n || bps > 10_000n || !overrideHasCarrier(order)) return { kind: "hard", endsAt };
  return { kind: "soft", endsAt, overrideBps: bps };
}

/**
 * When a held order should be re-quoted because its exclusivity window ends — the one
 * moment its price steps in an outsider's favour (the premium drops away, a hard
 * window opens). `undefined` when there is no running timestamp-clocked window.
 */
export function windowEndMs(order: Order, nowMs: number): number | undefined {
  if (order.exclusiveFiller === zeroAddress || isDeltaVerify(order)) return undefined;
  if (((order.timing >> BLOCK_CLOCK_BIT) & 1n) === 1n) return undefined;
  const end = unpackTiming(order.timing).exclusivityEndTime * 1000;
  return end > nowMs ? end : undefined;
}

/**
 * INVENTORY strategy: the plain shape, pull delivery only (an EOA cannot run the
 * callback a delta-verify order needs), on the USDRIF/USDT0 pair, and fillable by
 * this wallet NOW: open, exclusive to this wallet, or inside another filler's SOFT
 * window (priced at the override by the preview — see {@link exclusivityFor}).
 */
export function classify(
  order: Order,
  cfg: Pick<Config, "tokens"> & { policy: Pick<Policy, "buyUsdrif" | "sellUsdrif"> },
  me: Address,
  extras: { hasPermitBatch?: boolean; sigless?: boolean; nowS?: bigint } = {},
): Verdict<{ direction: Direction }> {
  const shape = plainShape(order, extras);
  if (!shape.ok) return shape;
  if (isDeltaVerify(order)) {
    return { ok: false, reason: "delta-verify order: needs a callback filler, an EOA cannot fill it" };
  }
  const ex = exclusivityFor(order, me, extras.nowS ?? BigInt(Math.floor(Date.now() / 1000)));
  if (ex.kind === "hard") {
    return { ok: false, reason: `exclusive to another filler (hard window${ex.endsAt !== undefined ? ` until ${ex.endsAt}` : ""})` };
  }
  const tin = order.legsIn[0]!.token.toLowerCase();
  const tout = order.legsOut[0]!.token.toLowerCase();
  const usdrif = cfg.tokens.usdrif.toLowerCase();
  const usdt0 = cfg.tokens.usdt0.toLowerCase();
  if (tin === usdrif && tout === usdt0) {
    return cfg.policy.buyUsdrif ? { ok: true, direction: "buyUsdrif" } : { ok: false, reason: "buy side disabled" };
  }
  if (tin === usdt0 && tout === usdrif) {
    return cfg.policy.sellUsdrif ? { ok: true, direction: "sellUsdrif" } : { ok: false, reason: "sell side disabled" };
  }
  return { ok: false, reason: "not the USDRIF/USDT0 pair" };
}

/** The token we pay and the token we receive, for a direction. */
export function legsFor(direction: Direction, tokens: Config["tokens"]): { pay: Address; receive: Address } {
  return direction === "buyUsdrif"
    ? { pay: tokens.usdt0, receive: tokens.usdrif }
    : { pay: tokens.usdrif, receive: tokens.usdt0 };
}

/** USDT0 per USDRIF, 1e18-scaled, for one fill's `paid`/`received` (each in its own token's units). */
export function fillPrice(direction: Direction, paid: bigint, received: bigint): bigint {
  // buy: we pay USDT0 (paid) for USDRIF (received); sell: we receive USDT0 for USDRIF paid.
  const usdt0 = direction === "buyUsdrif" ? paid : received;
  const usdrif = direction === "buyUsdrif" ? received : paid;
  if (usdrif === 0n) return direction === "buyUsdrif" ? 2n ** 255n : 0n;
  return (usdt0 * USDT0_TO_18 * ONE) / usdrif;
}

export function priceOk(direction: Direction, paid: bigint, received: bigint, p: Policy): Verdict<{ price: bigint }> {
  if (paid === 0n || received === 0n) return { ok: false, reason: "zero-sized leg" };
  const price = fillPrice(direction, paid, received);
  if (direction === "buyUsdrif" && price > p.maxBuyPrice) {
    return { ok: false, reason: `price ${fmt18(price)} above max ${fmt18(p.maxBuyPrice)}` };
  }
  if (direction === "sellUsdrif" && price < p.minSellPrice) {
    return { ok: false, reason: `price ${fmt18(price)} below min ${fmt18(p.minSellPrice)}` };
  }
  return { ok: true, price };
}

/** Whether `order` prices the same at every time: no curve and every leg fixed (`end == 0`). */
export function isFixedPrice(order: Order): boolean {
  return order.curve.length === 0 && order.legsIn.every((l) => l.end === 0n) && order.legsOut.every((l) => l.end === 0n);
}

/**
 * Zero-RPC price pre-filter for a FIXED-price plain order: its implied price at full
 * size (we pay `legsOut[0].start`, receive `legsIn[0].start` — either direction)
 * against MAX_BUY_PRICE / MIN_SELL_PRICE. A partial fill scales both legs and rounds
 * maker-ward, so the price at any size is that one or worse: out of bounds here means
 * out of bounds after any preview. An order whose price moves with time passes (it
 * is judged on a live preview).
 */
export function fixedPriceOk(order: Order, direction: Direction, p: Policy): Verdict<{}> {
  const legIn = order.legsIn[0];
  const legOut = order.legsOut[0];
  if (!isFixedPrice(order) || !legIn || !legOut) return { ok: true };
  const v = priceOk(direction, legOut.start, legIn.start, p);
  return v.ok ? { ok: true } : { ok: false, reason: `fixed-price order: ${v.reason}` };
}

/**
 * Buy side only: the USDT0 we would actually get back by redeeming the received
 * USDRIF at MoC's oracle and selling the RIF on the pool must beat what we pay by
 * `minExitEdgeBps`. `exitQuoteUsdt0` is that round trip, quoted live by the caller.
 */
export function exitOk(paidUsdt0: bigint, exitQuoteUsdt0: bigint, p: Policy): Verdict<{ edgeBps: bigint }> {
  if (paidUsdt0 === 0n) return { ok: false, reason: "zero payment" };
  const edgeBps = ((exitQuoteUsdt0 - paidUsdt0) * 10_000n) / paidUsdt0;
  if (edgeBps < p.minExitEdgeBps) return { ok: false, reason: `exit edge ${edgeBps} bps < ${p.minExitEdgeBps}` };
  return { ok: true, edgeBps };
}

/**
 * The inventory fill's all-in cost gate. `edgeUsdt0` is what the fill earns before
 * gas (buy: live redeem+sell exit − paid; sell: received − mint replacement cost).
 * It must cover the fill's own gas, its pro-rata share of the rebalance it causes,
 * and `minProfitUsdt0` — all already converted to USDT0 by the caller.
 */
export function inventoryProfitOk(edgeUsdt0: bigint, costUsdt0: bigint, minProfitUsdt0: bigint): Verdict<{ marginUsdt0: bigint }> {
  const margin = edgeUsdt0 - costUsdt0 - minProfitUsdt0;
  if (margin < 0n) {
    return { ok: false, reason: `unprofitable after gas: edge ${edgeUsdt0} < gas+rebalance ${costUsdt0} + min profit ${minProfitUsdt0} (USDT0 units)` };
  }
  return { ok: true, marginUsdt0: margin };
}

/** Pro-rata share of a rebalance cost for a fill of `usdrif` when a rebalance batches `redeemMin`. */
export function rebalanceShare(costWei: bigint, usdrif: bigint, redeemMin: bigint): bigint {
  if (redeemMin === 0n || usdrif >= redeemMin) return costWei;
  return (costWei * usdrif + redeemMin - 1n) / redeemMin; // round up: never under-charge
}

/**
 * Sell side: the USDT0 it costs to replace `usdrif` sold from inventory — ~$1 each
 * through a MoC mint, plus the mint fee (`MOC_FEE_BPS`); 18 → 6 decimals, rounded up.
 * Used by both the all-in gate and the recorded `profitEst`, so the two agree.
 */
export function mintReplaceUsdt0(usdrif: bigint): bigint {
  return (usdrif * (10_000n + MOC_FEE_BPS) + 10n ** 16n - 1n) / 10n ** 16n;
}

/** USDT0 notional of a fill (the USDT0 side, whichever direction). */
export function notionalUsdt0(direction: Direction, paid: bigint, received: bigint): bigint {
  return direction === "buyUsdrif" ? paid : received;
}

/**
 * Scale a fill down so the amount we PAY stays within `capPaid`. Previews are
 * linear in the fill amount up to rounding, so the caller must re-preview the
 * result. Returns 0 when nothing fits.
 */
export function capFillAmount(fillAmount: bigint, paidAtFill: bigint, capPaid: bigint): bigint {
  if (paidAtFill <= capPaid) return fillAmount;
  if (capPaid <= 0n || paidAtFill === 0n) return 0n;
  // Floor, then shave one unit so the rounded-up output of the re-preview still fits.
  const scaled = (fillAmount * capPaid) / paidAtFill;
  return scaled > 1n ? scaled - 1n : 0n;
}

/**
 * Rolling one-hour outflow budget per token. The hot wallet's blast radius is its
 * balance; this bounds how fast even a mispriced stream of orders can move it.
 */
export class Budget {
  constructor(
    private readonly caps: Record<string, bigint>,
    private spends: SpendEntry[] = [],
    private readonly windowMs = 3_600_000,
  ) {}

  private prune(now: number) {
    this.spends = this.spends.filter((s) => now - s.at < this.windowMs);
  }

  remaining(token: Address, now: number): bigint {
    this.prune(now);
    const cap = this.caps[token.toLowerCase()] ?? 0n;
    const used = this.spends
      .filter((s) => s.token === token.toLowerCase())
      .reduce((a, s) => a + BigInt(s.amount), 0n);
    return cap > used ? cap - used : 0n;
  }

  /**
   * Record a spend. `ref` (a tx hash) makes it a reservation {@link settle} can
   * adjust later — and makes the spend idempotent per `(ref, token)`: a dropped
   * tx re-sent with identical bytes has the same hash, and used to stack a second
   * full-limit entry the receipt's `settle` could never reach (review 2026-10-05).
   * The entry takes the newer time, so the window runs from the actual send.
   */
  spend(token: Address, amount: bigint, now: number, ref?: string) {
    this.prune(now);
    const k = token.toLowerCase();
    const i = ref ? this.spends.findIndex((s) => s.ref === ref && s.token === k) : -1;
    const entry = { token: k, amount: amount.toString(), at: now, ...(ref ? { ref } : {}) };
    if (i < 0) this.spends.push(entry);
    else this.spends[i] = entry;
  }

  /**
   * Replace the amount of the reservation tagged `ref` for `token` (0 removes it).
   * The entry keeps its original time, so the rolling window is unchanged.
   */
  settle(ref: string, token: Address, amount: bigint): void {
    const k = token.toLowerCase();
    const i = this.spends.findIndex((s) => s.ref === ref && s.token === k);
    if (i < 0) return;
    if (amount === 0n) this.spends.splice(i, 1);
    else this.spends[i] = { ...this.spends[i]!, amount: amount.toString() };
  }

  toJSON(): SpendEntry[] {
    return this.spends;
  }
}

export function fmt18(v: bigint): string {
  const neg = v < 0n;
  const a = neg ? -v : v;
  const s = `${a / ONE}.${(a % ONE).toString().padStart(18, "0").slice(0, 6)}`;
  return neg ? `-${s}` : s;
}

export function fmtUnits(v: bigint, decimals: number): string {
  const base = 10n ** BigInt(decimals);
  return `${v / base}.${(v % base).toString().padStart(decimals, "0").slice(0, Math.min(decimals, 6))}`;
}
