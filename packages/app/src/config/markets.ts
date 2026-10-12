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

/** One leg of a SYNTHETIC market's route: a pool pair, in its own orientation. */
export interface MarketHop {
  /** Pinned symbols (TOKENS) of the hop's pair; the route visits them in either order. */
  base: string;
  quote: string;
  pools: PoolRef[];
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
  /**
   * SYNTHETIC market (docs/synthetic-pairs.md): no pool holds this pair, so the book
   * is composed from these hops, ordered base → quote (lib/synthetic). `pools` is then
   * every hop's pools, flattened, so venue loading / status / legend work unchanged.
   */
  via?: MarketHop[];
}

/** Whether a market's book is composed from hops rather than read from its own pools. */
export function isSynthetic(market: Market): market is Market & { via: MarketHop[] } {
  return !!market.via && market.via.length > 0;
}

/** The hop a pool belongs to on a synthetic market. */
export function hopOfPool(market: Market, pool: string): MarketHop | undefined {
  const p = pool.toLowerCase();
  return market.via?.find((h) => h.pools.some((r) => r.address.toLowerCase() === p));
}

/** The hub tokens a synthetic market's route passes through, in order. */
export function hubsOf(market: Market): string[] {
  if (!isSynthetic(market)) return [];
  const out: string[] = [];
  let cur = market.base;
  for (const h of market.via.slice(0, -1)) {
    cur = cur === h.base ? h.quote : h.base;
    out.push(cur);
  }
  return out;
}

/** A synthetic market from its hops: `pools` is derived, so the two cannot drift. */
function synthetic(m: Omit<Market, "pools"> & { via: MarketHop[] }): Market {
  return { ...m, pools: m.via.flatMap((h) => h.pools) };
}

const DEX_LABEL: Record<Dex, string> = { "uniswap-v3": "Uni v3", "sushiswap-v3": "Sushi v3" };

/** "Uni v3 0.05% · Sushi v3 0.30%" — what the picker shows under the pair. */
export function venueLabel(market: Market): string {
  const pools = (ps: PoolRef[]) => ps.map((p) => `${DEX_LABEL[p.dex]} ${(p.feeBps / 10_000).toFixed(2)}%`);
  if (market.via?.length) return `via ${hubsOf(market).join(" → ")} · ${market.via.map((h) => pools(h.pools).join(" + ")).join(" → ")}`;
  return pools(market.pools).join(" · ");
}

/** The pool whose metadata defines the pair. */
export function primaryPool(market: Market): PoolRef {
  return market.pools[0]!;
}

/** A token's identity, pinned. */
export interface PinnedToken {
  address: `0x${string}`;
  decimals: number;
}

/**
 * Token address and decimals, PINNED per chain under the config symbol.
 *
 * These are the values that go into the EIP-712 order a maker signs — the
 * receive-token address and the scale its floor is written in — so they are
 * configuration, read once from the pools' own `token0()/token1()/decimals()`
 * on-chain, and never taken from an indexer response or a token list at
 * runtime (audit G-TS_SIGN-1). Indexers still supply logos and depth; when one
 * reports a pool whose tokens disagree with these pins the market is refused
 * (see `assertPoolTokens`), so a poisoned feed can blank the book but cannot
 * change what is signed.
 */
export const TOKENS: Record<number, Record<string, PinnedToken>> = {
  1: {
    ETH: { address: "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2", decimals: 18 },
    USDC: { address: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", decimals: 6 },
    USDT: { address: "0xdac17f958d2ee523a2206206994597c13d831ec7", decimals: 6 },
    WBTC: { address: "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599", decimals: 8 },
    LINK: { address: "0x514910771af9ca656af840dff83e8264ecf986ca", decimals: 18 },
  },
  56: {
    WBNB: { address: "0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c", decimals: 18 },
    USDT: { address: "0x55d398326f99059ff775485246999027b3197955", decimals: 18 },
    BTCB: { address: "0x7130d2a12b9bcbfae4f2634d864a1ee1ce3ead9c", decimals: 18 },
    ETH: { address: "0x2170ed0880ac9a755fd29b2688956bd959f933f8", decimals: 18 },
  },
  30: {
    WRBTC: { address: "0x542fda317318ebf1d3deaf76e0b632741a7e677d", decimals: 18 },
    USD0: { address: "0x779ded0c9e1022225f8e0630b35a9b54be713736", decimals: 6 },
    WETH: { address: "0x2f6f07cdcf3588944bf4c42ac74ff24bf56e7590", decimals: 18 },
    USDRIF: { address: "0x3a15461d8ae0f0fb5fa2629e9da7d66a794a6e37", decimals: 18 },
    // RIF (ERC-677, no ERC-2612 permit) — decimals() = 18, read on-chain 2026-10-12.
    RIF: { address: "0x2acc95758f8b5f583470ba265eb685a8f45fc9d5", decimals: 18 },
    // 2026-10-12, decimals() read on-chain. USDT 0xaf36… and USDC.e (Stargate) carry an
    // ERC-2612 permit (docs/gasless-permit-relay.md); RIFPro (Money on Chain) does not.
    USDT: { address: "0xaf368c91793cb22739386dfcbbb2f1a9e4bcbebf", decimals: 6 },
    "USDC.e": { address: "0x74c9f2b00581f1b11aa7ff05aa9f608b7389de67", decimals: 6 },
    RIFP: { address: "0xf4d27c56595ed59b66cc7f03cff5193e4bd74a61", decimals: 18 },
  },
};

/**
 * The chain's wrapped native coin, by config symbol, where the app AUTO-WRAPS it:
 * a ticket selling it may be funded from the native coin (WRBTC ← RBTC). Only
 * Rootstock: WRBTC 0x542f… is a verified WETH9 port (`deposit()` payable,
 * `withdraw(uint)`, `Deposit`/`Withdrawal` events), checked on-chain 2026-10-11.
 */
export const WRAPPED_NATIVE: Record<number, string> = { 30: "WRBTC" };

/** The auto-wrapped symbol on a chain, or undefined. */
export function wrappedNativeSymbol(chainId: number): string | undefined {
  return WRAPPED_NATIVE[chainId];
}

/** The config symbol of a pinned token address on a chain (display), else a short address. */
export function symbolOfAddress(chainId: number, address: string): string {
  const a = address.toLowerCase();
  for (const [sym, t] of Object.entries(TOKENS[chainId] ?? {})) if (t.address === a) return sym;
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

/** The pinned token behind a config symbol on a chain, or `undefined` if none is configured. */
export function pinnedToken(chainId: number, symbol: string): PinnedToken | undefined {
  return TOKENS[chainId]?.[symbol];
}

/**
 * Throw unless an indexer-reported pool holds exactly the market's pinned pair.
 * Compared by ADDRESS, never by symbol: symbols are display strings an indexer
 * is free to report however it likes.
 */
export function assertPoolTokens(
  market: Market,
  pool: string,
  token0: string,
  token1: string,
): { baseIsToken0: boolean } {
  const base = pinnedToken(market.chainId, market.base);
  const quote = pinnedToken(market.chainId, market.quote);
  if (!base || !quote) throw new Error(`market ${market.id} has no pinned tokens`);
  const t0 = token0.toLowerCase();
  const t1 = token1.toLowerCase();
  if (t0 === base.address && t1 === quote.address) return { baseIsToken0: true };
  if (t1 === base.address && t0 === quote.address) return { baseIsToken0: false };
  throw new Error(
    `pool ${pool} reported ${token0}/${token1}, which is not the pinned ${market.base}/${market.quote} pair — refusing it`,
  );
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
  // RIF markets (2026-10-12): the deepest tier on each factory — Oku RIF/USD₮0 0.3 %
  // (~$85k), RIF/WRBTC 0.3 % on Oku (~$35k) and Sushi v3 (~$58k). Other tiers hold dust.
  {
    id: "rsk-30-rif-usd0",
    chainId: 30,
    pools: [{ dex: "uniswap-v3", address: "0x57079b2d3071eb06cce6dbafb9b0306bcc49b020", feeBps: 3000 }],
    base: "RIF",
    quote: "USD0",
  },
  {
    id: "rsk-30-rif-wrbtc",
    chainId: 30,
    pools: [
      { dex: "uniswap-v3", address: "0xfba1ca3f3f5eafa65c2a535a54fe11f1c3a5f416", feeBps: 3000 },
      { dex: "sushiswap-v3", address: "0x7a110977b642b64ddde6c6d2d4d370ad48993a74", feeBps: 3000 },
    ],
    base: "RIF",
    quote: "WRBTC",
  },
  // Permit-token and RIFPro markets (2026-10-12): getPool on both factories, token0/
  // token1/fee read back, the deepest tier each. USDT/WRBTC ~$70k, RIF/USDT ~$128k,
  // USDC.e/USD₮0 0.01 % ~$197k, RIFP/RIF ~$90k (Uni) + Sushi.
  {
    id: "rsk-30-usdt-wrbtc",
    chainId: 30,
    pools: [{ dex: "uniswap-v3", address: "0xe54d5c25aad95cda8979ee502d4f3d70892444d1", feeBps: 3000 }],
    base: "WRBTC",
    quote: "USDT",
  },
  {
    id: "rsk-30-rif-usdt",
    chainId: 30,
    pools: [{ dex: "uniswap-v3", address: "0xa89a86d3d9481a741833208676fa57d0f1d5c6cb", feeBps: 3000 }],
    base: "RIF",
    quote: "USDT",
  },
  {
    id: "rsk-30-usdc.e-usd0",
    chainId: 30,
    pools: [{ dex: "uniswap-v3", address: "0xbbb5bc594f1551a0ea0758a99cf721951f280f5a", feeBps: 100 }],
    base: "USDC.e",
    quote: "USD0",
  },
  {
    id: "rsk-30-rifp-rif",
    chainId: 30,
    pools: [
      { dex: "uniswap-v3", address: "0x42c4fa60bcfe42019264def97a75c77f319e2c46", feeBps: 3000 },
      { dex: "sushiswap-v3", address: "0x64e6fdd9f86cc2d8c25908eda4c6f1468a4301c3", feeBps: 3000 },
    ],
    base: "RIFP",
    quote: "RIF",
  },
];

// ── DERIVED markets: any token pair the user picks (docs/synthetic-pairs.md) ──────
//
// The configured MARKETS are the POOLS. A pair the user picks that no pool holds is
// derived on demand as a synthetic market over ONE hub — base → hub → quote, both
// hops configured markets — so its book is composed from them (lib/synthetic).
// Derived markets are cached (stable identity: the book hook keys on the object).

/** Market id prefix per chain (`rsk-30-…`). */
const CHAIN_PREFIX: Record<number, string> = { 1: "eth-1", 56: "bsc-56", 30: "rsk-30" };
/** Hubs tried in order when a pair has no pool of its own. */
const HUBS: Record<number, string[]> = { 30: ["USD0", "WRBTC", "RIF"], 1: ["ETH", "USDC"], 56: ["WBNB", "USDT"] };
/** Which side quotes a derived pair: the first of these the pair holds is the QUOTE. */
const QUOTE_RANK: Record<number, string[]> = {
  30: ["USD0", "USDT", "USDC.e", "USDRIF", "WRBTC", "RIF", "WETH"],
  1: ["USDC", "USDT", "ETH", "WBTC"],
  56: ["USDT", "WBNB", "BTCB", "ETH"],
};

const derived = new Map<string, Market | null>();

function directFor(chainId: number, a: string, b: string): Market | undefined {
  return MARKETS.find((m) => m.chainId === chainId && ((m.base === a && m.quote === b) || (m.base === b && m.quote === a)));
}

/** [base, quote] of a derived pair. */
function orient(chainId: number, a: string, b: string): [string, string] {
  const rank = QUOTE_RANK[chainId] ?? [];
  const ra = rank.indexOf(a);
  const rb = rank.indexOf(b);
  if (ra === -1 && rb === -1) return [a, b];
  if (ra === -1) return [a, b];
  if (rb === -1) return [b, a];
  return ra < rb ? [b, a] : [a, b];
}

/** The synthetic market for a pair with no pool, via the first hub that connects it; undefined when none does. */
export function derivedMarket(chainId: number, a: string, b: string): Market | undefined {
  if (a === b || !pinnedToken(chainId, a) || !pinnedToken(chainId, b) || !CHAIN_PREFIX[chainId]) return undefined;
  const [base, quote] = orient(chainId, a, b);
  const id = `${CHAIN_PREFIX[chainId]}-${base.toLowerCase()}-${quote.toLowerCase()}`;
  if (derived.has(id)) return derived.get(id) ?? undefined;
  let out: Market | null = null;
  for (const hub of HUBS[chainId] ?? []) {
    if (hub === base || hub === quote) continue;
    const m1 = directFor(chainId, base, hub);
    const m2 = directFor(chainId, hub, quote);
    if (!m1 || !m2) continue;
    out = synthetic({
      id,
      chainId,
      base,
      quote,
      via: [
        { base: m1.base, quote: m1.quote, pools: m1.pools },
        { base: m2.base, quote: m2.quote, pools: m2.pools },
      ],
    });
    break;
  }
  derived.set(id, out);
  return out ?? undefined;
}

/** A derived market back from its id (a restored order names one). */
function derivedById(id: string): Market | undefined {
  for (const [chainIdStr, prefix] of Object.entries(CHAIN_PREFIX)) {
    if (!id.startsWith(`${prefix}-`)) continue;
    const chainId = Number(chainIdStr);
    const rest = id.slice(prefix.length + 1);
    const syms = Object.keys(TOKENS[chainId] ?? {});
    for (const x of syms) {
      for (const y of syms) {
        if (`${x.toLowerCase()}-${y.toLowerCase()}` !== rest) continue;
        const m = derivedMarket(chainId, x, y);
        if (m && m.id === id) return m;
      }
    }
  }
  return undefined;
}

export function marketById(id: string): Market {
  const m = MARKETS.find((x) => x.id === id) ?? derivedById(id);
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

/** Every token `symbol` can trade against: a pool of its own, or a derived route via a hub. */
export function pairsWith(chainId: number, symbol: string): string[] {
  return symbolsOn(chainId).filter((other) => other !== symbol && marketFor(chainId, symbol, other) !== undefined);
}

/** The market for `a` against `b`: the configured pool market, else a derived synthetic one. */
export function marketFor(chainId: number, a: string, b: string): Market | undefined {
  return directFor(chainId, a, b) ?? derivedMarket(chainId, a, b);
}
