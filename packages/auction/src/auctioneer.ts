import {
  ANY_FILLER,
  signQuote,
  type QuoteBinding,
  type QuoteBid,
  type QuoteSigner,
  type SignedQuote,
} from "@1delta-x/sdk";
import type { Hex } from "viem";

import { AuctionRound, type BidReceipt, type Clock, type RoundConfig, type SettledRound } from "./round";

/**
 * The operator side of the quote channel: hold open rounds, take bids from
 * anyone, and turn a settled round into the ONE artifact that reaches the chain
 * — a cosigned quote the winner presents in its own fill.
 *
 * What this deliberately is NOT: a venue. It never holds funds, never sequences
 * fills, and cannot stop anyone filling the order at its dutch price while a
 * round is open. Losing a round costs a filler nothing — no gas, no locked
 * capital — because a losing bid never reaches the chain.
 *
 * Trust: the operator sees every bid and could omit one before publishing. The
 * bound on that is the settlement, not this class — a quote can only move the
 * price inside the maker's signed band, and under `ClockFlooredQuoteModule` no
 * further than the dutch clock, so a rigged round degrades to a plain dutch
 * fill. See `docs/quote-auctions.md`.
 */
export interface AuctioneerConfig {
  /** The quote module instance and chain every quote is bound to. */
  binding: QuoteBinding;
  /** Signs the raw quote digest. Its address must be the module's COSIGNER. */
  signer: QuoteSigner;
  /** How long a signed quote stays presentable, in seconds. Default 60. */
  quoteTtlSeconds?: number;
  /**
   * Bind the quote to the winning filler (default) or mint an OPEN quote any
   * filler may present. Open quotes are simpler to relay but transferable —
   * the winner's improvement can be taken by whoever sees the bytes first.
   */
  bindToWinner?: boolean;
  now?: Clock;
}

export interface SettledAuction {
  round: SettledRound;
  /** `undefined` when the round granted no concession — nothing to sign. */
  quote?: SignedQuote;
}

export class Auctioneer {
  private readonly rounds = new Map<Hex, AuctionRound>();
  private readonly now: Clock;

  constructor(private readonly config: AuctioneerConfig) {
    this.now = config.now ?? (() => Math.floor(Date.now() / 1000));
  }

  /** Open a round for an order. Re-opening a live round returns the existing
   *  one rather than resetting it — a duplicate open must not discard bids. */
  open(config: RoundConfig): AuctionRound {
    const existing = this.rounds.get(config.orderHash);
    if (existing && existing.status === "open") return existing;
    const round = new AuctionRound(config, this.now);
    this.rounds.set(config.orderHash, round);
    return round;
  }

  round(orderHash: Hex): AuctionRound | undefined {
    return this.rounds.get(orderHash);
  }

  /** Submit a bid to an open round. Unknown order ⇒ rejected, not thrown. */
  submit(orderHash: Hex, bid: QuoteBid): BidReceipt {
    const round = this.rounds.get(orderHash);
    if (!round) return { accepted: false, reason: "no such round", bids: 0 };
    return round.submit(bid);
  }

  /**
   * Settle a round and mint its quote.
   *
   * A round that granted no concession (`bumpBps === 0` from the thin-bidder
   * guard) settles WITHOUT a quote: signing a zero-bump quote would pin the
   * price at the maker's ambition and, under the clock-floored module, throw
   * away the decay ramp the filler was going to need. Signing nothing leaves
   * the order on its clock, which is the correct "the auction found nothing"
   * outcome.
   */
  async settle(orderHash: Hex): Promise<SettledAuction | undefined> {
    const round = this.rounds.get(orderHash);
    if (!round) return undefined;
    const settled = round.settle();
    if (!settled) return undefined;
    if (settled.outcome.bumpBps === 0) return { round: settled };

    const ttl = this.config.quoteTtlSeconds ?? 60;
    const quote = await signQuote(
      this.config.signer,
      {
        orderHash,
        filler: this.config.bindToWinner === false ? ANY_FILLER : settled.outcome.winner,
        bumpBps: settled.outcome.bumpBps,
        deadline: BigInt(this.now() + ttl),
      },
      this.config.binding,
    );
    return { round: settled, quote };
  }

  /** Settle every round whose close time has passed. For a service tick. */
  async settleDue(): Promise<SettledAuction[]> {
    const out: SettledAuction[] = [];
    for (const [orderHash, round] of this.rounds) {
      if (round.status !== "open" || !round.isClosed) continue;
      const settled = await this.settle(orderHash);
      if (settled) out.push(settled);
    }
    return out;
  }

  /** Drop settled/void rounds older than `olderThanSeconds`. A long-running
   *  operator needs this or the map is a leak with a public write path. */
  prune(olderThanSeconds = 3600): number {
    const cutoff = this.now() - olderThanSeconds;
    let dropped = 0;
    for (const [hash, round] of this.rounds) {
      const done = round.status !== "open";
      const stale = round.result ? round.result.settledAt < cutoff : round.config.closesAt < cutoff;
      if (done && stale) {
        this.rounds.delete(hash);
        dropped++;
      }
    }
    return dropped;
  }
}
