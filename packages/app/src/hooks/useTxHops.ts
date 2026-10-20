import { useEffect, useMemo, useState } from "react";
import {
  createPublicClient,
  http,
  parseAbi,
  type Address,
  type Hex,
} from "viem";

import { chainById } from "../config/chains";
import { hopsOf, type Hop, type PoolTokens } from "../lib/turnover";

const POOL_ABI = parseAbi([
  "function token0() view returns (address)",
  "function token1() view returns (address)",
]);
/** Receipts read at once (the public node takes JSON-RPC batches). */
const CONCURRENCY = 8;
const TX_KEY = "x.dash.hops.";
const POOL_KEY = "x.dash.pool.";

function load<T>(key: string): T | undefined {
  try {
    const v = localStorage.getItem(key);
    return v ? (JSON.parse(v) as T) : undefined;
  } catch {
    return undefined;
  }
}

function save(key: string, v: unknown) {
  try {
    localStorage.setItem(key, JSON.stringify(v));
  } catch {
    // storage full or blocked: the next visit reads the chain again
  }
}

/**
 * The pool hops of each fill transaction (lib/turnover.ts), read from the chain's public
 * RPC — no wallet needed — and cached in the browser: receipts and a pool's tokens
 * never change. `pending` = transactions not read yet (turnover is partial meanwhile).
 */
export function useTxHops(
  chainId: number,
  txs: readonly string[],
): {
  hops: Map<string, Hop[]>;
  pools: Map<string, PoolTokens>;
  pending: number;
} {
  const [state, setState] = useState<{
    hops: Map<string, Hop[]>;
    pools: Map<string, PoolTokens>;
  }>({ hops: new Map(), pools: new Map() });
  const key = useMemo(
    () => [...new Set(txs.map((t) => t.toLowerCase()))].sort().join(","),
    [txs],
  );

  useEffect(() => {
    const url = chainById(chainId)?.chain.rpcUrls.default.http[0];
    const list = key ? key.split(",") : [];
    if (!url || list.length === 0) return;
    const client = createPublicClient({
      transport: http(url, { batch: true, retryCount: 2, timeout: 20_000 }),
    });
    let alive = true;
    const hops = new Map<string, Hop[]>();
    const pools = new Map<string, PoolTokens>();
    const publish = () =>
      alive && setState({ hops: new Map(hops), pools: new Map(pools) });

    const poolTokens = async (pool: string) => {
      if (pools.has(pool)) return;
      const cached = load<PoolTokens>(POOL_KEY + pool);
      if (cached) return void pools.set(pool, cached);
      try {
        const [t0, t1] = await Promise.all([
          client.readContract({
            address: pool as Address,
            abi: POOL_ABI,
            functionName: "token0",
          }),
          client.readContract({
            address: pool as Address,
            abi: POOL_ABI,
            functionName: "token1",
          }),
        ]);
        const p = { token0: t0.toLowerCase(), token1: t1.toLowerCase() };
        pools.set(pool, p);
        save(POOL_KEY + pool, p);
      } catch {
        // not a v3 pool, or the node failed: the hop prices from its other side or not at all
      }
    };

    const one = async (tx: string) => {
      let h = load<Hop[]>(TX_KEY + tx);
      if (!h) {
        try {
          const r = await client.getTransactionReceipt({ hash: tx as Hex });
          h = hopsOf(r.logs);
          save(TX_KEY + tx, h);
        } catch {
          return; // retried on the next mount
        }
      }
      for (const hop of h) await poolTokens(hop.pool);
      hops.set(tx, h);
    };

    void (async () => {
      const queue = [...list];
      const worker = async () => {
        while (alive && queue.length) {
          await one(queue.shift()!);
          publish();
        }
      };
      await Promise.all(Array.from({ length: CONCURRENCY }, worker));
      publish();
    })();
    return () => {
      alive = false;
    };
  }, [chainId, key]);

  const pending = key
    ? key.split(",").filter((t) => !state.hops.has(t)).length
    : 0;
  return { ...state, pending };
}
