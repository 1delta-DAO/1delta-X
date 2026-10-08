/**
 * The TICKET-SIZED market floor (2026-10-07).
 *
 * A market order's floor is what the maker is guaranteed, and the beta filler only
 * fills an order when, at the owed amount,
 *
 *     quote × (1 − haircut) ≥ owed + gas (+ min profit, 0 by default)
 *
 * (packages/beta-filler, `RouteFiller` profitability check). `quote` ≈ the ladder's
 * EXECUTABLE (fee-net) output and the auction's `owed` decays from it to
 * expectedOut × (1 − floor), so the floor has to clear `haircut + gas / expectedOut`.
 * The filler prices a fill at ~$0.75 of gas on Rootstock today, so a flat 30 bps
 * floor works from ~$300 up and a $20 test ticket (gas ≈ 380 bps of it) could never be
 * filled — it just expired. The floor is therefore
 *
 *     floorBps = max(MARKET_SLIPPAGE_BPS,
 *                    haircutBps(pair) + ⌈gasCostInRecv / expectedOut × 1e4⌉ + FLOOR_BUFFER_BPS)
 *
 * Small tickets are NOT refused: they get a worse floor, and the form says how much
 * of it is network gas. The filler takes the order as soon as the decaying auction
 * crosses its break-even (`haircut + gas`), so the likely fill is near that, not at
 * the floor ({@link MarketFloor.likelyBps}).
 *
 * The only bound is a sanity one: broken inputs (a gas price or native price read
 * that failed or is absurd) fall back to Rootstock's gas price and a conservative
 * native price, so the floor is never NaN / infinite, and it is clamped below 100 %
 * ({@link MAX_FLOOR_BPS}) so `minOut` stays positive.
 *
 * Pure and node-importable: the app (`App.tsx`) and the filler-worker app-shape e2e
 * (`packages/filler-worker/e2e/app-shape.ts`) build the floor with the same code.
 */
import { zeroAddress } from "viem";

import {
  DEFAULT_FILL_GAS,
  FILLER_DEFAULT_GAS_RECEIPT_RATIO_PPM,
  FILLER_FILL_GAS_ESTIMATE,
  solverForMarket,
  type DeploymentConfig,
  type FillGas,
} from "../config/deploymentConfig";
import { marketById } from "../config/markets";

import type { Side } from "./types";

/** Headroom on top of haircut + gas: price drift between quote and fill, rounding. */
export const FLOOR_BUFFER_BPS = 2;
/**
 * Numerical sanity clamp only (NOT a policy cap): a ticket worth less than one
 * fill's gas would otherwise sign a floor ≥ 100 % — a zero or negative `minOut`.
 */
export const MAX_FLOOR_BPS = 9_900;
/** The form calls a floor above this out prominently ("small order: ~X % goes to network gas"). */
export const GAS_NOTE_BPS = 100;

/**
 * The beta filler's quote haircuts — MUST equal `ROUTE_SLIPPAGE_BPS` /
 * `ROUTE_STABLE_SLIPPAGE_BPS` in packages/filler-worker/wrangler.toml (the deployed
 * values; packages/beta-filler/src/config.ts carries the same defaults). Pinned by
 * `test/crossComponent.audit.test.ts` (APP-FLOOR-1), which reads that file.
 */
export const FILLER_HAIRCUT_BPS = 10;
/** Haircut when BOTH tokens are $1 tokens (the filler's `USD_TOKENS`). */
export const FILLER_STABLE_HAIRCUT_BPS = 5;

/**
 * Gas of one fill AS THE FILLER PRICES IT — direct 352k / pull 370k. The filler's gate
 * charges `eth_estimateGas` × r (production e2e 2026-10-07 estimates: 363k–385k direct,
 * 386k–404k pull — the defaults take the top, 400k / 420k, as the 2 bps buffer cannot
 * absorb that spread on a $20 ticket), r = the receipt/estimate ratio it learns per
 * fill shape, 0.88 before its first receipt. The learned r only goes lower (receipts
 * ran 0.845–0.877 on a fresh solver), so this floor stays conservative and the filler
 * fills before the auction reaches it. Defined with the deployment config, which may
 * override it (`fillGas`).
 */
export { DEFAULT_FILL_GAS, FILLER_DEFAULT_GAS_RECEIPT_RATIO_PPM, FILLER_FILL_GAS_ESTIMATE, type FillGas };

/**
 * The filler sends every tx at ⌈latest block `minimumGasPrice` × this / 10000⌉ — MUST
 * equal `GAS_PRICE_MIN_MULT_BPS` in packages/filler-worker/wrangler.toml (pinned by
 * test/crossComponent.audit.test.ts, APP-FLOOR-2). +3 %: the minimum moves at most
 * ±1 % per block (RSKIP-09), so the tx outlasts two maximal rises.
 */
export const FILLER_GAS_PRICE_MIN_MULT_BPS = 10_300;
/**
 * Rootstock's `minimumGasPrice` (block header, read 2026-10-07: 23,696,000 wei, flat
 * since ~March 2025). The fallback when the live read fails (no wallet, wrong chain)
 * is what the filler pays at that minimum: × 1.03 = 24,406,880 wei (`eth_gasPrice`,
 * min × 1.1, is ~7 % above what the filler pays).
 */
export const ROOTSTOCK_MIN_GAS_PRICE_WEI = 23_696_000n;
export const ROOTSTOCK_FALLBACK_GAS_PRICE_WEI = (ROOTSTOCK_MIN_GAS_PRICE_WEI * BigInt(FILLER_GAS_PRICE_MIN_MULT_BPS) + 9_999n) / 10_000n;
/**
 * A live gas price above this is treated as a broken read (fallback instead): the
 * filler's own `MAX_GAS_PRICE_GWEI` (0.1 gwei) — above it the filler stops filling, so
 * no floor sized to it would ever be used. Was 1 gwei, which let anvil's default
 * `eth_gasPrice` (1 gwei, ~38× Rootstock's) through and inflated a $300 floor to 8 %.
 */
export const ROOTSTOCK_MAX_SANE_GAS_PRICE_WEI = 100_000_000n;

/**
 * Chains a filler runs on, so where the gas-sized floor applies. Elsewhere the floor
 * stays the flat MARKET_SLIPPAGE_BPS (no filler, no gas to cover).
 */
export interface FloorProfile {
  /** Wrapped-native symbol: gas is paid in it. */
  native: string;
  /** $1 tokens (the filler's `USD_TOKENS`): stable haircut, and priced at the native's USD mid. */
  usd: readonly string[];
  /** Market whose (pool) mid prices the native in USD. */
  nativeUsdMarket: string;
  minGasPriceWei: bigint;
  fallbackGasPriceWei: bigint;
  maxSaneGasPriceWei: bigint;
  /** A pool-derived native USD price outside this band is a broken read. */
  saneNativeUsd: readonly [number, number];
  /**
   * Last resort when no pool price has EVER been read: deliberately high, so gas is
   * over- rather than under-priced (a floor that is too low is an order that expires).
   */
  fallbackNativeUsd: number;
}
export const FLOOR_PROFILES: Readonly<Record<number, FloorProfile>> = Object.freeze({
  30: {
    native: "WRBTC",
    usd: ["USD0", "USDRIF"],
    nativeUsdMarket: "rsk-30-wrbtc-usd0",
    minGasPriceWei: ROOTSTOCK_MIN_GAS_PRICE_WEI,
    fallbackGasPriceWei: ROOTSTOCK_FALLBACK_GAS_PRICE_WEI,
    maxSaneGasPriceWei: ROOTSTOCK_MAX_SANE_GAS_PRICE_WEI,
    saneNativeUsd: [1_000, 10_000_000],
    fallbackNativeUsd: 150_000,
  },
});

/** The filler's haircut for a pair: stable when both legs are $1 tokens. */
export function haircutBps(chainId: number, a: string, b: string): number {
  const usd = FLOOR_PROFILES[chainId]?.usd ?? [];
  return usd.includes(a) && usd.includes(b) ? FILLER_STABLE_HAIRCUT_BPS : FILLER_HAIRCUT_BPS;
}

/** What {@link marketFloor} needs besides the quote. */
export interface FloorInputs {
  gasPriceWei: bigint;
  fillGas: number;
  /** RECEIVE-token units one native (RBTC) is worth. Positive and finite (see floorInputsFor). */
  nativeInRecv: number;
  haircutBps: number;
  /** The flat floor the result never goes under. Default MARKET_SLIPPAGE_BPS (plan.ts). */
  baseBps?: number;
  /** Which inputs fell back from a live / pool read — the form says "approximate". */
  fallback?: { gasPrice: boolean; nativePrice: boolean };
}

export interface MarketFloor {
  /** The effective floor, bps under the executable price — what the order guarantees. */
  bps: number;
  baseBps: number;
  haircutBps: number;
  gasBps: number;
  bufferBps: number;
  /**
   * Where the filler breaks even (`haircut + gas`, capped at the floor): it fills as
   * soon as the auction decays this far, so this — not the floor — is the likely
   * price. Approximate: the auction moves on ~30 s blocks.
   */
  likelyBps: number;
  /** One fill's gas, in the RECEIVE token. */
  gasCostOut: number;
  /** True when gas (not the flat base) set the floor — a small ticket. */
  gasBound: boolean;
  /** Copied from the inputs: a live read failed and a fallback priced the gas. */
  approximate: boolean;
}

/**
 * The floor for a market ticket expected to receive `expectedOut` (executable,
 * RECEIVE token). `defaultBaseBps` is the flat floor when `f.baseBps` is unset —
 * plan.ts passes MARKET_SLIPPAGE_BPS (kept there; this file must not import plan.ts).
 * Total: any non-finite input degrades to the flat base, never to NaN.
 */
export function marketFloor(expectedOut: number, f: FloorInputs, defaultBaseBps: number): MarketFloor {
  const base = f.baseBps ?? defaultBaseBps;
  const approximate = !!(f.fallback?.gasPrice || f.fallback?.nativePrice);
  const gasNative = Number(f.gasPriceWei * BigInt(Math.max(0, Math.round(f.fillGas)))) / 1e18;
  const gasCostOut = gasNative * f.nativeInRecv;
  const share = expectedOut > 0 ? (gasCostOut / expectedOut) * 1e4 : Number.POSITIVE_INFINITY;
  // Ceil, with a hair of tolerance so float noise on an exact bps does not add one.
  const gasBps = Number.isFinite(share) ? Math.min(MAX_FLOOR_BPS, Math.max(0, Math.ceil(share - 1e-9))) : MAX_FLOOR_BPS;
  const needed = f.haircutBps + gasBps + FLOOR_BUFFER_BPS;
  const bps = Math.min(MAX_FLOOR_BPS, Math.max(base, needed));
  return {
    bps,
    baseBps: base,
    haircutBps: f.haircutBps,
    gasBps,
    bufferBps: FLOOR_BUFFER_BPS,
    likelyBps: Math.min(bps, f.haircutBps + gasBps),
    gasCostOut: Number.isFinite(gasCostOut) ? gasCostOut : 0,
    gasBound: needed > base,
    approximate,
  };
}

/**
 * RECEIVE-token units per one native, from what the app already prices: the native
 * itself is 1, a $1 token is the native's USD (pool) mid, and the other leg of a
 * native-quoted market is the market's own mid (or its inverse). `null` when none
 * applies or the price is not in yet.
 */
export function nativeInToken(
  chainId: number,
  symbol: string,
  ctx: { marketId: string; mid: number | null; nativeUsd: number | null },
): number | null {
  const p = FLOOR_PROFILES[chainId];
  if (!p) return null;
  if (symbol === p.native) return 1;
  const ok = (x: number | null): x is number => x !== null && Number.isFinite(x) && x > 0;
  if (p.usd.includes(symbol)) {
    const [lo, hi] = p.saneNativeUsd;
    return ok(ctx.nativeUsd) && ctx.nativeUsd >= lo && ctx.nativeUsd <= hi ? ctx.nativeUsd : null;
  }
  if (!ok(ctx.mid)) return null;
  const m = marketById(ctx.marketId);
  if (m.base === p.native && m.quote === symbol) return ctx.mid;
  if (m.quote === p.native && m.base === symbol) return 1 / ctx.mid;
  return null;
}

/** Fill gas for a market: direct when its orders name a solver (delta-verify), else pull. */
export function fillGasFor(deployment: DeploymentConfig | null, marketId: string): number {
  const g = deployment?.fillGas ?? DEFAULT_FILL_GAS;
  const solver = solverForMarket(deployment, marketId);
  return solver && solver !== zeroAddress ? g.direct : g.pull;
}

/**
 * Everything {@link marketFloor} needs for one ticket, or `undefined` on a chain
 * without a {@link FloorProfile} (flat floor) or when the receive token cannot be
 * priced in the native at all (no mid yet).
 *
 * Sanity: a live gas price that is missing (`null`: read failed / no wallet), not
 * positive, or above `maxSaneGasPriceWei` → the profile's fallback; one below the
 * chain minimum is lifted to it. A missing or out-of-band native USD price → the
 * profile's conservative `fallbackNativeUsd`.
 */
export function floorInputsFor(a: {
  chainId: number;
  marketId: string;
  side: Side;
  deployment: DeploymentConfig | null;
  gasPriceWei: bigint | null;
  /** The market's own (fee-net) mid. */
  mid: number | null;
  /** USD per native, from {@link FloorProfile.nativeUsdMarket}'s pool mid. */
  nativeUsd: number | null;
  baseBps?: number;
}): FloorInputs | undefined {
  const p = FLOOR_PROFILES[a.chainId];
  if (!p) return undefined;
  const m = marketById(a.marketId);
  const recv = a.side === "sell" ? m.quote : m.base;
  const live = a.gasPriceWei;
  const gasBroken = live === null || live <= 0n || live > p.maxSaneGasPriceWei;
  const gasPriceWei = gasBroken ? p.fallbackGasPriceWei : live < p.minGasPriceWei ? p.minGasPriceWei : live;
  const ctx = { marketId: a.marketId, mid: a.mid, nativeUsd: a.nativeUsd };
  let nativeInRecv = nativeInToken(a.chainId, recv, ctx);
  let nativeFallback = false;
  if (nativeInRecv === null && p.usd.includes(recv)) {
    nativeInRecv = p.fallbackNativeUsd;
    nativeFallback = true;
  }
  if (nativeInRecv === null) return undefined;
  return {
    gasPriceWei,
    fillGas: fillGasFor(a.deployment, a.marketId),
    nativeInRecv,
    haircutBps: haircutBps(a.chainId, m.base, m.quote),
    baseBps: a.baseBps,
    fallback: { gasPrice: gasBroken, nativePrice: nativeFallback },
  };
}
