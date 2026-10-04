import { describe, expect, it } from "vitest";
import { DELTA_VERIFY_OUTPUTS_BIT } from "@1delta-x/sdk";
import { getAddress, zeroAddress } from "viem";

import { PULL_MODE, isPullMarket, parseDeployments, solverForMarket } from "../src/config/deployments";
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
