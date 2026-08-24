import { describe, expect, it } from "vitest";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";
import type { Address, Hex } from "viem";

import {
  ANY_FILLER,
  bidDigest,
  decodeQuoteTakerData,
  signBid,
  verifyQuote,
  type QuoteBinding,
  type SignedBid,
} from "@1delta-x/sdk";
import { AuctionRound, Auctioneer, checkRound } from "../src/index";

const cosigner = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
// Three real solvers with real keys — bids are signed now, so tests need them.
const A = privateKeyToAccount("0x0000000000000000000000000000000000000000000000000000000000000a11");
const B = privateKeyToAccount("0x0000000000000000000000000000000000000000000000000000000000000b22");
const C = privateKeyToAccount("0x0000000000000000000000000000000000000000000000000000000000000c33");

const ORDER = `0x${"11".repeat(32)}` as Hex;
const CLOSES = 1_060;
const binding: QuoteBinding = { module: "0x00000000000000000000000000000000000000cc", chainId: 31 };

/** Controllable clock: rounds are time-boxed and tests must not race wall time. */
function clockAt(t = 1_000): { now: () => number; set: (v: number) => void } {
  let cur = t;
  return { now: () => cur, set: (v) => (cur = v) };
}

const bid = (who: PrivateKeyAccount, bumpBps: number, closesAt = CLOSES): Promise<SignedBid> =>
  signBid(who, { orderHash: ORDER, filler: who.address, bumpBps, closesAt }, binding);

describe("AuctionRound", () => {
  it("accepts signed bids and settles to the lowest bid's winner", async () => {
    const round = new AuctionRound({ orderHash: ORDER, closesAt: CLOSES, binding }, clockAt().now);
    expect((await round.submit(await bid(A, 4_000))).accepted).toBe(true);
    expect((await round.submit(await bid(B, 1_200))).accepted).toBe(true);

    const settled = round.settle()!;
    expect(settled.outcome.winner).toBe(B.address);
    // Vickrey by default: the runner-up's bump, not the winner's own.
    expect(settled.outcome.bumpBps).toBe(4_000);
  });

  // ──────────────── the forgery cases this whole layer exists for ────────────────

  it("REJECTS a rival bidding in another solver's name", async () => {
    // C wants B out: it submits an aggressive bump as B, wins, never fills.
    const round = new AuctionRound({ orderHash: ORDER, closesAt: CLOSES, binding }, clockAt().now);
    const payload = { orderHash: ORDER, filler: B.address, bumpBps: 1, closesAt: CLOSES };
    const forged: SignedBid = { ...payload, signature: await C.sign({ hash: bidDigest(payload, binding) }) };

    const receipt = await round.submit(forged);
    expect(receipt.accepted).toBe(false);
    expect(receipt.reason).toMatch(/forged/);
    expect(receipt.bids).toBe(0);
  });

  it("REJECTS a bid whose bump was edited after signing", async () => {
    const round = new AuctionRound({ orderHash: ORDER, closesAt: CLOSES, binding }, clockAt().now);
    const real = await bid(A, 4_000);
    expect((await round.submit({ ...real, bumpBps: 50 })).accepted).toBe(false);
  });

  it("REJECTS a bid signed for a different round or order", async () => {
    const round = new AuctionRound({ orderHash: ORDER, closesAt: CLOSES, binding }, clockAt().now);
    expect((await round.submit(await bid(A, 100, 9_999))).reason).toBe("bid is for another round");

    const otherOrder = await signBid(
      A,
      { orderHash: `0x${"22".repeat(32)}`, filler: A.address, bumpBps: 100, closesAt: CLOSES },
      binding,
    );
    expect((await round.submit(otherOrder)).reason).toBe("bid is for another order");
  });

  it("REJECTS a bid signed for another module instance", async () => {
    const round = new AuctionRound({ orderHash: ORDER, closesAt: CLOSES, binding }, clockAt().now);
    const elsewhere = await signBid(
      A,
      { orderHash: ORDER, filler: A.address, bumpBps: 100, closesAt: CLOSES },
      { ...binding, module: "0x00000000000000000000000000000000000000dd" },
    );
    expect((await round.submit(elsewhere)).accepted).toBe(false);
  });

  // ──────────────── round mechanics ────────────────

  it("refuses bids once the close time has passed", async () => {
    const clock = clockAt();
    const round = new AuctionRound({ orderHash: ORDER, closesAt: CLOSES, binding }, clock.now);
    clock.set(CLOSES);
    expect((await round.submit(await bid(A, 100))).reason).toBe("round closed");
  });

  it("rejects one bad bid without voiding the round for everyone else", async () => {
    const round = new AuctionRound({ orderHash: ORDER, closesAt: CLOSES, binding }, clockAt().now);
    await round.submit({ ...(await bid(A, 4_000)), bumpBps: 20_000 });
    expect((await round.submit(await bid(B, 500))).accepted).toBe(true);
    expect(round.settle()!.outcome.winner).toBe(B.address);
  });

  it("drops an exact duplicate so a replay cannot inflate the bidder count", async () => {
    const round = new AuctionRound({ orderHash: ORDER, closesAt: CLOSES, binding }, clockAt().now);
    const b = await bid(A, 500);
    await round.submit(b);
    expect((await round.submit(b)).reason).toBe("duplicate bid");
    await round.submit(await bid(B, 900));
    expect(round.settle()!.outcome.bidders).toBe(2);
  });

  it("lets a filler improve its own bid", async () => {
    const round = new AuctionRound({ orderHash: ORDER, closesAt: CLOSES, binding }, clockAt().now);
    await round.submit(await bid(A, 5_000));
    await round.submit(await bid(A, 900));
    await round.submit(await bid(B, 3_000));
    const settled = round.settle()!;
    expect(settled.outcome.winner).toBe(A.address);
    expect(settled.outcome.bidders).toBe(2);
  });

  it("grants no concession to a lone bidder", async () => {
    const round = new AuctionRound({ orderHash: ORDER, closesAt: CLOSES, binding }, clockAt().now);
    await round.submit(await bid(A, 500));
    const settled = round.settle()!;
    expect(settled.outcome.bidders).toBe(1);
    expect(settled.outcome.bumpBps).toBe(0);
  });

  it("bounds retained bids — a public write path needs a cap", async () => {
    const round = new AuctionRound({ orderHash: ORDER, closesAt: CLOSES, binding, maxBids: 2 }, clockAt().now);
    await round.submit(await bid(A, 100));
    await round.submit(await bid(B, 200));
    expect((await round.submit(await bid(C, 300))).reason).toBe("round at capacity");
  });

  it("is idempotent on settle and refuses late bids", async () => {
    const round = new AuctionRound({ orderHash: ORDER, closesAt: CLOSES, binding }, clockAt().now);
    await round.submit(await bid(A, 100));
    await round.submit(await bid(B, 200));
    const first = round.settle()!;
    expect(round.settle()).toBe(first);
    expect((await round.submit(await bid(C, 1))).reason).toBe("round already settled");
  });
});

describe("checkRound — policy, authenticity AND arithmetic", () => {
  /** What an auditor of these rounds was promised. */
  const EXPECTED = { rule: "second-price" as const };

  async function settledRound() {
    const round = new AuctionRound({ orderHash: ORDER, closesAt: CLOSES, binding }, clockAt().now);
    await round.submit(await bid(A, 4_000));
    await round.submit(await bid(B, 1_200));
    return round.settle()!;
  }

  it("accepts an honestly settled round", async () => {
    expect(await checkRound(await settledRound(), EXPECTED)).toEqual({ ok: true });
  });

  it("CATCHES AN OPERATOR-FABRICATED SHILL BID", async () => {
    // The classic Vickrey attack. The operator has one real bid (B at 1200) and
    // wants to charge a worse second price, so it invents a runner-up. Without
    // bid signatures the arithmetic below would check out perfectly.
    const round = new AuctionRound({ orderHash: ORDER, closesAt: CLOSES, binding }, clockAt().now);
    await round.submit(await bid(B, 1_200));
    const honest = round.settle()!;

    const shill = { orderHash: ORDER, filler: C.address, bumpBps: 8_000, closesAt: CLOSES, signature: "0x" as Hex };
    const rigged = {
      ...honest,
      bids: [...honest.bids, shill],
      outcome: { ...honest.outcome, bumpBps: 8_000, runnerUpBps: 8_000, bidders: 2 },
    };
    const res = await checkRound(rigged, EXPECTED);
    expect(res.ok).toBe(false);
    expect(res.reason).toMatch(/bid 1/);
  });

  it("catches an operator that charged the winner's own bid under Vickrey", async () => {
    const settled = await settledRound();
    const tampered = { ...settled, outcome: { ...settled.outcome, bumpBps: 1_200 } };
    expect((await checkRound(tampered, EXPECTED)).reason).toMatch(/does not follow/);
  });

  it("catches a swapped winner", async () => {
    const settled = await settledRound();
    const tampered = { ...settled, outcome: { ...settled.outcome, winner: A.address } };
    expect((await checkRound(tampered, EXPECTED)).ok).toBe(false);
  });

  it("catches a padded bid set built by replaying one real bid", async () => {
    const settled = await settledRound();
    const padded = { ...settled, bids: [...settled.bids, settled.bids[0]!] };
    expect((await checkRound(padded, EXPECTED)).reason).toMatch(/duplicate/);
  });

  // ── the policy the arithmetic runs under is the AUDITOR'S ──────────────

  it("CATCHES A SWAPPED SELECTION RULE", async () => {
    // Every bid still verifies and the arithmetic still follows — under the rule
    // the OPERATOR published. Re-running with `round.rule` is checking the
    // operator against itself, so this must be caught by the policy check.
    const round = new AuctionRound(
      { orderHash: ORDER, closesAt: CLOSES, binding, rule: "first-price" },
      clockAt().now,
    );
    await round.submit(await bid(A, 4_000));
    await round.submit(await bid(B, 1_200));
    const settled = round.settle()!;

    expect((await checkRound(settled, { rule: "first-price" })).ok).toBe(true);
    expect((await checkRound(settled, EXPECTED)).reason).toMatch(/first-price/);
  });

  it("CATCHES A LOWERED QUORUM", async () => {
    // One colluding bidder at a generous bump. With `minBidders: 1` the outcome
    // follows perfectly; the auditor expected 2, and a thin round to settle at 0.
    const round = new AuctionRound(
      { orderHash: ORDER, closesAt: CLOSES, binding, minBidders: 1 },
      clockAt().now,
    );
    await round.submit(await bid(C, 9_000));
    const settled = round.settle()!;

    expect(settled.outcome.bumpBps).toBe(9_000);
    expect((await checkRound(settled, { rule: "second-price", minBidders: 2 })).reason).toMatch(/minBidders/);
  });

  it("rejects a round that states no quorum when one was expected", async () => {
    const settled = await settledRound();
    expect((await checkRound(settled, { rule: "second-price", minBidders: 2 })).reason).toMatch(/no minBidders/);
  });
});

describe("Auctioneer — bids in, one signed quote out", () => {
  it("mints a quote the winner can carry straight into its fill", async () => {
    const clock = clockAt();
    const auctioneer = new Auctioneer({ binding, signer: cosigner, now: clock.now, quoteTtlSeconds: 60 });
    auctioneer.open({ orderHash: ORDER, closesAt: CLOSES });
    await auctioneer.submit(ORDER, await bid(A, 4_000));
    await auctioneer.submit(ORDER, await bid(B, 1_200));

    const { round, quote } = (await auctioneer.settle(ORDER))!;
    expect(round.outcome.winner).toBe(B.address);
    expect(quote!.bumpBps).toBe(4_000); // Vickrey price
    expect(quote!.filler).toBe(B.address); // bound to the winner
    expect(await verifyQuote(quote!, { cosigner: cosigner.address, filler: B.address, now: 1_000n })).toEqual({
      ok: true,
    });
    expect(decodeQuoteTakerData(quote!.takerData).quote.bumpBps).toBe(4_000);
    // The published round is self-auditing.
    expect(await checkRound(round, { rule: "second-price" })).toEqual({ ok: true });
  });

  it("binds the quote to the winner, so a loser cannot present it", async () => {
    const auctioneer = new Auctioneer({ binding, signer: cosigner, now: clockAt().now });
    auctioneer.open({ orderHash: ORDER, closesAt: CLOSES });
    await auctioneer.submit(ORDER, await bid(A, 4_000));
    await auctioneer.submit(ORDER, await bid(B, 1_200));
    const { quote } = (await auctioneer.settle(ORDER))!;
    expect((await verifyQuote(quote!, { cosigner: cosigner.address, filler: A.address, now: 1_000n })).reason).toBe(
      "QuoteNotForFiller",
    );
  });

  it("can mint an OPEN quote when relaying matters more than exclusivity", async () => {
    const auctioneer = new Auctioneer({ binding, signer: cosigner, now: clockAt().now, bindToWinner: false });
    auctioneer.open({ orderHash: ORDER, closesAt: CLOSES });
    await auctioneer.submit(ORDER, await bid(A, 4_000));
    await auctioneer.submit(ORDER, await bid(B, 1_200));
    const { quote } = (await auctioneer.settle(ORDER))!;
    expect(quote!.filler).toBe(ANY_FILLER);
    expect(await verifyQuote(quote!, { cosigner: cosigner.address, filler: C.address, now: 1_000n })).toEqual({
      ok: true,
    });
  });

  it("signs NOTHING for a thin round — the order stays on its dutch clock", async () => {
    const auctioneer = new Auctioneer({ binding, signer: cosigner, now: clockAt().now });
    auctioneer.open({ orderHash: ORDER, closesAt: CLOSES });
    await auctioneer.submit(ORDER, await bid(A, 500));
    const settled = (await auctioneer.settle(ORDER))!;
    expect(settled.round.outcome.bumpBps).toBe(0);
    expect(settled.quote).toBeUndefined();
  });

  it("rejects a bid for an order with no open round", async () => {
    const auctioneer = new Auctioneer({ binding, signer: cosigner, now: clockAt().now });
    expect((await auctioneer.submit(ORDER, await bid(A, 100))).reason).toBe("no such round");
  });

  it("does not discard bids when a round is re-opened", async () => {
    const auctioneer = new Auctioneer({ binding, signer: cosigner, now: clockAt().now });
    auctioneer.open({ orderHash: ORDER, closesAt: CLOSES });
    await auctioneer.submit(ORDER, await bid(A, 100));
    auctioneer.open({ orderHash: ORDER, closesAt: CLOSES });
    expect(auctioneer.round(ORDER)!.submissions).toHaveLength(1);
  });

  it("settles every due round on a tick, and prunes stale ones", async () => {
    const clock = clockAt();
    const auctioneer = new Auctioneer({ binding, signer: cosigner, now: clock.now });
    const second = `0x${"22".repeat(32)}` as Hex;
    auctioneer.open({ orderHash: ORDER, closesAt: CLOSES });
    auctioneer.open({ orderHash: second, closesAt: 9_999 });
    await auctioneer.submit(ORDER, await bid(A, 4_000));
    await auctioneer.submit(ORDER, await bid(B, 1_200));

    clock.set(CLOSES);
    const due = await auctioneer.settleDue();
    expect(due).toHaveLength(1);
    expect(due[0]!.round.orderHash).toBe(ORDER);

    clock.set(CLOSES + 7_200);
    expect(auctioneer.prune(3_600)).toBe(1);
    expect(auctioneer.round(ORDER)).toBeUndefined();
    expect(auctioneer.round(second)).toBeDefined();
  });

  it("first-price mode charges the winner its own bid", async () => {
    const auctioneer = new Auctioneer({ binding, signer: cosigner, now: clockAt().now });
    auctioneer.open({ orderHash: ORDER, closesAt: CLOSES, rule: "first-price" });
    await auctioneer.submit(ORDER, await bid(A, 4_000));
    await auctioneer.submit(ORDER, await bid(B, 1_200));
    const { quote } = (await auctioneer.settle(ORDER))!;
    expect(quote!.bumpBps).toBe(1_200);
  });
});

describe("submit — concurrency", () => {
  it("DEDUPES ACROSS CONCURRENT SUBMISSIONS, not just sequential ones", async () => {
    // `verifyBid` yields, so a check-then-insert around it lets two in-flight
    // copies of the same signed bid both observe an empty set. Selection would
    // survive it — but `checkRound` rejects duplicates, so any bidder could
    // publish the same bid twice and make every audit of the round fail.
    const round = new AuctionRound({ orderHash: ORDER, closesAt: CLOSES, binding }, clockAt().now);
    const one = await bid(A, 1_200);

    const receipts = await Promise.all([round.submit(one), round.submit(one), round.submit(one)]);
    expect(receipts.filter((r) => r.accepted)).toHaveLength(1);

    const settled = round.settle()!;
    expect(settled.bids).toHaveLength(1);
    expect(await checkRound(settled, { rule: "second-price" })).toEqual({ ok: true });
  });

  it("releases the key again when verification fails, so the real bidder can still bid", async () => {
    const round = new AuctionRound({ orderHash: ORDER, closesAt: CLOSES, binding }, clockAt().now);
    const real = await bid(A, 1_200);
    const forged = { ...real, signature: `0x${"11".repeat(65)}` as Hex };

    expect((await round.submit(forged)).accepted).toBe(false);
    expect((await round.submit(real)).accepted).toBe(true);
  });
});
