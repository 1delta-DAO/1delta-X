import type { Dex } from "../lib/types";
import { CHAINS, DEFAULT_CHAIN_ID } from "./chains";

/**
 * Markets are configuration, not discovery. A pool address pinned here always
 * resolves; searching for one by token pair adds a round-trip and a second
 * failure mode before the book can render at all.
 *
 * `base`/`quote` are how the pair is quoted in this UI. Which of them is the
 * pool's token0 is resolved from the pool's own metadata at runtime, so a pool
 * whose token order is the other way round still lands correctly.
 */
/** One AMM pool a market aggregates. */
export interface PoolRef {
  dex: Dex;
  address: `0x${string}`;
  /** Fee tier in hundredths of a bip, as Uniswap and Sushi both store it. */
  feeBps: number;
}

export interface Market {
  id: string;
  chainId: number;
  /**
   * Every pool whose depth this market shows, in priority order. The first is
   * the PRIMARY: its token metadata resolves the pair, and the rest are matched
   * to it by token address rather than symbol — the two indexers disagree on
   * symbols (`USD0` vs `USD₮0`) and agree on addresses.
   */
  pools: PoolRef[];
  base: string;
  quote: string;
}

const DEX_LABEL: Record<Dex, string> = { "uniswap-v3": "Uni v3", "sushiswap-v3": "Sushi v3" };

/** "Uni v3 0.05% · Sushi v3 0.30%" — what the picker shows under the pair. */
export function venueLabel(market: Market): string {
  return market.pools.map((p) => `${DEX_LABEL[p.dex]} ${(p.feeBps / 10_000).toFixed(2)}%`).join(" · ");
}

/** The pool whose metadata defines the pair. */
export function primaryPool(market: Market): PoolRef {
  return market.pools[0]!;
}

export const MARKETS: Market[] = [
  // ── Ethereum ───────────────────────────────────────────
  {
    id: "eth-1-eth-usdc",
    chainId: 1,
    pools: [{ dex: "uniswap-v3", address: "0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640", feeBps: 500 }],
    base: "ETH",
    quote: "USDC",
  },
  {
    id: "eth-1-eth-usdt",
    chainId: 1,
    pools: [{ dex: "uniswap-v3", address: "0x11b815efb8f581194ae79006d24e0d814b7697f6", feeBps: 500 }],
    base: "ETH",
    quote: "USDT",
  },
  {
    id: "eth-1-wbtc-eth",
    chainId: 1,
    pools: [{ dex: "uniswap-v3", address: "0x4585fe77225b41b697c938b018e2ac67ac5a20c0", feeBps: 500 }],
    base: "WBTC",
    quote: "ETH",
  },
  {
    id: "eth-1-usdc-usdt",
    chainId: 1,
    pools: [{ dex: "uniswap-v3", address: "0x3416cf6c708da44db2624d63ea0aaef7113527c6", feeBps: 100 }],
    base: "USDC",
    quote: "USDT",
  },
  {
    id: "eth-1-link-eth",
    chainId: 1,
    pools: [{ dex: "uniswap-v3", address: "0xa6cc3c2531fdaa6ae1a3ca84c2855806728693e8", feeBps: 3000 }],
    base: "LINK",
    quote: "ETH",
  },

  // ── BNB Chain ──────────────────────────────────────────
  {
    id: "bsc-56-bnb-usdt",
    chainId: 56,
    pools: [{ dex: "uniswap-v3", address: "0x47a90a2d92a8367a91efa1906bfc8c1e05bf10c4", feeBps: 100 }],
    base: "WBNB",
    quote: "USDT",
  },
  {
    id: "bsc-56-btcb-bnb",
    chainId: 56,
    pools: [{ dex: "uniswap-v3", address: "0x28df0835942396b7a1b7ae1cd068728e6ddbbafd", feeBps: 500 }],
    base: "BTCB",
    quote: "WBNB",
  },
  {
    id: "bsc-56-eth-bnb",
    chainId: 56,
    pools: [{ dex: "uniswap-v3", address: "0x0f338ec12d3f7c3d77a4b9fcc1f95f3fb6ad0ea6", feeBps: 500 }],
    base: "ETH",
    quote: "WBNB",
  },

  // ── Rootstock ──────────────────────────────────────────
  // The only chain here whose SushiSwap subgraph is public, so it is where the
  // aggregated two-venue book actually runs without an API key.
  {
    id: "rsk-30-wrbtc-usd0",
    chainId: 30,
    pools: [
      { dex: "uniswap-v3", address: "0xaef6fabf3b0c9e5f9d6d5170afc703a633479bbd", feeBps: 3000 },
      { dex: "sushiswap-v3", address: "0x6d778c369cb386d50f4ee676c5c264374c52fd71", feeBps: 3000 },
    ],
    base: "WRBTC",
    quote: "USD0",
  },
  {
    id: "rsk-30-weth-wrbtc",
    chainId: 30,
    pools: [
      { dex: "uniswap-v3", address: "0x7717364fa619fc22a8f8eae124e79a1b9a2cf3e6", feeBps: 3000 },
      { dex: "sushiswap-v3", address: "0x5dd94c3f508da1b5152ebc365fa44b1bf7c628eb", feeBps: 3000 },
    ],
    base: "WETH",
    quote: "WRBTC",
  },
  {
    id: "rsk-30-usdrif-usd0",
    chainId: 30,
    pools: [{ dex: "uniswap-v3", address: "0xd845702af381f0405661747a6a20bde0401a19d6", feeBps: 500 }],
    base: "USDRIF",
    quote: "USD0",
  },
];

export function marketById(id: string): Market {
  const m = MARKETS.find((x) => x.id === id);
  if (!m) throw new Error(`unknown market ${id}`);
  return m;
}

export function marketsOn(chainId: number): Market[] {
  return MARKETS.filter((m) => m.chainId === chainId);
}

/** Only chains that actually have a market are worth offering in the selector. */
export function tradableChains(): number[] {
  return CHAINS.map((c) => c.chainId).filter((id) => marketsOn(id).length > 0);
}

/**
 * The chain to open on: the configured default, or the first tradable one if
 * that default has no markets left. Falling back beats booting into a chain
 * with an empty picker.
 */
export function defaultChain(): number {
  const tradable = tradableChains();
  return tradable.includes(DEFAULT_CHAIN_ID) ? DEFAULT_CHAIN_ID : tradable[0]!;
}

export function symbolsOn(chainId: number): string[] {
  const out: string[] = [];
  for (const m of marketsOn(chainId)) {
    for (const s of [m.base, m.quote]) if (!out.includes(s)) out.push(s);
  }
  return out;
}

export function pairsWith(chainId: number, symbol: string): string[] {
  const out: string[] = [];
  for (const m of marketsOn(chainId)) {
    const other = m.base === symbol ? m.quote : m.quote === symbol ? m.base : null;
    if (other && !out.includes(other)) out.push(other);
  }
  return out;
}

/** The market quoting `a` against `b`, in whichever orientation it is configured. */
export function marketFor(chainId: number, a: string, b: string): Market | undefined {
  return marketsOn(chainId).find(
    (m) => (m.base === a && m.quote === b) || (m.base === b && m.quote === a),
  );
}
