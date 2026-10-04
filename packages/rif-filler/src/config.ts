import { getAddress, isAddress, type Address, type Hex } from "viem";

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
} as const satisfies Record<string, string | number>;

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
  privateKey: Hex;
  settlement: Address;
  permit3: Address;
  lens: Address;
  orderbookUrl: string;
  tokens: { usdrif: Address; usdt0: Address; rif: Address };
  moc: { core: Address; queue: Address };
  uniswap: { router: Address; quoter: Address; rifUsdt0Fee: number };
  policy: Policy;
  /** When true (the default) nothing is broadcast: every decision is simulated and logged. */
  dryRun: boolean;
  /** Re-scan cadence for the book and the rebalancer, ms. */
  pollMs: number;
  /** Rolling-budget state survives restarts here. */
  stateFile: string;
}

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

function bps(env: Env, key: string, fallback: number): bigint {
  const v = BigInt(env[key] ?? String(fallback));
  if (v < 0n || v > 10_000n) throw new Error(`env ${key} must be 0..10000 bps`);
  return v;
}

function flag(env: Env, key: string, fallback: boolean): boolean {
  const v = env[key];
  if (v === undefined || v === "") return fallback;
  return v === "1" || v.toLowerCase() === "true";
}

export function loadConfig(env: Env = process.env): Config {
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
    hourlyUsdt0: fixed(env, "HOURLY_USDT0", "2000", USDT0_DECIMALS),
    hourlyUsdrif: fixed(env, "HOURLY_USDRIF", "2000", USDRIF_DECIMALS),
    usdrifReserve: fixed(env, "USDRIF_RESERVE", "0", USDRIF_DECIMALS),
    redeemMin: fixed(env, "REDEEM_MIN_USDRIF", "50", USDRIF_DECIMALS),
    redeemSlippageBps: bps(env, "REDEEM_SLIPPAGE_BPS", 50),
    rifSellMin: fixed(env, "RIF_SELL_MIN", "200", 18),
    rifSellMaxDiscountBps: bps(env, "RIF_SELL_MAX_DISCOUNT_BPS", 150),
    rifSellSlippageBps: bps(env, "RIF_SELL_SLIPPAGE_BPS", 50),
  };
  if (policy.buyUsdrif && policy.maxBuyPrice >= 10n ** 18n) {
    throw new Error("MAX_BUY_PRICE must be below 1.0: redemption returns $1 of RIF minus the MoC fee");
  }
  return {
    chainId: Number(env.CHAIN_ID ?? ROOTSTOCK.chainId),
    rpcUrl: env.RPC_URL ?? ROOTSTOCK.rpcUrl,
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
      rifUsdt0Fee: Number(env.RIF_USDT0_FEE ?? ROOTSTOCK.rifUsdt0Fee),
    },
    policy,
    // Fail safe: only an explicit DRY_RUN=0 broadcasts.
    dryRun: !(env.DRY_RUN === "0" || env.DRY_RUN?.toLowerCase() === "false"),
    pollMs: Number(env.POLL_MS ?? 15_000),
    stateFile: env.STATE_FILE ?? ".rif-filler-state.json",
  };
}
