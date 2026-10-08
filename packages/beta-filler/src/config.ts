import { getAddress, isAddress, type Address, type Hex } from "viem";

import { SUSHI_RED_SNWAPPER_ROOTSTOCK, type SushiConfig } from "./sushi";

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
  /** RIF/USDT0 0.3% pool fee tier. */
  rifUsdt0Fee: 3000,
  wrbtc: "0x542fDA317318eBF1d3DEAf76E0b632741A7e677d",
  weth: "0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590",
} as const satisfies Record<string, string | number>;

/**
 * The Uniswap v3 (Oku) pools of the app's Rootstock markets
 * (packages/app/src/config/markets.ts) — the ones SwapRouter02 can route locally.
 * Sushi liquidity (and Sushi's own view of these pools) is reached through the
 * Sushi API source instead (`SUSHI_ENABLED`, pull orders only) — the solver has no
 * router allowlist, so no redeploy is needed for it.
 */
export const ROOTSTOCK_POOLS: readonly RoutePool[] = [
  { market: "rsk-30-wrbtc-usd0", tokenA: ROOTSTOCK.wrbtc, tokenB: ROOTSTOCK.usdt0, fee: 3000, pool: "0xaef6fabf3b0c9e5f9d6d5170afc703a633479bbd" },
  { market: "rsk-30-weth-wrbtc", tokenA: ROOTSTOCK.weth, tokenB: ROOTSTOCK.wrbtc, fee: 3000, pool: "0x7717364fa619fc22a8f8eae124e79a1b9a2cf3e6" },
  { market: "rsk-30-usdrif-usd0", tokenA: ROOTSTOCK.usdrif, tokenB: ROOTSTOCK.usdt0, fee: 500, pool: "0xd845702af381f0405661747a6a20bde0401a19d6" },
];

/**
 * Default multi-hop paths (swap order; each is usable in either direction).
 * USDRIF → USDT0 → WRBTC is what prices gas for a USDRIF-output fill; it also lets
 * the route strategy take a USDRIF↔WRBTC order should one appear.
 */
export const ROOTSTOCK_PATHS = `${ROOTSTOCK.usdrif}>500>${ROOTSTOCK.usdt0}>3000>${ROOTSTOCK.wrbtc}`;

/** One Uniswap v3 pool, by its two tokens and fee tier (hundredths of a bip). */
export interface RoutePool {
  market?: string;
  tokenA: Address | string;
  tokenB: Address | string;
  fee: number;
  pool?: string;
}

/** A multi-hop path in swap order: `tokens[0] →fees[0]→ tokens[1] → …`. */
export interface RoutePath {
  tokens: Address[];
  fees: number[];
}

/** The "route" strategy: fills through `AggregatorFillSolver.executeFill` from the operator EOA. */
export interface RouteConfig {
  /** The deployed, operator-gated AggregatorFillSolver (msg.sender to Settlement). */
  solver: Address;
  pools: RoutePool[];
  paths: RoutePath[];
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
   * `eth_estimateGas` units assumed for an executeFill before the simulation's own
   * estimate — the floor of the estimate the plan is priced at: the sent plan is
   * priced at max(this, simulated) × r (the learned receipt ratio, gasRatio.ts) and
   * sent with gas limit max(that, simulated × 1.25).
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
  /** Tokens worth $1: the {@link rbtcUsd} fallback, and the pairs {@link stableSlippageBps} applies to. */
  usdTokens: Address[];
  /** RoutePlan.profitRecipient; zero = the operator EOA. */
  profitRecipient: Address;
  /** Rolling one-hour cap on the number of route fills (gas is capped by {@link Config.gas}). */
  hourlyFills: bigint;
  /** The Sushi API route source (pull orders only). */
  sushi: SushiConfig;
  /**
   * Whether local Oku routes compete on PULL orders (default on). Off = Sushi-only
   * pull fills; the pools still price gas, and DIRECT orders always use Oku (the only
   * exact-output source).
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
}

export interface Config {
  chainId: number;
  rpcUrl: string;
  /** Where {@link rpcUrl} came from: the `RPC_URL_SECRET` secret wins over `RPC_URL`. */
  rpcSource: "RPC_URL_SECRET" | "RPC_URL" | "default";
  privateKey: Hex;
  settlement: Address;
  permit3: Address;
  lens: Address;
  orderbookUrl: string;
  tokens: { usdrif: Address; usdt0: Address; rif: Address };
  moc: { core: Address; queue: Address };
  uniswap: { router: Address; quoter: Address; rifUsdt0Fee: number };
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

/**
 * `ROUTE_PATHS`: `;`-separated paths, each `token>fee>token[>fee>token…]` in swap
 * order, e.g. `0xUSDRIF>500>0xUSDT0>3000>0xWRBTC`. Empty string = none.
 */
export function parsePaths(raw: string): RoutePath[] {
  return raw
    .split(";")
    .map((p) => p.trim())
    .filter(Boolean)
    .map((p) => {
      const parts = p.split(">").map((x) => x.trim());
      if (parts.length < 3 || parts.length % 2 === 0) throw new Error(`ROUTE_PATHS: bad path ${p}`);
      const tokens: Address[] = [];
      const fees: number[] = [];
      parts.forEach((x, i) => {
        if (i % 2 === 0) {
          if (!isAddress(x, { strict: false })) throw new Error(`ROUTE_PATHS: not an address: ${x}`);
          tokens.push(getAddress(x));
        } else {
          fees.push(parseFee(x, "ROUTE_PATHS"));
        }
      });
      return { tokens, fees };
    });
}

/** `ROUTE_POOLS`: `;`-separated `tokenA/tokenB/fee` triples. Unset = the app's Rootstock markets. */
export function parsePools(raw: string): RoutePool[] {
  return raw
    .split(";")
    .map((p) => p.trim())
    .filter(Boolean)
    .map((p) => {
      const [a, b, f] = p.split("/").map((x) => x.trim());
      if (!a || !b || !f || !isAddress(a, { strict: false }) || !isAddress(b, { strict: false })) {
        throw new Error(`ROUTE_POOLS: bad pool ${p} (want tokenA/tokenB/fee)`);
      }
      return { tokenA: getAddress(a), tokenB: getAddress(b), fee: parseFee(f, "ROUTE_POOLS") };
    });
}

function loadRoute(env: Env): RouteConfig | undefined {
  if (!env.AGGREGATOR_SOLVER) return undefined;
  const rbtcUsd = env.RBTC_PRICE_USD ? parseFixed(env.RBTC_PRICE_USD, 18) : undefined;
  if (rbtcUsd === 0n) throw new Error("env RBTC_PRICE_USD must be > 0");
  const gasEstimate = posInt(env, "ROUTE_GAS_ESTIMATE", 320_000);
  const maxGas = posInt(env, "MAX_ROUTE_GAS", 1_200_000);
  if (gasEstimate > maxGas) throw new Error(`ROUTE_GAS_ESTIMATE ${gasEstimate} exceeds MAX_ROUTE_GAS ${maxGas}`);
  return {
    solver: addr(env, "AGGREGATOR_SOLVER"),
    pools: env.ROUTE_POOLS !== undefined ? parsePools(env.ROUTE_POOLS) : [...ROOTSTOCK_POOLS],
    paths: parsePaths(env.ROUTE_PATHS ?? ROOTSTOCK_PATHS),
    slippageBps: bps(env, "ROUTE_SLIPPAGE_BPS", 10),
    stableSlippageBps: bps(env, "ROUTE_STABLE_SLIPPAGE_BPS", 5),
    gasEstimate,
    maxGas,
    routeTokens: addrList(env, "ROUTE_TOKENS", [ROOTSTOCK.wrbtc, ROOTSTOCK.usdt0, ROOTSTOCK.weth, ROOTSTOCK.usdrif]),
    minProfitWei: fixed(env, "MIN_PROFIT_RBTC", "0", 18),
    rbtcUsd,
    usdTokens: (env.USD_TOKENS ? env.USD_TOKENS.split(",") : [ROOTSTOCK.usdt0, ROOTSTOCK.usdrif]).map((t) => getAddress(t.trim())),
    profitRecipient: addr(env, "ROUTE_PROFIT_RECIPIENT", "0x0000000000000000000000000000000000000000"),
    hourlyFills: uint(env, "ROUTE_HOURLY_FILLS", 60),
    okuPull: flag(env, "ROUTE_OKU_PULL", true),
    sushi: {
      enabled: flag(env, "SUSHI_ENABLED", true),
      baseUrl: env.SUSHI_API_URL ?? "https://api.sushi.com",
      router: addr(env, "SUSHI_ROUTER", SUSHI_RED_SNWAPPER_ROOTSTOCK),
      timeoutMs: posNum(env, "SUSHI_TIMEOUT_MS", 4_000),
      executors: addrList(env, "SUSHI_EXECUTORS", []),
      maxPerSweep: posNum(env, "SUSHI_MAX_PER_SWEEP", 10),
    },
  };
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
  };
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
  };
}
