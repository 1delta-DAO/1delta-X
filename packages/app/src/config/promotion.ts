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
  /** What an address has to do in a day to qualify. */
  qualifier: string;
  /** The prize pool, in the promoter's own words. */
  pool: string;
  /** How the pool is spread. */
  cadence: string;
}

const DEFAULT: Promotion = {
  live: true,
  chainId: 30,
  qualifier: "US$20",
  pool: "around 100 USDRIF",
  cadence: "roughly ten daily draws",
};

function parse(): Promotion {
  const raw = import.meta.env.VITE_PROMOTION;
  if (!raw) return DEFAULT;
  try {
    return { ...DEFAULT, ...(JSON.parse(raw) as Partial<Promotion>) };
  } catch {
    // A malformed override must not take the app down, and it must not invent a
    // draw either — it degrades to the compiled-in description.
    console.warn("VITE_PROMOTION is not valid JSON — ignoring");
    return DEFAULT;
  }
}

export const PROMOTION: Promotion = parse();

/** Whether the draw should be described on this chain at all. */
export function promotionRunsOn(chainId: number): boolean {
  return PROMOTION.live && PROMOTION.chainId === chainId;
}
