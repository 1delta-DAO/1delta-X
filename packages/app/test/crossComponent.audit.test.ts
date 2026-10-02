import { describe, expect, it } from "vitest";
import { getAddress, zeroAddress } from "viem";

import { parseDeployments, solverForMarket } from "../src/config/deployments";
import { buildOrder, randomOrderNonce } from "../src/lib/order";

/**
 * 2026-09-30 audit, cross-component remediation (app side).
 */
describe("APP-RIF4 — per-market delta-verify filler", () => {
  const base = {
    settlement: "0x00000000000000000000000000000000005e771e",
    permit3: "0x000000000000000000000000000000000000aaaa",
    solver: "0x000000000000000000000000000000000000a660",
  };
  const INVENTORY = "0x000000000000000000000000000000000000f1d1";

  it("test_audit_APP_RIF4_inventoryMarketNamesItsOwnSolver", () => {
    const deps = parseDeployments(
      JSON.stringify({ 30: { ...base, marketSolvers: { "rsk-30-usdrif-usd0": INVENTORY } } }),
    );
    const dep = deps[30] ?? null;
    expect(solverForMarket(dep, "rsk-30-usdrif-usd0")).toBe(getAddress(INVENTORY));
    // Every other market keeps the deployment-wide aggregator solver.
    expect(solverForMarket(dep, "rsk-30-rif-usd0")).toBe(getAddress(base.solver));
    expect(solverForMarket(null, "rsk-30-usdrif-usd0")).toBeUndefined();
  });

  it("test_audit_APP_RIF4_badMarketSolverDropsTheDeployment", () => {
    expect(parseDeployments(JSON.stringify({ 30: { ...base, marketSolvers: { m: "0xnope" } } }))[30]).toBeUndefined();
    expect(parseDeployments(JSON.stringify({ 30: { ...base, marketSolvers: { m: zeroAddress } } }))[30]).toBeUndefined();
    expect(parseDeployments(JSON.stringify({ 30: base }))[30]?.marketSolvers).toEqual({});
  });
});

describe("G-TS_SIGN-3 — the app draws nonces through the SDK", () => {
  it("test_audit_G_TS_SIGN_3_appNonceAboveWatermarkBelowReservedHalf", () => {
    const floor = (1n << 255n) - 1000n;
    for (let i = 0; i < 50; i++) {
      const n = randomOrderNonce(floor);
      expect(n >= floor && n < 1n << 255n).toBe(true);
    }
    expect(typeof buildOrder).toBe("function");
  });
});
