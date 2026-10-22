import type { RestingOrder } from "./types";

/**
 * THE PRE-AUDIT CAPS (2026-10-22; Rootstock grant thread #1, #21, #25), in USD at today's
 * prices, Rootstock only:
 *  • per ORDER: no single order (a TWAP's whole size) worth more than the cap;
 *  • per WALLET: the wallet's OPEN orders (what they can still fill, i.e. what its exact
 *    approvals still let Settlement take) plus the new one may not pass the cap either.
 *    Filled orders no longer count: room frees up as orders fill or expire.
 *  • the TOTAL filled before the audit is enforced by the filler (beta-filler totalCap.ts,
 *    {@link BETA_TOTAL_FILL_CAP_USD}): it stops quoting and filling once reached.
 *
 * The per-order and per-wallet caps are enforced in the UI only.
 */
export const BETA_CAP_USD: Record<number, number> = { 30: 1_000 };
export const BETA_TOTAL_FILL_CAP_USD: Record<number, number> = { 30: 25_000 };

export function betaCapFor(chainId: number): number | undefined {
  return BETA_CAP_USD[chainId];
}

const same = (a: string | undefined, b: string) => !!a && a.toLowerCase() === b.toLowerCase();

/** USD the wallet's open orders can still fill (soft-cancelled ones too: fillable until expiry). Unpriced rests are skipped. */
export function openUsd(a: {
  account: string;
  chainId: number;
  orders: readonly RestingOrder[];
  baseUsd: (marketId: string) => number | undefined;
  chainOf: (marketId: string) => number;
}): number {
  let usd = 0;
  for (const o of a.orders) {
    if (!o.mine || !same(o.signed?.order.maker, a.account) || a.chainOf(o.marketId) !== a.chainId) continue;
    const rest = o.size - o.filled;
    const px = a.baseUsd(o.marketId);
    if (rest > 0 && px !== undefined) usd += rest * px;
  }
  return usd;
}

export interface CapVerdict {
  capUsd: number;
  /** Room the wallet's open orders leave (= capUsd without open orders). */
  leftUsd: number;
  over: boolean;
  /** Which cap the ticket breaks: the per-order one, or the wallet's open-order one. */
  kind?: "order" | "wallet";
}

/** The verdict for a ticket worth `ticketUsd`, with the wallet's open orders worth `open`. */
export function capCheck(capUsd: number, ticketUsd: number | undefined, open = 0): CapVerdict {
  const leftUsd = Math.max(0, capUsd - open);
  // 0.5 % slack: prices move between the form and the check, a ticket AT the cap must pass.
  const slack = 1.005;
  if (ticketUsd === undefined) return { capUsd, leftUsd, over: false };
  if (ticketUsd > capUsd * slack) return { capUsd, leftUsd, over: true, kind: "order" };
  if (ticketUsd > leftUsd * slack) return { capUsd, leftUsd, over: true, kind: "wallet" };
  return { capUsd, leftUsd, over: false };
}

/** The tooltip that states every pre-audit limit. */
export function capLimitsNote(capUsd: number, totalUsd: number | undefined): string {
  const fmt = (v: number) => `$${v.toLocaleString("en-US")}`;
  return (
    `Pre-audit limits: each order is capped at ${fmt(capUsd)}, and a wallet's open orders together may not exceed ${fmt(capUsd)} ` +
    `(filled or expired orders no longer count).` +
    (totalUsd !== undefined ? ` The beta also stops filling once ${fmt(totalUsd)} has been filled in total, until the audit is done.` : "")
  );
}
