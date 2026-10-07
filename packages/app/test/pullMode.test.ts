import { describe, expect, it } from "vitest";
import { DELTA_VERIFY_OUTPUTS_BIT, exclusivityOverrideFor, overrideHasCarrier, unpackTiming } from "@1delta-x/sdk";
import { getAddress, zeroAddress } from "viem";

import { DEFAULT_PULL_EXCLUSIVITY, PULL_MODE, exclusivityForMarket, isPullMarket, parseDeployments, solverForMarket } from "../src/config/deployments";
import { marketById, pinnedToken } from "../src/config/markets";
import { buildOrder } from "../src/lib/order";

/**
 * Rootstock beta: the USDRIF/USDT0 market is filled by a plain EOA bot, which
 * cannot run the fill callback a delta-verify order needs — so that market signs
 * plain pull delivery with no named filler (`marketSolvers: { …: "pull" }`).
 */
const SETTLEMENT = "0x00000000000000000000000000000000005e771e";
const PERMIT3 = "0x000000000000000000000000000000000000aaaa";
const LENS = "0x000000000000000000000000000000000000beef";
const AGG = "0x000000000000000000000000000000000000a660";
const MARKET = "rsk-30-usdrif-usd0";

/** The exact beta shape from the README, with placeholder addresses filled in. */
const BETA = JSON.stringify({
  30: {
    settlement: SETTLEMENT,
    permit3: PERMIT3,
    lens: LENS,
    solver: zeroAddress,
    marketSolvers: { [MARKET]: "pull" },
  },
});

describe("marketSolvers \"pull\" — plain pull delivery, no named filler", () => {
  it("parses the beta example: zero solver allowed, pull market resolves to the zero address", () => {
    const dep = parseDeployments(BETA)[30] ?? null;
    expect(dep).not.toBeNull();
    expect(dep!.solver).toBe(zeroAddress);
    expect(dep!.marketSolvers).toEqual({ [MARKET]: zeroAddress });
    expect(solverForMarket(dep, MARKET)).toBe(zeroAddress);
    expect(isPullMarket(dep, MARKET)).toBe(true);
    expect(PULL_MODE).toBe("pull");
  });

  it("a pull market wins over a non-zero deployment-wide solver; other markets keep that solver", () => {
    const dep =
      parseDeployments(
        JSON.stringify({ 30: { settlement: SETTLEMENT, permit3: PERMIT3, solver: AGG, marketSolvers: { [MARKET]: "pull" } } }),
      )[30] ?? null;
    expect(solverForMarket(dep, MARKET)).toBe(zeroAddress);
    expect(isPullMarket(dep, MARKET)).toBe(true);
    expect(solverForMarket(dep, "rsk-30-rif-usd0")).toBe(getAddress(AGG));
    expect(isPullMarket(dep, "rsk-30-rif-usd0")).toBe(false);
    // Prototype keys are not market entries.
    expect(solverForMarket(dep, "toString")).toBe(getAddress(AGG));
  });

  it("anything other than the exact literal, or a zero / invalid address, still drops the deployment", () => {
    for (const bad of ["PULL", " pull", "pull ", "push", zeroAddress, "0xnope", 123, null, true]) {
      const deps = parseDeployments(
        JSON.stringify({ 30: { settlement: SETTLEMENT, permit3: PERMIT3, solver: AGG, marketSolvers: { [MARKET]: bad } } }),
      );
      expect(deps[30], String(bad)).toBeUndefined();
    }
  });

  it("a pull-mode market's order has no delta-verify bit and exclusiveFiller == 0", () => {
    const dep = parseDeployments(BETA)[30] ?? null;
    const m = marketById(MARKET);
    const pay = pinnedToken(m.chainId, m.base)!;
    const recv = pinnedToken(m.chainId, m.quote)!;
    const common = {
      maker: "0x00000000000000000000000000000000000000aa" as const,
      pay,
      recv,
      amountIn: 25,
      targetOut: 25.1,
      minOut: 24.9,
      ttlSeconds: 60,
      decaySeconds: 60,
      nonce: 7n,
      now: 1_700_000_000,
    };
    for (const side of ["sell", "buy"] as const) {
      const { order } = buildOrder({ ...common, side, solver: solverForMarket(dep, MARKET) });
      expect(order.exclusiveFiller).toBe(zeroAddress);
      expect((order.timing >> DELTA_VERIFY_OUTPUTS_BIT) & 1n).toBe(0n);
    }
    // Contrast: a named solver signs direct (delta-verify) delivery for that filler only.
    const named = buildOrder({ ...common, side: "sell", solver: getAddress(AGG) }).order;
    expect(named.exclusiveFiller).toBe(getAddress(AGG));
    expect((named.timing >> DELTA_VERIFY_OUTPUTS_BIT) & 1n).toBe(1n);
  });
});

/**
 * B13 (2026-10-06): OPT-IN — a pull market of a deployment that configures a window
 * names the deployment's SOLVER with a UniswapX-style SOFT window (~2 Rootstock blocks,
 * outsiders pay a small premium), then it is open to every filler until expiry. Off by
 * default (+509 gas/fill measured; zero-gas rule). Direct markets keep their whole-life
 * exclusivity (F30).
 */
describe("pull-market soft exclusivity window", () => {
  const NOW = 1_700_000_000;
  const raw = (extra: Record<string, unknown> = {}) =>
    parseDeployments(
      JSON.stringify({ 30: { settlement: SETTLEMENT, permit3: PERMIT3, lens: LENS, solver: AGG, marketSolvers: { [MARKET]: "pull" }, ...extra } }),
    )[30] ?? null;
  /** A deployment that OPTS IN to the ~2-block window (seconds only: 5 bps inherited). */
  const withSolver = (extra: Record<string, unknown> = {}) => raw({ pullExclusivity: { seconds: 60 }, ...extra });
  const m = marketById(MARKET);
  const base = pinnedToken(m.chainId, m.base)!;
  const quote = pinnedToken(m.chainId, m.quote)!;
  const common = {
    maker: "0x00000000000000000000000000000000000000aa" as const,
    amountIn: 25,
    targetOut: 25.1,
    minOut: 24.9,
    ttlSeconds: 300,
    decaySeconds: 60,
    nonce: 7n,
    now: NOW,
  };
  const legsFor = (side: "sell" | "buy") => (side === "sell" ? { pay: base, recv: quote } : { pay: quote, recv: base });
  const build = (dep: ReturnType<typeof withSolver>, side: "sell" | "buy", market = MARKET, over: Partial<typeof common> = {}) =>
    buildOrder({ ...common, ...over, ...legsFor(side), side, solver: solverForMarket(dep, market), exclusivity: exclusivityForMarket(dep, market) }).order;

  it("default: NO window (zero gas change) — a pull order is open from the start, exactly as before", () => {
    expect(DEFAULT_PULL_EXCLUSIVITY).toEqual({ seconds: 0, overrideBps: 5 });
    const def = raw();
    expect(def!.pullExclusivity).toEqual({ seconds: 0, overrideBps: 5 });
    expect(exclusivityForMarket(def, MARKET)).toBeUndefined();
    for (const side of ["sell", "buy"] as const) {
      const o = build(def, side);
      expect(o.exclusiveFiller).toBe(zeroAddress);
      expect(o.exclusivityOverrideBps).toBe(0n);
      expect(unpackTiming(o.timing).exclusivityEndTime).toBe(0);
    }
  });

  it("opt-in: {seconds: 60} (≈ 2 Rootstock blocks) inherits 5 bps", () => {
    const dep = withSolver();
    expect(dep!.pullExclusivity).toEqual({ seconds: 60, overrideBps: 5 });
    expect(dep!.marketExclusivity).toEqual({});
    expect(exclusivityForMarket(dep, MARKET)).toEqual({ filler: getAddress(AGG), seconds: 60, overrideBps: 5 });
  });

  it("a pull order (SELL and BUY) names the solver, ends the window at now + 60, carries 5 bps — and stays pull", () => {
    const dep = withSolver();
    for (const side of ["sell", "buy"] as const) {
      const o = build(dep, side);
      expect(o.exclusiveFiller).toBe(getAddress(AGG));
      expect(o.exclusivityOverrideBps).toBe(5n);
      expect((o.timing >> DELTA_VERIFY_OUTPUTS_BIT) & 1n).toBe(0n);
      expect(unpackTiming(o.timing)).toEqual({ decayStartTime: NOW, decayDuration: 60, exclusivityEndTime: NOW + 60 });
      // The premium has a leg to ride on (else the core would make the window HARD).
      expect(overrideHasCarrier(o)).toBe(true);
      // Expiry is untouched: MARKET_TTL_SECONDS, well past the window.
      expect(o.expiry).toBe(BigInt(NOW + 300));
    }
  });

  it("the window is SOFT for outsiders inside it, gone after it, and nothing for the solver (SDK mirror of OrderGates)", () => {
    const o = build(withSolver(), "sell");
    const OUTSIDER = "0x00000000000000000000000000000000000000cc" as const;
    expect(exclusivityOverrideFor(o, getAddress(AGG), BigInt(NOW + 1))).toBe(0n);
    expect(exclusivityOverrideFor(o, OUTSIDER, BigInt(NOW + 59))).toBe(5n);
    expect(exclusivityOverrideFor(o, OUTSIDER, BigInt(NOW + 60))).toBe(0n);
  });

  it("a fixed-price pull order (limit / TWAP slice) gets the window on an otherwise zero timing", () => {
    const o = build(withSolver(), "sell", MARKET, { decaySeconds: 0, targetOut: 24.9 });
    expect(unpackTiming(o.timing)).toEqual({ decayStartTime: 0, decayDuration: 0, exclusivityEndTime: NOW + 60 });
    expect(o.exclusiveFiller).toBe(getAddress(AGG));
  });

  it("0 seconds = no window: open from the start (the default, or an opted-in deployment turned off per market)", () => {
    for (const dep of [raw(), withSolver({ pullExclusivity: { seconds: 0 } }), withSolver({ marketExclusivity: { [MARKET]: { seconds: 0 } } })]) {
      expect(exclusivityForMarket(dep, MARKET)).toBeUndefined();
      const o = build(dep, "sell");
      expect(o.exclusiveFiller).toBe(zeroAddress);
      expect(o.exclusivityOverrideBps).toBe(0n);
      expect(unpackTiming(o.timing).exclusivityEndTime).toBe(0);
    }
  });

  it("no solver configured: a pull market has nobody to favour — open from the start", () => {
    const dep = parseDeployments(BETA)[30] ?? null;
    expect(exclusivityForMarket(dep, MARKET)).toBeUndefined();
    expect(build(dep, "buy").exclusiveFiller).toBe(zeroAddress);
  });

  it("per-deployment and per-market overrides inherit field by field", () => {
    const dep = withSolver({ pullExclusivity: { seconds: 90 }, marketExclusivity: { [MARKET]: { overrideBps: 10 } } });
    expect(dep!.pullExclusivity).toEqual({ seconds: 90, overrideBps: 5 });
    expect(dep!.marketExclusivity[MARKET]).toEqual({ seconds: 90, overrideBps: 10 });
    expect(exclusivityForMarket(dep, MARKET)).toEqual({ filler: getAddress(AGG), seconds: 90, overrideBps: 10 });
    const o = build(dep, "sell");
    expect(unpackTiming(o.timing).exclusivityEndTime).toBe(NOW + 90);
    expect(o.exclusivityOverrideBps).toBe(10n);
  });

  it("DIRECT markets are unchanged: delta-verify, the solver for the whole life, no window, no override", () => {
    const dep = withSolver({ pullExclusivity: { seconds: 120, overrideBps: 50 } });
    expect(exclusivityForMarket(dep, "rsk-30-wrbtc-usd0")).toBeUndefined();
    const wr = marketById("rsk-30-wrbtc-usd0");
    const o = buildOrder({
      ...common,
      side: "sell",
      pay: pinnedToken(wr.chainId, wr.base)!,
      recv: pinnedToken(wr.chainId, wr.quote)!,
      amountIn: 0.01,
      targetOut: 1000,
      minOut: 995,
      solver: solverForMarket(dep, "rsk-30-wrbtc-usd0"),
      // Even if a caller passes a window, a direct order ignores it.
      exclusivity: { filler: getAddress(AGG), seconds: 60, overrideBps: 5 },
    }).order;
    expect((o.timing >> DELTA_VERIFY_OUTPUTS_BIT) & 1n).toBe(1n);
    expect(o.exclusiveFiller).toBe(getAddress(AGG));
    expect(o.exclusivityOverrideBps).toBe(0n);
    expect(unpackTiming(o.timing).exclusivityEndTime).toBe(0);
  });

  it("strict parsing: anything malformed drops the deployment", () => {
    const bad: Array<Record<string, unknown>> = [
      { pullExclusivity: { seconds: -1 } },
      { pullExclusivity: { seconds: 601 } },
      { pullExclusivity: { seconds: 1.5 } },
      { pullExclusivity: { seconds: "60" } },
      { pullExclusivity: { overrideBps: 0 } },
      { pullExclusivity: { overrideBps: 10_001 } },
      { pullExclusivity: { seconds: 60, overrideBps: 5, hard: true } },
      { pullExclusivity: [60, 5] },
      { pullExclusivity: null },
      { pullExclusivity: 60 },
      { marketExclusivity: { [MARKET]: { seconds: 60.5 } } },
      { marketExclusivity: { [MARKET]: null } },
      { marketExclusivity: [] },
      { marketExclusivity: "none" },
    ];
    for (const extra of bad) expect(withSolver(extra), JSON.stringify(extra)).toBeNull();
    // The bounds themselves are accepted.
    expect(withSolver({ pullExclusivity: { seconds: 600, overrideBps: 10_000 } })).not.toBeNull();
    expect(withSolver({ pullExclusivity: { seconds: 0, overrideBps: 1 } })).not.toBeNull();
  });
});

describe("the form's \"Filled by\" line", () => {
  it("states the signed delivery: direct, soft window then open, or open", async () => {
    const { deliveryLabel } = await import("../src/components/OrderForm");
    expect(deliveryLabel({ direct: true, windowSeconds: 0, overrideBps: 0 })).toBe("our solver only (direct delivery)");
    expect(deliveryLabel({ direct: false, windowSeconds: 60, overrideBps: 5 })).toBe("our solver first for ~2 blocks (others pay you +5 bps), then any filler");
    expect(deliveryLabel({ direct: false, windowSeconds: 0, overrideBps: 0 })).toBe("any filler");
  });
});
