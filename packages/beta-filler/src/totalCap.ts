import type { Address } from "viem";

import type { Config } from "./config";

/**
 * THE PRE-AUDIT TOTAL FILL CAP (2026-10-22; Rootstock grant thread #1: "a cap per fill and
 * a cap on the total filled before the audit"). The filler stops filling, and stops
 * quoting, once the USD value of everything it has filled reaches TOTAL_FILL_CAP_USD
 * (default 25,000). A fill in flight when the cap is crossed still lands, so the overshoot
 * is at most one fill (≤ the app's $1,000 per-order cap).
 *
 * A fill's USD value is its stable leg when it has one (USD₮0 at face, USDRIF at $1 — the
 * larger of the two when both), else the received token at the live pool price (`price`).
 */
export const DEFAULT_TOTAL_FILL_CAP_USD = 25_000;

const lc = (a: string | null | undefined) => (a ?? "").toLowerCase();

/** USD (6 dec) of one fill's legs, or `undefined` when neither leg can be priced. */
export async function fillUsd6(
  cfg: Pick<Config, "tokens">,
  leg: { payToken?: string | null; paid?: string | null; recvToken?: string | null; received?: string | null },
  price: (token: Address, amount: bigint) => Promise<bigint | undefined>,
): Promise<bigint | undefined> {
  const num = (v?: string | null) => (v && /^\d+$/.test(v) ? BigInt(v) : undefined);
  const legs = [
    { token: leg.payToken, amount: num(leg.paid) },
    { token: leg.recvToken, amount: num(leg.received) },
  ];
  let stable: bigint | undefined;
  for (const l of legs) {
    if (l.amount === undefined) continue;
    const v = lc(l.token) === lc(cfg.tokens.usdt0) ? l.amount : lc(l.token) === lc(cfg.tokens.usdrif) ? l.amount / 10n ** 12n : undefined;
    if (v !== undefined && (stable === undefined || v > stable)) stable = v;
  }
  if (stable !== undefined) return stable;
  for (const l of [legs[1]!, legs[0]!]) {
    if (l.amount === undefined || !l.token) continue;
    const v = await price(l.token as Address, l.amount).catch(() => undefined);
    if (v !== undefined) return v;
  }
  return undefined;
}
