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
  /** Slug in Oku's `/{chain}/cush/...` path — the Uniswap v3 tick source. */
  oku: string;
  label: string;
  chain: Chain;
  /**
   * SushiSwap v3 subgraph. Goldsky-hosted deployments are public; the ones
   * behind The Graph's gateway need an API key, so those carry a `${GRAPH_KEY}`
   * placeholder and stay dark unless `VITE_GRAPH_KEY` is set.
   */
  sushi?: string;
}

const GOLDSKY = "https://api.goldsky.com/api/public/project_clslspm3c0knv01wvgfb2fqyq/subgraphs";
const GATEWAY = "https://gateway-arbitrum.network.thegraph.com/api/${GRAPH_KEY}/deployments/id";

export const CHAINS: ChainConfig[] = [
  { chainId: 1, oku: "ethereum", label: "Ethereum", chain: mainnet, sushi: `${GATEWAY}/QmP1FMFsU4wNcui1eezwuvBjxrbLPucKrKZ9Kftn34nULw` },
  { chainId: 56, oku: "bsc", label: "BNB Chain", chain: bsc, sushi: `${GATEWAY}/QmWQcbEg7J9gWBWfuqnknj5pdYZTp4U31JxQrmjWNEmpTM` },
  // Rootstock is the one chain here whose Sushi subgraph is public, so it is
  // the only one where the second venue works out of the box.
  { chainId: 30, oku: "rootstock", label: "Rootstock", chain: rootstock, sushi: `${GOLDSKY}/sushiswap/v3-rootstock-3/gn` },
];

/**
 * The usable SushiSwap subgraph for a chain, or `undefined`.
 *
 * A gateway URL without a key is not a degraded endpoint, it is a 401 — so it
 * is reported as absent rather than tried and failed. Set `VITE_GRAPH_KEY` to
 * light those chains up.
 */
export function sushiEndpoint(chainId: number): string | undefined {
  const url = chainById(chainId)?.sushi;
  if (!url) return undefined;
  if (!url.includes("${GRAPH_KEY}")) return url;
  const key = import.meta.env.VITE_GRAPH_KEY;
  return key ? url.replace("${GRAPH_KEY}", key) : undefined;
}

export function chainById(chainId: number): ChainConfig | undefined {
  return CHAINS.find((c) => c.chainId === chainId);
}

export function chainLabel(chainId: number): string {
  return chainById(chainId)?.label ?? `Chain ${chainId}`;
}
