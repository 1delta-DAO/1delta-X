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

/** How long one `eth_gasPrice` answer is reused (Rootstock's minimum gas price moves slowly). */
export const GAS_PRICE_TTL_MS = 10_000;

/**
 * The same chain with `getGasPrice` answered from a short-lived cache: every order
 * of a sweep (and every strategy on it) used to ask `eth_gasPrice` again — 197 of
 * the 809 calls a resting-book soak window cost. A failed read is not cached.
 */
export function withGasPriceCache(c: Chain, ttlMs: number = GAS_PRICE_TTL_MS, now: () => number = Date.now): Chain {
  let hit: { at: number; price: Promise<bigint> } | undefined;
  const getGasPrice = (): Promise<bigint> => {
    const t = now();
    if (!hit || t - hit.at >= ttlMs || t < hit.at) {
      const price = c.pub.getGasPrice();
      const entry = { at: t, price };
      hit = entry;
      price.catch(() => {
        if (hit === entry) hit = undefined;
      });
    }
    return hit.price;
  };
  const pub = new Proxy(c.pub, {
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
