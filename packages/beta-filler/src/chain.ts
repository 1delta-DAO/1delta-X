import { packOrder, SETTLEMENT_LENS_ABI, type Order } from "@1delta-x/sdk";
import {
  createPublicClient,
  defineChain,
  encodeFunctionData,
  erc20Abi,
  http,
  maxUint256,
  type Address,
  type Hex,
  type LocalAccount,
  type PublicClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

import type { Config } from "./config";

export const MOC_CORE_ABI = [
  {
    type: "function",
    name: "redeemTP",
    stateMutability: "payable",
    inputs: [
      { name: "tp_", type: "address" },
      { name: "qTP_", type: "uint256" },
      { name: "qACmin_", type: "uint256" },
      { name: "recipient_", type: "address" },
      { name: "vendor_", type: "address" },
    ],
    outputs: [{ name: "operId", type: "uint256" }],
  },
  {
    type: "function",
    name: "mintTP",
    stateMutability: "payable",
    inputs: [
      { name: "tp_", type: "address" },
      { name: "qTP_", type: "uint256" },
      { name: "qACmax_", type: "uint256" },
      { name: "recipient_", type: "address" },
      { name: "vendor_", type: "address" },
    ],
    outputs: [{ name: "operId", type: "uint256" }],
  },
  {
    type: "function",
    name: "getPACtp",
    stateMutability: "view",
    inputs: [{ name: "tp_", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
] as const;

export const MOC_QUEUE_ABI = [
  {
    type: "function",
    name: "getExecFee",
    stateMutability: "view",
    inputs: [{ name: "operType_", type: "uint8" }],
    outputs: [{ type: "uint256" }],
  },
  { type: "function", name: "firstOperId", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
] as const;

/** `OperType` in the MoC queue: {none, mintTC, redeemTC, mintTP, redeemTP, …}. */
export const OPER_MINT_TP = 3;
export const OPER_REDEEM_TP = 4;

export const QUOTER_V2_ABI = [
  {
    type: "function",
    name: "quoteExactInputSingle",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "params",
        type: "tuple",
        components: [
          { name: "tokenIn", type: "address" },
          { name: "tokenOut", type: "address" },
          { name: "amountIn", type: "uint256" },
          { name: "fee", type: "uint24" },
          { name: "sqrtPriceLimitX96", type: "uint160" },
        ],
      },
    ],
    outputs: [
      { name: "amountOut", type: "uint256" },
      { name: "sqrtPriceX96After", type: "uint160" },
      { name: "initializedTicksCrossed", type: "uint32" },
      { name: "gasEstimate", type: "uint256" },
    ],
  },
] as const;

/** SwapRouter02: `ExactInputSingleParams` has no deadline. */
export const SWAP_ROUTER02_ABI = [
  {
    type: "function",
    name: "exactInputSingle",
    stateMutability: "payable",
    inputs: [
      {
        name: "params",
        type: "tuple",
        components: [
          { name: "tokenIn", type: "address" },
          { name: "tokenOut", type: "address" },
          { name: "fee", type: "uint24" },
          { name: "recipient", type: "address" },
          { name: "amountIn", type: "uint256" },
          { name: "amountOutMinimum", type: "uint256" },
          { name: "sqrtPriceLimitX96", type: "uint160" },
        ],
      },
    ],
    outputs: [{ name: "amountOut", type: "uint256" }],
  },
] as const;

/**
 * What the filler needs from a chain: a public client for reads and simulation,
 * and a LOCAL account that signs legacy transactions itself (the signed bytes'
 * hash is recorded as pending BEFORE the broadcast — see guard.ts `broadcast`).
 */
export interface Chain {
  pub: PublicClient;
  account: LocalAccount;
  me: Address;
  chainId: number;
}

export interface ConnectOptions {
  /** Custom fetch for the RPC transport (the Worker counts subrequests through it). */
  fetchFn?: typeof fetch;
  /** Transport retries per call (viem's default 3; the Worker uses 1). */
  retryCount?: number;
}

export function connect(cfg: Config, opts: ConnectOptions = {}): Chain {
  const chain = defineChain({
    id: cfg.chainId,
    name: cfg.chainId === 30 ? "Rootstock" : `chain-${cfg.chainId}`,
    nativeCurrency: { name: "RBTC", symbol: "RBTC", decimals: 18 },
    rpcUrls: { default: { http: [cfg.rpcUrl] } },
  });
  const account = privateKeyToAccount(cfg.privateKey);
  const transport = http(cfg.rpcUrl, {
    batch: false,
    ...(opts.fetchFn ? { fetchFn: opts.fetchFn } : {}),
    ...(opts.retryCount !== undefined ? { retryCount: opts.retryCount } : {}),
  });
  return {
    pub: createPublicClient({ chain, transport }) as PublicClient,
    account,
    me: account.address,
    chainId: cfg.chainId,
  };
}

export async function balanceOf(c: Chain, token: Address, who: Address = c.me): Promise<bigint> {
  return c.pub.readContract({ address: token, abi: erc20Abi, functionName: "balanceOf", args: [who] });
}

/** `token.allowance(me, spender)`. */
export async function allowanceOf(c: Chain, token: Address, spender: Address): Promise<bigint> {
  return c.pub.readContract({ address: token, abi: erc20Abi, functionName: "allowance", args: [c.me, spender] });
}

/** How long one send-gas-price answer is reused (Rootstock's minimum gas price moves at most 1 % per ~30 s block). */
export const GAS_PRICE_TTL_MS = 10_000;

/** Where a send gas price came from. */
export type GasPriceSource = "minimumGasPrice" | "eth_gasPrice";

export interface SendGasPrice {
  wei: bigint;
  source: GasPriceSource;
  /** The latest block's `minimumGasPrice`, when it had one. */
  minWei?: bigint;
}

/** A JSON-RPC quantity (hex string, decimal string, number or bigint) → bigint; undefined when absent / malformed. */
export function quantity(v: unknown): bigint | undefined {
  try {
    if (typeof v === "bigint") return v;
    if (typeof v === "number" && Number.isSafeInteger(v)) return BigInt(v);
    if (typeof v === "string" && /^(0x[0-9a-fA-F]+|\d+)$/.test(v.trim())) return BigInt(v.trim());
  } catch {
    // fall through
  }
  return undefined;
}

/**
 * The gas price every tx is SENT at — and so the price every profit gate and the gas
 * budget are priced at: ⌈latestBlock.minimumGasPrice × multBps / 10000⌉.
 *
 * Rootstock has no fee market (verified 2026-10-07 against rskj master 53c040f,
 * paths under rskj-core/src/main/java/, and RSKj/9.0.3 on public-node.rsk.co):
 *
 *  • each block header carries a miner-voted `minimumGasPrice` (RSKIP-09,
 *    https://github.com/rsksmart/RSKIPs/blob/master/IPs/RSKIP09.md) that may move at
 *    most ±1 % from its parent's (co/rsk/mine/BlockGasPriceRange.java,
 *    VARIATION_PERCENTAGE_RANGE = 1, enforced by co/rsk/validators/PrevMinGasPriceRule;
 *    miners clamp their target to it, co/rsk/mine/MinimumGasPriceCalculator);
 *  • every tx in a block must pay ≥ THAT block's minimum (TxsMinGasPriceRule); a
 *    node's pool admits a tx at ≥ its best block's minimum, with no buffer
 *    (TxValidatorMinimuGasPriceValidator); a MINING node evicts a pending tx that a
 *    risen minimum leaves behind (BlockToMineBuilder → MinerUtils, removePendingTransactions);
 *  • `eth_gasPrice` answers bestBlock.min × `rpc.minGasPriceMultiplier` (1.1) unless
 *    blocks run ≥ 90 % full (GasPriceTracker; EthereumImpl.getGasPrice);
 *  • live: 23,696,000 wei, flat since ~March 2025 (201 samples over 20k blocks, 53
 *    weekly samples over a year: no change); its last move (Dec 2024 – Mar 2025,
 *    59.24 → 23.70 Mwei) went in exact 1 % steps, both ways.
 *
 * So min × 1.03 (config.ts DEFAULT_GAS_PRICE_MIN_MULT_BPS) is admitted
 * everywhere and stays includable through two consecutive maximal rises after the
 * block read; 1.02 through one. A tx stranded by a longer rise is not repriced:
 * re-broadcast keeps the signed bytes, and the 15-minute drop rule (guard.ts) frees
 * the nonce — note rskj needs a +40 % bump to REPLACE a same-nonce tx still pooled
 * (`transaction.gasPriceBump`). `eth_gasPrice` (+10 %) would pay ~7 % more on every
 * fill to cover a rise that has not happened for 19 months.
 *
 * Fallback: `eth_gasPrice` when the latest block has no `minimumGasPrice` (anvil
 * forks, non-Rootstock chains) or the block read fails. viem's `getBlock` passes
 * fields it does not know through untouched (a hex string here).
 */
export async function readSendGasPrice(pub: Pick<PublicClient, "getGasPrice"> & Partial<Pick<PublicClient, "getBlock">>, multBps: bigint): Promise<SendGasPrice> {
  let minWei: bigint | undefined;
  if (pub.getBlock) {
    try {
      const block = (await pub.getBlock({ blockTag: "latest" })) as { minimumGasPrice?: unknown } | null;
      minWei = quantity(block?.minimumGasPrice);
    } catch {
      minWei = undefined; // an RPC hiccup: eth_gasPrice below (~7 % dearer, never cheaper than the minimum)
    }
  }
  if (minWei !== undefined && minWei > 0n) return { wei: (minWei * multBps + 9_999n) / 10_000n, source: "minimumGasPrice", minWei };
  return { wei: await pub.getGasPrice(), source: "eth_gasPrice" };
}

export interface SendGasPriceOptions {
  /** ⌈min × multBps / 10000⌉ (config `GAS_PRICE_MIN_MULT_BPS`). */
  multBps: bigint;
  ttlMs?: number;
  now?: () => number;
  /** Told which source priced the sends: on the first read and whenever it changes. */
  log?: (m: string) => void;
}

/**
 * The same chain with `getGasPrice` answering THE SEND PRICE ({@link readSendGasPrice})
 * from a short-lived cache. Every strategy, the rebalancer and `estimateAndBroadcast`
 * read the price through `chain.pub.getGasPrice()`, so the profit gates, the gas
 * budget, the lens previews and the signed tx all use this one figure. Every order of
 * a sweep used to ask `eth_gasPrice` again (197 of the 809 calls a resting-book soak
 * window cost); a failed read is not cached.
 */
export function withSendGasPrice(c: Chain, o: SendGasPriceOptions): Chain {
  const ttlMs = o.ttlMs ?? GAS_PRICE_TTL_MS;
  const now = o.now ?? Date.now;
  const inner = c.pub;
  let hit: { at: number; price: Promise<bigint> } | undefined;
  let lastSource: GasPriceSource | undefined;
  const getGasPrice = (): Promise<bigint> => {
    const t = now();
    if (!hit || t - hit.at >= ttlMs || t < hit.at) {
      const price = readSendGasPrice(inner, o.multBps).then((r) => {
        if (r.source !== lastSource) {
          lastSource = r.source;
          o.log?.(
            r.source === "minimumGasPrice"
              ? `gas price: sending at latest block minimumGasPrice ${r.minWei} × ${o.multBps} bps = ${r.wei} wei`
              : `gas price: the latest block has no minimumGasPrice — sending at eth_gasPrice (${r.wei} wei)`,
          );
        }
        return r.wei;
      });
      const entry = { at: t, price };
      hit = entry;
      price.catch(() => {
        if (hit === entry) hit = undefined;
      });
    }
    return hit.price;
  };
  const pub = new Proxy(inner, {
    get: (target, key, receiver) => (key === "getGasPrice" ? getGasPrice : Reflect.get(target, key, receiver)),
  });
  return { ...c, pub };
}

/**
 * The `eth_call` gas price for a lens preview. A priority auction prices off
 * `tx.gasprice − basefee` and a gas-bump order off the basefee, so a preview quoted
 * at the default gas price (0) is the NO-BID tick, not the one the fill will see
 * (review 2026-10-05 §4). Pass the gas price the fill will be SENT with. viem's
 * `readContract` forwards it to `eth_call` at runtime but does not declare it, hence
 * the spread.
 */
function atGasPrice(gasPrice: bigint | undefined): object {
  return gasPrice === undefined ? {} : { gasPrice };
}

export async function previewFill(
  c: Chain,
  lens: Address,
  order: Order,
  fillAmount: bigint,
  /** Who Settlement will see as `msg.sender`: our EOA (inventory) or the solver contract (route). */
  filler: Address = c.me,
  /** The gas price the fill will be sent with — see {@link atGasPrice}. */
  gasPrice?: bigint,
): Promise<{ delta: bigint; received: readonly bigint[]; paid: readonly bigint[] }> {
  const [delta, received, paid] = (await c.pub.readContract({
    address: lens,
    abi: SETTLEMENT_LENS_ABI,
    functionName: "previewFill",
    args: [packOrder(order) as never, fillAmount, filler, "0x"],
    ...atGasPrice(gasPrice),
  })) as readonly [bigint, readonly bigint[], readonly bigint[]];
  return { delta, received, paid };
}

export async function previewBump(
  c: Chain,
  lens: Address,
  order: Order,
  filler: Address = c.me,
  /** The gas price the fill will be sent with — see {@link atGasPrice}. */
  gasPrice?: bigint,
): Promise<bigint> {
  return (await c.pub.readContract({
    address: lens,
    abi: SETTLEMENT_LENS_ABI,
    functionName: "previewBump",
    args: [packOrder(order) as never, filler, "0x"],
    ...atGasPrice(gasPrice),
  })) as bigint;
}

/** RIF out of the MoC for `qTP` USDRIF at the oracle price, before the MoC fee. */
export async function rifForUsdrif(c: Chain, cfg: Config, qTP: bigint): Promise<bigint> {
  const pACtp = await c.pub.readContract({
    address: cfg.moc.core,
    abi: MOC_CORE_ABI,
    functionName: "getPACtp",
    args: [cfg.tokens.usdrif],
  });
  if (pACtp === 0n) throw new Error("MoC getPACtp returned 0");
  return (qTP * 10n ** 18n) / pACtp;
}

/** USDT0 out of the RIF/USDT0 pool for `amountIn` RIF, quoted live. */
export async function quoteRifToUsdt0(c: Chain, cfg: Config, amountIn: bigint): Promise<bigint> {
  if (amountIn === 0n) return 0n;
  const { result } = await c.pub.simulateContract({
    address: cfg.uniswap.quoter,
    abi: QUOTER_V2_ABI,
    functionName: "quoteExactInputSingle",
    args: [
      {
        tokenIn: cfg.tokens.rif,
        tokenOut: cfg.tokens.usdt0,
        amountIn,
        fee: cfg.uniswap.rifUsdt0Fee,
        sqrtPriceLimitX96: 0n,
      },
    ],
  });
  return result[0];
}

/** USDT0 out for `amountIn` WRBTC on the WRBTC/USDT0 pool (fee `fee`), quoted live. */
export async function quoteWrbtcToUsdt0(c: Chain, cfg: Config, amountIn: bigint, fee = 3000): Promise<bigint> {
  if (amountIn === 0n) return 0n;
  const { result } = await c.pub.simulateContract({
    address: cfg.uniswap.quoter,
    abi: QUOTER_V2_ABI,
    functionName: "quoteExactInputSingle",
    args: [{ tokenIn: cfg.wrbtc, tokenOut: cfg.tokens.usdt0, amountIn, fee, sqrtPriceLimitX96: 0n }],
  });
  return result[0];
}

/**
 * The approval tx (if any) that lets `spender` pull at least `needed` of `token`
 * from us: a bounded `target` (never unlimited). A token that refuses a non-zero →
 * non-zero change is first reset to 0 — as its OWN tx (`reset`), so the caller
 * sends one transaction per tick and comes back for the second.
 */
export async function allowanceCall(
  c: Chain,
  token: Address,
  spender: Address,
  needed: bigint,
  target: bigint,
  /** The allowance already read by the caller (saves the read). */
  known?: bigint,
): Promise<{ data: Hex; amount: bigint; reset: boolean } | undefined> {
  const current = known ?? (await allowanceOf(c, token, spender));
  if (current >= needed) return undefined;
  const amount = target > needed ? target : needed;
  if (amount === maxUint256) throw new Error("refusing an unlimited approval");
  if (current > 0n) return { data: encodeFunctionData({ abi: erc20Abi, functionName: "approve", args: [spender, 0n] }), amount: 0n, reset: true };
  return { data: encodeFunctionData({ abi: erc20Abi, functionName: "approve", args: [spender, amount] }), amount, reset: false };
}
