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

/**
 * Review 2026-10-05 (H1): three shipped defaults share one number and nothing
 * reconciled them — the app's market TTL (60 s) was below the beta book's
 * `MIN_TTL_SECONDS` (120 s), so every market ticket was refused with a 422, and
 * below the filler's `EXPIRY_MARGIN_SECONDS` (90 s), so an admitted one would
 * never have been quoted. Read the two wrangler files so the triangle is pinned
 * where the numbers actually live.
 */
describe("APP-TTL-1 — a market order outlives the book's minimum TTL and the filler's expiry margin", () => {
  const wranglerVar = (pkg: string, name: string): number => {
    const { readFileSync } = require("node:fs") as typeof import("node:fs");
    const { resolve } = require("node:path") as typeof import("node:path");
    const toml = readFileSync(resolve(__dirname, "..", "..", pkg, "wrangler.toml"), "utf8");
    const m = toml.match(new RegExp(`^${name}\\s*=\\s*"(\\d+)"`, "m"));
    if (!m) throw new Error(`${pkg}/wrangler.toml has no ${name}`);
    return Number(m[1]);
  };

  it("test_audit_APP_TTL1_marketTtlClearsBookMinAndFillerMargin", async () => {
    const { MARKET_TTL_SECONDS, MARKET_DECAY_SECONDS } = await import("../src/lib/plan");
    const bookMin = wranglerVar("orderbook-worker", "MIN_TTL_SECONDS");
    const fillerMargin = wranglerVar("filler-worker", "EXPIRY_MARGIN_SECONDS");
    // Admitted by the book at all…
    expect(MARKET_TTL_SECONDS).toBeGreaterThanOrEqual(bookMin);
    // …and still quotable by the filler for at least two Rootstock blocks after
    // the auction has reached its floor.
    expect(MARKET_TTL_SECONDS - fillerMargin - MARKET_DECAY_SECONDS).toBeGreaterThanOrEqual(60);
    // The auction itself is the short part.
    expect(MARKET_DECAY_SECONDS).toBeLessThan(MARKET_TTL_SECONDS);
  });
});
