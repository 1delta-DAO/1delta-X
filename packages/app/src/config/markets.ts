import { CHAINS } from "./chains";

/**
 * Markets are configuration, not discovery. A pool address pinned here always
 * resolves; searching for one by token pair adds a round-trip and a second
 * failure mode before the book can render at all.
 *
 * `base`/`quote` are how the pair is quoted in this UI. Which of them is the
 * pool's token0 is resolved from the pool's own metadata at runtime, so a pool
 * whose token order is the other way round still lands correctly.
 */
export interface Market {
  id: string;
  chainId: number;
  pool: `0x${string}`;
  base: string;
  quote: string;
  /** Shown under the pair in the picker. */
  venue: string;
}

function venue(feeBps: number): string {
  return `Uniswap v3 · ${(feeBps / 10_000).toFixed(2)}%`;
}

export const MARKETS: Market[] = [
  // ── Ethereum ───────────────────────────────────────────
  {
    id: "eth-1-eth-usdc",
    chainId: 1,
    pool: "0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640",
    base: "ETH",
    quote: "USDC",
    venue: venue(500),
  },
  {
    id: "eth-1-eth-usdt",
    chainId: 1,
    pool: "0x11b815efb8f581194ae79006d24e0d814b7697f6",
    base: "ETH",
    quote: "USDT",
    venue: venue(500),
  },
  {
    id: "eth-1-wbtc-eth",
    chainId: 1,
    pool: "0x4585fe77225b41b697c938b018e2ac67ac5a20c0",
    base: "WBTC",
    quote: "ETH",
    venue: venue(500),
  },
  {
    id: "eth-1-usdc-usdt",
    chainId: 1,
    pool: "0x3416cf6c708da44db2624d63ea0aaef7113527c6",
    base: "USDC",
    quote: "USDT",
    venue: venue(100),
  },
  {
    id: "eth-1-link-eth",
    chainId: 1,
    pool: "0xa6cc3c2531fdaa6ae1a3ca84c2855806728693e8",
    base: "LINK",
    quote: "ETH",
    venue: venue(3000),
  },

  // ── BNB Chain ──────────────────────────────────────────
  {
    id: "bsc-56-bnb-usdt",
    chainId: 56,
    pool: "0x47a90a2d92a8367a91efa1906bfc8c1e05bf10c4",
    base: "WBNB",
    quote: "USDT",
    venue: venue(100),
  },
  {
    id: "bsc-56-btcb-bnb",
    chainId: 56,
    pool: "0x28df0835942396b7a1b7ae1cd068728e6ddbbafd",
    base: "BTCB",
    quote: "WBNB",
    venue: venue(500),
  },
  {
    id: "bsc-56-eth-bnb",
    chainId: 56,
    pool: "0x0f338ec12d3f7c3d77a4b9fcc1f95f3fb6ad0ea6",
    base: "ETH",
    quote: "WBNB",
    venue: venue(500),
  },

  // ── Rootstock ──────────────────────────────────────────
  // Thin by mainnet standards: the ladder legitimately shows only a handful of
  // rungs, which is the point — it is what the pool actually holds.
  {
    id: "rsk-30-wrbtc-usd0",
    chainId: 30,
    pool: "0xaef6fabf3b0c9e5f9d6d5170afc703a633479bbd",
    base: "WRBTC",
    quote: "USD0",
    venue: venue(3000),
  },
  {
    id: "rsk-30-usdrif-usd0",
    chainId: 30,
    pool: "0xd845702af381f0405661747a6a20bde0401a19d6",
    base: "USDRIF",
    quote: "USD0",
    venue: venue(500),
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
