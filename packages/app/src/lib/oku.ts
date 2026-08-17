import { asSigned, type PoolLiquidity, type RawTick } from "./univ3";

/**
 * Oku's public JSON-RPC ("cush") API. No key, no signup, and it answers with a
 * permissive CORS header, so the browser talks to it directly and this app
 * needs no backend of its own to show real depth.
 *
 * Base: `https://omni.icarus.tools/{chain}/cush/{method}`, POST `{id, params}`.
 * Spec: https://oku.trade/api (OpenAPI at unpkg.com/@gfxlabs/oku/openapi.yaml).
 */
export const OKU_BASE = "https://omni.icarus.tools";

async function rpc<T>(chain: string, method: string, params: unknown[], signal?: AbortSignal): Promise<T> {
  const res = await fetch(`${OKU_BASE}/${chain}/cush/${method}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ id: 1, params }),
    signal,
  });
  if (!res.ok) throw new Error(`oku ${method}: HTTP ${res.status}`);
  const body = (await res.json()) as { result?: T; error?: { message?: string } };
  if (body.error) throw new Error(`oku ${method}: ${body.error.message ?? "rpc error"}`);
  if (body.result === undefined) throw new Error(`oku ${method}: empty result`);
  return body.result;
}

export interface TokenRef {
  address: `0x${string}`;
  symbol: string;
  name: string;
  decimals: number;
}

export interface PoolMeta {
  pool: `0x${string}`;
  /** Fee tier in hundredths of a bip, as Uniswap stores it. */
  fee: number;
  token0: TokenRef;
  token1: TokenRef;
  tvlUsd: number;
}

interface OkuPool {
  address: string;
  fee: number;
  t0: string;
  t0_name: string;
  t0_symbol: string;
  t0_decimals: number;
  t1: string;
  t1_name: string;
  t1_symbol: string;
  t1_decimals: number;
  tvl_usd: number;
}

/**
 * Pool identity: token addresses, symbols and decimals. Fetched once per pool —
 * none of it changes — and it is what lets the rest of the app work in token
 * addresses rather than in symbols typed into a config file.
 */
export async function fetchPoolMeta(
  chain: string,
  pool: string,
  signal?: AbortSignal,
): Promise<PoolMeta> {
  const res = await rpc<{ pools: OkuPool[] }>(
    chain,
    "searchPoolsByAddress",
    [pool, { result_size: 1 }],
    signal,
  );
  const p = res.pools?.[0];
  if (!p) throw new Error(`pool ${pool} not indexed on ${chain}`);
  return {
    pool: p.address as `0x${string}`,
    fee: p.fee,
    token0: {
      address: p.t0 as `0x${string}`,
      symbol: p.t0_symbol,
      name: p.t0_name,
      decimals: p.t0_decimals,
    },
    token1: {
      address: p.t1 as `0x${string}`,
      symbol: p.t1_symbol,
      name: p.t1_name,
      decimals: p.t1_decimals,
    },
    tvlUsd: p.tvl_usd,
  };
}

interface OkuLiquidity {
  block: number;
  current_pool_tick: number;
  tick_spacing: number;
  sqrt_price_x96: string;
  token0_decimals: number;
  token1_decimals: number;
  ticks: Array<{ tick_index: number; sqrt_price: string; liquidity_net: string }>;
}

/**
 * Every initialized tick in the pool, reconstructed by Oku from mint/burn/swap
 * logs. This is the pool's actual liquidity distribution — not a bucketed
 * rendering of it — so the ladder built on top shows real concentration.
 */
export async function fetchPoolLiquidity(
  chain: string,
  pool: string,
  signal?: AbortSignal,
): Promise<PoolLiquidity> {
  const res = await rpc<OkuLiquidity>(chain, "simulatePoolLiquidity", [pool, 0], signal);
  const ticks: RawTick[] = [];
  for (const t of res.ticks ?? []) {
    const sqrtPrice = BigInt(t.sqrt_price);
    if (sqrtPrice <= 0n) continue;
    ticks.push({
      index: t.tick_index,
      sqrtPrice,
      liquidityNet: asSigned(BigInt(t.liquidity_net)),
    });
  }
  if (ticks.length < 2) throw new Error(`pool ${pool} has no initialized ticks`);
  return {
    block: res.block,
    currentTick: res.current_pool_tick,
    tickSpacing: res.tick_spacing,
    sqrtPriceX96: BigInt(res.sqrt_price_x96),
    decimals0: res.token0_decimals,
    decimals1: res.token1_decimals,
    ticks,
  };
}
