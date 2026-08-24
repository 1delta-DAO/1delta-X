import { describe, expect, it } from "vitest";
import { privateKeyToAccount } from "viem/accounts";
import { zeroAddress, type Address, type Hex } from "viem";

import { OrderSide, verifyBid, type Order, type QuoteBinding } from "@1delta-x/sdk";
import { AuctionRound, QuoteSolver, costInBandToken, minimumBump, pricedLegOf, type RouteSource } from "../src/index";

const solverKey = privateKeyToAccount("0x0000000000000000000000000000000000000000000000000000000000000a11");
const rival = privateKeyToAccount("0x0000000000000000000000000000000000000000000000000000000000000b22");

const ORDER_HASH = `0x${"11".repeat(32)}` as Hex;
const CLOSES = 1_060;
const binding: QuoteBinding = { module: "0x00000000000000000000000000000000000000cc", chainId: 31 };
const TOKEN_IN = "0x1111111111111111111111111111111111111111" as Address;
const TOKEN_OUT = "0x2222222222222222222222222222222222222222" as Address;

/** A decaying SELL: 1000 in, output falling 2000 → 1000. */
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

const source = (name: string, amountOut: bigint | null): RouteSource => ({
  name,
  quote: async () => (amountOut === null ? null : { amountOut }),
});

describe("minimumBump — the bid economics", () => {
  const band = { start: 2_000n, end: 1_000n, rising: false };

  it("bids 0 when the route clears the maker's ambition", () => {
    expect(minimumBump({ band, available: 2_500n })).toBe(0);
    expect(minimumBump({ band, available: 2_000n })).toBe(0);
  });

  it("bids the exact break-even in between", () => {
    // Route yields 1500 = the band midpoint ⇒ 5000 bps.
    expect(minimumBump({ band, available: 1_500n })).toBe(5_000);
    expect(minimumBump({ band, available: 1_750n })).toBe(2_500);
  });

  it("bids the floor when the route only just clears it", () => {
    expect(minimumBump({ band, available: 1_000n })).toBe(10_000);
  });

  it("does NOT bid when the route cannot clear even the floor", () => {
    // Winning a round you cannot fill costs the maker the improvement.
    expect(minimumBump({ band, available: 999n })).toBeNull();
  });

  it("rounds the bump UP, never leaving the solver short", () => {
    // Any rounding must land on the side the solver can actually honour.
    const bump = minimumBump({ band, available: 1_501n })!;
    const required = band.start - ((band.start - band.end) * BigInt(bump)) / 10_000n;
    expect(required).toBeLessThanOrEqual(1_501n);
  });

  it("raises the bid by the requested margin", () => {
    const honest = minimumBump({ band, available: 1_500n })!;
    const greedy = minimumBump({ band, available: 1_500n, minProfitBps: 100 })!;
    expect(greedy).toBeGreaterThan(honest);
  });

  it("mirrors correctly on a RISING (BUY) band", () => {
    // The maker pays 100 → 300; the solver's cost is 200 ⇒ the midpoint.
    const rising = { start: 100n, end: 300n, rising: true };
    expect(minimumBump({ band: rising, available: 200n })).toBe(5_000);
    expect(minimumBump({ band: rising, available: 100n })).toBe(0);
    expect(minimumBump({ band: rising, available: 301n })).toBeNull();
  });

  it("rejects a band signed the wrong way round rather than mispricing", () => {
    expect(() => minimumBump({ band: { start: 1_000n, end: 2_000n, rising: false }, available: 1n })).toThrow();
  });
});

describe("pricedLegOf", () => {
  it("reads a SELL order's falling output band", () => {
    const leg = pricedLegOf(sellOrder())!;
    expect(leg.band).toEqual({ start: 2_000n, end: 1_000n, rising: false });
    expect(leg.amountIn).toBe(1_000n);
    expect(leg.tokenIn).toBe(TOKEN_IN);
  });

  it("declines a fixed-output order — nothing decays, so there is no bump to bid", () => {
    const fixed = sellOrder({ legsOut: [{ token: TOKEN_OUT, start: 2_000n, end: 0n, recipient: zeroAddress }] });
    expect(pricedLegOf(fixed)).toBeNull();
  });

  it("declines a multi-leg order rather than guessing which leg it is quoting", () => {
    const multi = sellOrder({
      legsOut: [
        { token: TOKEN_OUT, start: 2_000n, end: 1_000n, recipient: zeroAddress },
        { token: TOKEN_IN, start: 10n, end: 5n, recipient: zeroAddress },
      ],
    });
    expect(pricedLegOf(multi)).toBeNull();
  });
});

describe("QuoteSolver", () => {
  const solverFor = (routes: RouteSource[], minProfitBps?: number) =>
    new QuoteSolver({
      account: solverKey,
      binding,
      routes,
      ...(minProfitBps !== undefined ? { minProfitBps } : {}),
    });

  it("picks the best route across sources and signs a bid for it", async () => {
    const solver = solverFor([source("a", 1_500n), source("b", 1_800n)]);
    const result = (await solver.bidFor(sellOrder(), { orderHash: ORDER_HASH, closesAt: CLOSES }))!;
    expect(result.quote.amountOut).toBe(1_800n);
    expect(result.quote.source).toBe("b");
    expect(result.bumpBps).toBe(2_000);
    expect(await verifyBid(result.bid, binding)).toEqual({ ok: true });
    expect(result.bid.filler).toBe(solverKey.address);
  });

  it("produces a bid an actual round accepts", async () => {
    const solver = solverFor([source("a", 1_500n)]);
    const round = new AuctionRound({ orderHash: ORDER_HASH, closesAt: CLOSES, binding }, () => 1_000);
    const result = (await solver.bidFor(sellOrder(), { orderHash: ORDER_HASH, closesAt: CLOSES }))!;
    expect((await round.submit(result.bid)).accepted).toBe(true);
  });

  it("survives a dead source rather than failing to bid", async () => {
    const broken: RouteSource = {
      name: "broken",
      quote: async () => {
        throw new Error("502");
      },
    };
    const errors: string[] = [];
    const solver = new QuoteSolver({
      account: solverKey,
      binding,
      routes: [broken, source("good", 1_600n)],
      onError: (name) => errors.push(name),
    });
    const result = (await solver.bidFor(sellOrder(), { orderHash: ORDER_HASH, closesAt: CLOSES }))!;
    expect(result.quote.amountOut).toBe(1_600n);
    expect(errors).toEqual(["broken"]);
  });

  it("does not bid when no source can serve the pair", async () => {
    const solver = solverFor([source("a", null)]);
    expect(await solver.bidFor(sellOrder(), { orderHash: ORDER_HASH, closesAt: CLOSES })).toBeNull();
  });

  it("does not bid when the best route cannot clear the maker's floor", async () => {
    const solver = solverFor([source("a", 900n)]);
    expect(await solver.bidFor(sellOrder(), { orderHash: ORDER_HASH, closesAt: CLOSES })).toBeNull();
  });

  it("bids the filler it signs as, so a round cannot be entered on someone else's behalf", async () => {
    const solver = solverFor([source("a", 1_500n)]);
    const result = (await solver.bidFor(sellOrder(), { orderHash: ORDER_HASH, closesAt: CLOSES }))!;
    expect(result.bid.filler).not.toBe(rival.address);
    expect(await verifyBid({ ...result.bid, filler: rival.address }, binding)).toMatchObject({ ok: false });
  });

  it("competes correctly: the better-routed solver wins the round", async () => {
    const round = new AuctionRound({ orderHash: ORDER_HASH, closesAt: CLOSES, binding }, () => 1_000);
    const good = new QuoteSolver({ account: solverKey, binding, routes: [source("a", 1_800n)] });
    const worse = new QuoteSolver({ account: rival, binding, routes: [source("b", 1_400n)] });

    const round_ = { orderHash: ORDER_HASH, closesAt: CLOSES };
    await round.submit((await good.bidFor(sellOrder(), round_))!.bid);
    await round.submit((await worse.bidFor(sellOrder(), round_))!.bid);

    const settled = round.settle()!;
    expect(settled.outcome.winner).toBe(solverKey.address);
    // Vickrey: the winner is charged the weaker solver's bump.
    expect(settled.outcome.bumpBps).toBe(6_000);
    expect(settled.outcome.winningBidBps).toBe(2_000);
  });
});

// ─────────────────── BUY orders price on the INPUT leg ───────────────────

/**
 * An exact-output BUY: the maker must receive a FIXED 5,000,000 units of
 * `tokenOut`, and pays a rising 1e14 → 1e15 of `tokenIn` for it.
 *
 * The numbers are deliberately lop-sided in the way a real WETH→USDC pair is:
 * the input leg counts in wei and the output leg in 6-decimal units, so a
 * quantity from one side compared against the other is off by orders of
 * magnitude rather than by a little. That is what makes the bug visible.
 */
function buyOrder(over: Partial<Order> = {}): Order {
  return sellOrder({
    side: OrderSide.BUY,
    legsIn: [{ token: TOKEN_IN, start: 100_000_000_000_000n, end: 1_000_000_000_000_000n }],
    legsOut: [{ token: TOKEN_OUT, start: 5_000_000n, end: 0n, recipient: zeroAddress }],
    ...over,
  });
}

describe("costInBandToken — the BUY leg's cost is not the route's output", () => {
  it("passes a SELL quote straight through: band and route share a token", () => {
    const leg = pricedLegOf(sellOrder())!;
    expect(costInBandToken(leg, { amountOut: 1_500n })).toBe(1_500n);
  });

  it("CONVERTS ON BUY, rather than comparing tokenOut units against a tokenIn band", () => {
    const leg = pricedLegOf(buyOrder())!;
    expect(leg.bandToken).toBe(TOKEN_IN);
    expect(leg.requiredOut).toBe(5_000_000n);

    // Quoted for the band ceiling (1e15 wei) the route yields 10,000,000 units —
    // twice what the maker needs, so half the input buys it: 5e14.
    expect(costInBandToken(leg, { amountOut: 10_000_000n })).toBe(500_000_000_000_000n);
    // Exactly enough ⇒ the whole ceiling is the cost.
    expect(costInBandToken(leg, { amountOut: 5_000_000n })).toBe(1_000_000_000_000_000n);
  });

  it("refuses a route that cannot produce the fixed output at any price", () => {
    const leg = pricedLegOf(buyOrder())!;
    expect(costInBandToken(leg, { amountOut: 4_999_999n })).toBeNull();
    expect(costInBandToken(leg, { amountOut: 0n })).toBeNull();
  });
});

describe("bidFor — BUY orders", () => {
  const solverFor = (routes: RouteSource[]) => new QuoteSolver({ account: solverKey, binding, routes });
  const round_ = { orderHash: ORDER_HASH, closesAt: CLOSES };

  it("DOES NOT BID 0 JUST BECAUSE THE OUTPUT UNITS ARE SMALL", async () => {
    // The regression. `amountOut` (5,000,000) is numerically far below the band's
    // floor (1e14), so feeding it in as the solver's cost made `minimumBump`
    // return 0 — a bid at the maker's cheapest price with no relation to the
    // route, which the solver then fills at a loss or fails outright.
    // The route here needs the ENTIRE ceiling, i.e. the maximum bump.
    const solver = solverFor([source("a", 5_000_000n)]);
    const result = await solver.bidFor(buyOrder(), round_);
    expect(result!.bumpBps).toBe(10_000);
  });

  it("bids the break-even inside the band", async () => {
    // Yields 10,000,000 for the ceiling ⇒ cost 5e14 ⇒ the band midpoint ⇒ 4,445 bps
    // (ceil((5e14 − 1e14)·10000 / 9e14)).
    const solver = solverFor([source("a", 10_000_000n)]);
    const result = await solver.bidFor(buyOrder(), round_);
    expect(result!.bumpBps).toBe(4_445);
  });

  it("bids 0 when the route clears at the maker's floor", async () => {
    // Cheap enough that 1e14 already covers it.
    const solver = solverFor([source("a", 100_000_000n)]);
    expect((await solver.bidFor(buyOrder(), round_))!.bumpBps).toBe(0);
  });

  it("DOES NOT BID AT ALL when the route cannot make the fixed output", async () => {
    // Previously this returned `null` for the right reason only by accident, and
    // the mirror case returned a bid. Now it is the route that decides.
    const solver = solverFor([source("a", 4_000_000n)]);
    expect(await solver.bidFor(buyOrder(), round_)).toBeNull();
  });
});
