import { useEffect, useState } from "react";

import { chainById } from "../config/chains";
import { marketsOn, type Market } from "../config/markets";
import type { PoolMeta } from "../lib/oku";
import { fetchMarketMeta } from "../lib/poolbook";
import { ensureTokens } from "../lib/tokens";

/**
 * Keyed by MARKET, not by pool address: identity comes from whichever of the
 * market's pools answers first, which is not always the primary one. Pool
 * identity never changes, so it is fetched once and kept for the
 * life of the tab. Resolving every market on the chain up front — rather than
 * only the selected one — is what lets the market picker show real token icons
 * and the token menu list real balances before you have opened a market.
 */
const cache = new Map<string, PoolMeta>();

export interface ChainPools {
  metas: Record<string, PoolMeta>;
  loading: boolean;
}

const NONE: Record<string, PoolMeta> = {};

export function useChainPools(chainId: number): ChainPools {
  const [loaded, setLoaded] = useState<{ key: number; metas: Record<string, PoolMeta> }>(() => ({
    key: chainId,
    metas: seed(chainId),
  }));
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    const config = chainById(chainId);
    if (!config) return;
    const markets = marketsOn(chainId);
    setLoaded({ key: chainId, metas: seed(chainId) });

    const missing = markets.filter((m) => !cache.has(m.id));
    if (!missing.length) {
      ensureTokens(chainId, addressesOf(markets));
      return;
    }

    let alive = true;
    setLoading(true);
    let outstanding = missing.length;

    // Each market commits the moment its own metadata lands. Joining them means
    // the picker shows no icons and no pair labels until the SLOWEST pool on the
    // chain answers — one unlucky market holding every other one hostage.
    for (const m of missing) {
      void fetchMarketMeta(m, config)
        .then((meta) => {
          cache.set(m.id, meta);
          if (!alive) return;
          setLoaded({ key: chainId, metas: seed(chainId) });
          ensureTokens(chainId, addressesOf(markets));
        })
        .catch(() => {
          // A market whose pool will not resolve simply has no icons; it is not
          // a reason to withhold the ones that did.
        })
        .finally(() => {
          if (!alive) return;
          if (--outstanding === 0) setLoading(false);
        });
    }

    return () => {
      alive = false;
    };
  }, [chainId]);

  // Matched at RENDER time rather than cleared by an effect. An effect runs a
  // render too late, and in that render the previous chain's token addresses sit
  // under the new chain's id — which is exactly enough to send a token-list
  // lookup after the wrong chain's tokens.
  return { metas: loaded.key === chainId ? loaded.metas : NONE, loading };
}

function seed(chainId: number): Record<string, PoolMeta> {
  const out: Record<string, PoolMeta> = {};
  for (const m of marketsOn(chainId)) {
    const meta = cache.get(m.id);
    if (meta) out[m.id] = meta;
  }
  return out;
}

function addressesOf(markets: Market[]): string[] {
  const out: string[] = [];
  for (const m of markets) {
    const meta = cache.get(m.id);
    if (!meta) continue;
    for (const a of [meta.token0.address, meta.token1.address]) {
      if (!out.includes(a)) out.push(a);
    }
  }
  return out;
}
