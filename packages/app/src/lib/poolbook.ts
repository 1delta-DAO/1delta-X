import { sushiEndpoint, type ChainConfig } from "../config/chains";
import { primaryPool, type Market, type PoolRef } from "../config/markets";
import { fetchPoolLiquidity, fetchPoolMeta, type PoolMeta, type TokenRef } from "./oku";
import { fetchSushiPool } from "./sushi";
import { normSymbol as norm } from "./symbols";
import { DEX_SOURCE, type Level, type PoolBook, type Venue } from "./types";
import { buildLadder, type PoolLiquidity } from "./univ3";

/** Rungs walked out from mid per side, per venue, before the ladder is truncated. */
const MAX_RUNGS = 90;

/** Nothing further than this from mid is book, it is scenery. */
const MAX_SPREAD = 0.2;

/**
 * Display precision, in significant figures rather than fixed decimals: the
 * same app quotes ETH at ~1,900 and UNI at ~0.0017, and one decimal count
 * cannot serve both.
 */
function tickFor(mid: number): number {
  if (!(mid > 0)) return 4;
  const magnitude = Math.floor(Math.log10(mid)) + 1;
  return Math.max(0, Math.min(10, 6 - magnitude));
}

/**
 * Typical gap between adjacent rungs, used to place seeded orders on-grid.
 *
 * Clamped, because a thin pool's rungs can be percent apart: unclamped, orders
 * seeded a few "steps" from mid would land tens of percent away and never
 * appear in the ladder at all.
 */
function stepOf(levels: Level[], mid: number): number {
  const gaps: number[] = [];
  for (let i = 1; i < levels.length && gaps.length < 24; i++) {
    const gap = Math.abs(levels[i].price - levels[i - 1].price);
    if (gap > 0) gaps.push(gap);
  }
  gaps.sort((a, b) => a - b);
  const median = gaps.length ? gaps[Math.floor(gaps.length / 2)] : mid * 0.0005;
  return Math.min(Math.max(median, mid * 1e-6), mid * 0.002);
}

/** Pool identity and liquidity, whichever indexer serves this venue. */
async function fetchPool(
  ref: PoolRef,
  chain: ChainConfig,
  signal?: AbortSignal,
): Promise<{ meta: PoolMeta; liquidity: PoolLiquidity }> {
  if (ref.dex === "sushiswap-v3") {
    const endpoint = sushiEndpoint(chain.chainId);
    if (!endpoint) throw new Error("no SushiSwap subgraph for this chain (set VITE_GRAPH_KEY)");
    const { meta, liquidity } = await fetchSushiPool(endpoint, ref.address, signal);
    return { meta, liquidity };
  }
  if (!chain.oku) throw new Error("Oku does not index this chain");
  const [meta, liquidity] = await Promise.all([
    fetchPoolMeta(chain.oku, ref.address, signal),
    fetchPoolLiquidity(chain.oku, ref.address, signal),
  ]);
  return { meta, liquidity };
}

/** Just the identity — used to label a market before its ladder is fetched. */
export async function fetchMarketMeta(
  market: Market,
  chain: ChainConfig,
  signal?: AbortSignal,
): Promise<PoolMeta> {
  const ref = primaryPool(market);
  if (ref.dex === "sushiswap-v3") {
    const endpoint = sushiEndpoint(chain.chainId);
    if (!endpoint) throw new Error("no SushiSwap subgraph for this chain (set VITE_GRAPH_KEY)");
    return (await fetchSushiPool(endpoint, ref.address, signal)).meta;
  }
  return fetchPoolMeta(chain.oku, ref.address, signal);
}

/**
 * A deadline for one venue's fetch.
 *
 * Without it "gradual loading" is a lie: a hung endpoint holds its venue in
 * `loading` forever, and the legend never resolves to either depth or a reason.
 * The parent signal still wins, so switching markets aborts immediately.
 */
export function withTimeout(parent: AbortSignal | undefined, ms: number): { signal: AbortSignal; done: () => void } {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(new Error(`timed out after ${ms / 1000}s`)), ms);
  const relay = () => controller.abort(parent?.reason);
  parent?.addEventListener("abort", relay);
  return {
    signal: controller.signal,
    done: () => {
      clearTimeout(timer);
      parent?.removeEventListener("abort", relay);
    },
  };
}

/** How long any single venue gets before it is called slow rather than waited on. */
export const VENUE_TIMEOUT_MS = 20_000;

/** The pair, resolved from the primary pool. Everything else keys off this. */
export interface ResolvedMarket {
  meta: PoolMeta;
  base: TokenRef;
  quote: TokenRef;
}

/**
 * Work out which token is the base, from the primary pool's own metadata.
 *
 * Orientation of the PRIMARY pool comes from symbols, because that is all the
 * market config names. Every other pool is then matched by token ADDRESS: the
 * two indexers report different symbols for the same token (`USD0` vs `USD₮0`)
 * and identical addresses.
 */
export async function resolveMarket(
  market: Market,
  chain: ChainConfig,
  meta?: PoolMeta,
  signal?: AbortSignal,
): Promise<ResolvedMarket> {
  const ref = primaryPool(market);
  const primary = meta ?? (await fetchMarketMeta(market, chain, signal));

  const wantBase = norm(market.base);
  const wantQuote = norm(market.quote);
  const t0 = norm(primary.token0.symbol);
  const t1 = norm(primary.token1.symbol);
  let baseIsToken0: boolean;
  if (t0 === wantBase && t1 === wantQuote) baseIsToken0 = true;
  else if (t1 === wantBase && t0 === wantQuote) baseIsToken0 = false;
  else {
    throw new Error(
      `pool ${ref.address} holds ${primary.token0.symbol}/${primary.token1.symbol}, not ${market.base}/${market.quote}`,
    );
  }
  return {
    meta: primary,
    base: baseIsToken0 ? primary.token0 : primary.token1,
    quote: baseIsToken0 ? primary.token1 : primary.token0,
  };
}

export interface VenueResult {
  venue: Venue;
  bids: Level[];
  asks: Level[];
}

/**
 * One venue's ladder, walked and tagged. Independent of every other venue —
 * which is what lets the book render the fast pool while the slow one is still
 * in flight, instead of joining them and waiting for the worst.
 *
 * Never rejects: a failure comes back as a `Venue` carrying its reason, because
 * a venue that is down is a thing the UI should say, not an exception to catch.
 */
export async function fetchVenue(
  ref: PoolRef,
  chain: ChainConfig,
  base: TokenRef,
  parentSignal?: AbortSignal,
): Promise<VenueResult> {
  const source = DEX_SOURCE[ref.dex];
  const blank: Venue = { source, dex: ref.dex, pool: ref.address, feeBps: ref.feeBps, block: 0, rungs: 0 };
  const { signal, done } = withTimeout(parentSignal, VENUE_TIMEOUT_MS);
  try {
    const { meta, liquidity } = await fetchPool(ref, chain, signal);
    const baseAddress = base.address.toLowerCase();
    const isToken0 = meta.token0.address.toLowerCase() === baseAddress;
    if (!isToken0 && meta.token1.address.toLowerCase() !== baseAddress) {
      throw new Error(`pool does not hold ${base.symbol}`);
    }

    const ladder = buildLadder(liquidity, { baseIsToken0: isToken0, maxRungs: MAX_RUNGS, maxSpread: MAX_SPREAD });
    const tag = (r: { price: number; size: number }): Level => ({
      price: r.price,
      size: r.size,
      source,
      pool: ref.address,
      feeBps: ref.feeBps,
    });
    const bids = ladder.bids.map(tag);
    const asks = ladder.asks.map(tag);
    return { venue: { ...blank, block: liquidity.block, rungs: bids.length + asks.length }, bids, asks };
  } catch (e) {
    const reason = signal.aborted && signal.reason instanceof Error ? signal.reason.message : undefined;
    return { venue: { ...blank, error: reason ?? (e instanceof Error ? e.message : String(e)) }, bids: [], asks: [] };
  } finally {
    done();
  }
}

/**
 * Merge whatever venues have landed into one sorted, venue-tagged ladder.
 *
 * Pure and total: it takes the results it is given, so a caller streaming them
 * in one at a time gets a valid book at every step. `null` when nothing usable
 * has arrived yet — which is different from "this market is empty".
 */
export function assembleBook(
  market: Market,
  resolved: ResolvedMarket,
  results: readonly VenueResult[],
): PoolBook | null {
  const venues = results.map((r) => r.venue);
  const bids = results.flatMap((r) => r.bids).sort((a, b) => b.price - a.price);
  const asks = results.flatMap((r) => r.asks).sort((a, b) => a.price - b.price);
  if (!bids.length || !asks.length) return null;

  // Mid is the midpoint of what a taker can actually get across all venues, not
  // any single pool's spot: the best bid and the best ask may be in different
  // pools, which is the entire point of aggregating them.
  const mid = (bids[0].price + asks[0].price) / 2;

  return {
    pool: primaryPool(market).address,
    chainId: market.chainId,
    block: Math.max(0, ...venues.map((v) => v.block)),
    base: resolved.base,
    quote: resolved.quote,
    venues,
    tick: tickFor(mid),
    step: Math.max(stepOf(asks, mid), stepOf(bids, mid)),
    bids,
    asks,
    mid,
  };
}

export interface FetchBookArgs {
  market: Market;
  chain: ChainConfig;
  /** Cached primary-pool identity; fetched on first use and reused after. */
  meta?: PoolMeta;
  signal?: AbortSignal;
}

export interface FetchBookResult {
  book: PoolBook;
  meta: PoolMeta;
}

/**
 * One-shot convenience: resolve, fetch every venue, assemble. Waits for the
 * slowest venue by construction, so the UI does NOT use this — it streams the
 * same pieces through `usePoolBook`. Kept for scripts and tests, where a single
 * awaited answer is what you want.
 */
export async function fetchPoolBook(args: FetchBookArgs): Promise<FetchBookResult> {
  const { market, chain, signal } = args;
  const resolved = await resolveMarket(market, chain, args.meta, signal);
  const results = await Promise.all(market.pools.map((p) => fetchVenue(p, chain, resolved.base, signal)));
  const book = assembleBook(market, resolved, results);
  if (!book) {
    const why = results.map((r) => r.venue.error).filter(Boolean).join("; ");
    throw new Error(why || "no venue has liquidity around the current price");
  }
  return { meta: resolved.meta, book };
}
