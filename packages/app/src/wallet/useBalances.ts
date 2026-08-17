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

    const load = async () => {
      try {
        const values = await Promise.all(
          tokens.map((t) =>
            client.readContract({
              address: t.address,
              abi: erc20Abi,
              functionName: "balanceOf",
              args: [address],
            }),
          ),
        );
        if (!alive) return;
        const next: Record<string, number> = {};
        tokens.forEach((t, i) => {
          next[t.address.toLowerCase()] = Number(formatUnits(values[i], t.decimals));
        });
        setBalances(next);
      } catch {
        // A balance we cannot read is shown as unknown, not as zero — zero would
        // read as "you hold none of this" and is a different statement.
        if (alive) setBalances({});
      }
    };

    void load();
    const t = setInterval(load, 20_000);
    return () => {
      alive = false;
      clearInterval(t);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [provider, address, chainId, onChain, key]);

  return balances;
}
