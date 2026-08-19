import { getSqrtRatioAtTick, type PoolLiquidity, type RawTick } from "./univ3";
import type { PoolMeta, TokenRef } from "./oku";

/**
 * SushiSwap v3 tick liquidity, straight from the subgraph.
 *
 * Oku only indexes Uniswap v3, so a second venue needs a second source. The
 * subgraph answers with tick INDICES rather than sqrt prices, which is why
 * {@link getSqrtRatioAtTick} exists — reconstructing them in floating point
 * would corrupt every rung size, since the ladder differences adjacent sqrt
 * prices.
 */

/** Ticks fetched per request. The subgraph caps a page at 1000. */
const PAGE = 1000;

/** Stop paginating here. A pool with more initialized ticks than this is not one this UI can usefully render. */
const MAX_TICKS = 6_000;

interface GraphToken {
  id: string;
  symbol: string;
  name: string;
  decimals: string;
}

interface GraphPool {
  id: string;
  feeTier: string;
  liquidity: string;
  sqrtPrice: string;
  tick: string | null;
  token0: GraphToken;
  token1: GraphToken;
}

interface GraphTick {
  tickIdx: string;
  liquidityNet: string;
}

async function graphql<T>(endpoint: string, query: string, variables: Record<string, unknown>, signal?: AbortSignal): Promise<T> {
  const res = await fetch(endpoint, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ query, variables }),
    signal,
  });
  if (!res.ok) throw new Error(`sushi subgraph: HTTP ${res.status}`);
  const body = (await res.json()) as { data?: T; errors?: Array<{ message?: string }> };
  if (body.errors?.length) throw new Error(`sushi subgraph: ${body.errors[0]?.message ?? "query error"}`);
  if (!body.data) throw new Error("sushi subgraph: empty response");
  return body.data;
}

function toTokenRef(t: GraphToken): TokenRef {
  return {
    address: t.id.toLowerCase() as `0x${string}`,
    symbol: t.symbol,
    name: t.name,
    decimals: Number(t.decimals),
  };
}

const POOL_QUERY = `
  query Pool($id: ID!) {
    pool(id: $id) {
      id feeTier liquidity sqrtPrice tick
      token0 { id symbol name decimals }
      token1 { id symbol name decimals }
    }
    _meta { block { number } }
  }
`;

const TICKS_QUERY = `
  query Ticks($pool: String!, $after: BigInt!) {
    ticks(
      first: ${PAGE}
      where: { pool: $pool, liquidityNet_not: "0", tickIdx_gt: $after }
      orderBy: tickIdx
      orderDirection: asc
    ) {
      tickIdx
      liquidityNet
    }
  }
`;

export interface SushiPool {
  meta: PoolMeta;
  liquidity: PoolLiquidity;
}

/**
 * One pool's identity AND tick liquidity, in the shapes the rest of the app
 * already speaks — so a Sushi ladder goes through exactly the same
 * `buildLadder` as a Uniswap one, and a rung from either is comparable.
 */
export async function fetchSushiPool(
  endpoint: string,
  pool: string,
  signal?: AbortSignal,
): Promise<SushiPool> {
  const id = pool.toLowerCase();
  const head = await graphql<{ pool: GraphPool | null; _meta: { block: { number: number } } }>(
    endpoint,
    POOL_QUERY,
    { id },
    signal,
  );
  if (!head.pool) throw new Error(`sushi pool ${pool} not indexed`);

  const ticks: RawTick[] = [];
  let after = "-887273";
  // Paginate by tick index rather than by skip: `skip` degrades badly on large
  // sets and can silently drop rows when the set shifts between pages.
  for (let page = 0; page * PAGE < MAX_TICKS; page++) {
    const res = await graphql<{ ticks: GraphTick[] }>(endpoint, TICKS_QUERY, { pool: id, after }, signal);
    if (!res.ticks.length) break;
    for (const t of res.ticks) {
      const index = Number(t.tickIdx);
      ticks.push({ index, sqrtPrice: getSqrtRatioAtTick(index), liquidityNet: BigInt(t.liquidityNet) });
    }
    after = res.ticks[res.ticks.length - 1]!.tickIdx;
    if (res.ticks.length < PAGE) break;
  }
  if (ticks.length < 2) throw new Error(`sushi pool ${pool} has no initialized ticks`);

  const decimals0 = Number(head.pool.token0.decimals);
  const decimals1 = Number(head.pool.token1.decimals);

  return {
    meta: {
      pool: head.pool.id.toLowerCase() as `0x${string}`,
      fee: Number(head.pool.feeTier),
      token0: toTokenRef(head.pool.token0),
      token1: toTokenRef(head.pool.token1),
      // The subgraph reports TVL per pool, but not in the same call shape Oku
      // uses; it is not needed for the ladder, so it is left unclaimed.
      tvlUsd: 0,
    },
    liquidity: {
      block: head._meta.block.number,
      currentTick: Number(head.pool.tick ?? 0),
      // Not reported per pool by this subgraph and not needed: the ladder walks
      // initialized ticks, never the spacing between them.
      tickSpacing: 0,
      sqrtPriceX96: BigInt(head.pool.sqrtPrice),
      decimals0,
      decimals1,
      ticks,
    },
  };
}
