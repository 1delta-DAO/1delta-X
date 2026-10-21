/**
 * Pool DISCOVERY from the venues' own indexers (2026-10-14) — Oku's API for venue 0
 * (Uniswap v3 on Rootstock), Sushi's v3 subgraph for venue 1 — instead of probing every
 * (token pair × fee tier × venue) with `factory.getPool` over the RPC.
 *
 * Why: the indexers report each pool's TVL in USD, so a dust pool (8 RIF in range) is
 * pruned on its real size instead of "any liquidity > 0", and they list every pool a
 * token has, not only the token × hub grid the RPC probe enumerated. One request per
 * token (Oku) and one per venue (Sushi) per refresh; no RPC at all.
 *
 * TRUST: nothing an indexer says can put a pool into a fill. Every pool is re-derived
 * locally (CREATE2 from the venue's factory + init code hash, the same derivation the
 * solver enforces on-chain) and dropped on a mismatch; both tokens must be graph tokens
 * (ROUTE_TOKENS ∪ hubs) and the fee a configured tier. Quotes still come from the
 * on-chain QuoterV2, and the solver pays only pools it derives itself. A wrong indexer
 * answer can at worst waste a quote slot. Any indexer failure → the caller falls back
 * to the RPC probe (`discoverPools`).
 */
import { v3PoolAddress, type PoolVenue } from "@1delta-x/sdk";
import { getAddress, type Address } from "viem";

import type { GraphPool } from "./poolGraph";

export interface IndexerConfig {
  /** Oku's cush API base (`https://cush.lat.gfx.town`) and chain slug (`rootstock`). */
  okuBase: string;
  okuChain: string;
  /** Sushi v3 subgraph (GraphQL) URL; "" = venue 1 from the RPC probe only. */
  sushiSubgraph: string;
  /** A pool must hold at least this much TVL, USD (`ROUTE_MIN_TVL_USD`, default 1000). */
  minTvlUsd: number;
  timeoutMs: number;
}

export interface IndexedPool extends GraphPool {
  tvlUsd: number;
}

const lc = (a: string) => a.toLowerCase();

/** sqrtPriceX96 from a human price of token0 in token1 (Oku reports no sqrtPrice). */
export function sqrtPriceX96FromPrice(price0In1: number, dec0: number, dec1: number): bigint | undefined {
  if (!(price0In1 > 0) || !Number.isFinite(price0In1)) return undefined;
  const raw = price0In1 * 10 ** (dec1 - dec0);
  const s = Math.sqrt(raw) * 2 ** 96;
  return Number.isFinite(s) && s > 0 ? BigInt(Math.floor(s)) : undefined;
}

interface OkuPool {
  address?: string;
  fee?: number;
  t0?: string;
  t1?: string;
  t0_decimals?: number;
  t1_decimals?: number;
  liquidity?: string;
  t0_price?: number;
  tvl_usd?: number;
}

interface SushiPool {
  id?: string;
  feeTier?: string;
  liquidity?: string;
  sqrtPrice?: string;
  totalValueLockedUSD?: string;
  token0?: { id?: string };
  token1?: { id?: string };
}

/** Admit one indexer pool: graph tokens, a configured tier, the TVL floor, the CREATE2 check. */
function admit(
  p: { pool: string; a: string; b: string; fee: number; liquidity?: string; sqrtPriceX96?: bigint; tvlUsd: number },
  venue: number,
  v: PoolVenue,
  tokens: ReadonlyMap<string, Address>,
  fees: ReadonlySet<number>,
  minTvlUsd: number,
  warnings: string[],
): IndexedPool | undefined {
  const a = tokens.get(lc(p.a));
  const b = tokens.get(lc(p.b));
  if (!a || !b || a === b || !fees.has(p.fee)) return undefined;
  if (!(p.tvlUsd >= minTvlUsd)) return undefined;
  let pool: Address;
  try {
    pool = getAddress(p.pool);
  } catch {
    return undefined;
  }
  const derived = v3PoolAddress(v, a, b, p.fee);
  if (lc(derived) !== lc(pool)) {
    warnings.push(`indexer venue ${venue} ${a}/${b} fee ${p.fee}: reported ${pool} but CREATE2 derives ${derived} — dropped`);
    return undefined;
  }
  let liquidity: bigint | undefined;
  try {
    liquidity = p.liquidity !== undefined ? BigInt(p.liquidity) : undefined;
  } catch {
    liquidity = undefined;
  }
  return {
    tokenA: a,
    tokenB: b,
    fee: p.fee,
    venue,
    pool,
    ...(liquidity !== undefined ? { liquidity } : {}),
    ...(p.sqrtPriceX96 !== undefined ? { sqrtPriceX96: p.sqrtPriceX96 } : {}),
    tvlUsd: p.tvlUsd,
  };
}

/** Oku: one `searchPoolsByAddress` per graph token (it returns that token's pools). */
export async function okuPools(
  cfg: IndexerConfig,
  venue: number,
  v: PoolVenue,
  graphTokens: readonly Address[],
  fees: ReadonlySet<number>,
  fetchImpl: typeof fetch,
  warnings: string[],
): Promise<IndexedPool[]> {
  const tokens = new Map(graphTokens.map((t) => [lc(t), t]));
  const out = new Map<string, IndexedPool>();
  const url = `${cfg.okuBase.replace(/\/$/, "")}/${cfg.okuChain}/cush/searchPoolsByAddress`;
  const answers = await Promise.all(
    graphTokens.map(async (t) => {
      const res = await fetchImpl(url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ id: 1, params: [t, { result_size: 50 }] }),
        signal: AbortSignal.timeout(cfg.timeoutMs),
      });
      if (!res.ok) throw new Error(`oku searchPoolsByAddress: HTTP ${res.status}`);
      const body = (await res.json()) as { result?: { pools?: OkuPool[] }; error?: { message?: string } };
      if (body.error) throw new Error(`oku searchPoolsByAddress: ${body.error.message ?? "error"}`);
      return body.result?.pools ?? [];
    }),
  );
  for (const list of answers) {
    for (const p of list) {
      if (!p.address || !p.t0 || !p.t1 || typeof p.fee !== "number") continue;
      const sqrt = typeof p.t0_price === "number" && typeof p.t0_decimals === "number" && typeof p.t1_decimals === "number" ? sqrtPriceX96FromPrice(p.t0_price, p.t0_decimals, p.t1_decimals) : undefined;
      const g = admit(
        { pool: p.address, a: p.t0, b: p.t1, fee: p.fee, ...(p.liquidity ? { liquidity: p.liquidity } : {}), ...(sqrt ? { sqrtPriceX96: sqrt } : {}), tvlUsd: Number(p.tvl_usd ?? 0) },
        venue,
        v,
        tokens,
        fees,
        cfg.minTvlUsd,
        warnings,
      );
      if (g) out.set(lc(g.pool), g);
    }
  }
  return [...out.values()];
}

/** Sushi v3 subgraph: every pool among the graph tokens, one GraphQL request. */
export async function sushiPools(
  cfg: IndexerConfig,
  venue: number,
  v: PoolVenue,
  graphTokens: readonly Address[],
  fees: ReadonlySet<number>,
  fetchImpl: typeof fetch,
  warnings: string[],
): Promise<IndexedPool[]> {
  const tokens = new Map(graphTokens.map((t) => [lc(t), t]));
  const ids = graphTokens.map((t) => `"${lc(t)}"`).join(",");
  const query = `{ pools(first: 500, where: { token0_in: [${ids}], token1_in: [${ids}] }) { id feeTier liquidity sqrtPrice totalValueLockedUSD token0 { id } token1 { id } } }`;
  const res = await fetchImpl(cfg.sushiSubgraph, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ query }),
    signal: AbortSignal.timeout(cfg.timeoutMs),
  });
  if (!res.ok) throw new Error(`sushi subgraph: HTTP ${res.status}`);
  const body = (await res.json()) as { data?: { pools?: SushiPool[] }; errors?: { message?: string }[] };
  if (body.errors?.length) throw new Error(`sushi subgraph: ${body.errors[0]?.message ?? "error"}`);
  const out: IndexedPool[] = [];
  for (const p of body.data?.pools ?? []) {
    if (!p.id || !p.token0?.id || !p.token1?.id || !p.feeTier) continue;
    let sqrt: bigint | undefined;
    try {
      sqrt = p.sqrtPrice ? BigInt(p.sqrtPrice) : undefined;
    } catch {
      sqrt = undefined;
    }
    const g = admit(
      { pool: p.id, a: p.token0.id, b: p.token1.id, fee: Number(p.feeTier), ...(p.liquidity ? { liquidity: p.liquidity } : {}), ...(sqrt ? { sqrtPriceX96: sqrt } : {}), tvlUsd: Number(p.totalValueLockedUSD ?? 0) },
      venue,
      v,
      tokens,
      fees,
      cfg.minTvlUsd,
      warnings,
    );
    if (g) out.push(g);
  }
  return out;
}
