import type { Quote } from "./ladder";
import { inputWei } from "./order";
import type { OrderType, Side } from "./types";

/**
 * How long a market order's dutch auction runs: it decays from the quoted price
 * to the floor over this window, then RESTS at the floor until it expires.
 */
export const MARKET_DECAY_SECONDS = 60;
/**
 * How long a market order stays live. ⚠ Not the auction length (review
 * 2026-10-05): the beta book refuses any order expiring within its
 * `MIN_TTL_SECONDS` (120 s, packages/orderbook-worker/wrangler.toml) and the
 * filler never touches one expiring within its `EXPIRY_MARGIN_SECONDS` (90 s,
 * packages/filler-worker/wrangler.toml — three Rootstock blocks for a tx to
 * land), so a 60-second order was refused by the book and, had it been admitted,
 * would have been held by the filler for its whole life. The life has to exceed
 * both; the margin above them is the fill window. Pinned by
 * `test/crossComponent.audit.test.ts` against the two wrangler files.
 */
export const MARKET_TTL_SECONDS = 300;
/**
 * Slippage floor quoted on market orders: the auction decays from the book's
 * price to `crossedOut × (1 − this)`. Lives here (not in App.tsx) so node
 * scripts can sign exactly the app's market shape. Since task 15 the book's pool
 * rungs are priced NET of each pool's fee tier (`applyPoolFee`, lib/univ3.ts), so
 * these bps are headroom over an EXECUTABLE price — before, a 0.3 % pool's fee
 * alone ate 30 of 50 and no filler could fill at the floor. 30 since 2026-10-07: the
 * filler's quote haircut is 10 bps (volatile) / 5 bps (stable), so 30 still leaves
 * 20–25 bps for gas while makers keep 20 bps more than at 50 (they end at the floor).
 */
export const MARKET_SLIPPAGE_BPS = 30;
/** How long a resting limit order lives. */
export const LIMIT_TTL_SECONDS = 24 * 3600;

/**
 * What the next signature actually commits, plus what funding it needs.
 *
 * The approval and the order are both sized from this one value. Deriving them
 * separately is how an interface ends up approving one amount and signing
 * another — which, under an exact-amount allowance policy, is not a cosmetic
 * mismatch but a fill that cannot happen.
 */
export interface TicketPlan {
  kind: "market" | "limit" | "twap";
  price: number;
  /** PAY amount of the ONE order signed now (one slice, for a TWAP). */
  amountIn: number;
  /** Best-case RECEIVE amount — the auction's start. */
  targetOut: number;
  /** Guaranteed RECEIVE amount. */
  minOut: number;
  ttlSeconds: number;
  decaySeconds: number;
  /** Orders this ticket signs in total: 1, or the TWAP's slice count. */
  orders: number;
  /** How long the funding must stay live: the whole schedule for a TWAP. */
  fundingTtlSeconds: number;
  /** BASE that crosses the book immediately — part of the SIGNED order, never outside it. */
  crossedBase: number;
  /** BASE the signed order leaves resting. */
  restingBase: number;
}

export interface PlanArgs {
  q: Quote;
  mid: number;
  mode: OrderType;
  side: Side;
  amount: number;
  limit: number | null;
  slices: number;
  everyMin: number;
  slippageBps?: number;
}

export function planTicket(a: PlanArgs): TicketPlan | null {
  const { q, mode, side, amount, limit } = a;
  if (amount <= 0 || q.totalIn <= 0) return null;
  const price = limit ?? a.mid;

  // A TWAP signs one slice at a time, so the slice — not the notional — is
  // what each signature commits. The FUNDING covers the whole schedule, so a
  // later slice can be signed when it comes due without another approval.
  if (mode === "twap") {
    const amountIn = amount / a.slices;
    const out = side === "sell" ? amountIn * price : amountIn / price;
    const ttlSeconds = a.everyMin * 60 + 60;
    return {
      kind: "twap",
      price,
      amountIn,
      targetOut: out,
      minOut: out,
      ttlSeconds,
      decaySeconds: 0,
      orders: a.slices,
      fundingTtlSeconds: a.slices * a.everyMin * 60 + 60,
      crossedBase: 0,
      restingBase: side === "sell" ? amount : amount / price,
    };
  }

  // A limit ticket that rests signs the WHOLE ticket as one order (G-TS_SIGN-15):
  // the part that crosses the book now is filled from that same signed order,
  // not booked as a fill no signature backs. Its floor is the limit price over
  // the full size; a short opening auction from the book's own price lets the
  // crossing part fill near the book rather than hand the filler the spread.
  if (mode === "limit" && q.resting && limit) {
    const amountIn = q.totalIn;
    const minOut = side === "sell" ? amountIn * limit : amountIn / limit;
    const targetOut = Math.max(q.totalOut, minOut);
    return {
      kind: "limit",
      price,
      amountIn,
      targetOut,
      minOut,
      ttlSeconds: LIMIT_TTL_SECONDS,
      decaySeconds: targetOut > minOut ? MARKET_DECAY_SECONDS : 0,
      orders: 1,
      fundingTtlSeconds: LIMIT_TTL_SECONDS,
      crossedBase: q.crossedBase,
      restingBase: q.resting.size,
    };
  }

  // A market order is a short dutch auction: the maker names the price the
  // book shows now and a floor, and lets fillers compete in between — then it
  // rests at the floor for the remainder of its life (see MARKET_TTL_SECONDS).
  // A PULL market's order is open to every filler (B13); a deployment may opt in
  // to a ~2-block soft window for its solver (`pullExclusivity`,
  // config/deploymentConfig.ts — off by default, it costs gas per fill). The 300 s
  // life is right for 30 s blocks: the auction is ~2 blocks, the rest is the
  // landing margin the book / filler gates need.
  return {
    kind: "market",
    price,
    amountIn: q.totalIn,
    targetOut: q.crossedOut,
    minOut: q.minReceived,
    ttlSeconds: MARKET_TTL_SECONDS,
    decaySeconds: MARKET_DECAY_SECONDS,
    orders: 1,
    fundingTtlSeconds: MARKET_TTL_SECONDS,
    crossedBase: q.crossedBase,
    restingBase: 0,
  };
}

/**
 * The per-order input cap: the raw balance, split evenly across a TWAP's
 * slices so the last one is still funded.
 */
export function perOrderCap(plan: TicketPlan, balanceWei: bigint | undefined): bigint | undefined {
  if (balanceWei === undefined) return undefined;
  return balanceWei / BigInt(plan.orders);
}

/** The exact funding a ticket needs: every order it will sign, each capped at the balance share. */
export function requiredInputWei(plan: TicketPlan, decimals: number, balanceWei: bigint | undefined): bigint {
  return inputWei(plan.amountIn, decimals, perOrderCap(plan, balanceWei)) * BigInt(plan.orders);
}

/**
 * The input cap for the NEXT TWAP slice the maker signs: the LIVE balance split
 * across the slices still to be signed, never across the total.
 *
 * Slices that already filled have left the wallet, so dividing what is left by
 * the original slice count shrank every later slice below its size (slice 2 of
 * N got (B - s)/N < s) and, with only the input clamped, signed less input for
 * the same output: a worse price that cannot fill (G-TS_SIGN-7).
 */
export function sliceCap(balanceWei: bigint | undefined, totalSlices: number, signedSlices: number): bigint | undefined {
  if (balanceWei === undefined) return undefined;
  const remaining = Math.max(1, totalSlices - signedSlices);
  return balanceWei / BigInt(remaining);
}
