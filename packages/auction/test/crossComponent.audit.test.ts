import { describe, expect, it } from "vitest";
import { privateKeyToAccount } from "viem/accounts";
import { zeroAddress, type Address, type Hex } from "viem";

import { OrderSide, quoteDigest, signBid, verifyQuote, type Order, type QuoteBinding } from "@1delta-x/sdk";
import { Auctioneer, QuoteSolver, checkApiRoute, type RouteGuard, type RouteSource } from "../src/index";

/**
 * 2026-09-30 audit, cross-component remediation (auction side). Each test fails
 * on the pre-fix package: the guard / readFilled / minBumpBps did not exist.
 */
const solverKey = privateKeyToAccount("0x0000000000000000000000000000000000000000000000000000000000000a11");
const B = privateKeyToAccount("0x0000000000000000000000000000000000000000000000000000000000000b22");
const cosigner = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
const ORDER_HASH = `0x${"11".repeat(32)}` as Hex;
const CLOSES = 1_060;
const binding: QuoteBinding = { module: "0x00000000000000000000000000000000000000cc", chainId: 31 };
const TOKEN_IN = "0x1111111111111111111111111111111111111111" as Address;
const TOKEN_OUT = "0x2222222222222222222222222222222222222222" as Address;
const ROUTER = "0x3333333333333333333333333333333333333333" as Address;
const EXECUTOR = "0x4444444444444444444444444444444444444444" as Address;
const SWAP_SEL = "0x12345678" as Hex;
const SWEEP_SEL = "0xdf2ab5bb" as Hex; // sweepToken(address,uint256,address)

const w = (a: Address | bigint) =>
  (typeof a === "bigint" ? a.toString(16) : a.toLowerCase().slice(2)).padStart(64, "0");
const swapData = (recipient: Address, sel: Hex = SWAP_SEL) =>
  `${sel}${w(TOKEN_IN)}${w(TOKEN_OUT)}${w(1_000n)}${w(recipient)}` as Hex;

function sellOrder(): Order {
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
  } as Order;
}

const routed = (name: string, amountOut: bigint, data: Hex, to: Address = ROUTER): RouteSource => ({
  name,
  quote: async () => ({ amountOut, route: { to, data, value: 0n } }),
});

const guard: RouteGuard = { routers: [ROUTER], selectors: [SWAP_SEL] };

describe("AUCTION-AGG4 — API calldata is validated before a standing executor runs it", () => {
  const req = { chainId: 31, tokenIn: TOKEN_IN, tokenOut: TOKEN_OUT, amountIn: 1_000n, recipient: EXECUTOR };

  it("test_audit_AUCTION_AGG4_checkApiRouteRefusesHostileCalldata", () => {
    expect(checkApiRoute({ to: ROUTER, data: swapData(EXECUTOR), value: 0n }, req, guard)).toBeNull();
    expect(checkApiRoute({ to: EXECUTOR, data: swapData(EXECUTOR), value: 0n }, req, guard)).toMatch(/router/);
    expect(checkApiRoute({ to: ROUTER, data: swapData(EXECUTOR, SWEEP_SEL), value: 0n }, req, guard)).toMatch(
      /selector/,
    );
    // Pays someone else.
    expect(checkApiRoute({ to: ROUTER, data: swapData(B.address), value: 0n }, req, guard)).toMatch(/recipient/);
    expect(checkApiRoute({ to: ROUTER, data: swapData(EXECUTOR), value: 1n }, req, guard)).toMatch(/native value/);
  });

  it("test_audit_AGG_4_guardMatchesWordAlignedOnly", () => {
    // Pays B in the real recipient word, and smuggles the executor's address in
    // one byte OFF the word grid (a dynamic `bytes` tail) — a substring test
    // admitted it.
    const smuggled = `${SWAP_SEL}${w(TOKEN_IN)}${w(TOKEN_OUT)}${w(1_000n)}${w(B.address)}ab${w(EXECUTOR)}${"00".repeat(31)}` as Hex;
    expect(checkApiRoute({ to: ROUTER, data: smuggled, value: 0n }, req, guard)).toMatch(/recipient/);
    // As a real (aligned) word it passes: the guard is a PRESENCE check, and the
    // selector allowlist (fixed-recipient swap entrypoints only) bounds the rest.
    const aligned = `${SWAP_SEL}${w(TOKEN_IN)}${w(TOKEN_OUT)}${w(1_000n)}${w(B.address)}${w(EXECUTOR)}` as Hex;
    expect(checkApiRoute({ to: ROUTER, data: aligned, value: 0n }, req, guard)).toBeNull();
  });

  it("test_audit_AUCTION_AGG4_standingExecutorWithoutGuardIsRefused", () => {
    expect(
      () =>
        new QuoteSolver({ account: solverKey, binding, routes: [], executor: EXECUTOR, executorStanding: true }),
    ).toThrow(/routeGuard/);
  });

  it("test_audit_AUCTION_AGG4_standingExecutorBidsOnlyOnAdmittedRoutes", async () => {
    const errors: string[] = [];
    const solver = new QuoteSolver({
      account: solverKey,
      binding,
      executor: EXECUTOR,
      executorStanding: true,
      routeGuard: guard,
      // The hostile route quotes MORE — it would otherwise win.
      routes: [routed("evil", 1_900n, swapData(EXECUTOR, SWEEP_SEL)), routed("good", 1_700n, swapData(EXECUTOR))],
      onError: (name) => errors.push(name),
    });
    const res = (await solver.bidFor(sellOrder(), { orderHash: ORDER_HASH, closesAt: CLOSES }))!;
    expect(res.quote.amountOut).toBe(1_700n);
    expect(errors).toEqual(["evil"]);
  });
});

describe("QUOTE-TOOLING — quotes are minted for the order's current progress", () => {
  it("test_audit_QUOTE_TOOLING_auctioneerBindsLiveFilled", async () => {
    let t = 1_000;
    const now = () => t;
    const auctioneer = new Auctioneer({ binding, signer: cosigner, now, readFilled: async () => 7_777n });
    auctioneer.open({ orderHash: ORDER_HASH, closesAt: CLOSES });
    for (const [who, bump] of [
      [solverKey, 3_000],
      [B, 4_000],
    ] as const) {
      await auctioneer.submit(
        ORDER_HASH,
        await signBid(who, { orderHash: ORDER_HASH, filler: who.address, bumpBps: bump, closesAt: CLOSES }, binding),
      );
    }
    t = CLOSES + 1; // close the round
    const done = (await auctioneer.settle(ORDER_HASH))!;
    const q = done.quote!;
    expect(q.prevFilled).toBe(7_777n);
    // Signed over the live progress: verifies as such, and its digest is NOT the
    // first-fill digest a stale (prevFilled = 0) module check would compute.
    expect(await verifyQuote(q, { cosigner: cosigner.address, now: BigInt(CLOSES + 1) })).toEqual({ ok: true });
    expect(q.digest).not.toBe(quoteDigest({ ...q, prevFilled: 0n }, binding));
  });

  it("test_audit_QUOTE_TOOLING_solverBidCarriesItsFloor", async () => {
    const solver = new QuoteSolver({ account: solverKey, binding, routes: [routed("a", 1_800n, "0x")] });
    const res = (await solver.bidFor(sellOrder(), { orderHash: ORDER_HASH, closesAt: CLOSES }))!;
    expect(res.minBumpBps).toBe(BigInt(res.bumpBps));
    expect(res.minBumpBps).toBe(2_000n);
  });
});
