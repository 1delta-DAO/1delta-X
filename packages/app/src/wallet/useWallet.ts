import { useCallback, useEffect, useState, useSyncExternalStore } from "react";
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

  const provider = rdns ? (providerByRdns(rdns)?.provider ?? null) : null;

  const read = useCallback(async (p: EIP1193Provider, accounts?: string[]) => {
    const list = accounts ?? ((await p.request({ method: "eth_accounts" })) as string[]);
    const id = (await p.request({ method: "eth_chainId" })) as string;
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
