/**
 * THE PRE-AUDIT CAP (2026-10-22): no single order may be worth more than the cap, in USD
 * at today's prices. Per ORDER, not cumulative per wallet (operator decision, 2026-10-22).
 * Rootstock only; other chains have none.
 *
 * Enforced in the UI only: an order posted straight to the orderbook is not checked here.
 */
export const BETA_CAP_USD: Record<number, number> = { 30: 1_000 };

export function betaCapFor(chainId: number): number | undefined {
  return BETA_CAP_USD[chainId];
}

/** The cap verdict for a ticket worth `ticketUsd`: whether it exceeds the per-order cap. */
export function capCheck(capUsd: number, ticketUsd: number | undefined): { capUsd: number; over: boolean } {
  // 0.5 % slack: prices move between the form and the check, a ticket AT the cap must pass.
  return { capUsd, over: ticketUsd !== undefined && ticketUsd > capUsd * 1.005 };
}
