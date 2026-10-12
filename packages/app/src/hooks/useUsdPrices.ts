import { useEffect, useState } from "react";

import { USD_POLL_MS, fetchUsdTable, type UsdTable } from "../lib/usdPrices";

/**
 * The chain's USD price table (lib/usdPrices), refreshed once a minute. A failed
 * refresh keeps the last good table; with none, `ok` is false and the heuristic
 * (stables = $1, the market's other leg via its mid) is all the form shows.
 */
export function useUsdPrices(chainId: number): { table: UsdTable; ok: boolean } {
  const [state, setState] = useState<{ chainId: number; table: UsdTable; ok: boolean }>({ chainId, table: {}, ok: false });
  useEffect(() => {
    let alive = true;
    const load = async () => {
      try {
        const table = await fetchUsdTable(chainId);
        if (alive && Object.keys(table).length > 0) setState({ chainId, table, ok: true });
      } catch {
        // keep the last good table (or the heuristic)
      }
    };
    void load();
    const t = setInterval(() => void load(), USD_POLL_MS);
    return () => {
      alive = false;
      clearInterval(t);
    };
  }, [chainId]);
  return state.chainId === chainId ? { table: state.table, ok: state.ok } : { table: {}, ok: false };
}
