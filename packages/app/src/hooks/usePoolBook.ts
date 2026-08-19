import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { chainById } from "../config/chains";
import type { Market } from "../config/markets";
import type { PoolMeta } from "../lib/oku";
import {
  assembleBook,
  fetchVenue,
  resolveMarket,
  type ResolvedMarket,
  type VenueResult,
} from "../lib/poolbook";
import type { PoolBook } from "../lib/types";

/** Tick liquidity moves per block; this is often enough to feel live. */
const POLL_MS = 12_000;

export type VenuePhase = "loading" | "ready" | "error";

export interface VenueStatus {
  pool: `0x${string}`;
  phase: VenuePhase;
  /** Milliseconds since this venue last answered, or null before it ever has. */
  age: number | null;
}

export interface PoolBookState {
  book: PoolBook | null;
  error: string | null;
  /** True only until the FIRST venue answers — not until all of them do. */
  loading: boolean;
  /** Age of the freshest venue. */
  age: number | null;
  /** Per-venue phase, so the UI can say which pool is still coming. */
  venues: VenueStatus[];
  /** True while at least one venue is still in flight behind a rendered book. */
  partial: boolean;
  refresh: () => void;
}

interface VenueSlot {
  result: VenueResult | null;
  phase: VenuePhase;
  at: number | null;
}

interface MarketState {
  key: string;
  resolved: ResolvedMarket | null;
  /** Keyed by pool address, in the market's own pool order. */
  slots: Record<string, VenueSlot>;
  error: string | null;
}

function blankState(market: Market): MarketState {
  return {
    key: market.id,
    resolved: null,
    slots: Object.fromEntries(
      market.pools.map((p) => [p.address.toLowerCase(), { result: null, phase: "loading" as VenuePhase, at: null }]),
    ),
    error: null,
  };
}

/**
 * The market's ladder, streamed one venue at a time.
 *
 * Each pool is fetched independently and committed the moment it lands, so the
 * book renders from whatever has arrived rather than from whatever arrives
 * last. Joining them — one `Promise.all` over the venues — is the version that
 * makes a fast Uniswap ladder wait on a slow Sushi subgraph, which is exactly
 * the coupling worth avoiding: the whole point of aggregating venues is that
 * they are independent.
 *
 * Poll cycles are per venue too, so a consistently slow endpoint falls behind
 * on its own without dragging the others' cadence with it.
 */
export function usePoolBook(market: Market, meta: PoolMeta | undefined): PoolBookState {
  const [state, setState] = useState<MarketState>(() => blankState(market));
  const [nonce, setNonce] = useState(0);
  const [now, setNow] = useState(() => Date.now());
  const stateRef = useRef(state);
  stateRef.current = state;

  const refresh = useCallback(() => setNonce((n) => n + 1), []);

  useEffect(() => {
    const config = chainById(market.chainId);
    if (!config) return;

    let alive = true;
    const controller = new AbortController();
    const timers: ReturnType<typeof setInterval>[] = [];

    // A market switch resets the slots so the previous pair's rungs never sit
    // under the new pair's heading, even for one frame.
    setState(blankState(market));

    const run = async () => {
      let resolved: ResolvedMarket;
      try {
        resolved = await resolveMarket(market, config, meta, controller.signal);
      } catch (e) {
        if (!alive || controller.signal.aborted) return;
        const text = e instanceof Error ? e.message : String(e);
        setState((prev) => (prev.key === market.id ? { ...prev, error: text } : prev));
        return;
      }
      if (!alive) return;
      setState((prev) => (prev.key === market.id ? { ...prev, resolved, error: null } : prev));

      // One independent loop per venue. Nothing here awaits anything else.
      for (const pool of market.pools) {
        const key = pool.address.toLowerCase();
        const load = async () => {
          const result = await fetchVenue(pool, config, resolved.base, controller.signal);
          if (!alive || controller.signal.aborted) return;
          setState((prev) => {
            if (prev.key !== market.id) return prev;
            const previous = prev.slots[key];
            return {
              ...prev,
              slots: {
                ...prev.slots,
                [key]: result.venue.error
                  ? // Keep the last good rungs on screen: a venue that just
                    // failed still has depth that was true a moment ago, and
                    // dropping it would blank the book on one bad poll.
                    { result: previous?.result ?? result, phase: "error", at: previous?.at ?? null }
                  : { result, phase: "ready", at: Date.now() },
              },
            };
          });
        };
        void load();
        timers.push(setInterval(() => void load(), POLL_MS));
      }
    };

    void run();
    return () => {
      alive = false;
      controller.abort();
      for (const t of timers) clearInterval(t);
    };
  }, [market, meta, nonce]);

  // Drives the staleness indicator without re-fetching.
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 1_000);
    return () => clearInterval(t);
  }, []);

  // Matched at RENDER time rather than cleared by an effect: an effect runs a
  // render too late, and in that render the previous market's depth is visible
  // under the new market's id.
  const fresh = state.key === market.id;

  const book = useMemo(() => {
    if (!fresh || !state.resolved) return null;
    const results = market.pools
      .map((p) => state.slots[p.address.toLowerCase()]?.result)
      .filter((r): r is VenueResult => r !== null && r !== undefined);
    return results.length ? assembleBook(market, state.resolved, results) : null;
  }, [fresh, market, state.resolved, state.slots]);

  const venues: VenueStatus[] = fresh
    ? market.pools.map((p) => {
        const slot = state.slots[p.address.toLowerCase()];
        return {
          pool: p.address,
          phase: slot?.phase ?? "loading",
          age: slot?.at === null || slot?.at === undefined ? null : now - slot.at,
        };
      })
    : [];

  const ages = venues.map((v) => v.age).filter((a): a is number => a !== null);
  const settled = venues.filter((v) => v.phase !== "loading").length;

  return {
    book,
    error: fresh ? state.error : null,
    // "Loading" ends when the first venue answers, not the last.
    loading: book === null && (fresh ? state.error : null) === null,
    age: ages.length ? Math.min(...ages) : null,
    venues,
    partial: book !== null && settled < venues.length,
    refresh,
  };
}
