import { describe, expect, it } from "vitest";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";
import { zeroAddress, type Address, type Hex } from "viem";

import { encodeProportional, OrderSide, signBid, type Order, type QuoteBinding, type SignedBid } from "@1delta-x/sdk";
import { AuctionRound, Auctioneer, checkRound, pricedLegOf, QuoteSolver, signExecutor, type RouteSource } from "../src/index";

/**
 * Regressions for the 2026-09-30 whole-tree audit, group B-offchain (auction).
 * Named `test_audit_<ID>_<what>`; each asserts the safe end state and fails on the
 * pre-fix package.
 */

const cosigner = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
const keys = ["0a11", "0b22", "0c33", "0d44", "0e55"].map((k) =>
  privateKeyToAccount(`0x${k.padStart(64, "0")}` as Hex),
);
const [A, B, C, D, E] = keys as [PrivateKeyAccount, PrivateKeyAccount, PrivateKeyAccount, PrivateKeyAccount, PrivateKeyAccount];

const ORDER = `0x${"11".repeat(32)}` as Hex;
const CLOSES = 1_060;
const binding: QuoteBinding = { module: "0x00000000000000000000000000000000000000cc", chainId: 31 };
const now = () => 1_000;
const TOKEN_IN = "0x1111111111111111111111111111111111111111" as Address;
const TOKEN_OUT = "0x2222222222222222222222222222222222222222" as Address;
const EXECUTOR = "0x000000000000000000000000000000000000e8ec" as Address;

const bid = (who: PrivateKeyAccount, bumpBps: number): Promise<SignedBid> =>
  signBid(who, { orderHash: ORDER, filler: who.address, bumpBps, closesAt: CLOSES }, binding);

function sellOrder(over: Partial<Order> = {}): Order {
  return {
    maker: "0x00000000000000000000000000000000000000ff",
    side: OrderSide.SELL,
    nonce: 1n,
    expiry: 4_000_000_000n,
    legsIn: [{ token: TOKEN_IN, start: 1_000n, end: 0n }],
    legsOut: [{ token: TOKEN_OUT, start: 2_000n, end: 1_000n, recipient: zeroAddress }],
    timing: 0n,
    exclusiveFiller: zeroAddress,
    minFillAnchor: 0n,
    exclusivityOverrideBps: 0n,
    curve: [],
    gasBumpBps: 0n,
    gasPriceRef: 0n,
    items: [],
    validators: [],
    invariants: [],
    fillModule: zeroAddress,
    fillTotal: 0n,
    priorityScale: 0n,
    pricingModule: zeroAddress,
    ...over,
  } as Order;
}

// ──────────────────── G-TS_FILLER-1 ────────────────────

describe("G-TS_FILLER-1 — a full round keeps the lowest bids, one per filler", () => {
  it("test_audit_G_TS_FILLER_1_two_keys_cannot_crowd_out_honest_solvers", async () => {
    const round = new AuctionRound({ orderHash: ORDER, closesAt: CLOSES, binding, maxBids: 4 }, now);
    // Two free keys arrive first and spray bumps near the maker's floor.
    for (const bump of [9_990, 9_991, 9_992, 9_993]) {
      await round.submit(await bid(A, bump));
      await round.submit(await bid(B, bump + 5));
    }
    // Honest solvers arrive later with real prices.
    expect((await round.submit(await bid(C, 1_000))).accepted).toBe(true);
    expect((await round.submit(await bid(D, 2_000))).accepted).toBe(true);
    const settled = round.settle()!;
    expect(settled.outcome.winner).toBe(C.address);
    expect(settled.outcome.bumpBps).toBe(2_000); // Vickrey: D's bump, not the floor
    expect(await checkRound(settled, { rule: "second-price" })).toEqual({ ok: true });
  });

  it("test_audit_G_TS_FILLER_1_full_round_admits_a_better_bid_by_displacing_the_worst", async () => {
    const round = new AuctionRound({ orderHash: ORDER, closesAt: CLOSES, binding, maxBids: 2 }, now);
    await round.submit(await bid(A, 9_000));
    await round.submit(await bid(B, 9_500));
    expect((await round.submit(await bid(C, 1_000))).accepted).toBe(true);
    expect(round.submissions.map((b) => b.filler)).toEqual([A.address, C.address]);
    expect((await round.submit(await bid(D, 9_800))).reason).toBe("round at capacity");
  });

  it("test_audit_G_TS_FILLER_1_unsigned_commitment_cannot_win_a_tie", async () => {
    const [low, high] = [D, E].sort((x, y) => (x.address.toLowerCase() < y.address.toLowerCase() ? -1 : 1)) as [
      PrivateKeyAccount,
      PrivateKeyAccount,
    ];
    const round = new AuctionRound({ orderHash: ORDER, closesAt: CLOSES, binding, minBidders: 1, rule: "first-price" }, now);
    await round.submit(await bid(low, 3_000));
    // The higher address ties and attaches an unsigned tie-break key that sorts first.
    await round.submit({ ...(await bid(high, 3_000)), commitment: `0x${"00".repeat(32)}` } as SignedBid);
    expect(round.settle()!.outcome.winner).toBe(low.address);
  });
});

// ──────────────────── PRICE-1.v1 ────────────────────

describe("PRICE-1.v1 — SELL bids are sized by the input a full fill pays", () => {
  it("test_audit_PRICE_1_v1_fillTotal_does_not_size_the_route", () => {
    expect(pricedLegOf(sellOrder({ fillTotal: 1n }))!.amountIn).toBe(1_000n);
    expect(pricedLegOf(sellOrder({ fillTotal: 10n ** 18n }))!.amountIn).toBe(1_000n);
  });

  it("test_audit_PRICE_1_v1_fullfill_order_gets_a_real_bid", async () => {
    const requested: bigint[] = [];
    const route: RouteSource = { name: "r", quote: async (req) => (requested.push(req.amountIn), { amountOut: req.amountIn * 2n }) };
    const solver = new QuoteSolver({ account: A, binding, routes: [route] });
    const res = await solver.bidFor(sellOrder({ fillTotal: 1n }), { orderHash: ORDER, closesAt: CLOSES });
    expect(requested).toEqual([1_000n]);
    expect(res).not.toBeNull();
    expect(res!.bumpBps).toBe(0);
  });

  it("test_audit_PRICE_1_v1_proportional_sell_returns_null_or_resolves_never_throws", () => {
    const prop = sellOrder({ legsIn: [{ token: TOKEN_IN, start: encodeProportional(5_000n), end: 10n ** 30n }] });
    expect(pricedLegOf(prop)).toBeNull();
    expect(pricedLegOf(prop, { makerBalance: 4_000n })!.amountIn).toBe(2_000n);
  });
});

// ──────────────────── CORE-FILLER-1.v3 ────────────────────

describe("CORE-FILLER-1.v3 — a won quote binds to the contract that executes", () => {
  it("test_audit_CORE_FILLER_1_v3_quote_is_bound_to_the_declared_executor", async () => {
    const auctioneer = new Auctioneer({ binding, signer: cosigner, now });
    auctioneer.open({ orderHash: ORDER, closesAt: CLOSES });
    const routes: RouteSource[] = [{ name: "r", quote: async () => ({ amountOut: 1_800n }) }];
    const viaContract = new QuoteSolver({ account: A, binding, routes, executor: EXECUTOR } as never);
    const rival = new QuoteSolver({ account: B, binding, routes: [{ name: "r", quote: async () => ({ amountOut: 1_400n }) }] });
    const r = { orderHash: ORDER, closesAt: CLOSES };
    const won = (await viaContract.bidFor(sellOrder(), r))!;
    expect((await auctioneer.submit(ORDER, won.bid)).accepted).toBe(true);
    expect((await auctioneer.submit(ORDER, (await rival.bidFor(sellOrder(), r))!.bid)).accepted).toBe(true);
    const settled = (await auctioneer.settle(ORDER))!;
    expect(settled.round.outcome.winner).toBe(A.address);
    expect(settled.quote!.filler).toBe(EXECUTOR);
    expect(await checkRound(settled.round, { rule: "second-price" })).toEqual({ ok: true });
  });

  it("test_audit_CORE_FILLER_1_v3_executor_declaration_must_be_the_bidders", async () => {
    const round = new AuctionRound({ orderHash: ORDER, closesAt: CLOSES, binding }, now);
    const b = await bid(A, 1_000);
    // B signs "bind A's quote to my contract" — refused.
    const forged = await signExecutor(B, { orderHash: ORDER, filler: B.address, executor: EXECUTOR, closesAt: CLOSES }, binding);
    const res = await round.submit({ ...b, executor: EXECUTOR, executorSignature: forged } as never);
    expect(res.accepted).toBe(false);
  });

  it("test_audit_CORE_FILLER_1_v3_soft_exclusivity_premium_is_priced", () => {
    const other = "0x0000000000000000000000000000000000000abc" as Address;
    const soft = sellOrder({ exclusiveFiller: other, exclusivityOverrideBps: 500n, timing: 2_000n << 64n });
    const leg = pricedLegOf(soft, { filler: A.address })!;
    // A non-member owes +5% on the maker's output.
    expect(leg.band.start).toBe(2_100n);
    expect(leg.band.end).toBe(1_050n);
    // The member itself owes nothing; after the window nobody does.
    expect(pricedLegOf(soft, { filler: other })!.band.start).toBe(2_000n);
    expect(pricedLegOf(soft, { filler: A.address, now: 2_000n })!.band.start).toBe(2_000n);
    // A hard window excludes the bidder entirely.
    expect(pricedLegOf(sellOrder({ exclusiveFiller: other, timing: 2_000n << 64n }), { filler: A.address })).toBeNull();
  });
});
