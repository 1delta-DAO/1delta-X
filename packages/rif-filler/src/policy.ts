import { DELTA_VERIFY_OUTPUTS_BIT, isProportional, type Order } from "@1delta-x/sdk";
import { zeroAddress, type Address } from "viem";

import type { Config, Policy } from "./config";

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
 * Accept only the plain one-in/one-out shape the beta app signs. Every extra
 * feature (items, validators, modules, fee legs, proportional legs, delta-verify,
 * single-signature permits) is a way for the price we preview to differ from what
 * we pay, so in the beta we simply do not take it.
 */
export function classify(
  order: Order,
  cfg: Pick<Config, "tokens"> & { policy: Pick<Policy, "buyUsdrif" | "sellUsdrif"> },
  me: Address,
  extras: { hasPermitBatch?: boolean; sigless?: boolean } = {},
): Verdict<{ direction: Direction }> {
  if (extras.hasPermitBatch) return { ok: false, reason: "single-signature permit orders not supported" };
  if (extras.sigless) return { ok: false, reason: "on-chain-approved (sigless) orders not supported" };
  if (order.legsIn.length !== 1 || order.legsOut.length !== 1) return { ok: false, reason: "not one-in/one-out" };
  if (order.items.length || order.validators.length || order.invariants.length) {
    return { ok: false, reason: "items/validators/invariants not supported" };
  }
  if (order.fillModule !== zeroAddress || order.pricingModule !== zeroAddress) {
    return { ok: false, reason: "fill/pricing modules not supported" };
  }
  if ((order.timing >> DELTA_VERIFY_OUTPUTS_BIT) & 1n) {
    return { ok: false, reason: "delta-verify order: needs a callback filler, an EOA cannot fill it" };
  }
  if (order.exclusiveFiller !== zeroAddress && order.exclusiveFiller.toLowerCase() !== me.toLowerCase()) {
    return { ok: false, reason: "names another exclusive filler" };
  }
  const legIn = order.legsIn[0]!;
  const legOut = order.legsOut[0]!;
  if (isProportional(legIn.start)) return { ok: false, reason: "proportional (balance-relative) leg" };
  if (legOut.recipient !== zeroAddress && legOut.recipient.toLowerCase() !== order.maker.toLowerCase()) {
    return { ok: false, reason: "output goes to a third party" };
  }
  const tin = legIn.token.toLowerCase();
  const tout = legOut.token.toLowerCase();
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
    private spends: { token: string; amount: string; at: number }[] = [],
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

  spend(token: Address, amount: bigint, now: number) {
    this.prune(now);
    this.spends.push({ token: token.toLowerCase(), amount: amount.toString(), at: now });
  }

  toJSON() {
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
