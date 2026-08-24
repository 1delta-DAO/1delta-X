import { describe, expect, it } from "vitest";
import { privateKeyToAccount } from "viem/accounts";
import { zeroAddress, type Address, type Hex } from "viem";

import { OrderSide, type Order, type QuoteBinding } from "@1delta-x/sdk";
import { QuoteSolver, gasInBandToken, minimumBump, nativePriceVia, type RouteSource } from "../src/index";

const solverKey = privateKeyToAccount("0x0000000000000000000000000000000000000000000000000000000000000a11");
const binding: QuoteBinding = { module: "0x00000000000000000000000000000000000000cc", chainId: 31 };
const TOKEN_IN = "0x1111111111111111111111111111111111111111" as Address;
const TOKEN_OUT = "0x2222222222222222222222222222222222222222" as Address;
const ROUND = { orderHash: `0x${"11".repeat(32)}` as Hex, closesAt: 1_060 };

function order(side: OrderSide): Order {
  const base = {
    maker: "0x00000000000000000000000000000000000000ff",
    nonce: 1n,
    expiry: 4_000_000_000n,
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
  };
  return side === OrderSide.SELL
    ? ({
        ...base,
        side,
        legsIn: [{ token: TOKEN_IN, start: 1_000_000n, end: 0n }],
        legsOut: [{ token: TOKEN_OUT, start: 2_000_000n, end: 1_000_000n, recipient: zeroAddress }],
      } as Order)
    : ({
        ...base,
        side,
        legsIn: [{ token: TOKEN_IN, start: 100n, end: 300n }],
        legsOut: [{ token: TOKEN_OUT, start: 1_000n, end: 0n, recipient: zeroAddress }],
      } as Order);
}

const source = (name: string, amountOut: bigint | null, gasUnits?: bigint): RouteSource => ({
  name,
  quote: async () => (amountOut === null ? null : { amountOut, ...(gasUnits ? { gasUnits } : {}) }),
});

describe("gasInBandToken", () => {
  it("converts wei of gas into band-token units at the native rate", () => {
    // 200k gas at 1 gwei = 2e14 wei. At 3000 USDC(6dp) per native:
    //   2e14 * 3000e6 / 1e18 = 600000 = 0.60 USDC
    expect(
      gasInBandToken({ gasUnits: 200_000n, gasPriceWei: 1_000_000_000n, nativePriceInToken: 3_000_000_000n }),
    ).toBe(600_000n);
  });

  it("rounds UP — an understated cost is a bid the solver cannot honour", () => {
    const cost = gasInBandToken({ gasUnits: 1n, gasPriceWei: 1n, nativePriceInToken: 1n });
    expect(cost).toBe(1n);
  });
});

describe("minimumBump with gas", () => {
  const falling = { start: 2_000n, end: 1_000n, rising: false };
  const rising = { start: 100n, end: 300n, rising: true };

  it("SELL: gas makes the solver PROVIDE LESS — the bump rises", () => {
    const free = minimumBump({ band: falling, available: 1_500n })!;
    const costed = minimumBump({ band: falling, available: 1_500n, gasInBandToken: 100n })!;
    expect(free).toBe(5_000);
    // 100 less to deliver with ⇒ 1400 ⇒ 6000 bps.
    expect(costed).toBe(6_000);
    expect(costed).toBeGreaterThan(free);
  });

  it("BUY: gas makes the solver TAKE MORE INPUT — the bump also rises", () => {
    const free = minimumBump({ band: rising, available: 200n })!;
    const costed = minimumBump({ band: rising, available: 200n, gasInBandToken: 20n })!;
    expect(free).toBe(5_000);
    // Must now be paid 220 rather than 200 ⇒ 6000 bps.
    expect(costed).toBe(6_000);
  });

  it("does NOT bid when gas alone exceeds the route output", () => {
    expect(minimumBump({ band: falling, available: 1_500n, gasInBandToken: 1_500n })).toBeNull();
    expect(minimumBump({ band: falling, available: 1_500n, gasInBandToken: 2_000n })).toBeNull();
  });

  it("does not bid when gas pushes the fill past the maker's floor", () => {
    // Route yields 1100, comfortably above the 1000 floor — until gas.
    expect(minimumBump({ band: falling, available: 1_100n })).not.toBeNull();
    expect(minimumBump({ band: falling, available: 1_100n, gasInBandToken: 200n })).toBeNull();
  });

  it("applies gas BEFORE the margin — margin is profit on the net", () => {
    const both = minimumBump({ band: falling, available: 1_500n, gasInBandToken: 100n, minProfitBps: 100 })!;
    const gasOnly = minimumBump({ band: falling, available: 1_500n, gasInBandToken: 100n })!;
    expect(both).toBeGreaterThan(gasOnly);
  });

  it("rejects a negative gas cost rather than crediting it", () => {
    expect(() => minimumBump({ band: falling, available: 1_500n, gasInBandToken: -1n })).toThrow();
  });
});

describe("nativePriceVia", () => {
  it("quotes a WHOLE native token, not the dust the gas actually costs", async () => {
    let seen = 0n;
    const probe: RouteSource = {
      name: "probe",
      quote: async (req) => {
        seen = req.amountIn;
        return { amountOut: 3_000_000_000n };
      },
    };
    const rate = await nativePriceVia({ routes: [probe], chainId: 31, token: TOKEN_OUT });
    expect(seen).toBe(10n ** 18n);
    expect(rate).toBe(3_000_000_000n);
  });

  it("returns null when nothing can price the native token", async () => {
    expect(await nativePriceVia({ routes: [source("a", null)], chainId: 31, token: TOKEN_OUT })).toBeNull();
  });
});

describe("QuoteSolver gas costing", () => {
  it("folds gas into the bid and reports it — the bump rises to cover it", async () => {
    const free = new QuoteSolver({ account: solverKey, binding, routes: [source("a", 1_500_000n)] });
    const costed = new QuoteSolver({
      account: solverKey,
      binding,
      routes: [source("a", 1_500_000n)],
      gas: {
        gasPriceWei: 1_000_000_000n,
        settlementGasUnits: 200_000n,
        nativePriceInToken: 500_000_000n, // band-token units per 1e18 wei
      },
    });
    // 200k gas * 1 gwei = 2e14 wei;  2e14 * 5e8 / 1e18 = 100_000 band units.
    const a = (await free.bidFor(order(OrderSide.SELL), ROUND))!;
    const b = (await costed.bidFor(order(OrderSide.SELL), ROUND))!;
    expect(b.gasInBandToken).toBe(100_000n);
    expect(a.bumpBps).toBe(5_000);
    expect(b.bumpBps).toBe(6_000); // 100k less to deliver with, on a 1M-wide band
  });

  it("prices gas as ZERO only when no gas config is given", async () => {
    const solver = new QuoteSolver({ account: solverKey, binding, routes: [source("a", 1_500_000n)] });
    const result = (await solver.bidFor(order(OrderSide.SELL), ROUND))!;
    expect(result.gasInBandToken).toBe(0n);
    expect(result.bumpBps).toBe(5_000);
  });

  it("uses the route's own reported gas on top of settlement overhead", async () => {
    const solver = new QuoteSolver({
      account: solverKey,
      binding,
      routes: [source("a", 1_500_000n, 150_000n)],
      gas: { gasPriceWei: 1n, settlementGasUnits: 50_000n, nativePriceInToken: 10n ** 18n },
    });
    const result = (await solver.bidFor(order(OrderSide.SELL), ROUND))!;
    expect(result.gasInBandToken).toBe(200_000n); // 150k route + 50k settlement
  });

  it("resolves the native rate live when none is supplied", async () => {
    // The same source answers both the swap quote and the native probe.
    const src: RouteSource = {
      name: "live",
      quote: async (req) => ({ amountOut: req.amountIn === 10n ** 18n ? 2n * 10n ** 18n : 1_500_000n }),
    };
    const solver = new QuoteSolver({
      account: solverKey,
      binding,
      routes: [src],
      gas: { gasPriceWei: 1n, settlementGasUnits: 100n, routeGasUnits: 0n },
    });
    const result = (await solver.bidFor(order(OrderSide.SELL), ROUND))!;
    expect(result.gasInBandToken).toBe(200n); // 100 gas * 1 wei * 2
  });

  it("does NOT bid when the gas rate cannot be resolved — never prices gas as free", async () => {
    const swapOnly: RouteSource = {
      name: "swap-only",
      quote: async (req) => (req.amountIn === 10n ** 18n ? null : { amountOut: 1_500_000n }),
    };
    const solver = new QuoteSolver({
      account: solverKey,
      binding,
      routes: [swapOnly],
      gas: { gasPriceWei: 1_000_000_000n },
    });
    expect(await solver.bidFor(order(OrderSide.SELL), ROUND)).toBeNull();
  });

  it("does not bid when gas makes the route unprofitable", async () => {
    const solver = new QuoteSolver({
      account: solverKey,
      binding,
      routes: [source("a", 1_100_000n)],
      gas: { gasPriceWei: 1n, settlementGasUnits: 200_000n, nativePriceInToken: 10n ** 18n },
    });
    expect(await solver.bidFor(order(OrderSide.SELL), ROUND)).toBeNull();
  });
});
