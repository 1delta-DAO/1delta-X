import { describe, expect, it } from "vitest";
import { privateKeyToAccount } from "viem/accounts";
import type { Address, Hex } from "viem";

import { decodeQuoteTakerData, verifyQuote, ANY_FILLER, type QuoteBinding } from "@1delta-x/sdk";
import { AuctionRound, Auctioneer, checkRound } from "../src/index";

const cosigner = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");

const A = "0x00000000000000000000000000000000000000aa" as Address;
const B = "0x00000000000000000000000000000000000000bb" as Address;
const C = "0x00000000000000000000000000000000000000cc" as Address;
const ORDER = `0x${"11".repeat(32)}` as Hex;

const binding: QuoteBinding = { module: "0x00000000000000000000000000000000000000cc", chainId: 31 };

/** Controllable clock: rounds are time-boxed and tests must not race wall time. */
function clockAt(t = 1_000): { now: () => number; set: (v: number) => void } {
  let cur = t;
  return { now: () => cur, set: (v) => (cur = v) };
}

const bid = (filler: Address, bumpBps: number) => ({ filler, bumpBps });

describe("AuctionRound", () => {
  it("accepts bids while open and settles to the lowest bid's winner", () => {
    const clock = clockAt();
    const round = new AuctionRound({ orderHash: ORDER, closesAt: 1_060 }, clock.now);
    expect(round.submit(bid(A, 4_000)).accepted).toBe(true);
    expect(round.submit(bid(B, 1_200)).accepted).toBe(true);

    const settled = round.settle()!;
    expect(settled.outcome.winner).toBe(B);
    // Vickrey by default: the runner-up's bump, not the winner's own.
    expect(settled.outcome.bumpBps).toBe(4_000);
    expect(round.status).toBe("settled");
  });

  it("refuses bids once the close time has passed", () => {
    const clock = clockAt();
    const round = new AuctionRound({ orderHash: ORDER, closesAt: 1_060 }, clock.now);
    clock.set(1_060);
    const receipt = round.submit(bid(A, 100));
    expect(receipt.accepted).toBe(false);
    expect(receipt.reason).toBe("round closed");
  });

  it("rejects a malformed bid without voiding the round for everyone else", () => {
    const round = new AuctionRound({ orderHash: ORDER, closesAt: 1_060 }, clockAt().now);
    expect(round.submit(bid(A, 20_000)).accepted).toBe(false);
    expect(round.submit({ filler: "0xnope" as Address, bumpBps: 10 }).accepted).toBe(false);
    expect(round.submit(bid(B, 500)).accepted).toBe(true);
    expect(round.settle()!.outcome.winner).toBe(B);
  });

  it("drops an exactly-duplicated bid so a replay cannot inflate the bidder count", () => {
    const round = new AuctionRound({ orderHash: ORDER, closesAt: 1_060 }, clockAt().now);
    round.submit(bid(A, 500));
    expect(round.submit(bid(A, 500)).reason).toBe("duplicate bid");
    round.submit(bid(B, 900));
    expect(round.settle()!.outcome.bidders).toBe(2);
  });

  it("lets a filler improve its own bid", () => {
    const round = new AuctionRound({ orderHash: ORDER, closesAt: 1_060 }, clockAt().now);
    round.submit(bid(A, 5_000));
    round.submit(bid(A, 900)); // re-bid, better
    round.submit(bid(B, 3_000));
    const settled = round.settle()!;
    expect(settled.outcome.winner).toBe(A);
    expect(settled.outcome.bidders).toBe(2);
  });

  it("grants no concession to a lone bidder", () => {
    const round = new AuctionRound({ orderHash: ORDER, closesAt: 1_060 }, clockAt().now);
    round.submit(bid(A, 500));
    const settled = round.settle()!;
    expect(settled.outcome.bidders).toBe(1);
    expect(settled.outcome.bumpBps).toBe(0);
  });

  it("returns nothing when no bid was usable", () => {
    const round = new AuctionRound({ orderHash: ORDER, closesAt: 1_060 }, clockAt().now);
    round.submit(bid(A, 99_999));
    expect(round.settle()).toBeUndefined();
  });

  it("bounds retained bids — a public write path needs a cap", () => {
    const round = new AuctionRound({ orderHash: ORDER, closesAt: 1_060, maxBids: 2 }, clockAt().now);
    round.submit(bid(A, 100));
    round.submit(bid(B, 200));
    expect(round.submit(bid(C, 300)).reason).toBe("round at capacity");
  });

  it("is idempotent on settle and refuses late bids", () => {
    const round = new AuctionRound({ orderHash: ORDER, closesAt: 1_060 }, clockAt().now);
    round.submit(bid(A, 100));
    round.submit(bid(B, 200));
    const first = round.settle()!;
    expect(round.settle()).toBe(first);
    expect(round.submit(bid(C, 1)).reason).toBe("round already settled");
  });
});

describe("checkRound — accountability with no proving system", () => {
  it("accepts an honestly settled round", () => {
    const round = new AuctionRound({ orderHash: ORDER, closesAt: 1_060 }, clockAt().now);
    round.submit(bid(A, 4_000));
    round.submit(bid(B, 1_200));
    expect(checkRound(round.settle()!)).toBe(true);
  });

  it("catches an operator that charged the winner's own bid under Vickrey", () => {
    // The shill shape: keep the winner, pocket the spread to the runner-up.
    const round = new AuctionRound({ orderHash: ORDER, closesAt: 1_060 }, clockAt().now);
    round.submit(bid(A, 4_000));
    round.submit(bid(B, 1_200));
    const settled = round.settle()!;
    const tampered = { ...settled, outcome: { ...settled.outcome, bumpBps: 1_200 } };
    expect(checkRound(tampered)).toBe(false);
  });

  it("catches a swapped winner", () => {
    const round = new AuctionRound({ orderHash: ORDER, closesAt: 1_060 }, clockAt().now);
    round.submit(bid(A, 4_000));
    round.submit(bid(B, 1_200));
    const settled = round.settle()!;
    expect(checkRound({ ...settled, outcome: { ...settled.outcome, winner: A } })).toBe(false);
  });
});

describe("Auctioneer — bids in, one signed quote out", () => {
  it("mints a quote the winner can carry straight into its fill", async () => {
    const clock = clockAt();
    const auctioneer = new Auctioneer({ binding, signer: cosigner, now: clock.now, quoteTtlSeconds: 60 });
    auctioneer.open({ orderHash: ORDER, closesAt: 1_060 });
    auctioneer.submit(ORDER, bid(A, 4_000));
    auctioneer.submit(ORDER, bid(B, 1_200));

    const { round, quote } = (await auctioneer.settle(ORDER))!;
    expect(round.outcome.winner).toBe(B);
    expect(quote).toBeDefined();
    expect(quote!.bumpBps).toBe(4_000); // Vickrey price
    expect(quote!.filler).toBe(B); // bound to the winner
    expect(quote!.deadline).toBe(1_060n);

    // The quote verifies exactly as the module will check it.
    expect(await verifyQuote(quote!, { cosigner: cosigner.address, filler: B, now: 1_000n })).toEqual({ ok: true });
    // ...and the takerData is the bytes the fill takes.
    expect(decodeQuoteTakerData(quote!.takerData).quote.bumpBps).toBe(4_000);
  });

  it("binds the quote to the winner, so a loser cannot present it", async () => {
    const auctioneer = new Auctioneer({ binding, signer: cosigner, now: clockAt().now });
    auctioneer.open({ orderHash: ORDER, closesAt: 1_060 });
    auctioneer.submit(ORDER, bid(A, 4_000));
    auctioneer.submit(ORDER, bid(B, 1_200));
    const { quote } = (await auctioneer.settle(ORDER))!;
    const res = await verifyQuote(quote!, { cosigner: cosigner.address, filler: A, now: 1_000n });
    expect(res.reason).toBe("QuoteNotForFiller");
  });

  it("can mint an OPEN quote when relaying matters more than exclusivity", async () => {
    const auctioneer = new Auctioneer({ binding, signer: cosigner, now: clockAt().now, bindToWinner: false });
    auctioneer.open({ orderHash: ORDER, closesAt: 1_060 });
    auctioneer.submit(ORDER, bid(A, 4_000));
    auctioneer.submit(ORDER, bid(B, 1_200));
    const { quote } = (await auctioneer.settle(ORDER))!;
    expect(quote!.filler).toBe(ANY_FILLER);
    expect(await verifyQuote(quote!, { cosigner: cosigner.address, filler: C, now: 1_000n })).toEqual({ ok: true });
  });

  it("signs NOTHING for a thin round — the order stays on its dutch clock", async () => {
    const auctioneer = new Auctioneer({ binding, signer: cosigner, now: clockAt().now });
    auctioneer.open({ orderHash: ORDER, closesAt: 1_060 });
    auctioneer.submit(ORDER, bid(A, 500)); // lone bidder
    const settled = (await auctioneer.settle(ORDER))!;
    expect(settled.round.outcome.bumpBps).toBe(0);
    expect(settled.quote).toBeUndefined();
  });

  it("rejects a bid for an order with no open round", () => {
    const auctioneer = new Auctioneer({ binding, signer: cosigner, now: clockAt().now });
    expect(auctioneer.submit(ORDER, bid(A, 100)).reason).toBe("no such round");
  });

  it("does not discard bids when a round is re-opened", () => {
    const auctioneer = new Auctioneer({ binding, signer: cosigner, now: clockAt().now });
    auctioneer.open({ orderHash: ORDER, closesAt: 1_060 });
    auctioneer.submit(ORDER, bid(A, 100));
    auctioneer.open({ orderHash: ORDER, closesAt: 1_060 });
    expect(auctioneer.round(ORDER)!.submissions).toHaveLength(1);
  });

  it("settles every due round on a service tick, and prunes stale ones", async () => {
    const clock = clockAt();
    const auctioneer = new Auctioneer({ binding, signer: cosigner, now: clock.now });
    const second = `0x${"22".repeat(32)}` as Hex;
    auctioneer.open({ orderHash: ORDER, closesAt: 1_060 });
    auctioneer.open({ orderHash: second, closesAt: 9_999 });
    auctioneer.submit(ORDER, bid(A, 4_000));
    auctioneer.submit(ORDER, bid(B, 1_200));

    clock.set(1_060);
    const due = await auctioneer.settleDue();
    expect(due).toHaveLength(1); // only the closed round
    expect(due[0]!.round.orderHash).toBe(ORDER);

    clock.set(1_060 + 7_200);
    expect(auctioneer.prune(3_600)).toBe(1); // the settled one; the open one stays
    expect(auctioneer.round(ORDER)).toBeUndefined();
    expect(auctioneer.round(second)).toBeDefined();
  });

  it("first-price mode charges the winner its own bid", async () => {
    const auctioneer = new Auctioneer({ binding, signer: cosigner, now: clockAt().now });
    auctioneer.open({ orderHash: ORDER, closesAt: 1_060, rule: "first-price" });
    auctioneer.submit(ORDER, bid(A, 4_000));
    auctioneer.submit(ORDER, bid(B, 1_200));
    const { quote } = (await auctioneer.settle(ORDER))!;
    expect(quote!.bumpBps).toBe(1_200);
  });
});
