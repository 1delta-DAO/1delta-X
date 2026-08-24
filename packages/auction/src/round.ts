import {
  selectQuote,
  verifyBid,
  verifyOutcome,
  type AuctionOutcome,
  type AuctionRule,
  type QuoteBid,
  type QuoteBinding,
  type SignedBid,
} from "@1delta-x/sdk";
import type { Address, Hex } from "viem";

/**
 * One quote auction, as a state machine.
 *
 * OPEN → (signed bids arrive, permissionlessly) → SETTLED (an outcome, and a
 * signed bid set anyone can re-run it against).
 *
 * The round holds NO funds and grants NO rights: its entire output is a number
 * (`bumpBps`) and a name (`winner`), which become a cosigned quote the winner
 * carries into its own fill. Everything the settlement will enforce — the
 * maker's band, and the dutch clock under `ClockFlooredQuoteModule` — is
 * enforced regardless of what this produces, so a broken or hostile round costs
 * the maker at most the improvement it would have granted.
 *
 * ⚠ EVERY BID MUST BE SIGNED BY THE FILLER IT NAMES, and there is no flag to
 * turn that off. An unsigned bid set is forgeable by a rival (bid as someone
 * else, displace the real winner, never fill) AND by the operator (fabricate a
 * runner-up to justify a worse Vickrey price — the classic shill attack, which
 * an outcome check alone cannot see). See {@link SignedBid} in the SDK.
 */

/** Wall-clock injection, so tests are deterministic and a service can use a
 *  monotonic source. Unix seconds throughout. */
export type Clock = () => number;

export type RoundStatus = "open" | "settled" | "void";

export interface RoundConfig {
  /** The order being quoted for. Bound into every bid and quote signature. */
  orderHash: Hex;
  /** Unix seconds after which no further bid is accepted. Also bound into every
   *  bid signature, so a bid cannot be lifted into a later round. */
  closesAt: number;
  /** The quote module instance + chain every bid and quote is bound to. */
  binding: QuoteBinding;
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
 * system: `bids` are the signed openings, and anyone can feed them back through
 * {@link checkRound} to confirm both that every bid is genuine and that the
 * winner and price follow from them.
 *
 * It does NOT prove the operator published every bid it RECEIVED — censorship
 * is the residual trust, and the fix for that is a public commitment log, not a
 * bigger receipt.
 */
export interface SettledRound {
  orderHash: Hex;
  binding: QuoteBinding;
  outcome: AuctionOutcome;
  /** Every bid the round counted, with signatures, in submission order. */
  bids: readonly SignedBid[];
  settledAt: number;
  rule: AuctionRule;
  minBidders?: number;
}

export class AuctionRound {
  readonly config: RoundConfig;
  private readonly bids: SignedBid[] = [];
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
  get submissions(): readonly SignedBid[] {
    return this.bids;
  }

  /**
   * Accept a SIGNED bid. Permissionless: anyone may submit, and a bad
   * submission is REJECTED rather than thrown, so one malformed or forged
   * bidder cannot void a round for everyone else.
   *
   * A filler may re-bid; the selection rule collapses its submissions to its
   * best. Exact duplicates are dropped so a replayed message cannot inflate the
   * bidder count — which matters, because the bidder count gates whether any
   * concession is granted at all.
   */
  async submit(bid: SignedBid): Promise<BidReceipt> {
    if (this.settled) return { accepted: false, reason: "round already settled", bids: this.bids.length };
    if (this.voided) return { accepted: false, reason: "round void", bids: this.bids.length };
    if (this.isClosed) return { accepted: false, reason: "round closed", bids: this.bids.length };
    if (this.bids.length >= (this.config.maxBids ?? 256)) {
      return { accepted: false, reason: "round at capacity", bids: this.bids.length };
    }
    // The bid's own binding must be THIS round's, or its signature authenticates
    // a commitment to something else.
    if (bid.orderHash.toLowerCase() !== this.config.orderHash.toLowerCase()) {
      return { accepted: false, reason: "bid is for another order", bids: this.bids.length };
    }
    if (bid.closesAt !== this.config.closesAt) {
      return { accepted: false, reason: "bid is for another round", bids: this.bids.length };
    }
    // RESERVE THE KEY BEFORE AWAITING. `verifyBid` yields (viem's `recoverAddress`
    // is async), so a check-then-insert around it is a genuine interleaving hole:
    // two concurrent `submit` calls carrying the SAME signed bid both observe an
    // empty set and both push. Selection would survive that — it collapses per
    // filler — but {checkRound} rejects a duplicate, so any bidder could publish
    // the same bid twice and make every third-party audit of the round fail.
    const key = `${bid.filler.toLowerCase()}:${bid.bumpBps}`;
    if (this.seen.has(key)) return { accepted: false, reason: "duplicate bid", bids: this.bids.length };
    this.seen.add(key);

    const check = await verifyBid(bid, this.config.binding);
    if (!check.ok) {
      // Release it again: a bid that failed verification was never in the round,
      // and the real bidder must still be able to submit at this bump.
      this.seen.delete(key);
      return { accepted: false, reason: check.reason ?? "invalid bid", bids: this.bids.length };
    }

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
    const outcome = selectQuote(this.bids as readonly QuoteBid[], {
      ...(this.config.rule ? { rule: this.config.rule } : {}),
      ...(this.config.minBidders !== undefined ? { minBidders: this.config.minBidders } : {}),
    });
    if (outcome === null) return undefined;
    this.settled = {
      orderHash: this.config.orderHash,
      binding: this.config.binding,
      outcome,
      bids: [...this.bids],
      settledAt: this.now(),
      rule: outcome.rule,
      ...(this.config.minBidders !== undefined ? { minBidders: this.config.minBidders } : {}),
    };
    return this.settled;
  }

  /** Abandon the round without settling — a cancelled order, a filled order. */
  void(): void {
    if (!this.settled) this.voided = true;
  }
}

export interface RoundCheck {
  ok: boolean;
  reason?: string;
}

/**
 * Audit a published round against the policy the AUDITOR was promised.
 *
 * THREE independent checks, and all three are needed:
 *  1. POLICY — the round was settled under the rule and quorum the caller
 *     expected.
 *  2. AUTHENTICITY — every published bid carries a signature recovering to the
 *     filler it names. Without this, an operator can fabricate a runner-up to
 *     justify a worse second price and the arithmetic below still passes.
 *  3. ARITHMETIC — the winner and the price follow from that bid set under that
 *     rule.
 *
 * ⚠ `expected` IS REQUIRED, AND IS THE POINT. Signatures make the BIDS
 * unforgeable; they say nothing about the RULE those bids were scored under, and
 * that rule is operator-authored metadata sitting in the same record being
 * audited. Re-running the arithmetic with `round.rule` and `round.minBidders`
 * checks the operator against itself: publish `minBidders: 1` with one colluding
 * 9000-bps bid, or swap `first-price` for `second-price`, and every bid verifies
 * and the arithmetic follows. The published fields are still checked — against
 * `expected` — so a swap is now a visible mismatch rather than a silent pass.
 *
 * Still cannot detect a bid the operator RECEIVED and did not publish.
 *
 * ⚠ NOR CAN IT DETECT A SYBIL. `verifyBid` proves a bid is not IMPERSONATED; it
 * does not prove the filler is a real, capitalised participant, and nothing here
 * gates who may bid. An operator holding N throwaway keys can still manufacture
 * a runner-up to move a Vickrey price, or satisfy `minBidders` alone. Closing
 * that needs a filler identity set the auditor can evaluate independently —
 * a registry, an allowlist, or a bond — which is a deployment concern, not one
 * this function can decide. See docs/quote-auctions.md.
 *
 * @param expected the rule and quorum the caller agreed to. A round settled
 *        under anything else is rejected, whatever its own record claims.
 */
export async function checkRound(
  round: SettledRound,
  expected: { rule: AuctionRule; minBidders?: number },
): Promise<RoundCheck> {
  if (round.rule !== expected.rule) {
    return { ok: false, reason: `round settled under "${round.rule}", expected "${expected.rule}"` };
  }
  if (round.outcome.rule !== expected.rule) {
    return { ok: false, reason: `outcome settled under "${round.outcome.rule}", expected "${expected.rule}"` };
  }
  // `undefined` on either side means "the library default", and the defaults
  // agree — so only a stated disagreement is a mismatch.
  if (
    expected.minBidders !== undefined &&
    round.minBidders !== undefined &&
    round.minBidders !== expected.minBidders
  ) {
    return { ok: false, reason: `round used minBidders ${round.minBidders}, expected ${expected.minBidders}` };
  }
  if (expected.minBidders !== undefined && round.minBidders === undefined) {
    return { ok: false, reason: `round states no minBidders, expected ${expected.minBidders}` };
  }
  const seen = new Set<string>();
  for (let i = 0; i < round.bids.length; i++) {
    const bid = round.bids[i]!;
    if (bid.orderHash.toLowerCase() !== round.orderHash.toLowerCase()) {
      return { ok: false, reason: `bid ${i} is for another order` };
    }
    const check = await verifyBid(bid, round.binding);
    if (!check.ok) return { ok: false, reason: `bid ${i}: ${check.reason}` };
    const key = `${bid.filler.toLowerCase()}:${bid.bumpBps}`;
    if (seen.has(key)) return { ok: false, reason: `bid ${i} is a duplicate` };
    seen.add(key);
  }
  // The AUDITOR's policy, not the record's — the record's has already been
  // checked to match it above, so using `expected` here makes the arithmetic
  // independent of anything the operator wrote.
  const arithmetic = verifyOutcome(round.bids as readonly QuoteBid[], round.outcome, {
    rule: expected.rule,
    ...(expected.minBidders !== undefined ? { minBidders: expected.minBidders } : {}),
  });
  return arithmetic ? { ok: true } : { ok: false, reason: "outcome does not follow from the published bids" };
}

/** The winner's address when a round granted a concession, else `undefined`. */
export function winnerOf(round: SettledRound): Address | undefined {
  return round.outcome.bidders > 0 ? round.outcome.winner : undefined;
}
