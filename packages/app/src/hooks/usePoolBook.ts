import { useCallback, useEffect, useState } from "react";

import { chainById } from "../config/chains";
import type { Market } from "../config/markets";
import type { PoolMeta } from "../lib/oku";
import { fetchPoolBook } from "../lib/poolbook";
import type { PoolBook } from "../lib/types";

/** Tick liquidity moves per block; this is often enough to feel live. */
const POLL_MS = 12_000;

export interface PoolBookState {
  book: PoolBook | null;
  error: string | null;
  /** True only before the first successful load — a refresh must not blank the UI. */
  loading: boolean;
  /** Milliseconds since the last successful load, or null if there has not been one. */
  age: number | null;
  refresh: () => void;
}

interface Loaded {
  /** Which market this book belongs to. */
  key: string;
  book: PoolBook | null;
  error: string | null;
  at: number | null;
}

export function usePoolBook(market: Market, meta: PoolMeta | undefined): PoolBookState {
  const [loaded, setLoaded] = useState<Loaded>({ key: market.id, book: null, error: null, at: null });
  const [nonce, setNonce] = useState(0);
  const [now, setNow] = useState(() => Date.now());

  const refresh = useCallback(() => setNonce((n) => n + 1), []);

  useEffect(() => {
    const config = chainById(market.chainId);
    if (!config) return;

    let alive = true;
    const controller = new AbortController();

    const load = async () => {
      try {
        const { book } = await fetchPoolBook({
          market,
          chain: config.oku,
          meta,
          signal: controller.signal,
        });
        if (!alive) return;
        setLoaded({ key: market.id, book, error: null, at: Date.now() });
      } catch (e) {
        if (!alive || controller.signal.aborted) return;
        // Keep the last good ladder on screen; a transient RPC failure should
        // not take the book away from someone mid-order.
        const text = e instanceof Error ? e.message : String(e);
        setLoaded((prev) => (prev.key === market.id ? { ...prev, error: text } : prev));
      }
    };

    void load();
    const t = setInterval(load, POLL_MS);
    return () => {
      alive = false;
      controller.abort();
      clearInterval(t);
    };
  }, [market, meta, nonce]);

  // Drives the staleness indicator without re-fetching.
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 1_000);
    return () => clearInterval(t);
  }, []);

  // The book is keyed by the market it was fetched for and matched at RENDER
  // time, not cleared by an effect. An effect runs a render too late, and in
  // that one render the previous market's mid, grid and depth are visible under
  // the new market's id — enough for a consumer to seed itself from the wrong
  // market entirely.
  const fresh = loaded.key === market.id;
  const book = fresh ? loaded.book : null;
  const error = fresh ? loaded.error : null;

  return {
    book,
    error,
    loading: book === null && error === null,
    age: fresh && loaded.at !== null ? now - loaded.at : null,
    refresh,
  };
}
