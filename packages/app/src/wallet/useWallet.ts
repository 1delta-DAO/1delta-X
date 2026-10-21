import { useCallback, useEffect, useRef, useState, useSyncExternalStore } from "react";
import { numberToHex } from "viem";

import { chainById } from "../config/chains";
import { getProviders, providerByRdns, subscribeProviders, type EIP1193Provider } from "./eip6963";

const LAST_WALLET = "1delta-x.wallet";

export interface WalletState {
  providers: ReturnType<typeof getProviders>;
  /** The connected account, or null. */
  address: `0x${string}` | null;
  /** The chain the wallet is currently on, or null when disconnected. */
  chainId: number | null;
  connecting: boolean;
  error: string | null;
  provider: EIP1193Provider | null;
  connect: (rdns: string) => Promise<void>;
  disconnect: () => void;
  switchChain: (chainId: number) => Promise<void>;
}

/**
 * True when the wallet moved from one connected account to ANOTHER one. Not on the
 * first connect (no previous account), not on a disconnect (no next account), and not
 * when a wallet re-announces the same account (Rabby does on unlock).
 */
export function accountSwitched(prev: string | null, next: string | null | undefined): boolean {
  return !!prev && !!next && prev.toLowerCase() !== next.toLowerCase();
}

function message(e: unknown): string {
  if (typeof e === "object" && e && "message" in e) return String((e as { message: unknown }).message);
  return String(e);
}

export function useWallet(): WalletState {
  const providers = useSyncExternalStore(subscribeProviders, getProviders, getProviders);
  const [rdns, setRdns] = useState<string | null>(() => localStorage.getItem(LAST_WALLET));
  const [address, setAddress] = useState<`0x${string}` | null>(null);
  const [chainId, setChainId] = useState<number | null>(null);
  const [connecting, setConnecting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  /** The account the app last loaded for, read synchronously by the wallet's event handler. */
  const current = useRef<string | null>(null);

  const provider = rdns ? (providerByRdns(rdns)?.provider ?? null) : null;

  const read = useCallback(async (p: EIP1193Provider, accounts?: string[]) => {
    const list = accounts ?? ((await p.request({ method: "eth_accounts" })) as string[]);
    const id = (await p.request({ method: "eth_chainId" })) as string;
    current.current = list[0] ?? null;
    setAddress((list[0] as `0x${string}`) ?? null);
    setChainId(Number.parseInt(id, 16));
  }, []);

  // Reconnect silently when the wallet still has this site authorised. Doing it
  // with `eth_accounts` rather than `eth_requestAccounts` means a reload never
  // pops a wallet prompt on its own.
  useEffect(() => {
    if (!provider) return;
    void read(provider).catch(() => setAddress(null));

    const onAccounts = (...args: never[]) => {
      const accounts = args[0] as unknown as string[];
      // ACCOUNT SWITCH (2026-10-21): reload the page. Balances re-read by address, but
      // much else is per account: the orderbook store's tracked orders (shown as
      // "yours" on the ladder), the last receipt, quotes sized for the old maker,
      // allowance and permit state, nonce reservations. Resetting each one by hand
      // would miss the next one added. The reload reconnects silently through
      // `eth_accounts` (LAST_WALLET), so it costs no wallet prompt, only the ticket input.
      if (accountSwitched(current.current, accounts?.[0])) {
        window.location.reload();
        return;
      }
      current.current = accounts?.[0] ?? null;
      setAddress((accounts?.[0] as `0x${string}`) ?? null);
      if (!accounts?.length) localStorage.removeItem(LAST_WALLET);
    };
    const onChain = (...args: never[]) => setChainId(Number.parseInt(args[0] as unknown as string, 16));

    provider.on?.("accountsChanged", onAccounts);
    provider.on?.("chainChanged", onChain);
    return () => {
      provider.removeListener?.("accountsChanged", onAccounts);
      provider.removeListener?.("chainChanged", onChain);
    };
  }, [provider, read]);

  const connect = useCallback(
    async (target: string) => {
      const detail = providerByRdns(target);
      if (!detail) {
        setError("wallet not available");
        return;
      }
      setConnecting(true);
      setError(null);
      try {
        const accounts = (await detail.provider.request({ method: "eth_requestAccounts" })) as string[];
        localStorage.setItem(LAST_WALLET, target);
        setRdns(target);
        await read(detail.provider, accounts);
      } catch (e) {
        setError(message(e));
      } finally {
        setConnecting(false);
      }
    },
    [read],
  );

  const disconnect = useCallback(() => {
    localStorage.removeItem(LAST_WALLET);
    setRdns(null);
    current.current = null;
    setAddress(null);
    setChainId(null);
    setError(null);
  }, []);

  const switchChain = useCallback(
    async (target: number) => {
      if (!provider) return;
      const config = chainById(target);
      if (!config) return;
      setError(null);
      try {
        await provider.request({
          method: "wallet_switchEthereumChain",
          params: [{ chainId: numberToHex(target) }],
        });
      } catch (e) {
        // 4902: the wallet does not know this chain yet. Offering to add it is
        // the difference between "switch failed" and a working Rootstock tab.
        const code = (e as { code?: number }).code;
        if (code !== 4902 && code !== -32603) {
          setError(message(e));
          return;
        }
        try {
          await provider.request({
            method: "wallet_addEthereumChain",
            params: [
              {
                chainId: numberToHex(target),
                chainName: config.chain.name,
                nativeCurrency: config.chain.nativeCurrency,
                rpcUrls: config.chain.rpcUrls.default.http,
                blockExplorerUrls: config.chain.blockExplorers
                  ? [config.chain.blockExplorers.default.url]
                  : undefined,
              },
            ],
          });
        } catch (addError) {
          setError(message(addError));
        }
      }
    },
    [provider],
  );

  return {
    providers,
    address: provider ? address : null,
    chainId: provider ? chainId : null,
    connecting,
    error,
    provider,
    connect,
    disconnect,
    switchChain,
  };
}
