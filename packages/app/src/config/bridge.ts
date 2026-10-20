import { arbitrum, berachain, hyperEvm, ink, mainnet, mantle, monad, optimism, plasma, polygon, unichain } from "viem/chains";
import type { Address, Chain } from "viem";

/**
 * THE USD₮0 ON-RAMP (2026-10-20): bridge USDT0 from another chain to the maker's own
 * address on Rootstock, through USDT0's LayerZero OFT mesh. On arrival nothing else is
 * needed — USD₮0 on Rootstock carries an ERC-2612 permit and the filler relays it, so a
 * wallet holding ZERO RBTC can sell USD₮0 for RBTC (or anything else on the book).
 *
 * Every address here is PINNED from docs.usdt0.to/technical-documentation/deployments
 * (read 2026-10-20) and re-checked on-chain by `scripts/verify-usdt0-bridge.ts`:
 * the OFT's `token()` is `token`, its Rootstock peer is {@link ROOTSTOCK_USDT0.oft}, and
 * the Rootstock OFT's peer for `eid` is `oft` back. Nothing is taken from a feed at runtime.
 *
 * Tron and TON reach this mesh only through USDT0's separate "Legacy Mesh" (0.03 %, a
 * hop via Arbitrum): those users are sent to usdt0.to rather than built for here.
 */
export interface BridgeSource {
  /** Stable key (also what the form's "which chain" answer reads). */
  key: string;
  label: string;
  chain: Chain;
  /** LayerZero v2 endpoint id. */
  eid: number;
  /** The ERC-20 the user sends (USDT on Ethereum, USDT0 elsewhere). */
  token: Address;
  /** What the wallet shows the token as. */
  symbol: string;
  decimals: number;
  /** The OFT (or, on Ethereum, the OFT adapter that locks USDT). */
  oft: Address;
  /**
   * A public RPC to use instead of viem's chain default — for wallet_addEthereumChain
   * and the verify script. Ethereum's default (eth.merkle.io) rate-limits (Cloudflare
   * 1015, seen 2026-10-20).
   */
  rpc?: string;
}

/** The destination: USD₮0 on Rootstock — the same token the app's markets pin (config/markets.ts). */
export const ROOTSTOCK_USDT0 = {
  chainId: 30,
  eid: 30333,
  token: "0x779ded0c9e1022225f8e0630b35a9b54be713736" as Address,
  oft: "0x1a594d5d5d1c426281c1064b07f23f57b2716b61" as Address,
  decimals: 6,
} as const;

/** In the order the picker lists them: the biggest USDT holder bases first. */
export const BRIDGE_SOURCES: readonly BridgeSource[] = [
  { key: "arbitrum", label: "Arbitrum", chain: arbitrum, eid: 30110, token: "0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9", symbol: "USD₮0", decimals: 6, oft: "0x14e4a1b13bf7f943c8ff7c51fb60fa964a298d92" },
  { key: "ethereum", label: "Ethereum", chain: mainnet, eid: 30101, token: "0xdac17f958d2ee523a2206206994597c13d831ec7", symbol: "USDT", decimals: 6, oft: "0x6c96de32cea08842dcc4058c14d3aaad7fa41dee", rpc: "https://ethereum-rpc.publicnode.com" },
  { key: "polygon", label: "Polygon", chain: polygon, eid: 30109, token: "0xc2132d05d31c914a87c6611c10748aeb04b58e8f", symbol: "USD₮0", decimals: 6, oft: "0x6ba10300f0dc58b7a1e4c0e41f5dabb7d7829e13" },
  { key: "hyperevm", label: "HyperEVM", chain: hyperEvm, eid: 30367, token: "0xb8ce59fc3717ada4c02eadf9682a9e934f625ebb", symbol: "USD₮0", decimals: 6, oft: "0x904861a24f30ec96ea7cfc3be9ea4b476d237e98" },
  { key: "plasma", label: "Plasma", chain: plasma, eid: 30383, token: "0xb8ce59fc3717ada4c02eadf9682a9e934f625ebb", symbol: "USD₮0", decimals: 6, oft: "0x02ca37966753bdddf11216b73b16c1de756a7cf9" },
  { key: "monad", label: "Monad", chain: monad, eid: 30390, token: "0xe7cd86e13ac4309349f30b3435a9d337750fc82d", symbol: "USD₮0", decimals: 6, oft: "0x9151434b16b9763660705744891fa906f660ecc5" },
  { key: "optimism", label: "Optimism", chain: optimism, eid: 30111, token: "0x01bff41798a0bcf287b996046ca68b395dbc1071", symbol: "USD₮0", decimals: 6, oft: "0xf03b4d9ac1d5d1e7c4cef54c2a313b9fe051a0ad" },
  { key: "unichain", label: "Unichain", chain: unichain, eid: 30320, token: "0x9151434b16b9763660705744891fa906f660ecc5", symbol: "USD₮0", decimals: 6, oft: "0xc07be8994d035631c36fb4a89c918cefb2f03ec3" },
  { key: "berachain", label: "Berachain", chain: berachain, eid: 30362, token: "0x779ded0c9e1022225f8e0630b35a9b54be713736", symbol: "USD₮0", decimals: 6, oft: "0x3dc96399109df5ceb2c226664a086140bd0379cb" },
  { key: "ink", label: "Ink", chain: ink, eid: 30339, token: "0x0200c29006150606b650577bbe7b6248f58470c1", symbol: "USD₮0", decimals: 6, oft: "0x1cb6de532588fca4a21b7209de7c456af8434a65" },
  { key: "mantle", label: "Mantle", chain: mantle, eid: 30181, token: "0x779ded0c9e1022225f8e0630b35a9b54be713736", symbol: "USD₮0", decimals: 6, oft: "0xcb768e263fb1c62214e7cab4aa8d036d76dc59cc" },
];

/** Where Tron / TON / any unlisted chain is sent. */
export const USDT0_APP_URL = "https://usdt0.to/transfer";

/** LayerZero's explorer for a source-chain send. */
export const layerZeroScanTx = (txHash: string) => `https://layerzeroscan.com/tx/${txHash}`;

/**
 * The suggested ceiling per bridge while the contracts are pre-audit. A suggestion the
 * panel states, not a cap it enforces: the user's funds on Rootstock are theirs.
 */
export const SUGGESTED_MAX_USD = 500;

/** The RPC for a source chain: the pinned override, else viem's default. */
export const sourceRpc = (s: BridgeSource): string => s.rpc ?? s.chain.rpcUrls.default.http[0]!;

export function bridgeSource(key: string): BridgeSource | undefined {
  return BRIDGE_SOURCES.find((s) => s.key === key);
}
