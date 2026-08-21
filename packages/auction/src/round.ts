import {
  selectQuote,
  verifyOutcome,
  type AuctionOutcome,
  type AuctionRule,
  type QuoteBid,
} from "@1delta-x/sdk";
import type { Address, Hex } from "viem";

/**
 * One quote auction, as a state machine.
 *
 * OPEN → (bids arrive, permissionlessly) → CLOSED → SETTLED (an outcome, and a
 * bid set anyone can re-run it against).
 *
 * The round holds NO funds and grants NO rights: its entire output is a number
 * (`bumpBps`) and a name (`winner`), which become a cosigned quote the winner
 * carries into its own fill. Everything the settlement will enforce — the
 * maker's band, and the dutch clock under `ClockFlooredQuoteModule` — is
 * enforced regardless of what this produces, so a broken or hostile round costs
 * the maker at most the improvement it would have granted.
 */

/** Wall-clock injection, so tests are deterministic and a service can use a
 *  monotonic source. Unix seconds throughout. */
export type Clock = () => number;

export type RoundStatus = "open" | "settled" | "void";

export interface RoundConfig {
  /** The order being quoted for. Bound into every quote signature. */
  orderHash: Hex;
  /** Unix seconds after which no further bid is accepted. */
  closesAt: number;
  /** First-price or Vickrey. Default Vickrey — see `docs/quote-auctions.md`. */
  rule?: AuctionRule;
  /**
   * Distinct bidders below which the round grants NO concession. Defaults to
   * the SDK's rule-dependent default (2 for Vickrey). A ring that shows up
   * alone gets the maker's ambition, not the reserve.
   */
  minBidders?: number;
  /** Cap on retained bids; a public write path needs a bound. Default 256. */
  maxBids?: number;
}

export interface BidReceipt {
  accepted: boolean;
  reason?: string;
  /** Bids retained for this round after this submission. */
  bids: number;
}

/**
 * The auditable record of a settled round.
 *
 * Publishing this is what makes an operator accountable WITHOUT any proving
 * system: `bids` are the openings, and anyone can feed them back through
 * {@link SettledRound.check} (or the SDK's `verifyOutcome`) and confirm the
 * winner and the price. It does NOT prove the operator published every bid it
 * received — censorship is the residual trust, and the fix for that is a public
 * commitment log, not a bigger receipt.
 */
export interface SettledRound {
  orderHash: Hex;
  outcome: AuctionOutcome;
  /** Every bid the round counted, in submission order. */
  bids: readonly QuoteBid[];
  settledAt: number;
}

export class AuctionRound {
  readonly config: Required<Pick<RoundConfig, "orderHash" | "closesAt">> & RoundConfig;
  private readonly bids: QuoteBid[] = [];
  private readonly seen = new Set<string>();
  private settled: SettledRound | undefined;
  private voided = false;

  constructor(config: RoundConfig, private readonly now: Clock) {
    if (!Number.isFinite(config.closesAt)) throw new Error("closesAt must be a unix timestamp");
    this.config = { maxBids: 256, ...config };
  }

  get status(): RoundStatus {
    if (this.voided) return "void";
    return this.settled ? "settled" : "open";
  }

  get isClosed(): boolean {
    return this.now() >= this.config.closesAt;
  }

  get result(): SettledRound | undefined {
    return this.settled;
  }

  /** Every bid counted so far. Exposed for a live "N bidders" display; the
   *  auditable copy is {@link SettledRound.bids}. */
  get submissions(): readonly QuoteBid[] {
    return this.bids;
  }

  /**
   * Accept a bid. Permissionless: anyone may submit, and a bad submission is
   * REJECTED rather than throwing, so one malformed bidder cannot void a round
   * for everyone else.
   *
   * A filler may re-bid; the round keeps every submission and the selection
   * rule collapses them to that filler's best. Exact duplicates are dropped so
   * a replayed message cannot inflate the bidder count.
   */
  submit(bid: QuoteBid): BidReceipt {
    if (this.settled) return { accepted: false, reason: "round already settled", bids: this.bids.length };
    if (this.voided) return { accepted: false, reason: "round void", bids: this.bids.length };
    if (this.isClosed) return { accepted: false, reason: "round closed", bids: this.bids.length };
    if (this.bids.length >= (this.config.maxBids ?? 256)) {
      return { accepted: false, reason: "round at capacity", bids: this.bids.length };
    }
    if (!Number.isInteger(bid.bumpBps) || bid.bumpBps < 0 || bid.bumpBps > 10_000) {
      return { accepted: false, reason: "bumpBps must be an integer in [0, 10000]", bids: this.bids.length };
    }
    if (!/^0x[0-9a-fA-F]{40}$/.test(bid.filler)) {
      return { accepted: false, reason: "filler is not an address", bids: this.bids.length };
    }
    const key = `${bid.filler.toLowerCase()}:${bid.bumpBps}:${bid.commitment ?? ""}`;
    if (this.seen.has(key)) return { accepted: false, reason: "duplicate bid", bids: this.bids.length };
    this.seen.add(key);
    this.bids.push(bid);
    return { accepted: true, bids: this.bids.length };
  }

  /**
   * Run the selection rule and freeze the round.
   *
   * Returns `undefined` when nothing was biddable — the caller should sign
   * nothing at all, which under `ClockFlooredQuoteModule` leaves the order
   * pricing on its dutch clock. That is DIFFERENT from a thin round, which
   * settles with `bumpBps: 0`: signing "you may fill at the maker's ambition"
   * and signing nothing are different messages to a filler.
   */
  settle(): SettledRound | undefined {
    if (this.settled) return this.settled;
    if (this.voided) return undefined;
    const outcome = selectQuote(this.bids, {
      ...(this.config.rule ? { rule: this.config.rule } : {}),
      ...(this.config.minBidders !== undefined ? { minBidders: this.config.minBidders } : {}),
    });
    if (outcome === null) return undefined;
    this.settled = { orderHash: this.config.orderHash, outcome, bids: [...this.bids], settledAt: this.now() };
    return this.settled;
  }

  /** Abandon the round without settling — a cancelled order, a filled order. */
  void(): void {
    if (!this.settled) this.voided = true;
  }
}

/**
 * Re-run a published round's selection over its published bids.
 *
 * This is the accountability primitive: a filler that lost, or a maker checking
 * its operator, calls this and gets a yes/no with no trust in the operator at
 * all. What it CANNOT detect is a bid that never made it into `bids` — see the
 * note on {@link SettledRound}.
 */
export function checkRound(round: SettledRound, opts?: { minBidders?: number }): boolean {
  return verifyOutcome(round.bids, round.outcome, {
    ...(opts?.minBidders !== undefined ? { minBidders: opts.minBidders } : {}),
  });
}

/** The winner's address when a round granted a concession, else `undefined`. */
export function winnerOf(round: SettledRound): Address | undefined {
  return round.outcome.bidders > 0 ? round.outcome.winner : undefined;
}
