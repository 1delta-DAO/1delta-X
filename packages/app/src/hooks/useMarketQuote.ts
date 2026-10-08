import { useCallback, useEffect, useRef, useState } from "react";

import { fetchQuote, QUOTE_DEBOUNCE_MS, QUOTE_REFRESH_MS, type FillerQuote, type QuoteRequest } from "../lib/quote";

/**
 * Where quotes are requested: `VITE_QUOTE_URL`, else `/api/quote` (the Pages worker's
 * same-origin proxy to the filler) whenever orders go to a real book. Unset with the
 * in-browser mock book: no filler reads it, so no quote — the gas-floor path.
 */
export function quoteUrl(raw: string | undefined, bookIsRemote: boolean): string | null {
  const url = raw?.trim().replace(/\/+$/, "");
  if (url) return url;
  return bookIsRemote ? "/api/quote" : null;
}

export interface MarketQuoteState {
  quote: FillerQuote | null;
  /** The last failure (the ticket then signs the gas-floor fallback). */
  error: string | null;
  loading: boolean;
  /** Fetch a fresh quote now (before signing); `null` on failure. */
  refresh: () => Promise<FillerQuote | null>;
}

/**
 * The filler's indicative quote for the market ticket on screen (lib/quote.ts):
 * debounced on the request (amount, market, side, maker), refreshed every
 * QUOTE_REFRESH_MS, and on demand before signing. `req` null = no quote wanted
 * (limit / TWAP, no deployment, unsupported chain, no amount).
 */
export function useMarketQuote(url: string | null, req: QuoteRequest | null): MarketQuoteState {
  const [state, setState] = useState<{ key: string; quote: FillerQuote | null; error: string | null; loading: boolean }>({ key: "", quote: null, error: null, loading: false });
  const key = req && url ? `${url}|${req.chainId}|${req.marketId}|${req.side}|${req.tokenIn}|${req.tokenOut}|${req.amountIn}|${req.delivery}|${req.maker ?? ""}` : "";
  const reqRef = useRef<QuoteRequest | null>(req);
  reqRef.current = req;
  const keyRef = useRef(key);
  keyRef.current = key;

  const load = useCallback(
    async (signal?: AbortSignal): Promise<FillerQuote | null> => {
      const r = reqRef.current;
      const k = keyRef.current;
      if (!r || !url || !k) return null;
      setState((s) => ({ ...s, key: k, loading: true }));
      try {
        const q = await fetchQuote((u, i) => fetch(u, i), url, r, signal);
        if (keyRef.current === k) setState({ key: k, quote: q, error: null, loading: false });
        return q;
      } catch (e) {
        if (signal?.aborted) return null;
        if (keyRef.current === k) setState({ key: k, quote: null, error: e instanceof Error ? e.message : String(e), loading: false });
        return null;
      }
    },
    [url],
  );

  useEffect(() => {
    if (!key) return;
    const controller = new AbortController();
    const first = setTimeout(() => void load(controller.signal), QUOTE_DEBOUNCE_MS);
    const every = setInterval(() => void load(controller.signal), QUOTE_REFRESH_MS);
    return () => {
      controller.abort();
      clearTimeout(first);
      clearInterval(every);
    };
  }, [key, load]);

  const current = state.key === key && key !== "";
  return {
    quote: current ? state.quote : null,
    error: current ? state.error : null,
    loading: current ? state.loading : !!key,
    refresh: useCallback(() => load(), [load]),
  };
}

