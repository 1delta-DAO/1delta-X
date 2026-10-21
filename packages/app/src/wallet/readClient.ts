import { createPublicClient, custom, http, type PublicClient } from "viem";

import { chainById } from "../config/chains";
import type { EIP1193Provider } from "./eip6963";

/**
 * A READ client for `chainId`: the wallet's provider while the wallet is on that chain,
 * else the chain's public RPC (allowed by the CSP's `connect-src`). Reads — balances,
 * allowances, gas price, fill state — never depend on which network the wallet is on;
 * only SIGNING does, and that is where the app asks to switch (2026-10-21). `null` for
 * an unknown chain.
 */
export function readClientFor(chainId: number, provider: EIP1193Provider | null | undefined, onChain: boolean): PublicClient | null {
  const config = chainById(chainId);
  if (!config) return null;
  if (provider && onChain) return createPublicClient({ chain: config.chain, transport: custom(provider as Parameters<typeof custom>[0]) }) as PublicClient;
  const url = config.chain.rpcUrls.default.http[0];
  if (!url) return null;
  return createPublicClient({ chain: config.chain, transport: http(url, { batch: true, retryCount: 1, timeout: 20_000 }) }) as PublicClient;
}
