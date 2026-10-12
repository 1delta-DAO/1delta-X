/**
 * USD reference prices for the ticket (2026-10-12): "≈ $12.75" under each amount and
 * the receive-vs-pay difference, so a user can judge a swap at a glance.
 *
 * SOURCE: Sushi's public price API (`GET https://api.sushi.com/price/v1/{chainId}` →
 * `{ lowercase address: usd }`, CORS *, cached 30 s), polled once a minute.
 * FALLBACK — any HTTP / parse / timeout failure, or a token the API does not list —
 * a heuristic: the chain's $1 stables at 1.00, and the other leg of the market on
 * screen through its live mid. With neither, no USD figure is shown (never a guess).
 * Display only: nothing signed or priced depends on these numbers.
 */
import { FLOOR_PROFILES } from "./marketFloor";

export const SUSHI_PRICE_URL = (chainId: number) => `https://api.sushi.com/price/v1/${chainId}`;
/** Refresh cadence, ms. */
export const USD_POLL_MS = 60_000;
/** Give the API this long, ms, then fall back. */
export const USD_TIMEOUT_MS = 6_000;
/** $1 tokens per chain (beyond the floor profile's `usd` list). */
const STABLES: Record<number, string[]> = { 30: ["USD0", "USDT", "USDC.e", "USDRIF", "DOC"] };

export type UsdTable = Record<string, number>;

/** Parse the API body: only finite positive prices under 0x-addresses, lowercased. */
export function parseUsdTable(raw: unknown): UsdTable {
  const out: UsdTable = {};
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return out;
  for (const [k, v] of Object.entries(raw as Record<string, unknown>)) {
    if (/^0x[0-9a-fA-F]{40}$/.test(k) && typeof v === "number" && Number.isFinite(v) && v > 0 && v < 1e12) out[k.toLowerCase()] = v;
  }
  return out;
}

export async function fetchUsdTable(chainId: number, doFetch: typeof fetch = fetch): Promise<UsdTable> {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), USD_TIMEOUT_MS);
  try {
    const res = await doFetch(SUSHI_PRICE_URL(chainId), { signal: ctrl.signal, headers: { accept: "application/json" } });
    if (!res.ok) throw new Error(`prices: HTTP ${res.status}`);
    return parseUsdTable(await res.json());
  } finally {
    clearTimeout(t);
  }
}

export interface UsdContext {
  chainId: number;
  /** Token symbol → pinned address (lowercase not required). */
  addressOf: (symbol: string) => string | undefined;
  /** The market on screen and its mid (QUOTE per BASE), for the heuristic. */
  market: { base: string; quote: string; mid: number | null };
}

/** USD per one `symbol`: the API's figure, else the heuristic, else undefined. */
export function usdPrice(table: UsdTable, ctx: UsdContext, symbol: string): number | undefined {
  const a = ctx.addressOf(symbol)?.toLowerCase();
  if (a && table[a] !== undefined) return table[a];
  return heuristicUsd(table, ctx, symbol);
}

function heuristicUsd(table: UsdTable, ctx: UsdContext, symbol: string, depth = 0): number | undefined {
  const stables = [...(STABLES[ctx.chainId] ?? []), ...(FLOOR_PROFILES[ctx.chainId]?.usd ?? [])];
  if (stables.includes(symbol)) return 1;
  if (depth > 0) return undefined;
  const { base, quote, mid } = ctx.market;
  if (!(mid !== null && mid > 0)) return undefined;
  // The other leg of the market on screen, through its mid.
  if (symbol === base) {
    const q = priceOrHeuristic(table, ctx, quote);
    return q !== undefined ? mid * q : undefined;
  }
  if (symbol === quote) {
    const b = priceOrHeuristic(table, ctx, base);
    return b !== undefined ? b / mid : undefined;
  }
  return undefined;
}

function priceOrHeuristic(table: UsdTable, ctx: UsdContext, symbol: string): number | undefined {
  const a = ctx.addressOf(symbol)?.toLowerCase();
  if (a && table[a] !== undefined) return table[a];
  return heuristicUsd(table, ctx, symbol, 1);
}

/** "$12.75", "$0.0042", "$1,234". */
export function fmtUsd(v: number): string {
  if (!Number.isFinite(v)) return "";
  if (v >= 1000) return `$${Math.round(v).toLocaleString("en-US")}`;
  if (v >= 1) return `$${v.toFixed(2)}`;
  if (v >= 0.01) return `$${v.toFixed(3)}`;
  return `<$0.01`;
}
