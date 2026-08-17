import { bsc, mainnet, rootstock } from "viem/chains";
import type { Chain } from "viem";

/**
 * Chains the app trades on.
 *
 * `oku` is the slug in Oku's `/{chain}/cush/...` path, which does not always
 * match the viem chain name — it is the one string the depth feed is addressed
 * by, so it is configuration rather than something derived.
 */
export interface ChainConfig {
  chainId: number;
  oku: string;
  label: string;
  chain: Chain;
}

export const CHAINS: ChainConfig[] = [
  { chainId: 1, oku: "ethereum", label: "Ethereum", chain: mainnet },
  { chainId: 56, oku: "bsc", label: "BNB Chain", chain: bsc },
  { chainId: 30, oku: "rootstock", label: "Rootstock", chain: rootstock },
];

export function chainById(chainId: number): ChainConfig | undefined {
  return CHAINS.find((c) => c.chainId === chainId);
}

export function chainLabel(chainId: number): string {
  return chainById(chainId)?.label ?? `Chain ${chainId}`;
}
