import type { Address, Hex } from "viem";

/**
 * OFF-CHAIN auction policy for a cosigned quote channel
 * ({@link https://github.com/ ClockFlooredQuoteModule} / `CosignedQuotePriceModule`).
 *
 * The contracts do not care how a cosigner arrives at the `bumpBps` it signs —
 * the module verifies the signature and (for the clock-floored instance) bounds
 * the result by the dutch clock. The auction FORMAT therefore lives entirely
 * here, which is what makes it changeable without a redeploy, a migration, or
 * re-signed orders.
 *
 * A bid is a bump: `0` = the maker's `start` (no concession), `10000` = the
 * maker's `end`. So the WINNER IS THE LOWEST BID — the filler that needs the
 * least concession to do the job — and "second price" means the runner-up's
 * bump, which is >= the winner's, i.e. slightly more generous to the winner.
 *
 * ⚠ The reserve is not implemented here because it does not need to be: no
 * mechanism can clear outside the maker's signed band, and under the
 * clock-floored module a quote can never beat the dutch clock either. Both
 * bounds are enforced on-chain, so a broken or hostile selection rule in this
 * file cannot price outside them.
 */

const BPS = 10_000;

export interface QuoteBid {
  /** Who would fill. Bound into the signed quote, so it is not transferable. */
  filler: Address;
  /** The concession this filler asks for, in bps of the maker's band. */
  bumpBps: number;
  /** Optional tie-break key — a commitment hash, for a sealed-bid round. */
  commitment?: Hex;
}

export type AuctionRule = "first-price" | "second-price";

export interface AuctionOutcome {
  winner: Address;
  /** The bump to sign into the quote. */
  bumpBps: number;
  /** The winning bid itself, which differs from `bumpBps` under second-price. */
  winningBidBps: number;
  /** Runner-up bump, when one existed. */
  runnerUpBps: number | null;
  /** Bids considered after filtering. */
  bidders: number;
  rule: AuctionRule;
}

/** Malformed bids are dropped rather than throwing: one bad submitter in a
 *  permissionless round must not void the auction for everyone else. */
function usable(b: QuoteBid): boolean {
  return Number.isInteger(b.bumpBps) && b.bumpBps >= 0 && b.bumpBps <= BPS;
}

/**
 * Deterministic total order over bids: lower bump first, then the commitment
 * hash, then the filler address.
 *
 * The tie-break MUST be total and deterministic or the outcome is not
 * objectively checkable — two honest parties replaying the same committed set
 * have to agree on the winner, and "whichever arrived first" is not a property
 * of the set.
 */
function compareBids(a: QuoteBid, b: QuoteBid): number {
  if (a.bumpBps !== b.bumpBps) return a.bumpBps - b.bumpBps;
  const ka = (a.commitment ?? a.filler).toLowerCase();
  const kb = (b.commitment ?? b.filler).toLowerCase();
  return ka < kb ? -1 : ka > kb ? 1 : 0;
}

export interface SelectOptions {
  rule?: AuctionRule;
  /**
   * Refuse to grant ANY concession below this many distinct bidders. A
   * second-price round with one bidder is not an auction, and a ring that shows
   * up alone should get nothing for it — so the outcome becomes `bumpBps = 0`,
   * the maker's ambition, which the filler is free to take or leave.
   *
   * Defaults to 2 for `second-price` (where a lone bidder would otherwise be
   * charged the reserve) and 1 for `first-price` (where a lone bidder is still
   * paying its own bid).
   */
  minBidders?: number;
}

/**
 * Run one quote auction over a set of bids.
 *
 * Returns `null` when there is nothing to sign — no usable bids at all. A
 * thin round that trips `minBidders` returns an outcome with `bumpBps = 0`
 * rather than `null`: the distinction matters to a cosigner, because signing a
 * zero-concession quote and signing nothing are different messages to a filler
 * (the first says "you may fill at the maker's ambition", the second says
 * nothing at all — and under the clock-floored module, that means the clock).
 */
export function selectQuote(bids: readonly QuoteBid[], opts: SelectOptions = {}): AuctionOutcome | null {
  const rule = opts.rule ?? "second-price";
  const minBidders = opts.minBidders ?? (rule === "second-price" ? 2 : 1);

  // One bid per filler — the best (lowest) it submitted. Without this, a single
  // filler can be its own runner-up and set its own second price.
  const best = new Map<string, QuoteBid>();
  for (const bid of bids) {
    if (!usable(bid)) continue;
    const key = bid.filler.toLowerCase();
    const prev = best.get(key);
    if (prev === undefined || compareBids(bid, prev) < 0) best.set(key, bid);
  }

  const sorted = [...best.values()].sort(compareBids);
  if (sorted.length === 0) return null;

  const winner = sorted[0]!;
  const runnerUp = sorted[1] ?? null;
  const bidders = sorted.length;

  if (bidders < minBidders) {
    return {
      winner: winner.filler,
      bumpBps: 0,
      winningBidBps: winner.bumpBps,
      runnerUpBps: runnerUp?.bumpBps ?? null,
      bidders,
      rule,
    };
  }

  // Second-price with no runner-up would have no price to charge; `minBidders`
  // defaults to 2 precisely so this cannot be reached, but an explicit
  // `minBidders: 1` opts into "lone bidder pays its own bid".
  const bumpBps = rule === "second-price" && runnerUp !== null ? runnerUp.bumpBps : winner.bumpBps;

  return {
    winner: winner.filler,
    bumpBps,
    winningBidBps: winner.bumpBps,
    runnerUpBps: runnerUp?.bumpBps ?? null,
    bidders,
    rule,
  };
}

/**
 * The auction outcome as an independently checkable claim.
 *
 * Publishing this alongside the committed bid set is what makes a cosigner
 * accountable WITHOUT any proving system: anyone holding the openings can
 * re-run {@link selectQuote} and compare. A zero-knowledge proof of the same
 * statement only becomes necessary when the losing bids must stay secret
 * permanently — until then, this is the cheap version of the same guarantee.
 */
export function verifyOutcome(
  bids: readonly QuoteBid[],
  claimed: AuctionOutcome,
  opts: SelectOptions = {},
): boolean {
  const actual = selectQuote(bids, { rule: claimed.rule, ...opts });
  if (actual === null) return false;
  return (
    actual.winner.toLowerCase() === claimed.winner.toLowerCase() &&
    actual.bumpBps === claimed.bumpBps &&
    actual.winningBidBps === claimed.winningBidBps &&
    actual.bidders === claimed.bidders
  );
}
