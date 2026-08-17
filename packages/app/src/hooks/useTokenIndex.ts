import { useMemo } from "react";

import type { PoolMeta, TokenRef } from "../lib/oku";
import { normSymbol } from "../lib/symbols";
import { useTokenMeta } from "./useTokens";

export interface TokenView {
  /** The symbol the market config uses — what the UI labels things with. */
  symbol: string;
  address?: `0x${string}`;
  decimals?: number;
  logoURI?: string;
}

export interface TokenIndex {
  view: (symbol: string) => TokenView;
  /** Every token the chain's markets touch, for balance reads. */
  tokens: Array<{ address: `0x${string}`; decimals: number }>;
}

/**
 * One lookup from "the symbol the market config uses" to everything the UI
 * needs about that token: address (from the pool), decimals and logo (from the
 * 1delta token list, falling back to the pool's own report).
 */
export function useTokenIndex(chainId: number, metas: Record<string, PoolMeta>): TokenIndex {
  const refs = useMemo(() => {
    const seen = new Map<string, TokenRef>();
    for (const meta of Object.values(metas)) {
      for (const ref of [meta.token0, meta.token1]) {
        const k = ref.address.toLowerCase();
        if (!seen.has(k)) seen.set(k, ref);
      }
    }
    return [...seen.values()];
  }, [metas]);

  const listed = useTokenMeta(
    chainId,
    refs.map((r) => r.address),
  );

  return useMemo(() => {
    const views = refs.map((ref, i) => {
      const meta = listed[i];
      return {
        ref,
        view: {
          symbol: meta?.symbol ?? ref.symbol,
          address: ref.address,
          decimals: meta?.decimals ?? ref.decimals,
          logoURI: meta?.logoURI,
        } satisfies TokenView,
      };
    });

    return {
      view(symbol: string): TokenView {
        const want = normSymbol(symbol);
        const hit = views.find(
          (v) => normSymbol(v.ref.symbol) === want || normSymbol(v.view.symbol) === want,
        );
        // Before the pools resolve there is nothing to look up, so the config
        // symbol is the answer and the generated mark stands in for the logo.
        return hit ? { ...hit.view, symbol } : { symbol };
      },
      tokens: views.map((v) => ({ address: v.ref.address, decimals: v.view.decimals ?? v.ref.decimals })),
    };
  }, [refs, listed]);
}
