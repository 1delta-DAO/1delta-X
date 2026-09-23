import { useCallback, useEffect, useState } from "react";
import { createPublicClient, createWalletClient, custom, erc20Abi, type Address } from "viem";

import { chainById } from "../config/chains";
import type { EIP1193Provider } from "./eip6963";

export interface AllowanceArgs {
  provider: EIP1193Provider | null;
  owner: Address | null;
  chainId: number;
  onChain: boolean;
  /** The token the order spends. Null while the market's metadata is loading. */
  token: Address | null;
  /** Permit3 — what actually pulls the maker's input. Null when undeployed. */
  spender: Address | null;
}

export interface AllowanceState {
  /** Current allowance in token wei. `undefined` means unknown, never zero. */
  allowance: bigint | undefined;
  approving: boolean;
  error: string | null;
  /**
   * Set the allowance to exactly `amount`.
   *
   * Pre-audit policy: this is called with the input of the single order about to
   * be signed, never with an unbounded value. Every trade therefore costs one
   * approval, and the most an unaudited contract can ever pull is the order the
   * user was looking at when they approved it.
   */
  approve: (amount: bigint) => Promise<void>;
  refresh: () => void;
}

function message(e: unknown): string {
  if (typeof e === "object" && e && "message" in e) {
    // Wallet errors arrive as multi-paragraph dumps; the first line is the part
    // a person can act on.
    return String((e as { message: unknown }).message).split("\n")[0]!;
  }
  return String(e);
}

export function useAllowance(args: AllowanceArgs): AllowanceState {
  const { provider, owner, chainId, onChain, token, spender } = args;
  const [allowance, setAllowance] = useState<bigint | undefined>(undefined);
  const [approving, setApproving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [nonce, setNonce] = useState(0);

  const refresh = useCallback(() => setNonce((n) => n + 1), []);

  useEffect(() => {
    if (!provider || !owner || !token || !spender || !onChain) {
      setAllowance(undefined);
      return;
    }
    const config = chainById(chainId);
    if (!config) return;

    let alive = true;
    const client = createPublicClient({ chain: config.chain, transport: custom(provider) });
    void client
      .readContract({ address: token, abi: erc20Abi, functionName: "allowance", args: [owner, spender] })
      .then((value) => alive && setAllowance(value))
      .catch(() => alive && setAllowance(undefined));
    return () => {
      alive = false;
    };
  }, [provider, owner, token, spender, chainId, onChain, nonce]);

  // A pending approval belongs to one token and spender; changing either leaves
  // its error describing something no longer on screen.
  useEffect(() => {
    setError(null);
  }, [token, spender, chainId]);

  const approve = useCallback(
    async (amount: bigint) => {
      if (!provider || !owner || !token || !spender) return;
      const config = chainById(chainId);
      if (!config) return;

      setApproving(true);
      setError(null);
      const publicClient = createPublicClient({ chain: config.chain, transport: custom(provider) });
      const wallet = createWalletClient({ account: owner, chain: config.chain, transport: custom(provider) });

      const send = (value: bigint) =>
        wallet.writeContract({ address: token, abi: erc20Abi, functionName: "approve", args: [spender, value] });

      try {
        let hash: `0x${string}`;
        try {
          hash = await send(amount);
        } catch (e) {
          // Some ERC-20s refuse to move a non-zero allowance straight to another
          // non-zero value. Only reached when a previous order was approved and
          // never filled, so the reset is not on the common path.
          const current = await publicClient
            .readContract({ address: token, abi: erc20Abi, functionName: "allowance", args: [owner, spender] })
            .catch(() => 0n);
          if (current === 0n) throw e;
          await publicClient.waitForTransactionReceipt({ hash: await send(0n) });
          hash = await send(amount);
        }
        const receipt = await publicClient.waitForTransactionReceipt({ hash });
        if (receipt.status !== "success") throw new Error("approval transaction reverted");
        setAllowance(amount);
      } catch (e) {
        // A declined prompt is an ordinary outcome: report it and leave the
        // allowance reading whatever the chain actually says.
        setError(message(e));
        refresh();
      } finally {
        setApproving(false);
      }
    },
    [provider, owner, token, spender, chainId, refresh],
  );

  return { allowance, approving, error, approve, refresh };
}
