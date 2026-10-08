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

/**
 * 2026-10-07 (ticket-sized market floor): the app sizes a small market ticket's floor
 * to clear the filler's quote haircut + gas (lib/marketFloor.ts). If the deployed
 * filler's haircut rises above the app's copy, every small ticket is signed a few bps
 * short of fillable and expires — so the copy is pinned to the deployed values in
 * packages/filler-worker/wrangler.toml, and the $1-token set to the filler's
 * default `USD_TOKENS` (packages/beta-filler/src/config.ts).
 */
describe("APP-FLOOR-1 — the app's floor mirrors the filler's haircut table", () => {
  const read = (...p: string[]): string => {
    const { readFileSync } = require("node:fs") as typeof import("node:fs");
    const { resolve } = require("node:path") as typeof import("node:path");
    return readFileSync(resolve(__dirname, "..", "..", ...p), "utf8");
  };
  const tomlVar = (name: string): number => {
    const m = read("filler-worker", "wrangler.toml").match(new RegExp(`^${name}\\s*=\\s*"(\\d+)"`, "m"));
    if (!m) throw new Error(`filler-worker/wrangler.toml has no ${name}`);
    return Number(m[1]);
  };

  it("test_audit_APP_FLOOR1_haircutsMatchFillerWrangler", async () => {
    const { FILLER_HAIRCUT_BPS, FILLER_STABLE_HAIRCUT_BPS, haircutBps } = await import("../src/lib/marketFloor");
    expect(FILLER_HAIRCUT_BPS).toBe(tomlVar("ROUTE_SLIPPAGE_BPS"));
    expect(FILLER_STABLE_HAIRCUT_BPS).toBe(tomlVar("ROUTE_STABLE_SLIPPAGE_BPS"));
    expect(haircutBps(30, "USDRIF", "USD0")).toBe(tomlVar("ROUTE_STABLE_SLIPPAGE_BPS"));
    expect(haircutBps(30, "WRBTC", "USD0")).toBe(tomlVar("ROUTE_SLIPPAGE_BPS"));
  });

  it("test_audit_APP_FLOOR1_haircutsMatchFillerDefaults", async () => {
    const { FILLER_HAIRCUT_BPS, FILLER_STABLE_HAIRCUT_BPS } = await import("../src/lib/marketFloor");
    const cfg = read("beta-filler", "src", "config.ts");
    const dflt = (name: string) => Number(cfg.match(new RegExp(`bps\\(env, "${name}", (\\d+)\\)`))?.[1]);
    expect(FILLER_HAIRCUT_BPS).toBe(dflt("ROUTE_SLIPPAGE_BPS"));
    expect(FILLER_STABLE_HAIRCUT_BPS).toBe(dflt("ROUTE_STABLE_SLIPPAGE_BPS"));
  });

  it("test_audit_APP_FLOOR1_usdTokensAreTheFillersUsdTokens", async () => {
    const { FLOOR_PROFILES } = await import("../src/lib/marketFloor");
    const { pinnedToken } = await import("../src/config/markets");
    const cfg = read("beta-filler", "src", "config.ts");
    const addr = (key: string) => cfg.match(new RegExp(`\\b${key}: "(0x[0-9a-fA-F]{40})"`))?.[1]?.toLowerCase();
    // The filler's default USD_TOKENS = [usdt0, usdrif]; the wrangler file does not override it.
    expect(read("filler-worker", "wrangler.toml")).not.toMatch(/^USD_TOKENS\s*=/m);
    const app = FLOOR_PROFILES[30]!.usd.map((s) => pinnedToken(30, s)?.address.toLowerCase()).sort();
    expect(app).toEqual([addr("usdt0"), addr("usdrif")].sort());
  });
});

/**
 * 2026-10-07 (gas priced closer to cost): the filler sends at the latest block's
 * minimumGasPrice × GAS_PRICE_MIN_MULT_BPS and prices a fill at eth_estimateGas × r,
 * r = DEFAULT_GAS_RECEIPT_RATIO until it learns a lower one from its receipts. The
 * app's floor uses the same multiplier and the same default ratio — if the deployed
 * filler paid more per gas or priced more gas than the app's copy, every gas-bound
 * small ticket would be signed short of fillable and expire.
 */
describe("APP-FLOOR-2 — the app's gas price multiplier and fill gas mirror the filler's defaults", () => {
  const read = (...p: string[]): string => {
    const { readFileSync } = require("node:fs") as typeof import("node:fs");
    const { resolve } = require("node:path") as typeof import("node:path");
    return readFileSync(resolve(__dirname, "..", "..", ...p), "utf8");
  };
  const tomlVar = (name: string): string => {
    const m = read("filler-worker", "wrangler.toml").match(new RegExp(`^${name}\\s*=\\s*"([0-9.]+)"`, "m"));
    if (!m) throw new Error(`filler-worker/wrangler.toml has no ${name}`);
    return m[1]!;
  };

  it("test_audit_APP_FLOOR2_gasPriceMultiplierMatchesFiller", async () => {
    const { FILLER_GAS_PRICE_MIN_MULT_BPS, ROOTSTOCK_FALLBACK_GAS_PRICE_WEI, ROOTSTOCK_MIN_GAS_PRICE_WEI } = await import("../src/lib/marketFloor");
    expect(FILLER_GAS_PRICE_MIN_MULT_BPS).toBe(Number(tomlVar("GAS_PRICE_MIN_MULT_BPS")));
    // …and the beta-filler's own default (config.ts DEFAULT_GAS_PRICE_MIN_MULT_BPS).
    const cfg = read("beta-filler", "src", "config.ts");
    expect(FILLER_GAS_PRICE_MIN_MULT_BPS).toBe(Number(cfg.match(/DEFAULT_GAS_PRICE_MIN_MULT_BPS = ([\d_]+);/)?.[1]?.replace(/_/g, "")));
    expect(ROOTSTOCK_FALLBACK_GAS_PRICE_WEI).toBe((ROOTSTOCK_MIN_GAS_PRICE_WEI * BigInt(FILLER_GAS_PRICE_MIN_MULT_BPS) + 9_999n) / 10_000n);
  });

  it("test_audit_APP_FLOOR2_fillGasIsEstimateTimesFillerDefaultRatio", async () => {
    const { DEFAULT_FILL_GAS, FILLER_DEFAULT_GAS_RECEIPT_RATIO_PPM, FILLER_FILL_GAS_ESTIMATE } = await import("../src/lib/marketFloor");
    const ppm = (dec: string) => Math.round(Number(dec) * 1e6);
    expect(FILLER_DEFAULT_GAS_RECEIPT_RATIO_PPM).toBe(ppm(tomlVar("DEFAULT_GAS_RECEIPT_RATIO")));
    const cfg = read("beta-filler", "src", "config.ts");
    expect(FILLER_DEFAULT_GAS_RECEIPT_RATIO_PPM).toBe(ppm(cfg.match(/"DEFAULT_GAS_RECEIPT_RATIO", "([0-9.]+)"/)![1]!));
    // The floor prices AT LEAST what the filler prices before any receipt (its learned
    // ratio only goes lower), so the filler can always fill before the floor.
    for (const k of ["direct", "pull"] as const) {
      expect(DEFAULT_FILL_GAS[k]).toBeGreaterThanOrEqual((FILLER_FILL_GAS_ESTIMATE[k] * FILLER_DEFAULT_GAS_RECEIPT_RATIO_PPM) / 1e6);
      expect(DEFAULT_FILL_GAS[k] - (FILLER_FILL_GAS_ESTIMATE[k] * FILLER_DEFAULT_GAS_RECEIPT_RATIO_PPM) / 1e6).toBeLessThan(1_000);
    }
    expect(DEFAULT_FILL_GAS).toEqual({ direct: 352_000, pull: 370_000 });
  });
});
