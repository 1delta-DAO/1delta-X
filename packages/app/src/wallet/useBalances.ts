import { useCallback, useEffect, useMemo, useState } from "react";
import { erc20Abi, formatUnits } from "viem";

import { readClientFor } from "./readClient";
import type { EIP1193Provider } from "./eip6963";

export interface BalanceArgs {
  provider: EIP1193Provider | null;
  address: `0x${string}` | null;
  /** The market's chain. Reads only happen when the wallet is on it. */
  chainId: number;
  /** Whether the wallet is currently on that chain. */
  onChain: boolean;
  tokens: Array<{ address: `0x${string}`; decimals: number }>;
}

/**
 * ERC-20 balances for the market's two tokens, read through the connected
 * wallet's own provider.
 *
 * Reading through the wallet rather than a public RPC keeps the app free of
 * per-chain endpoint configuration and of a key nobody wants to manage — and
 * the wallet is already talking to the chain the user is on.
 */
export interface Balances {
  /** Human units, for display and the ticket's float maths. */
  human: Record<string, number>;
  /**
   * The exact on-chain value in wei. "max" and every input cap use THIS: a
   * balance pushed through a double can round above itself (G-TS_SIGN-7).
   */
  raw: Record<string, bigint>;
  /** The chain's native coin (RBTC on Rootstock), wei; undefined until read. */
  native: bigint | undefined;
  /** Re-read everything now (after a signature or a transaction). */
  refresh: () => void;
}

/** How often balances are re-read while the page is open, ms. */
export const BALANCE_REFRESH_MS = 15_000;

export function useBalances(args: BalanceArgs): Balances {
  const { provider, address, chainId, onChain, tokens } = args;
  const [balances, setBalances] = useState<Record<string, bigint>>({});
  const [native, setNative] = useState<bigint | undefined>(undefined);
  const [nonce, setNonce] = useState(0);
  const key = tokens.map((t) => t.address).join(",");

  // Another account or chain: never show the previous one's numbers while re-reading.
  useEffect(() => {
    setBalances({});
    setNative(undefined);
  }, [address, chainId]);

  useEffect(() => {
    // Read whichever network the wallet is on: off-chain, through the public RPC.
    const client = address ? readClientFor(chainId, provider, onChain) : null;
    if (!address || !client) {
      setBalances({});
      setNative(undefined);
      return;
    }
    if (!tokens.length) return;

    let alive = true;

    // Per token, not one joined read: a single unresponsive ERC-20 would
    // otherwise leave every balance on the chain showing "—".
    const load = () => {
      void client
        .getBalance({ address })
        .then((v) => alive && setNative(v))
        .catch(() => alive && setNative(undefined));
      for (const t of tokens) {
        void client
          .readContract({ address: t.address, abi: erc20Abi, functionName: "balanceOf", args: [address] })
          .then((value) => {
            if (!alive) return;
            setBalances((prev) => ({ ...prev, [t.address.toLowerCase()]: value }));
          })
          .catch(() => {
            // A balance we cannot read stays unknown, never zero — zero reads as
            // "you hold none of this", which is a different statement.
            if (!alive) return;
            setBalances((prev) => {
              if (!(t.address.toLowerCase() in prev)) return prev;
              const next = { ...prev };
              delete next[t.address.toLowerCase()];
              return next;
            });
          });
      }
    };

    load();
    const t = setInterval(load, BALANCE_REFRESH_MS);
    return () => {
      alive = false;
      clearInterval(t);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [provider, address, chainId, onChain, key, nonce]);

  const refresh = useCallback(() => setNonce((n) => n + 1), []);

  const decimalsKey = tokens.map((t) => `${t.address.toLowerCase()}:${t.decimals}`).join(",");
  return useMemo(() => {
    const human: Record<string, number> = {};
    for (const t of tokens) {
      const v = balances[t.address.toLowerCase()];
      if (v !== undefined) human[t.address.toLowerCase()] = Number(formatUnits(v, t.decimals));
    }
    return { human, raw: balances, native, refresh };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [balances, native, refresh, decimalsKey]);
}
