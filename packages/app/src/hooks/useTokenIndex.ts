import { useMemo } from "react";

import { TOKENS } from "../config/markets";
import type { TokenMeta } from "../lib/tokens";
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
 * The lookup from "the symbol the market config uses" to everything the UI
 * needs about that token.
 *
 * ADDRESS and DECIMALS come only from the pinned config (`TOKENS`), because
 * they are what the maker signs: the receive-token address and the scale every
 * leg amount is written in. Off-chain sources — the indexers that serve depth,
 * the token list that serves logos — are consulted for the LOGO and nothing
 * else, and only by the pinned address, never by symbol (G-TS_SIGN-1). A
 * symbol with no pin has no address, so it cannot be signed for.
 *
 * Pure, so the rule is testable without React.
 */
export function buildTokenIndex(chainId: number, listed: ReadonlyArray<TokenMeta | undefined>): TokenIndex {
  const pinned = Object.entries(TOKENS[chainId] ?? {});
  const logoOf = new Map<string, string | undefined>();
  for (const meta of listed) {
    if (meta) logoOf.set(meta.address.toLowerCase(), meta.logoURI);
  }
  return {
    view(symbol: string): TokenView {
      const pin = TOKENS[chainId]?.[symbol];
      if (!pin) return { symbol };
      return { symbol, address: pin.address, decimals: pin.decimals, logoURI: logoOf.get(pin.address) };
    },
    tokens: pinned.map(([, t]) => ({ address: t.address, decimals: t.decimals })),
  };
}

export function useTokenIndex(chainId: number): TokenIndex {
  const addresses = useMemo(() => Object.values(TOKENS[chainId] ?? {}).map((t) => t.address), [chainId]);
  const listed = useTokenMeta(chainId, addresses);
  return useMemo(() => buildTokenIndex(chainId, listed), [chainId, listed]);
}
