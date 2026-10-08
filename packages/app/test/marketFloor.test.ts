/**
 * 2026-10-07: the ticket-sized market floor (lib/marketFloor.ts). A flat 30 bps floor
 * cannot pay the filler's fixed ~$0.60 of gas on a $20 ticket, so that ticket only
 * ever expired. The floor is now max(30, haircut + ⌈gas / expectedOut⌉ + 2) bps —
 * never refused, only clamped below 100 % for numerical sanity.
 */
import { describe, expect, it } from "vitest";

import { parseDeployments } from "../src/config/deploymentConfig";
import { readGasPrice } from "../src/lib/chain";
import { quote } from "../src/lib/ladder";
import {
  DEFAULT_FILL_GAS,
  FILLER_DEFAULT_GAS_RECEIPT_RATIO_PPM,
  FILLER_FILL_GAS_ESTIMATE,
  FILLER_GAS_PRICE_MIN_MULT_BPS,
  FILLER_HAIRCUT_BPS,
  FILLER_STABLE_HAIRCUT_BPS,
  FLOOR_BUFFER_BPS,
  FLOOR_PROFILES,
  MAX_FLOOR_BPS,
  ROOTSTOCK_FALLBACK_GAS_PRICE_WEI,
  ROOTSTOCK_MIN_GAS_PRICE_WEI,
  fillGasFor,
  floorInputsFor,
  haircutBps,
  marketFloor,
  nativeInToken,
  type FloorInputs,
} from "../src/lib/marketFloor";
import { MARKET_SLIPPAGE_BPS, planTicket } from "../src/lib/plan";
import type { Level, Side } from "../src/lib/types";

/**
 * Live Rootstock, 2026-10-07: block minimumGasPrice 23,696,000 wei → the filler sends
 * at × 1.03 = 24,406,880 wei (eth_gasPrice says × 1.1 = 26,065,600); RBTC ≈ $85,500.
 */
const GAS_PRICE = 24_406_880n;
const RBTC_USD = 85_500;
const gasUsd = (fillGas: number) => (Number(GAS_PRICE * BigInt(fillGas)) / 1e18) * RBTC_USD;

const stable: FloorInputs = { gasPriceWei: GAS_PRICE, fillGas: DEFAULT_FILL_GAS.pull, nativeInRecv: RBTC_USD, haircutBps: FILLER_STABLE_HAIRCUT_BPS };
const volatile: FloorInputs = { gasPriceWei: GAS_PRICE, fillGas: DEFAULT_FILL_GAS.direct, nativeInRecv: RBTC_USD, haircutBps: FILLER_HAIRCUT_BPS };
const floorOf = (out: number, f: FloorInputs) => marketFloor(out, f, MARKET_SLIPPAGE_BPS);

describe("marketFloor — the formula", () => {
  it("$20 USDRIF→USDT0 (stable, pull): haircut 5 + gas + 2 bps, far above the flat 30", () => {
    const f = floorOf(20, stable);
    const gasBps = Math.ceil((gasUsd(DEFAULT_FILL_GAS.pull) / 20) * 1e4);
    expect(f.gasBps).toBe(gasBps);
    expect(f.bps).toBe(FILLER_STABLE_HAIRCUT_BPS + gasBps + FLOOR_BUFFER_BPS);
    expect(f.bps).toBe(394); // 5 + 387 + 2
    expect(f.gasBound).toBe(true);
    expect(f.gasCostOut).toBeCloseTo(0.772, 3); // 370k gas × 24.41 Mwei × $85.5k
    // The filler breaks even at haircut + gas, so it fills there, not at the floor.
    expect(f.likelyBps).toBe(5 + 387);
  });

  it("$20 WRBTC→USDT0 (volatile, direct): haircut 10 + gas + 2 bps", () => {
    const f = floorOf(20, volatile);
    expect(f.bps).toBe(10 + 368 + 2);
    expect(f.gasBound).toBe(true);
  });

  it("$20 of WRBTC received (a BUY): gas priced in WRBTC, same bps", () => {
    const out = 20 / RBTC_USD; // WRBTC
    const f = floorOf(out, { ...volatile, nativeInRecv: 1 });
    expect(f.bps).toBe(380);
  });

  it("$5,000: gas is ~1 bp, so the flat 30 bps floor stands", () => {
    for (const f of [floorOf(5_000, stable), floorOf(5_000, volatile)]) {
      expect(f.bps).toBe(MARKET_SLIPPAGE_BPS);
      expect(f.gasBound).toBe(false);
      // Gas ≈ 2 bps: the filler fills at ~haircut + 2, well above the 30 bps floor.
      expect(f.likelyBps).toBeLessThan(15);
    }
  });

  it("the examples table", () => {
    const table = [20, 100, 300, 1_000].map((usd) => [usd, floorOf(usd, volatile).bps, floorOf(usd, stable).bps]);
    expect(table).toEqual([
      [20, 380, 394],
      [100, 86, 85],
      [300, 37, 33],
      [1_000, 30, 30],
    ]);
  });

  it("never refuses: a $5 ticket just gets a ~15 % floor", () => {
    const f = floorOf(5, volatile);
    expect(f.bps).toBe(10 + 1470 + 2);
    expect(Number.isFinite(f.bps)).toBe(true);
  });

  it("sanity clamp: a ticket worth less than its gas, or zero, never yields a floor ≥ 100 % or NaN", () => {
    for (const out of [0.1, 0, -1, Number.NaN]) {
      const f = floorOf(out, volatile);
      expect(f.bps).toBe(MAX_FLOOR_BPS);
      expect(Number.isFinite(f.gasCostOut)).toBe(true);
    }
  });

  it("a caller's base bps (the e2e economics override) still widens the floor", () => {
    expect(floorOf(5_000, { ...volatile, baseBps: 80 }).bps).toBe(80);
  });
});

describe("marketFloor — inputs", () => {
  it("haircut: stable only when BOTH legs are $1 tokens", () => {
    expect(haircutBps(30, "USDRIF", "USD0")).toBe(FILLER_STABLE_HAIRCUT_BPS);
    expect(haircutBps(30, "WRBTC", "USD0")).toBe(FILLER_HAIRCUT_BPS);
    expect(haircutBps(30, "WETH", "WRBTC")).toBe(FILLER_HAIRCUT_BPS);
  });

  it("native price per receive token", () => {
    const ctx = { marketId: "rsk-30-wrbtc-usd0", mid: RBTC_USD, nativeUsd: RBTC_USD };
    expect(nativeInToken(30, "WRBTC", ctx)).toBe(1);
    expect(nativeInToken(30, "USD0", ctx)).toBe(RBTC_USD);
    expect(nativeInToken(30, "USDRIF", { ...ctx, marketId: "rsk-30-usdrif-usd0", mid: 1 })).toBe(RBTC_USD);
    expect(nativeInToken(30, "USDRIF", { ...ctx, marketId: "rsk-30-usdrif-usd0", mid: 1, nativeUsd: null })).toBeNull();
    // An absurd pool read is no price at all.
    expect(nativeInToken(30, "USD0", { ...ctx, nativeUsd: 3 })).toBeNull();
    expect(nativeInToken(30, "USD0", { ...ctx, nativeUsd: Number.POSITIVE_INFINITY })).toBeNull();
    // WETH/WRBTC at 0.05 WRBTC per WETH ⇒ 1 RBTC = 20 WETH.
    expect(nativeInToken(30, "WETH", { marketId: "rsk-30-weth-wrbtc", mid: 0.05, nativeUsd: null })).toBeCloseTo(20);
    expect(nativeInToken(1, "USDC", ctx)).toBeNull();
  });

  const dep = (extra: Record<string, unknown> = {}) =>
    parseDeployments(
      JSON.stringify({
        30: {
          settlement: "0x00000000000000000000000000000000005e771e",
          permit3: "0x000000000000000000000000000000000000aaaa",
          solver: "0x000000000000000000000000000000000000a660",
          marketSolvers: { "rsk-30-usdrif-usd0": "pull" },
          ...extra,
        },
      }),
    )[30] ?? null;

  it("fill gas: direct for a solver-named market, pull for a pull market or no deployment", () => {
    expect(fillGasFor(dep(), "rsk-30-wrbtc-usd0")).toBe(DEFAULT_FILL_GAS.direct);
    expect(fillGasFor(dep(), "rsk-30-usdrif-usd0")).toBe(DEFAULT_FILL_GAS.pull);
    expect(fillGasFor(null, "rsk-30-wrbtc-usd0")).toBe(DEFAULT_FILL_GAS.pull);
    expect(fillGasFor(dep({ fillGas: { direct: 300_000 } }), "rsk-30-wrbtc-usd0")).toBe(300_000);
    expect(fillGasFor(dep({ fillGas: { direct: 300_000 } }), "rsk-30-usdrif-usd0")).toBe(DEFAULT_FILL_GAS.pull);
  });

  it("fillGas config is strict: a bad value drops the deployment", () => {
    for (const bad of [{ direct: 0 }, { pull: 1.5 }, { pull: "290000" }, { other: 1 }, [], null]) {
      expect(dep({ fillGas: bad })).toBeNull();
    }
  });

  it("gas price: live, lifted to the chain minimum, fallback when the read failed or is absurd", () => {
    const at = (gasPriceWei: bigint | null) =>
      floorInputsFor({ chainId: 30, marketId: "rsk-30-wrbtc-usd0", side: "sell", deployment: dep(), gasPriceWei, mid: RBTC_USD, nativeUsd: RBTC_USD })!;
    expect(at(40_000_000n).gasPriceWei).toBe(40_000_000n);
    expect(at(40_000_000n).fallback).toEqual({ gasPrice: false, nativePrice: false });
    expect(at(1n).gasPriceWei).toBe(ROOTSTOCK_MIN_GAS_PRICE_WEI);
    expect(at(null).gasPriceWei).toBe(ROOTSTOCK_FALLBACK_GAS_PRICE_WEI);
    expect(at(null).fallback?.gasPrice).toBe(true);
    expect(at(0n).gasPriceWei).toBe(ROOTSTOCK_FALLBACK_GAS_PRICE_WEI);
    expect(at(10n ** 15n).gasPriceWei).toBe(ROOTSTOCK_FALLBACK_GAS_PRICE_WEI);
    expect(ROOTSTOCK_FALLBACK_GAS_PRICE_WEI).toBe(24_406_880n); // the minimum × 1.03, what the filler pays
    expect(at(null).fillGas).toBe(DEFAULT_FILL_GAS.direct);
    expect(at(null).haircutBps).toBe(FILLER_HAIRCUT_BPS);
    expect(at(null).nativeInRecv).toBe(RBTC_USD);
  });

  it("fill gas defaults = the filler's estimate × its default receipt ratio: 400k → 352k, 420k → 370k", () => {
    expect(FILLER_FILL_GAS_ESTIMATE).toEqual({ direct: 400_000, pull: 420_000 });
    expect(FILLER_DEFAULT_GAS_RECEIPT_RATIO_PPM).toBe(880_000);
    expect(DEFAULT_FILL_GAS).toEqual({ direct: 352_000, pull: 370_000 });
  });

  it("readGasPrice: latest block minimumGasPrice × 1.03 (what the filler sends at), rounded up", async () => {
    const reader = (block: unknown, gasPrice: bigint | Error = 26_065_600n) => ({
      getBlock: async () => {
        if (block instanceof Error) throw block;
        return block;
      },
      getGasPrice: async () => {
        if (gasPrice instanceof Error) throw gasPrice;
        return gasPrice;
      },
    });
    expect(FILLER_GAS_PRICE_MIN_MULT_BPS).toBe(10_300);
    expect(await readGasPrice(reader({ minimumGasPrice: "0x1699280" }), FILLER_GAS_PRICE_MIN_MULT_BPS)).toBe(24_406_880n);
    expect(await readGasPrice(reader({ minimumGasPrice: "0x65" }), 10_300)).toBe(105n); // ⌈101 × 1.03⌉ = ⌈104.03⌉
    // No field (a non-Rootstock node / anvil without the proxy), a failed block read, no getBlock:
    // eth_gasPrice / 1.1 (rskj's buffer) × 1.03.
    expect(await readGasPrice(reader({ number: "0x1" }), 10_300)).toBe(24_406_880n);
    expect(await readGasPrice(reader(new Error("rpc")), 10_300)).toBe(24_406_880n);
    expect(await readGasPrice({ getGasPrice: async () => 26_065_600n }, 10_300)).toBe(24_406_880n);
    // Both reads fail / nonsense: null → the floor's fallback.
    expect(await readGasPrice(reader(null, new Error("rpc")), 10_300)).toBeNull();
    expect(await readGasPrice(reader({ minimumGasPrice: "0x0" }, 0n), 10_300)).toBeNull();
  });

  it("native price: a failed / absurd USD read falls back to the conservative constant, marked approximate", () => {
    const usdrif = (nativeUsd: number | null) =>
      floorInputsFor({ chainId: 30, marketId: "rsk-30-usdrif-usd0", side: "sell", deployment: dep(), gasPriceWei: GAS_PRICE, mid: 1, nativeUsd })!;
    expect(usdrif(RBTC_USD).nativeInRecv).toBe(RBTC_USD);
    for (const broken of [null, 0, -5, Number.NaN, 1e12]) {
      const f = usdrif(broken);
      expect(f.nativeInRecv).toBe(FLOOR_PROFILES[30]!.fallbackNativeUsd);
      expect(f.fallback?.nativePrice).toBe(true);
      expect(marketFloor(20, f, MARKET_SLIPPAGE_BPS).approximate).toBe(true);
    }
    expect(usdrif(RBTC_USD).haircutBps).toBe(FILLER_STABLE_HAIRCUT_BPS);
    expect(usdrif(RBTC_USD).fillGas).toBe(DEFAULT_FILL_GAS.pull);
  });

  it("no filler profile on the chain ⇒ no gas sizing (flat floor)", () => {
    expect(
      floorInputsFor({ chainId: 1, marketId: "eth-1-eth-usdc", side: "sell", deployment: null, gasPriceWei: null, mid: 2000, nativeUsd: null }),
    ).toBeUndefined();
  });
});

describe("planTicket — the market floor is the one the order signs", () => {
  /** One fee-net rung each side at `mid`, deep enough to cross the ticket in full. */
  const q = (side: Side, amountIn: number, mid: number) => {
    const lvl = (price: number): Level[] => [{ price, size: 1e9, source: "UNI" }];
    return quote({ bids: lvl(mid), asks: lvl(mid), side, amountIn, limit: null, slippageBps: MARKET_SLIPPAGE_BPS });
  };
  const plan = (side: Side, amount: number, mid: number, floor?: FloorInputs) =>
    planTicket({ q: q(side, amount, mid), mid, mode: "market", side, amount, limit: null, slices: 1, everyMin: 1, floor })!;

  it("without floor inputs: unchanged (flat 30 bps from the quote)", () => {
    const p = plan("sell", 1, 1);
    expect(p.floor).toBeUndefined();
    expect(p.minOut).toBeCloseTo(1 * (1 - MARKET_SLIPPAGE_BPS / 1e4), 12);
  });

  it("$20 USDRIF sell: minOut = targetOut × (1 − 394 bps)", () => {
    const p = plan("sell", 20, 1, stable);
    expect(p.floor!.bps).toBe(394);
    expect(p.targetOut).toBeCloseTo(20, 9);
    expect(p.minOut).toBeCloseTo(20 * (1 - 0.0394), 9);
  });

  it("$5,000 WRBTC sell: the flat 30 bps", () => {
    const p = plan("sell", 5_000 / RBTC_USD, RBTC_USD, volatile);
    expect(p.floor!.bps).toBe(30);
    expect(p.minOut).toBeCloseTo(5_000 * 0.997, 6);
  });

  it("$20 WRBTC buy: floor on the WRBTC received", () => {
    const p = plan("buy", 20, RBTC_USD, { ...volatile, nativeInRecv: 1 });
    expect(p.floor!.bps).toBe(380);
    expect(p.minOut).toBeCloseTo((20 / RBTC_USD) * (1 - 0.038), 12);
  });

  it("a tiny ticket is planned (not refused) with a positive minimum", () => {
    const p = plan("sell", 0.5, 1, stable);
    expect(p.floor!.bps).toBe(MAX_FLOOR_BPS);
    expect(p.minOut).toBeGreaterThan(0);
  });

  it("limit and TWAP tickets ignore the floor inputs", () => {
    const qq = quote({ bids: [{ price: 1, size: 1e9, source: "UNI" }], asks: [{ price: 1, size: 1e9, source: "UNI" }], side: "sell", amountIn: 20, limit: 1.1, slippageBps: 30 });
    const p = planTicket({ q: qq, mid: 1, mode: "limit", side: "sell", amount: 20, limit: 1.1, slices: 1, everyMin: 1, floor: stable })!;
    expect(p.floor).toBeUndefined();
    const t = planTicket({ q: qq, mid: 1, mode: "twap", side: "sell", amount: 20, limit: 1.1, slices: 4, everyMin: 5, floor: stable })!;
    expect(t.floor).toBeUndefined();
  });
});
