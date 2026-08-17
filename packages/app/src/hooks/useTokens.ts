import { useEffect, useMemo, useSyncExternalStore } from "react";

import { ensureTokens, subscribeTokens, tokenMeta, type TokenMeta } from "../lib/tokens";

let version = 0;
subscribeTokens(() => {
  version++;
});

const subscribe = (cb: () => void) => subscribeTokens(cb);
const getVersion = () => version;

/**
 * Resolve pool tokens against the 1delta token lists.
 *
 * The lookup is synchronous and the fetch is a side effect, so the first render
 * gets whatever is cached (usually everything, after one visit) and later
 * renders pick up the rest. Nothing waits on the network.
 *
 * The result is memoised on the store version rather than rebuilt per render:
 * callers derive further state from it, and a fresh array every render turns
 * that into an update loop.
 */
export function useTokenMeta(chainId: number, addresses: string[]): (TokenMeta | undefined)[] {
  const store = useSyncExternalStore(subscribe, getVersion, getVersion);
  const joined = addresses.join(",");

  useEffect(() => {
    if (joined) ensureTokens(chainId, joined.split(","));
  }, [chainId, joined]);

  return useMemo(
    () => (joined ? joined.split(",").map((a) => tokenMeta(chainId, a)) : []),
    [chainId, joined, store],
  );
}
