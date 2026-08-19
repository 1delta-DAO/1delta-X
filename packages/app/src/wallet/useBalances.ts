import { useEffect, useState } from "react";
import { createPublicClient, custom, erc20Abi, formatUnits } from "viem";

import { chainById } from "../config/chains";
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
export function useBalances(args: BalanceArgs): Record<string, number> {
  const { provider, address, chainId, onChain, tokens } = args;
  const [balances, setBalances] = useState<Record<string, number>>({});
  const key = tokens.map((t) => t.address).join(",");

  useEffect(() => {
    if (!provider || !address || !onChain) {
      setBalances({});
      return;
    }
    const config = chainById(chainId);
    if (!config || !tokens.length) return;

    let alive = true;
    const client = createPublicClient({ chain: config.chain, transport: custom(provider) });

    // Per token, not one joined read: a single unresponsive ERC-20 would
    // otherwise leave every balance on the chain showing "—".
    const load = () => {
      for (const t of tokens) {
        void client
          .readContract({ address: t.address, abi: erc20Abi, functionName: "balanceOf", args: [address] })
          .then((value) => {
            if (!alive) return;
            setBalances((prev) => ({ ...prev, [t.address.toLowerCase()]: Number(formatUnits(value, t.decimals)) }));
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
    const t = setInterval(load, 20_000);
    return () => {
      alive = false;
      clearInterval(t);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [provider, address, chainId, onChain, key]);

  return balances;
}
