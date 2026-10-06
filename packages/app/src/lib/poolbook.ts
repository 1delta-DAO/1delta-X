import { sushiEndpoint, type ChainConfig } from "../config/chains";
import { assertPoolTokens, pinnedToken, primaryPool, type Market, type PoolRef } from "../config/markets";
import { fetchPoolLiquidity, fetchPoolMeta, type PoolMeta, type TokenRef } from "./oku";
import { fetchSushiPool } from "./sushi";
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

/** One pool's identity, from whichever indexer serves its venue. */
export async function fetchPoolIdentity(
  ref: PoolRef,
  chain: ChainConfig,
  signal?: AbortSignal,
): Promise<PoolMeta> {
  if (ref.dex === "sushiswap-v3") {
    const endpoint = sushiEndpoint(chain.chainId);
    if (!endpoint) throw new Error("no SushiSwap subgraph for this chain (set VITE_GRAPH_KEY)");
    return (await fetchSushiPool(endpoint, ref.address, signal)).meta;
  }
  return fetchPoolMeta(chain.oku, ref.address, signal);
}

/**
 * The market's identity, from the first pool that answers.
 *
 * Not just the primary: venues fail independently and for reasons that have
 * nothing to do with the pair. If one indexer is unreachable the market is still
 * perfectly tradeable on the other, and refusing to name the pair would take the
 * whole book down over a source we do not even need to describe it.
 */
export async function fetchMarketMeta(
  market: Market,
  chain: ChainConfig,
  signal?: AbortSignal,
): Promise<PoolMeta> {
  const reasons: string[] = [];
  for (const ref of market.pools) {
    try {
      const meta = await fetchPoolIdentity(ref, chain, signal);
      // An indexer that names a different pair is a failed source, not an
      // answer: fall through to the next pool rather than adopt its tokens.
      assertPoolTokens(market, meta.pool, meta.token0.address, meta.token1.address);
      return meta;
    } catch (e) {
      if (signal?.aborted) throw e;
      reasons.push(`${ref.dex} ${ref.address.slice(0, 8)}…: ${e instanceof Error ? e.message : String(e)}`);
    }
  }
  throw new Error(reasons.join("; ") || "no pool configured");
}

/**
 * Bound how long one venue may take, and cancel it when the deadline passes.
 *
 * The signal is not enough on its own. Aborting only helps if whatever is slow
 * is watching for it — an in-flight `fetch` is, but a stall anywhere else in the
 * chain is not — so the work is RACED against the timer as well. Signal to be
 * polite and stop the request; race to guarantee the venue resolves either way.
 * Without the race a hung endpoint pins its venue in `loading` forever, and
 * "gradual loading" quietly becomes "one venue never arrives".
 *
 * The parent signal still wins, so switching markets cancels immediately.
 */
export async function withDeadline<T>(
  parent: AbortSignal | undefined,
  ms: number,
  work: (signal: AbortSignal) => Promise<T>,
): Promise<T> {
  const controller = new AbortController();
  const relay = () => controller.abort(parent?.reason);
  parent?.addEventListener("abort", relay);

  let timer: ReturnType<typeof setTimeout> | undefined;
  const expired = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      controller.abort();
      reject(new Error(`timed out after ${Math.round(ms / 1000)}s`));
    }, ms);
  });

  try {
    return await Promise.race([work(controller.signal), expired]);
  } finally {
    clearTimeout(timer);
    parent?.removeEventListener("abort", relay);
  }
}

/** How long any single venue gets before it is called slow rather than waited on. */
export const VENUE_TIMEOUT_MS = 20_000;

/** The pair, resolved from whichever pool answered. Everything else keys off this. */
export interface ResolvedMarket {
  meta: PoolMeta;
  base: TokenRef;
  quote: TokenRef;
}

/**
 * Work out which token is the base, from the resolving pool's own metadata.
 *
 * Orientation comes from the market's PINNED token addresses, not from the
 * symbols an indexer reports: a pool whose reported tokens are not exactly the
 * pinned pair is refused outright (G-TS_SIGN-1). The base/quote refs carry the
 * pinned decimals too, so nothing downstream inherits an indexer's scale.
 */
export async function resolveMarket(
  market: Market,
  chain: ChainConfig,
  meta?: PoolMeta,
  signal?: AbortSignal,
): Promise<ResolvedMarket> {
  const primary = meta ?? (await fetchMarketMeta(market, chain, signal));
  const { baseIsToken0 } = assertPoolTokens(market, primary.pool, primary.token0.address, primary.token1.address);
  const base = baseIsToken0 ? primary.token0 : primary.token1;
  const quote = baseIsToken0 ? primary.token1 : primary.token0;
  const pinnedBase = pinnedToken(market.chainId, market.base)!;
  const pinnedQuote = pinnedToken(market.chainId, market.quote)!;
  return {
    meta: primary,
    base: { ...base, address: pinnedBase.address, decimals: pinnedBase.decimals },
    quote: { ...quote, address: pinnedQuote.address, decimals: pinnedQuote.decimals },
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
  try {
    return await withDeadline(parentSignal, VENUE_TIMEOUT_MS, async (signal) => {
      const { meta, liquidity } = await fetchPool(ref, chain, signal);
      const baseAddress = base.address.toLowerCase();
      const isToken0 = meta.token0.address.toLowerCase() === baseAddress;
      if (!isToken0 && meta.token1.address.toLowerCase() !== baseAddress) {
        throw new Error(`pool does not hold ${base.symbol}`);
      }

      // Rungs are priced net of the pool's fee (task 15), so a market quote — and the
      // MARKET_SLIPPAGE_BPS floor below it — is relative to what the pool executes,
      // not the raw tick maths. The pinned tier; if the indexer reports a higher one,
      // the higher (a quote may only err toward what the maker can actually get).
      const fee = Math.max(ref.feeBps, Number.isFinite(meta.fee) && meta.fee > 0 && meta.fee < 1_000_000 ? meta.fee : 0);
      const ladder = buildLadder(liquidity, { baseIsToken0: isToken0, maxRungs: MAX_RUNGS, maxSpread: MAX_SPREAD, fee });
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
    });
  } catch (e) {
    return { venue: { ...blank, error: e instanceof Error ? e.message : String(e) }, bids: [], asks: [] };
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
