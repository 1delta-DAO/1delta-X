import { describe, expect, it } from "vitest";
import type { Address } from "viem";

import { selectQuote, verifyOutcome, type QuoteBid } from "../src/auction";

const A = "0x00000000000000000000000000000000000000aa" as Address;
const B = "0x00000000000000000000000000000000000000bb" as Address;
const C = "0x00000000000000000000000000000000000000cc" as Address;

const bid = (filler: Address, bumpBps: number): QuoteBid => ({ filler, bumpBps });

describe("selectQuote", () => {
  it("picks the lowest bump as winner — least concession wins", () => {
    const out = selectQuote([bid(A, 4_000), bid(B, 1_200), bid(C, 9_000)])!;
    expect(out.winner).toBe(B);
    expect(out.winningBidBps).toBe(1_200);
  });

  it("second-price charges the runner-up's bump, not the winner's", () => {
    const out = selectQuote([bid(A, 4_000), bid(B, 1_200), bid(C, 9_000)])!;
    expect(out.rule).toBe("second-price");
    expect(out.bumpBps).toBe(4_000);
    expect(out.runnerUpBps).toBe(4_000);
  });

  it("first-price charges the winner's own bump", () => {
    const out = selectQuote([bid(A, 4_000), bid(B, 1_200)], { rule: "first-price" })!;
    expect(out.winner).toBe(B);
    expect(out.bumpBps).toBe(1_200);
  });

  it("second price is never better for the filler than its own bid", () => {
    const bids = [bid(A, 100), bid(B, 250), bid(C, 9_999)];
    const out = selectQuote(bids)!;
    expect(out.bumpBps).toBeGreaterThanOrEqual(out.winningBidBps);
  });

  it("collapses a filler's multiple bids to its best, so it cannot be its own runner-up", () => {
    // Without the collapse, A's 9000 would set the second price for A's own 1000.
    const out = selectQuote([bid(A, 1_000), bid(A, 9_000), bid(B, 5_000)])!;
    expect(out.winner).toBe(A);
    expect(out.bidders).toBe(2);
    expect(out.bumpBps).toBe(5_000);
  });

  it("breaks ties deterministically and independently of submission order", () => {
    const forward = selectQuote([bid(A, 3_000), bid(B, 3_000), bid(C, 3_000)])!;
    const reverse = selectQuote([bid(C, 3_000), bid(B, 3_000), bid(A, 3_000)])!;
    expect(forward.winner).toBe(reverse.winner);
    expect(forward.bumpBps).toBe(reverse.bumpBps);
  });

  it("prefers the commitment hash over the address as tie-break when present", () => {
    const withCommit: QuoteBid[] = [
      { filler: A, bumpBps: 3_000, commitment: "0xff" },
      { filler: B, bumpBps: 3_000, commitment: "0x11" },
    ];
    expect(selectQuote(withCommit)!.winner).toBe(B);
  });

  it("grants no concession below minBidders — a lone bidder is not an auction", () => {
    const out = selectQuote([bid(A, 500)])!;
    expect(out.bidders).toBe(1);
    expect(out.bumpBps).toBe(0);
    expect(out.winningBidBps).toBe(500);
  });

  it("first-price admits a lone bidder by default, since it pays its own bid", () => {
    const out = selectQuote([bid(A, 500)], { rule: "first-price" })!;
    expect(out.bumpBps).toBe(500);
  });

  it("drops malformed bids rather than voiding the round", () => {
    const out = selectQuote([bid(A, -1), bid(B, 20_000), bid(C, 700), bid(A, 800)])!;
    expect(out.bidders).toBe(2);
    expect(out.winner).toBe(C);
  });

  it("returns null when nothing is usable", () => {
    expect(selectQuote([])).toBeNull();
    expect(selectQuote([bid(A, 99_999)])).toBeNull();
  });
});

describe("verifyOutcome", () => {
  it("accepts an honestly-run auction", () => {
    const bids = [bid(A, 4_000), bid(B, 1_200), bid(C, 9_000)];
    expect(verifyOutcome(bids, selectQuote(bids)!)).toBe(true);
  });

  it("rejects a cosigner that named the wrong winner", () => {
    const bids = [bid(A, 4_000), bid(B, 1_200)];
    const honest = selectQuote(bids)!;
    expect(verifyOutcome(bids, { ...honest, winner: A })).toBe(false);
  });

  it("rejects a cosigner that charged the winner's own bid under second price", () => {
    // The shill-bidding shape: keep the winner, pocket the spread to the runner-up.
    const bids = [bid(A, 4_000), bid(B, 1_200)];
    const honest = selectQuote(bids)!;
    expect(honest.bumpBps).toBe(4_000);
    expect(verifyOutcome(bids, { ...honest, bumpBps: 1_200 })).toBe(false);
  });

  it("rejects an outcome claimed over a bid set that does not produce it", () => {
    const claimed = selectQuote([bid(A, 4_000), bid(B, 1_200)])!;
    expect(verifyOutcome([bid(A, 4_000), bid(B, 1_200), bid(C, 100)], claimed)).toBe(false);
  });
});
