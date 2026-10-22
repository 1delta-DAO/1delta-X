import type { Fill, RestingOrder } from "./types";

/**
 * THE PRE-AUDIT CAP (2026-10-22; Rootstock grant thread #18 / #21 / #25: "capped in the
 * interface at ~1,000 USDRIF per user"). Per wallet, in USD, at today's prices: what the
 * wallet has had FILLED, what its open orders can still fill, and the ticket on the form
 * may not add up to more than the cap. Rootstock only; other chains have none.
 *
 * Enforced in the UI only: an order posted straight to the orderbook is not checked here.
 */
export const BETA_CAP_USD: Record<number, number> = { 30: 1_000 };

export function betaCapFor(chainId: number): number | undefined {
  return BETA_CAP_USD[chainId];
}

const same = (a: string | undefined, b: string) => !!a && a.toLowerCase() === b.toLowerCase();

/**
 * The wallet's USD toward the cap. `baseUsd(marketId)` = USD per one BASE token of the
 * market (a fill's and an order's `size` are in base units). Counted:
 *  • every fill of the wallet's own orders;
 *  • every open order's unfilled rest — soft-cancelled ones too, as they stay fillable
 *    on-chain until expiry. Expired and hard-cancelled orders have left the list.
 * Sizes without a USD price are skipped (`unpriced` says how many).
 */
export function usedUsd(a: {
  account: string;
  chainId: number;
  fills: readonly Fill[];
  orders: readonly RestingOrder[];
  baseUsd: (marketId: string) => number | undefined;
  chainOf: (marketId: string) => number;
}): { usd: number; unpriced: number } {
  let usd = 0;
  let unpriced = 0;
  const add = (marketId: string, size: number) => {
    if (!(size > 0) || a.chainOf(marketId) !== a.chainId) return;
    const px = a.baseUsd(marketId);
    if (px === undefined) unpriced++;
    else usd += size * px;
  };
  for (const f of a.fills) {
    if (!f.mine || f.simulated || !same(f.maker, a.account)) continue;
    add(f.marketId, f.size);
  }
  for (const o of a.orders) {
    if (!o.mine || !same(o.signed?.order.maker, a.account)) continue;
    add(o.marketId, o.size - o.filled);
  }
  return { usd, unpriced };
}

/** The cap verdict for a ticket worth `ticketUsd`: room left, and whether the ticket exceeds it. */
export function capCheck(capUsd: number, used: number, ticketUsd: number | undefined): { capUsd: number; usedUsd: number; leftUsd: number; over: boolean } {
  const leftUsd = Math.max(0, capUsd - used);
  // 0.5 % slack: prices move between the form and the check, a ticket AT the cap must pass.
  return { capUsd, usedUsd: used, leftUsd, over: ticketUsd !== undefined && ticketUsd > leftUsd * 1.005 };
}
