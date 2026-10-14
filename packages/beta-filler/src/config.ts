import { MAX_POOL_HOPS } from "@1delta-x/sdk";
import { getAddress, isAddress, type Address, type Hex } from "viem";

import { NORDSTERN_EXECUTOR_ROOTSTOCK, NORDSTERN_GUARD_ROOTSTOCK, type NordsternConfig } from "./nordstern";
import { SUSHI_RED_SNWAPPER_ROOTSTOCK, SUSHI_SNWAP_EXECUTOR_ROOTSTOCK, type SushiConfig } from "./sushi";
import type { IndexerConfig } from "./poolIndexers";

/** Rootstock mainnet addresses (chain 30). Verified on-chain — see the repo's MoC notes. */
export const ROOTSTOCK = {
  chainId: 30,
  rpcUrl: "https://public-node.rsk.co",
  usdrif: "0x3A15461d8aE0F0Fb5Fa2629e9DA7D66A794a6e37",
  usdt0: "0x779Ded0c9e1022225f8E0630b35a9b54bE713736",
  rif: "0x2AcC95758f8b5F583470ba265EB685a8F45fC9D5",
  mocCore: "0xA27024Ed70035E46dba712609fc2Afa1c97aA36A",
  mocQueue: "0x47f5014115d3bb29B20b5168Ee75050D6f8c3Bf1",
  /** Oku Uniswap v3 SwapRouter02 — `ExactInputSingleParams` has NO deadline field. */
  swapRouter: "0x0B14ff67f0014046b4b99057Aec4509640b3947A",
  quoterV2: "0xb51727c996C68E60F598A923a5006853cd2fEB31",
  /**
   * SushiSwap v3 QuoterV2 (factory 0x46B3…202e = the solver's pool venue 1). Found via
   * Blockscout (created by the factory's deployer 0x69ae…6327, 2024-05-21) and verified
   * by eth_call 2026-10-12: `factory()` = 0x46B3…202e; quoteExactInputSingle(WRBTC →
   * USD₮0, 0.001, fee 3000) = 82.965332 USD₮0 on pool 0x6d77…Fd71.
   */
  sushiV3Quoter: "0xE43ca1deE3f0fC1e2df73A0745674545f11A59f5",
  /** RIF/USDT0 0.3% pool fee tier. */
  rifUsdt0Fee: 3000,
  /** USDRIF/USDT0 0.05% pool fee tier (0xd845…19d6) — the RIF rail's refill leg. */
  usdrifUsdt0Fee: 500,
  wrbtc: "0x542fDA317318eBF1d3DEAf76E0b632741A7e677d",
  weth: "0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590",
  /** USDT 0xaf36… (ERC-2612) — pools vs WRBTC and RIF (2026-10-12). */
  usdt: "0xAf368c91793CB22739386DFCbBb2F1A9e4bCBeBf",
  /** USDC.e (Stargate, ERC-2612) — a 0.01 % pool vs USD₮0 (2026-10-12). */
  usdce: "0x74c9f2b00581F1B11AA7ff05aa9F608B7389De67",
  /** RIFPro (Money on Chain) — pools vs RIF on both venues (2026-10-12). */
  rifp: "0xf4d27c56595Ed59B66cC7F03CFF5193e4bd74a61",
  /** Money on Chain's DOC — a hub with live USD₮0 pools on both venues (verified 2026-10-12). */
  doc: "0xe700691dA7b9851F2F35f8b8182c69c53CcaD9Db",
  /** Multicall3 (canonical address; code verified on chain 30 2026-10-12). */
  multicall3: "0xcA11bde05977b3631167028862bE2a173976CA11",
} as const satisfies Record<string, string | number>;

/** Venue indices of the solver's pool allowlist as `DeployAggregatorFill.s.sol` deploys it on Rootstock (SDK `ROOTSTOCK_POOL_VENUES`). */
export const VENUE_OKU = 0;
export const VENUE_SUSHI_V3 = 1;

/**
 * The pools the route strategy quotes locally and swaps on DIRECTLY (a pool plan,
 * `RoutePlan.router = POOL_ROUTE`: the solver pays the pool in its swap callback — no
 * sandbox, no router). Venue 0 = the Uniswap v3 (Oku) pools of the app's Rootstock
 * markets (packages/app/src/config/markets.ts); venue 1 = SushiSwap v3's WRBTC/USD₮0
 * pool, quoted only while SUSHI_V3_QUOTER is set. Sushi's aggregated liquidity is
 * reached through the Sushi API source instead (`SUSHI_ENABLED`, pull orders only).
 */
export const ROOTSTOCK_POOLS: readonly RoutePool[] = [
  { market: "rsk-30-wrbtc-usd0", tokenA: ROOTSTOCK.wrbtc, tokenB: ROOTSTOCK.usdt0, fee: 3000, venue: VENUE_OKU, pool: "0xaef6fabf3b0c9e5f9d6d5170afc703a633479bbd" },
  { market: "rsk-30-weth-wrbtc", tokenA: ROOTSTOCK.weth, tokenB: ROOTSTOCK.wrbtc, fee: 3000, venue: VENUE_OKU, pool: "0x7717364fa619fc22a8f8eae124e79a1b9a2cf3e6" },
  { market: "rsk-30-usdrif-usd0", tokenA: ROOTSTOCK.usdrif, tokenB: ROOTSTOCK.usdt0, fee: 500, venue: VENUE_OKU, pool: "0xd845702af381f0405661747a6a20bde0401a19d6" },
  { tokenA: ROOTSTOCK.wrbtc, tokenB: ROOTSTOCK.usdt0, fee: 3000, venue: VENUE_SUSHI_V3, pool: "0x6d778c369cb386d50f4ee676c5c264374c52fd71" },
  // RIF markets (2026-10-12; getPool on both factories, the deepest tier each — ~$85k
  // Oku RIF/USD₮0 0.3 %, ~$35k Oku + ~$58k Sushi RIF/WRBTC 0.3 %).
  { market: "rsk-30-rif-usd0", tokenA: ROOTSTOCK.rif, tokenB: ROOTSTOCK.usdt0, fee: 3000, venue: VENUE_OKU, pool: "0x57079b2d3071eb06cce6dbafb9b0306bcc49b020" },
  { market: "rsk-30-rif-wrbtc", tokenA: ROOTSTOCK.rif, tokenB: ROOTSTOCK.wrbtc, fee: 3000, venue: VENUE_OKU, pool: "0xfba1ca3f3f5eafa65c2a535a54fe11f1c3a5f416" },
  { tokenA: ROOTSTOCK.rif, tokenB: ROOTSTOCK.wrbtc, fee: 3000, venue: VENUE_SUSHI_V3, pool: "0x7a110977b642b64ddde6c6d2d4d370ad48993a74" },
];

/**
 * SYNTHETIC app markets (docs/synthetic-pairs.md): pairs with no pool of their own,
 * quoted and filled as multi-hop routes. Listed only so `POST /quote` knows their
 * `marketId`; the route itself comes from ROOTSTOCK_PATHS / discovery.
 */
export const ROOTSTOCK_SYNTHETIC_MARKETS: readonly { market: string; base: Address; quote: Address }[] = [
  { market: "rsk-30-wrbtc-usdrif", base: ROOTSTOCK.wrbtc, quote: ROOTSTOCK.usdrif },
];

/**
 * Default multi-hop paths (swap order; each is usable in either direction).
 * USDRIF → USDT0 → WRBTC is what prices gas for a USDRIF-output fill; it also lets
 * the route strategy take a USDRIF↔WRBTC order should one appear.
 */
export const ROOTSTOCK_PATHS = `${ROOTSTOCK.usdrif}>500>${ROOTSTOCK.usdt0}>3000>${ROOTSTOCK.wrbtc}`;

/** One Uniswap-v3-style pool, by its two tokens, fee tier (hundredths of a bip) and venue. */
export interface RoutePool {
  market?: string;
  tokenA: Address | string;
  tokenB: Address | string;
  fee: number;
  /**
   * Index into the solver's pool-venue allowlist (`poolVenue(i)`): 0 = Uniswap v3
   * (Oku), 1 = SushiSwap v3 on Rootstock. Unset = 0. The pool is quoted on that
   * venue's QuoterV2 and swapped on the pool the solver derives for it.
   */
  venue?: number;
  pool?: string;
}

/**
 * A multi-hop path in swap order: `tokens[0] →fees[0]→ tokens[1] → …`. Each hop
 * swaps on its OWN venue (`venues[i]`, the solver encodes one per hop); a path whose
 * hops share one venue may instead (or also) carry `venue` — the pre-2026-10-12 shape.
 * Read it through `pathVenues` (./poolGraph.ts).
 */
export interface RoutePath {
  tokens: Address[];
  fees: number[];
  /** The venue every hop swaps on (see {@link RoutePool.venue}); unset = 0. Ignored when `venues` is set. */
  venue?: number;
  /** One venue per hop (mixed-venue paths). */
  venues?: number[];
}

/**
 * Automatic pool routing (./poolGraph.ts): discover the pools between the route
 * tokens and the hubs on every routable venue, enumerate multi-hop / mixed-venue
 * paths, and quote the best few.
 */
export interface DiscoveryConfig {
  /** `ROUTE_DISCOVERY` (default on). Off = only ROUTE_POOLS / ROUTE_PATHS, as before. */
  enabled: boolean;
  /** `ROUTE_FEE_TIERS` (default 100,500,3000,10000). */
  feeTiers: number[];
  /** `ROUTE_MIN_LIQUIDITY`: a pool's in-range `liquidity()` must reach this (default 1 = nonzero). */
  minLiquidity: bigint;
  /** `ROUTE_DISCOVERY_SECONDS` × 1000: re-read the graph this often (default 3600 s). */
  refreshMs: number;
  /**
   * `ROUTE_HUB_TOKENS`: the only tokens a path may pass THROUGH (never an order's
   * endpoints — those stay ROUTE_TOKENS). Rootstock default: WRBTC, USD₮0, RIF, DOC —
   * the tokens with liquid pools to more than one other token (2026-10-12).
   */
  hubTokens: Address[];
  /** `MULTICALL3` (Rootstock default: the canonical 0xcA11…CA11; "" = none: one `eth_call` per read). */
  multicall?: Address;
  /**
   * `ROUTE_DISCOVERY_SOURCE`: `rpc` (factory.getPool probe, the default) or `indexers`
   * (Oku API + Sushi subgraph, ./poolIndexers.ts — TVL-filtered, CREATE2-verified, and
   * the RPC probe as the fallback when an indexer fails).
   */
  source: "rpc" | "indexers";
  indexers: IndexerConfig;
}

/** The "route" strategy: fills through `AggregatorFillSolver.executeFill` from the operator EOA. */
export interface RouteConfig {
  /** The deployed, operator-gated AggregatorFillSolver (msg.sender to Settlement). */
  solver: Address;
  pools: RoutePool[];
  paths: RoutePath[];
  /**
   * The QuoterV2 of each pool venue, by venue index: `[0]` = QUOTER_V2 (Oku), `[1]` =
   * SUSHI_V3_QUOTER (unset = venue-1 pools and paths are never quoted, so never
   * routed). Start-up checks each quoter's `factory()` against the solver's
   * `poolVenue(i)` — a quote must price the very pool the plan swaps on.
   */
  venueQuoters: (Address | undefined)[];
  /** Haircut on the live quote before the profitability test, bps. */
  slippageBps: bigint;
  /**
   * The haircut for a stable pair (both tokens in {@link usdTokens}). The quote is
   * read on the block we simulate on and the plan's on-chain floor bounds the
   * output, so the haircut only buys protection against a move before inclusion —
   * which a $1/$1 pool barely has. A miss costs a revert's gas, never principal.
   */
  stableSlippageBps: bigint;
  /**
   * `eth_estimateGas` units assumed for an executeFill through the SANDBOX (an API
   * route) before the simulation's own estimate — the floor of the estimate the plan
   * is priced at: the sent plan is priced at max(this, simulated) × r (the learned
   * receipt ratio, gasRatio.ts) and sent with gas limit max(that, simulated × 1.25).
   * A pool plan assumes this − `SANDBOX_ROUTE_OVERHEAD_GAS` (route.ts `planGasEstimate`).
   */
  gasEstimate: bigint;
  /** Refuse any route fill whose priced gas limit exceeds this (gas units). */
  maxGas: bigint;
  /**
   * Route candidates must have BOTH tokens in this allowlist — with Sushi on, any
   * pair would otherwise pass classification (and cost an API call each sweep).
   */
  routeTokens: Address[];
  /** Extra profit required on top of gas, in RBTC wei (converted like the gas). */
  minProfitWei: bigint;
  /** Fallback RBTC price (USD, 18-dec fixed) when no pool path prices RBTC in the output token. */
  rbtcUsd?: bigint;
  /** Pool discovery and multi-hop enumeration (./poolGraph.ts). */
  discovery: DiscoveryConfig;
  /** `ROUTE_MAX_HOPS`: longest enumerated pool path (default 3, ≤ the solver's MAX_POOL_HOPS = 4). */
  maxHops: number;
  /** `ROUTE_MAX_CANDIDATES`: pool paths quoted per fill / quote, best estimated first (default 5). */
  maxCandidates: number;
  /** Tokens worth $1: the {@link rbtcUsd} fallback, and the pairs {@link stableSlippageBps} applies to. */
  usdTokens: Address[];
  /** RoutePlan.profitRecipient; zero = the operator EOA. */
  profitRecipient: Address;
  /** Rolling one-hour cap on the number of route fills (gas is capped by {@link Config.gas}). */
  hourlyFills: bigint;
  /** The Sushi API route source (pull orders only). */
  sushi: SushiConfig;
  /** The Nordstern API route source (pull orders only; ./nordstern.ts). */
  nordstern: NordsternConfig;
  /**
   * Whether the local pool plans (Oku and the other venues, `ROUTE_OKU_PULL`) compete
   * on PULL orders (default on). Off = API-only pull fills; the pools still price gas,
   * and DIRECT orders always use a pool plan (the only exact-output source).
   */
  okuPull: boolean;
}

export const USDRIF_DECIMALS = 18;
export const USDT0_DECIMALS = 6;
/** MoC charges 0.2% of the redeemed/minted amount (tpRedeemFees / tpMintFees = 2e15). */
export const MOC_FEE_BPS = 20n;

export interface Policy {
  /** Fill orders where a maker SELLS USDRIF for USDT0 (we pay USDT0, receive USDRIF). */
  buyUsdrif: boolean;
  /** Highest USDT0 we pay per USDRIF, 1e18-scaled. */
  maxBuyPrice: bigint;
  /**
   * Required edge (bps) of the live exit value — USDRIF redeemed at the MoC oracle
   * price, minus the MoC fee, then sold for USDT0 on the RIF pool — over what we pay.
   */
  minExitEdgeBps: bigint;
  /** Fill orders where a maker BUYS USDRIF with USDT0 (we deliver USDRIF from inventory). */
  sellUsdrif: boolean;
  /** Lowest USDT0 we accept per USDRIF delivered, 1e18-scaled. */
  minSellPrice: bigint;
  /** Largest single fill, in USDT0 units (6 dec) of notional. */
  maxFillUsdt0: bigint;
  /** Smallest fill worth the gas, in USDT0 units. */
  minFillUsdt0: bigint;
  /** `eth_estimateGas` units assumed for one inventory fill before it is estimated (priced × r, re-checked with the real estimate × r). */
  inventoryGasEstimate: bigint;
  /**
   * Gas units of the rebalance a fill eventually causes (redeem + RIF sale), charged
   * to each fill pro rata to its size over REDEEM_MIN_USDRIF (capped at the whole).
   */
  rebalanceGas: bigint;
  /** Absolute profit floor per inventory fill, USDT0 units, on top of gas. */
  minProfitUsdt0: bigint;
  /** Optional RBTC price (USD, 18 dec) — gas is priced at max(pool quote, this). */
  rbtcUsd?: bigint;
  /** Rolling one-hour outflow caps — the hot wallet's blast radius per hour. */
  hourlyUsdt0: bigint;
  hourlyUsdrif: bigint;
  /** Keep this much USDRIF (for sell-side fills); redeem everything above it. */
  usdrifReserve: bigint;
  /** Do not bother redeeming less than this. */
  redeemMin: bigint;
  /** qACmin tolerance below the oracle-implied RIF amount (bps, on top of the MoC fee). */
  redeemSlippageBps: bigint;
  /** Sell RIF once the wallet holds at least this much. */
  rifSellMin: bigint;
  /** Max discount of the pool quote vs. the MoC oracle value of the RIF (bps). Refuse worse. */
  rifSellMaxDiscountBps: bigint;
  /** Slippage tolerance on the quoted RIF→USDT0 swap (bps). */
  rifSellSlippageBps: bigint;
  /**
   * THE RIF RAIL (2026-10-14): fill orders where a maker BUYS RIF with USDT0 — we
   * deliver RIF from the wallet's float and price it at what replacing it costs
   * through MoC: USDT0 → USDRIF on the 0.05 % pool, then `redeemTP` at the oracle
   * (− the MoC fee). That beats the RIF pools on buys from ~$100 (rail probe).
   */
  sellRif: boolean;
  /**
   * …and orders where a maker SELLS RIF for USDT0: we pay USDT0 and keep the RIF. Valued
   * at its replacement cost while the wallet is below RIF_SHARE_TARGET_BPS (it saves a
   * refill), else at its MoC exit (mintTP at the oracle, USDRIF → USDT0 on the pool).
   */
  buyRif: boolean;
  /** Rolling one-hour RIF outflow cap (18 dec). */
  hourlyRif: bigint;
  /** Charged on the rail's MoC conversions (bps): the oracle can move while an async MoC op waits in the queue. */
  rifRailHaircutBps: bigint;
  /**
   * The RIF BAND, as a share of the wallet's value (USDT0 + USDRIF at $1 + RIF at the
   * MoC oracle; RBTC is gas, not counted), bps. RIF is volatile: the wallet holds a
   * minority of it. Below `low` the rebalancer buys RIF back to `target` (USDT0 →
   * USDRIF → redeemTP); above `high` it sells down to `target` (mintTP → USDRIF → USDT0);
   * between, user flow on both sides moves it. Buys from makers that would push the
   * share above `high` are refused.
   */
  rifShareLowBps: bigint;
  rifShareTargetBps: bigint;
  rifShareHighBps: bigint;
  /** USDT0 never spent by the rail (refills, RIF buys) — kept for the USDRIF buy side, 6 dec. */
  usdt0Reserve: bigint;
  /**
   * USDRIF the band collects before it acts on it (18 dec): a MoC op costs ~$2.4 (exec fee +
   * gas), so the USDRIF that USDRIF → RIF fills bring in is redeemed (below target) or
   * swapped out (above) in batches of at least this — or at once when RIF is below LOW.
   */
  railUsdrifBatch: bigint;
  /** Slippage tolerance on the rail's USDT0 ⇄ USDRIF pool swaps (bps). */
  railSwapSlippageBps: bigint;
  /** Refuse a rail swap whose pool price is more than this away from $1 per USDRIF (bps) — the peg guard. */
  usdrifPegToleranceBps: bigint;
}

export interface Config {
  chainId: number;
  rpcUrl: string;
  /** Per-request RPC timeout, ms (`RPC_TIMEOUT_MS`, default viem's 10 s; a lazily-forked anvil needs more). */
  rpcTimeoutMs: number;
  /**
   * Further RPC endpoints tried IN ORDER when the primary errors or times out
   * (`RPC_FALLBACK_URLS`, comma-separated; 2026-10-12: public-node.rsk.co went dark and
   * every quote waited 10–30 s for a 422).
   */
  rpcFallbackUrls: string[];
  /**
   * Merge concurrent `eth_call` reads into one Multicall3 `aggregate3` call (viem client
   * batching; `RPC_MULTICALL=1`). Reads with a sender (simulations, previews as the solver)
   * are never merged. Off in code (tests answer per-call), on in production.
   */
  rpcMulticall: boolean;
  /** Send-gas-price cache, ms (`GAS_PRICE_TTL_MS`, default 10 s; production ~one 30 s block). */
  gasPriceTtlMs: number;
  /** Where {@link rpcUrl} came from: the `RPC_URL_SECRET` secret wins over `RPC_URL`. */
  rpcSource: "RPC_URL_SECRET" | "RPC_URL" | "default";
  privateKey: Hex;
  settlement: Address;
  permit3: Address;
  lens: Address;
  orderbookUrl: string;
  tokens: { usdrif: Address; usdt0: Address; rif: Address };
  moc: { core: Address; queue: Address };
  uniswap: { router: Address; quoter: Address; rifUsdt0Fee: number; usdrifUsdt0Fee: number };
  /** Wrapped RBTC — the native-price anchor for gas costing. */
  wrbtc: Address;
  policy: Policy;
  /** Per-strategy switches. For an order both could fill, inventory goes first. */
  strategies: { inventory: boolean; route: boolean };
  /** Set when the route strategy is configured (AGGREGATOR_SOLVER). */
  route?: RouteConfig;
  /** When true (the default) nothing is broadcast: every decision is simulated and logged. */
  dryRun: boolean;
  /** Re-scan cadence for the book and the rebalancer, ms. */
  pollMs: number;
  /** Rolling-budget, gas and per-order backoff state survives restarts here. */
  stateFile: string;
  /** Gas policy shared by BOTH strategies (one hourly RBTC budget, one price ceiling). */
  gas: GasPolicy;
  /** How the engine walks the book (what it re-quotes, and when). */
  sweep: SweepPolicy;
  /** The public indicative quote endpoint (`POST /quote` on the Worker, ./quote.ts). */
  quote: QuotePolicy;
  /**
   * Gasless makers (`PERMIT_FILLS_ENABLED`, default on): a book order may carry the
   * maker's ERC-2612 permit (`erc2612Permit`, spender = Settlement) instead of an
   * on-chain approval. The route strategy passes it into `executeFill`'s `permits`, so
   * the solver runs `permit` and the fill in ONE tx (./permit.ts); the inventory
   * strategy (EOA `fillUpTo`) cannot carry it. Off: such orders wait until something
   * else funds them.
   */
  permitFills: boolean;
}

/**
 * Indicative quotes (./quote.ts, 2026-10-07): what the filler would pay for a market
 * ticket NOW — the best route (or inventory) output for the ticket's input, minus the
 * fill's gas, minus a margin on that gas. The app signs a short Dutch order that STARTS
 * at the quote and decays to the maker's own slippage floor.
 */
export interface QuotePolicy {
  /** Serve `POST /quote` at all (`QUOTE_ENABLED`, default on). */
  enabled: boolean;
  /** Margin on the fill's gas cost, bps of that cost (`QUOTE_GAS_MARGIN_BPS`, default 1000 = +10 %). */
  gasMarginBps: bigint;
  /** Optional extra price tolerance taken off the quoted output, bps of it (`QUOTE_TOLERANCE_BPS`, default 0). */
  toleranceBps: bigint;
  /** How long a quote is valid, seconds (`QUOTE_TTL_SECONDS`, default 30 = one Rootstock block). */
  ttlSeconds: number;
  /**
   * How long after `validUntil` an order may still be MATCHED to the quote it was
   * signed from (`QUOTE_MATCH_GRACE_SECONDS`, default 120): the wallet prompt and the
   * book post take time. A matched order is gated without the quote haircut.
   */
  matchGraceSeconds: number;
  /**
   * `eth_estimateGas` units a quote assumes for one fill before the filler has learned
   * an estimate for the shape (direct / pull route fills; the inventory path uses
   * INVENTORY_GAS_ESTIMATE). Then: the max of the learned estimates (gasRatio.ts).
   * Defaults = the top of the production e2e range (2026-10-07: direct 363k–385k,
   * pull 386k–404k), as the app's FILLER_FILL_GAS_ESTIMATE.
   */
  gasEstimateDirect: bigint;
  gasEstimatePull: bigint;
  /** Identical requests within this many ms reuse the priced result (fresh quote id). */
  cacheMs: number;
}

export interface SweepPolicy {
  /**
   * An order every strategy passed on (unprofitable, out of price, below minimum, a
   * shape no strategy takes) — or one we just FILLED — is not re-quoted for this long
   * unless the book reports a different `fillableAmount` for it. Each re-quote costs
   * a preview, quotes and gas reads: a book of 31 resting orders used to cost ~67 RPC
   * calls per tick. An order whose price moves with time (a decaying leg) is held at
   * most {@link AUCTION_RECHECK_MS} — and, within that, until the moment a strategy
   * predicts its gate passes (./recheck.ts), or the auction's floor.
   */
  restingRecheckMs: number;
  /** Orders expiring within this many seconds are skipped: a tx cannot land in time on ~30 s blocks. */
  expiryMarginS: number;
}

/**
 * Hold cap for an order whose price moves with time (any leg `end != 0`, a curve, a
 * gas bump or a priority auction).
 *
 * 30 s = one Rootstock block, i.e. about one re-quote per block — the meaningful
 * cadence, since every preview is an `eth_call` at `latest` and returns the same
 * answer until the next block lands. Considered and NOT done (2026-10-06): tying the
 * re-quote to block ARRIVAL instead. It would cut the phase lag (a hold placed late
 * in block N expires late in N+1 rather than at N+1's first tick), but it costs an
 * `eth_blockNumber` on every 5 s tick against the public node's rate limit, where a
 * held order costs zero RPC today, and the lag it saves is bounded by one block,
 * which the app's 300 s life and the e2e's `floor + hold + tick + landing` bound
 * already absorb. The step that DOES matter on a block clock — the end of an
 * exclusivity window — gets its own cap ({@link windowEndMs} in the engine).
 *
 * This is a CAP: an unprofitable decaying order is re-quoted sooner, at the second
 * its gate is predicted to pass from its own pricing ({@link profitableAt}, 2026-10-07).
 */
export const AUCTION_RECHECK_MS = 30_000;

export interface GasPolicy {
  /** Rolling one-hour cap on RBTC spent on fill gas, wei — inventory and route together. */
  hourlyWei: bigint;
  /** Never send a fill above this gas price, wei. */
  maxGasPriceWei: bigint;
  /** How long to wait for a receipt before treating the tx as pending, ms. */
  receiptTimeoutMs: number;
  /**
   * Every tx is sent (and every fill priced) at ⌈latestBlock.minimumGasPrice × this /
   * 10000⌉ (`GAS_PRICE_MIN_MULT_BPS`, ≥ 10000, default {@link DEFAULT_GAS_PRICE_MIN_MULT_BPS});
   * `eth_gasPrice` only when the block has no `minimumGasPrice` (see chain.ts `readSendGasPrice`).
   */
  minGasPriceMultBps: bigint;
  /**
   * receipt/estimate gas ratio, ppm, priced before any receipt of a fill shape
   * (`DEFAULT_GAS_RECEIPT_RATIO`, a decimal in [0.6, 1.0], default 0.88 — see gasRatio.ts).
   */
  defaultReceiptRatioPpm: bigint;
}

/**
 * Rootstock has no fee market: a block carries a miner-voted `minimumGasPrice`, and
 * `eth_gasPrice` answers min × 1.1 (rskj's default `rpc.minGasPriceMultiplier`). The
 * minimum may move at most ±1 % per block (RSKIP-09), so a tx at min × 1.03 stays
 * includable through TWO consecutive maximal rises after the block we read
 * (1.01² = 1.0201 < 1.03 < 1.01³) — enough when our read is a block stale (it is
 * cached ≤ 10 s; blocks are ~25–30 s) and the tx misses one block. 1.02 would hold
 * for exactly one rise (1.0201 > 1.02). Sources and the eviction behaviour: chain.ts
 * `readSendGasPrice`. The extra 1 % costs ~1 % of a ~$0.30 fill's gas.
 */
export const DEFAULT_GAS_PRICE_MIN_MULT_BPS = 10_300;

type Env = Record<string, string | undefined>;

function req(env: Env, key: string): string {
  const v = env[key];
  if (!v) throw new Error(`missing env ${key}`);
  return v;
}

function addr(env: Env, key: string, fallback?: string): Address {
  const v = env[key] ?? fallback;
  if (!v || !isAddress(v, { strict: false })) throw new Error(`env ${key} is not an address: ${v ?? "(unset)"}`);
  return getAddress(v);
}

/** Parse a decimal string ("0.995") into a fixed-point bigint with `decimals` places. */
export function parseFixed(value: string, decimals: number): bigint {
  const m = /^(\d+)(?:\.(\d+))?$/.exec(value.trim());
  if (!m) throw new Error(`not a non-negative decimal: ${value}`);
  const frac = (m[2] ?? "").padEnd(decimals, "0");
  if (frac.length > decimals) throw new Error(`too many decimals in ${value} (max ${decimals})`);
  return BigInt(m[1]!) * 10n ** BigInt(decimals) + BigInt(frac || "0");
}

function fixed(env: Env, key: string, fallback: string, decimals: number): bigint {
  return parseFixed(env[key] ?? fallback, decimals);
}

/** A non-negative integer env value (decimal digits only — "", "1.5", "0x10", "abc" are refused). */
function uint(env: Env, key: string, fallback: bigint | number): bigint {
  const raw = env[key];
  if (raw === undefined) return BigInt(fallback);
  const v = raw.trim();
  if (!/^\d+$/.test(v)) throw new Error(`env ${key} must be a non-negative integer: ${JSON.stringify(raw)}`);
  return BigInt(v);
}

/** A strictly positive integer env value. Fail closed: NaN, 0, negative and non-integers throw. */
function posInt(env: Env, key: string, fallback: bigint | number): bigint {
  const v = uint(env, key, fallback);
  if (v <= 0n) throw new Error(`env ${key} must be > 0`);
  return v;
}

/** {@link posInt} as a JS number (must stay a safe integer). */
function posNum(env: Env, key: string, fallback: number): number {
  const v = posInt(env, key, fallback);
  if (v > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error(`env ${key} is too large`);
  return Number(v);
}

/** A Uniswap v3 fee tier: an integer in (0, 2^24). */
export function parseFee(raw: string, what: string): number {
  const v = raw.trim();
  const f = /^\d+$/.test(v) ? Number(v) : NaN;
  if (!Number.isInteger(f) || f <= 0 || f >= 1 << 24) throw new Error(`${what}: bad fee ${JSON.stringify(raw)}`);
  return f;
}

function bps(env: Env, key: string, fallback: number): bigint {
  const v = uint(env, key, fallback);
  if (v > 10_000n) throw new Error(`env ${key} must be 0..10000 bps`);
  return v;
}

function addrList(env: Env, key: string, fallback: readonly string[]): Address[] {
  const raw = env[key];
  const items = raw === undefined ? [...fallback] : raw.split(",").map((t) => t.trim()).filter(Boolean);
  return items.map((t) => {
    if (!isAddress(t, { strict: false })) throw new Error(`env ${key}: not an address: ${t}`);
    return getAddress(t);
  });
}

function flag(env: Env, key: string, fallback: boolean): boolean {
  const v = env[key];
  if (v === undefined || v === "") return fallback;
  return v === "1" || v.toLowerCase() === "true";
}

/** A pool venue index (position in the solver's allowlist): an integer 0..255. */
export function parseVenue(raw: string, what: string): number {
  const v = raw.trim();
  const n = /^\d+$/.test(v) ? Number(v) : NaN;
  if (!Number.isInteger(n) || n < 0 || n > 255) throw new Error(`${what}: bad venue ${JSON.stringify(raw)} (want 0..255)`);
  return n;
}

/**
 * `ROUTE_PATHS`: `;`-separated paths, each `token>fee>token[>fee>token…]` in swap
 * order with an optional `@venue` suffix (every hop; default 0 = Oku), and/or a
 * per-hop `fee:venue` (mixed venues), e.g. `0xUSDRIF>500>0xUSDT0>3000>0xWRBTC`,
 * `0xWRBTC>3000>0xUSDT0@1` or `0xUSDRIF>500:0>0xUSDT0>3000:1>0xWRBTC`. Empty = none.
 */
export function parsePaths(raw: string): RoutePath[] {
  return raw
    .split(";")
    .map((p) => p.trim())
    .filter(Boolean)
    .map((entry) => {
      const at = entry.lastIndexOf("@");
      const p = at === -1 ? entry : entry.slice(0, at);
      const venue = at === -1 ? 0 : parseVenue(entry.slice(at + 1), "ROUTE_PATHS");
      const parts = p.split(">").map((x) => x.trim());
      if (parts.length < 3 || parts.length % 2 === 0) throw new Error(`ROUTE_PATHS: bad path ${p}`);
      if ((parts.length - 1) / 2 > MAX_POOL_HOPS) throw new Error(`ROUTE_PATHS: ${p} has more than ${MAX_POOL_HOPS} hops (the solver's pool-plan limit)`);
      const tokens: Address[] = [];
      const fees: number[] = [];
      const venues: number[] = [];
      parts.forEach((x, i) => {
        if (i % 2 === 0) {
          if (!isAddress(x, { strict: false })) throw new Error(`ROUTE_PATHS: not an address: ${x}`);
          tokens.push(getAddress(x));
        } else {
          const [f, v] = x.split(":");
          if (v !== undefined && at !== -1) throw new Error(`ROUTE_PATHS: ${p} mixes a per-hop venue with an @venue suffix`);
          fees.push(parseFee(f!, "ROUTE_PATHS"));
          venues.push(v === undefined ? venue : parseVenue(v, "ROUTE_PATHS"));
        }
      });
      const single = venues.every((v) => v === venues[0]);
      return single ? { tokens, fees, venue: venues[0]! } : { tokens, fees, venues };
    });
}

/**
 * `ROUTE_POOLS`: `;`-separated `tokenA/tokenB/fee[/venue]` entries (venue default 0 =
 * Oku, 1 = SushiSwap v3). Unset = {@link ROOTSTOCK_POOLS}.
 */
export function parsePools(raw: string): RoutePool[] {
  return raw
    .split(";")
    .map((p) => p.trim())
    .filter(Boolean)
    .map((p) => {
      const parts = p.split("/").map((x) => x.trim());
      const [a, b, f, v] = parts;
      if (parts.length > 4 || !a || !b || !f || !isAddress(a, { strict: false }) || !isAddress(b, { strict: false })) {
        throw new Error(`ROUTE_POOLS: bad pool ${p} (want tokenA/tokenB/fee[/venue])`);
      }
      return { tokenA: getAddress(a), tokenB: getAddress(b), fee: parseFee(f, "ROUTE_POOLS"), venue: v === undefined ? 0 : parseVenue(v, "ROUTE_POOLS") };
    });
}

/** An optional address env value: unset → `fallback`, `""` → none. */
function optAddr(env: Env, key: string, fallback: string | undefined): Address | undefined {
  const raw = env[key];
  if (raw === undefined) return fallback === undefined ? undefined : getAddress(fallback);
  if (raw.trim() === "") return undefined;
  return addr(env, key);
}

function loadRoute(env: Env): RouteConfig | undefined {
  if (!env.AGGREGATOR_SOLVER) return undefined;
  const rbtcUsd = env.RBTC_PRICE_USD ? parseFixed(env.RBTC_PRICE_USD, 18) : undefined;
  if (rbtcUsd === 0n) throw new Error("env RBTC_PRICE_USD must be > 0");
  const gasEstimate = posInt(env, "ROUTE_GAS_ESTIMATE", 320_000);
  const onRootstock = posNum(env, "CHAIN_ID", ROOTSTOCK.chainId) === ROOTSTOCK.chainId;
  const maxGas = posInt(env, "MAX_ROUTE_GAS", 1_200_000);
  if (gasEstimate > maxGas) throw new Error(`ROUTE_GAS_ESTIMATE ${gasEstimate} exceeds MAX_ROUTE_GAS ${maxGas}`);
  return {
    solver: addr(env, "AGGREGATOR_SOLVER"),
    pools: env.ROUTE_POOLS !== undefined ? parsePools(env.ROUTE_POOLS) : [...ROOTSTOCK_POOLS],
    paths: parsePaths(env.ROUTE_PATHS ?? ROOTSTOCK_PATHS),
    // Venue 0's quoter is the same QUOTER_V2 the rebalancer uses; venue 1 (SushiSwap v3)
    // defaults to Rootstock's Sushi QuoterV2 there and to none elsewhere.
    venueQuoters: [addr(env, "QUOTER_V2", ROOTSTOCK.quoterV2), optAddr(env, "SUSHI_V3_QUOTER", onRootstock ? ROOTSTOCK.sushiV3Quoter : undefined)],
    slippageBps: bps(env, "ROUTE_SLIPPAGE_BPS", 10),
    stableSlippageBps: bps(env, "ROUTE_STABLE_SLIPPAGE_BPS", 5),
    gasEstimate,
    maxGas,
    routeTokens: addrList(env, "ROUTE_TOKENS", [ROOTSTOCK.wrbtc, ROOTSTOCK.usdt0, ROOTSTOCK.weth, ROOTSTOCK.usdrif, ROOTSTOCK.rif, ROOTSTOCK.usdt, ROOTSTOCK.usdce, ROOTSTOCK.rifp]),
    minProfitWei: fixed(env, "MIN_PROFIT_RBTC", "0", 18),
    rbtcUsd,
    discovery: loadDiscovery(env, onRootstock),
    maxHops: rangeNum(env, "ROUTE_MAX_HOPS", 3, 1, MAX_POOL_HOPS),
    maxCandidates: rangeNum(env, "ROUTE_MAX_CANDIDATES", 5, 1, 32),
    usdTokens: (env.USD_TOKENS ? env.USD_TOKENS.split(",") : [ROOTSTOCK.usdt0, ROOTSTOCK.usdrif]).map((t) => getAddress(t.trim())),
    profitRecipient: addr(env, "ROUTE_PROFIT_RECIPIENT", "0x0000000000000000000000000000000000000000"),
    hourlyFills: uint(env, "ROUTE_HOURLY_FILLS", 60),
    okuPull: flag(env, "ROUTE_OKU_PULL", true),
    sushi: {
      enabled: flag(env, "SUSHI_ENABLED", true),
      baseUrl: env.SUSHI_API_URL ?? "https://api.sushi.com",
      router: addr(env, "SUSHI_ROUTER", SUSHI_RED_SNWAPPER_ROOTSTOCK),
      timeoutMs: posNum(env, "SUSHI_TIMEOUT_MS", 4_000),
      // Pinned by default on Rootstock (the executor every swap/v7 route named,
      // 2026-10); SUSHI_EXECUTORS = "" explicitly unpins (warned at start-up).
      executors: addrList(env, "SUSHI_EXECUTORS", onRootstock ? [SUSHI_SNWAP_EXECUTOR_ROOTSTOCK] : []),
      maxPerSweep: posNum(env, "SUSHI_MAX_PER_SWEEP", 10),
    },
    nordstern: {
      // OFF by default in code; the Worker's wrangler.toml turns it on for the beta.
      enabled: flag(env, "NORDSTERN_ENABLED", false),
      baseUrl: env.NORDSTERN_API_URL ?? "https://api.nordstern.finance",
      router: addr(env, "NORDSTERN_ROUTER", NORDSTERN_GUARD_ROOTSTOCK),
      // STRICT pin: an empty list accepts no route (the executor's source is unverified).
      executors: addrList(env, "NORDSTERN_EXECUTORS", onRootstock ? [NORDSTERN_EXECUTOR_ROOTSTOCK] : []),
      referer: env.NORDSTERN_REFERER || "https://1delta-x.pages.dev",
      timeoutMs: posNum(env, "NORDSTERN_TIMEOUT_MS", 3_000),
      maxPerSweep: posNum(env, "NORDSTERN_MAX_PER_SWEEP", 10),
      haircutBps: nordsternHaircut(env),
    },
  };
}

/** An integer env value in [min, max] (fail closed). */
function rangeNum(env: Env, key: string, fallback: number, min: number, max: number): number {
  const v = Number(uint(env, key, fallback));
  if (v < min || v > max) throw new Error(`env ${key} must be ${min}..${max}`);
  return v;
}

function loadDiscovery(env: Env, onRootstock: boolean): DiscoveryConfig {
  const fees = (env.ROUTE_FEE_TIERS ?? "100,500,3000,10000").split(",").map((x) => x.trim()).filter(Boolean).map((x) => parseFee(x, "ROUTE_FEE_TIERS"));
  if (fees.length === 0) throw new Error("env ROUTE_FEE_TIERS must name at least one fee tier");
  const hubDefault = onRootstock ? [ROOTSTOCK.wrbtc, ROOTSTOCK.usdt0, ROOTSTOCK.rif, ROOTSTOCK.doc] : [];
  return {
    enabled: flag(env, "ROUTE_DISCOVERY", true),
    feeTiers: [...new Set(fees)],
    minLiquidity: uint(env, "ROUTE_MIN_LIQUIDITY", 1),
    refreshMs: 1000 * posNum(env, "ROUTE_DISCOVERY_SECONDS", 3600),
    hubTokens: addrList(env, "ROUTE_HUB_TOKENS", hubDefault),
    multicall: optAddr(env, "MULTICALL3", onRootstock ? ROOTSTOCK.multicall3 : undefined),
    source: env.ROUTE_DISCOVERY_SOURCE === "indexers" ? "indexers" : "rpc",
    indexers: {
      okuBase: env.OKU_API_BASE ?? "https://omni.icarus.tools",
      okuChain: env.OKU_CHAIN ?? (onRootstock ? "rootstock" : ""),
      sushiSubgraph:
        env.SUSHI_V3_SUBGRAPH ?? (onRootstock ? "https://api.goldsky.com/api/public/project_clslspm3c0knv01wvgfb2fqyq/subgraphs/sushiswap/v3-rootstock-3/gn" : ""),
      minTvlUsd: Number(env.ROUTE_MIN_TVL_USD ?? "1000"),
      timeoutMs: posNum(env, "INDEXER_TIMEOUT_MS", 6000),
    },
  };
}

/** NORDSTERN_HAIRCUT_BPS: 0..1000 (default 2) — a haircut above 10 % is a typo, not a policy. */
function nordsternHaircut(env: Env): bigint {
  const v = bps(env, "NORDSTERN_HAIRCUT_BPS", 2);
  if (v > 1_000n) throw new Error("env NORDSTERN_HAIRCUT_BPS must be 0..1000");
  return v;
}

function loadQuote(env: Env): QuotePolicy {
  const gasMarginBps = uint(env, "QUOTE_GAS_MARGIN_BPS", 1_000);
  // 0..100000 bps: up to +1000 % on the gas (a 10× cushion is a typo-sized ceiling).
  if (gasMarginBps > 100_000n) throw new Error("env QUOTE_GAS_MARGIN_BPS must be 0..100000");
  const ttlSeconds = posNum(env, "QUOTE_TTL_SECONDS", 30);
  if (ttlSeconds > 600) throw new Error("env QUOTE_TTL_SECONDS must be 1..600");
  return {
    enabled: flag(env, "QUOTE_ENABLED", true),
    gasMarginBps,
    toleranceBps: bps(env, "QUOTE_TOLERANCE_BPS", 0),
    ttlSeconds,
    matchGraceSeconds: Number(uint(env, "QUOTE_MATCH_GRACE_SECONDS", 120)),
    gasEstimateDirect: posInt(env, "QUOTE_GAS_ESTIMATE_DIRECT", 360_000),
    gasEstimatePull: posInt(env, "QUOTE_GAS_ESTIMATE_PULL", 380_000),
    cacheMs: Number(uint(env, "QUOTE_CACHE_MS", 5_000)),
  };
}

function loadGas(env: Env): GasPolicy {
  // HOURLY_GAS_RBTC covers both strategies; ROUTE_HOURLY_GAS_RBTC is its pre-2026-10 name.
  const hourly = env.HOURLY_GAS_RBTC ?? env.ROUTE_HOURLY_GAS_RBTC ?? "0.002";
  const maxGasPriceWei = fixed(env, "MAX_GAS_PRICE_GWEI", "0.1", 9);
  if (maxGasPriceWei === 0n) throw new Error("env MAX_GAS_PRICE_GWEI must be > 0");
  const minGasPriceMultBps = uint(env, "GAS_PRICE_MIN_MULT_BPS", DEFAULT_GAS_PRICE_MIN_MULT_BPS);
  // Below 10000 the tx would be under the block minimum (never mined); above 2× it is a typo.
  if (minGasPriceMultBps < 10_000n || minGasPriceMultBps > 20_000n) throw new Error("env GAS_PRICE_MIN_MULT_BPS must be 10000..20000");
  const defaultReceiptRatioPpm = fixed(env, "DEFAULT_GAS_RECEIPT_RATIO", "0.88", 6);
  if (defaultReceiptRatioPpm < 600_000n || defaultReceiptRatioPpm > 1_000_000n) throw new Error("env DEFAULT_GAS_RECEIPT_RATIO must be 0.6..1.0");
  return {
    hourlyWei: parseFixed(hourly, 18),
    maxGasPriceWei,
    receiptTimeoutMs: posNum(env, "RECEIPT_TIMEOUT_MS", 120_000),
    minGasPriceMultBps,
    defaultReceiptRatioPpm,
  };
}

export function loadConfig(env: Env): Config {
  const privateKey = req(env, "PRIVATE_KEY");
  if (!/^0x[0-9a-fA-F]{64}$/.test(privateKey)) throw new Error("PRIVATE_KEY must be a 0x-prefixed 32-byte hex key");
  const policy: Policy = {
    buyUsdrif: flag(env, "BUY_USDRIF", true),
    maxBuyPrice: fixed(env, "MAX_BUY_PRICE", "0.995", 18),
    minExitEdgeBps: bps(env, "MIN_EXIT_EDGE_BPS", 30),
    sellUsdrif: flag(env, "SELL_USDRIF", false),
    minSellPrice: fixed(env, "MIN_SELL_PRICE", "1.003", 18),
    maxFillUsdt0: fixed(env, "MAX_FILL_USDT0", "500", USDT0_DECIMALS),
    minFillUsdt0: fixed(env, "MIN_FILL_USDT0", "5", USDT0_DECIMALS),
    inventoryGasEstimate: posInt(env, "INVENTORY_GAS_ESTIMATE", 260_000),
    rebalanceGas: posInt(env, "REBALANCE_GAS", 450_000),
    minProfitUsdt0: fixed(env, "INVENTORY_MIN_PROFIT_USDT0", "0.02", USDT0_DECIMALS),
    ...(env.RBTC_PRICE_USD ? { rbtcUsd: parseFixed(env.RBTC_PRICE_USD, 18) } : {}),
    hourlyUsdt0: fixed(env, "HOURLY_USDT0", "2000", USDT0_DECIMALS),
    hourlyUsdrif: fixed(env, "HOURLY_USDRIF", "2000", USDRIF_DECIMALS),
    usdrifReserve: fixed(env, "USDRIF_RESERVE", "0", USDRIF_DECIMALS),
    redeemMin: fixed(env, "REDEEM_MIN_USDRIF", "1000", USDRIF_DECIMALS),
    redeemSlippageBps: bps(env, "REDEEM_SLIPPAGE_BPS", 50),
    rifSellMin: fixed(env, "RIF_SELL_MIN", "200", 18),
    rifSellMaxDiscountBps: bps(env, "RIF_SELL_MAX_DISCOUNT_BPS", 150),
    rifSellSlippageBps: bps(env, "RIF_SELL_SLIPPAGE_BPS", 50),
    sellRif: flag(env, "SELL_RIF", false),
    hourlyRif: fixed(env, "HOURLY_RIF", "20000", 18),
    rifRailHaircutBps: bps(env, "RIF_RAIL_HAIRCUT_BPS", 20),
    buyRif: flag(env, "BUY_RIF", false),
    rifShareLowBps: bps(env, "RIF_SHARE_LOW_BPS", 1500),
    rifShareTargetBps: bps(env, "RIF_SHARE_TARGET_BPS", 2000),
    rifShareHighBps: bps(env, "RIF_SHARE_HIGH_BPS", 2500),
    usdt0Reserve: fixed(env, "USDT0_RESERVE", "0", USDT0_DECIMALS),
    railSwapSlippageBps: bps(env, "RAIL_SWAP_SLIPPAGE_BPS", 30),
    railUsdrifBatch: fixed(env, "RAIL_USDRIF_BATCH", "100", USDRIF_DECIMALS),
    usdrifPegToleranceBps: bps(env, "USDRIF_PEG_TOLERANCE_BPS", 50),
  };
  if (!(policy.rifShareLowBps <= policy.rifShareTargetBps && policy.rifShareTargetBps <= policy.rifShareHighBps && policy.rifShareHighBps <= 10_000n)) {
    throw new Error("RIF_SHARE_LOW_BPS ≤ RIF_SHARE_TARGET_BPS ≤ RIF_SHARE_HIGH_BPS ≤ 10000");
  }
  if (policy.buyUsdrif && policy.maxBuyPrice >= 10n ** 18n) {
    throw new Error("MAX_BUY_PRICE must be below 1.0: redemption returns $1 of RIF minus the MoC fee");
  }
  const route = loadRoute(env);
  const strategies = {
    inventory: flag(env, "INVENTORY_ENABLED", true),
    route: flag(env, "ROUTE_ENABLED", route !== undefined),
  };
  if (strategies.route && !route) throw new Error("ROUTE_ENABLED=1 needs AGGREGATOR_SOLVER");
  if (!strategies.inventory && !strategies.route) throw new Error("both strategies are disabled");
  // A keyed RPC goes in the RPC_URL_SECRET secret (the Worker: a var and a secret
  // cannot share a name, so the public-node RPC_URL var line can stay).
  const rpcSecret = env.RPC_URL_SECRET?.trim();
  const rpcVar = env.RPC_URL?.trim();
  return {
    chainId: posNum(env, "CHAIN_ID", ROOTSTOCK.chainId),
    rpcUrl: rpcSecret || rpcVar || ROOTSTOCK.rpcUrl,
    rpcTimeoutMs: posNum(env, "RPC_TIMEOUT_MS", 10_000),
    rpcMulticall: (env.RPC_MULTICALL ?? "") === "1",
    gasPriceTtlMs: posNum(env, "GAS_PRICE_TTL_MS", 10_000),
    // RPC_FALLBACK_URLS_SECRET (a keyed endpoint, never in a committed file) goes first.
    rpcFallbackUrls: [env.RPC_FALLBACK_URLS_SECRET ?? "", env.RPC_FALLBACK_URLS ?? ""]
      .join(",")
      .split(",")
      .map((u) => u.trim())
      .filter((u) => /^https?:\/\//.test(u)),
    rpcSource: rpcSecret ? "RPC_URL_SECRET" : rpcVar ? "RPC_URL" : "default",
    privateKey: privateKey as Hex,
    settlement: addr(env, "SETTLEMENT"),
    permit3: addr(env, "PERMIT3"),
    lens: addr(env, "LENS"),
    orderbookUrl: req(env, "ORDERBOOK_URL").replace(/\/$/, ""),
    tokens: {
      usdrif: addr(env, "USDRIF", ROOTSTOCK.usdrif),
      usdt0: addr(env, "USDT0", ROOTSTOCK.usdt0),
      rif: addr(env, "RIF", ROOTSTOCK.rif),
    },
    moc: { core: addr(env, "MOC_CORE", ROOTSTOCK.mocCore), queue: addr(env, "MOC_QUEUE", ROOTSTOCK.mocQueue) },
    uniswap: {
      router: addr(env, "SWAP_ROUTER", ROOTSTOCK.swapRouter),
      quoter: addr(env, "QUOTER_V2", ROOTSTOCK.quoterV2),
      rifUsdt0Fee: parseFee(env.RIF_USDT0_FEE ?? String(ROOTSTOCK.rifUsdt0Fee), "RIF_USDT0_FEE"),
      usdrifUsdt0Fee: parseFee(env.USDRIF_USDT0_FEE ?? String(ROOTSTOCK.usdrifUsdt0Fee), "USDRIF_USDT0_FEE"),
    },
    wrbtc: addr(env, "WRBTC", ROOTSTOCK.wrbtc),
    policy,
    strategies,
    route,
    // Fail safe: only an explicit DRY_RUN=0 broadcasts.
    dryRun: !(env.DRY_RUN === "0" || env.DRY_RUN?.toLowerCase() === "false"),
    pollMs: posNum(env, "POLL_MS", 15_000),
    stateFile: env.STATE_FILE || ".beta-filler-state.json",
    gas: loadGas(env),
    quote: loadQuote(env),
    sweep: {
      restingRecheckMs: 1000 * Number(uint(env, "RESTING_RECHECK_SECONDS", 300)),
      expiryMarginS: Number(uint(env, "EXPIRY_MARGIN_SECONDS", 90)),
    },
    permitFills: flag(env, "PERMIT_FILLS_ENABLED", true),
  };
}
