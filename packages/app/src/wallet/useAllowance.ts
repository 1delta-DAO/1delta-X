import { useCallback, useEffect, useState } from "react";
import { createPublicClient, createWalletClient, custom, erc20Abi, type Address } from "viem";

import { chainById } from "../config/chains";
import { readFundingState, verifyDeployment, type Reader } from "../lib/chain";
import { fundingCalls, planFunding, revokeCalls, type FundingState } from "../lib/funding";
import type { EIP1193Provider } from "./eip6963";

export interface AllowanceArgs {
  provider: EIP1193Provider | null;
  owner: Address | null;
  chainId: number;
  onChain: boolean;
  /** The token the order spends. Null while nothing is selected. */
  token: Address | null;
  /** The deployment the order is signed into. Null when nothing is deployed. */
  deployment: { permit3: Address; settlement: Address } | null;
}

export interface AllowanceState {
  /**
   * Both funding legs as the chain reports them. `undefined` means unknown —
   * not read yet, or the deployment failed verification — never zero.
   */
  funding: FundingState | undefined;
  /** Set when the configured Permit3 is not the one Settlement uses; nothing is offered then. */
  mismatch: string | null;
  busy: boolean;
  error: string | null;
  /**
   * Send whatever `planFunding` says is missing for an order of `amount` wei
   * living `ttlSeconds`: the exact ERC-20 approval to Permit3 and the exact,
   * expiring Permit3 book grant to Settlement (A-IMMUT-1).
   */
  fund: (amount: bigint, ttlSeconds: number) => Promise<void>;
  /** Clear both legs — the "no standing allowance" promise, kept by an action rather than a claim. */
  revoke: () => Promise<void>;
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
  const { provider, owner, chainId, onChain, token } = args;
  const permit3 = args.deployment?.permit3 ?? null;
  const settlement = args.deployment?.settlement ?? null;
  const [funding, setFunding] = useState<FundingState | undefined>(undefined);
  const [mismatch, setMismatch] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [nonce, setNonce] = useState(0);

  const refresh = useCallback(() => setNonce((n) => n + 1), []);

  useEffect(() => {
    if (!provider || !owner || !token || !permit3 || !settlement || !onChain) {
      setFunding(undefined);
      return;
    }
    const config = chainById(chainId);
    if (!config) return;

    let alive = true;
    const client = createPublicClient({ chain: config.chain, transport: custom(provider) }) as unknown as Reader;
    void verifyDeployment(client, { settlement, permit3 })
      .then(() => {
        if (alive) setMismatch(null);
        return readFundingState(client, { token, owner, permit3, settlement });
      })
      .then((state) => alive && setFunding(state))
      .catch((e) => {
        if (!alive) return;
        setFunding(undefined);
        if (message(e).startsWith("deployment mismatch")) setMismatch(message(e));
      });
    return () => {
      alive = false;
    };
  }, [provider, owner, token, permit3, settlement, chainId, onChain, nonce]);

  // A pending approval belongs to one token and deployment; changing either
  // leaves its error describing something no longer on screen.
  useEffect(() => {
    setError(null);
  }, [token, permit3, settlement, chainId]);

  const send = useCallback(
    async (build: (state: FundingState) => Array<{ to: Address; data: `0x${string}` }>) => {
      if (!provider || !owner || !token || !permit3 || !settlement) return;
      const config = chainById(chainId);
      if (!config) return;

      setBusy(true);
      setError(null);
      const publicClient = createPublicClient({ chain: config.chain, transport: custom(provider) });
      const wallet = createWalletClient({ account: owner, chain: config.chain, transport: custom(provider) });
      const reader = publicClient as unknown as Reader;

      try {
        // Re-verified and re-read at click time: the plan is built from what
        // the chain says NOW, not from a render that may be a block old.
        await verifyDeployment(reader, { settlement, permit3 });
        const state = await readFundingState(reader, { token, owner, permit3, settlement });
        for (const call of build(state)) {
          let hash: `0x${string}`;
          try {
            hash = await wallet.sendTransaction({ to: call.to, data: call.data, chain: config.chain, account: owner });
          } catch (e) {
            // Some ERC-20s refuse to move a non-zero allowance straight to
            // another non-zero value; reset to zero and retry, ERC-20 leg only.
            if (call.to !== token || state.erc20Allowance === 0n) throw e;
            const reset = await wallet.writeContract({
              address: token,
              abi: erc20Abi,
              functionName: "approve",
              args: [permit3, 0n],
            });
            await publicClient.waitForTransactionReceipt({ hash: reset });
            hash = await wallet.sendTransaction({ to: call.to, data: call.data, chain: config.chain, account: owner });
          }
          const receipt = await publicClient.waitForTransactionReceipt({ hash });
          if (receipt.status !== "success") throw new Error("transaction reverted");
        }
      } catch (e) {
        // A declined prompt is an ordinary outcome: report it and leave the
        // reading at whatever the chain actually says.
        setError(message(e));
      } finally {
        refresh();
        setBusy(false);
      }
    },
    [provider, owner, token, permit3, settlement, chainId, refresh],
  );

  const fund = useCallback(
    (amount: bigint, ttlSeconds: number) =>
      send((state) =>
        fundingCalls(planFunding(state, amount, ttlSeconds, Math.floor(Date.now() / 1000)).steps, {
          token: token!,
          permit3: permit3!,
          settlement: settlement!,
        }),
      ),
    [send, token, permit3, settlement],
  );

  const revoke = useCallback(
    () => send((state) => revokeCalls(state, { token: token!, permit3: permit3!, settlement: settlement! })),
    [send, token, permit3, settlement],
  );

  return { funding, mismatch, busy, error, fund, revoke, refresh };
}
