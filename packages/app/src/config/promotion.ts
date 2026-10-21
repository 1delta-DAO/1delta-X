/**
 * The trading prize draw, as the interface is allowed to describe it.
 *
 * `TC.md` deliberately fixes no numbers — §4.2 leaves the qualifying criteria
 * to be "communicated by 1delta through its official channels", and §2.1 leaves
 * the period there too. This file is that channel, which is why every figure is
 * a display string the promoter writes rather than a number the app computes:
 * the terms promise approximations, so the UI must not render precision the
 * terms do not carry.
 *
 * Overridable at deploy time, in the same shape as `VITE_DEPLOYMENTS`:
 *
 *   VITE_PROMOTION='{"live":false}'
 *   VITE_PROMOTION='{"pool":"200 USDRIF","cadence":"20 daily draws"}'
 */
export interface Promotion {
  /** Whether a draw is running. False removes every mention of it from the UI. */
  live: boolean;
  /** The chain qualifying trades have to happen on. */
  chainId: number;
  /** What an address has to do in a day for a ticket. */
  qualifier: string;
  /** The prize pool, in the promoter's own words. */
  pool: string;
  /** How the pool is spread. */
  cadence: string;
  /**
   * Where "Stuck? Report a problem" points (a Telegram group, a form) — open to
   * everyone, unlike Participate, because the people who never got to a first swap
   * are the ones whose feedback matters most. "" hides the link.
   */
  support: string;
}

const DEFAULT: Promotion = {
  live: true,
  chainId: 30,
  // Fallback copy only: with a live orderbook the notice states the rules the desk
  // publishes (periodDays, qualifier, prizes; lib/raffle.ts `describeRules`).
  qualifier: "US$20",
  pool: "around 200 USDRIF",
  cadence: "roughly eight draws, one every three days",
  support: "",
};

function parse(): Promotion {
  const raw = import.meta.env.VITE_PROMOTION;
  if (!raw) return DEFAULT;
  try {
    return { ...DEFAULT, ...(JSON.parse(raw) as Partial<Promotion>) };
  } catch {
    // A malformed override must not take the app down, and it must not invent a
    // draw either — it degrades to the compiled-in description.
    console.warn("VITE_PROMOTION is not valid JSON, ignoring it");
    return DEFAULT;
  }
}

export const PROMOTION: Promotion = parse();

/** Whether the draw should be described on this chain at all. */
export function promotionRunsOn(chainId: number): boolean {
  return PROMOTION.live && PROMOTION.chainId === chainId;
}
