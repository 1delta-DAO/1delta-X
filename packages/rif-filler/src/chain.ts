import { packOrder, SETTLEMENT_LENS_ABI, type Order } from "@1delta-x/sdk";
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  erc20Abi,
  http,
  maxUint256,
  type Address,
  type Hex,
  type PublicClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";

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

export interface Chain {
  pub: PublicClient;
  wallet: WalletClient;
  account: PrivateKeyAccount;
  me: Address;
}

export function connect(cfg: Config): Chain {
  const chain = defineChain({
    id: cfg.chainId,
    name: cfg.chainId === 30 ? "Rootstock" : `chain-${cfg.chainId}`,
    nativeCurrency: { name: "RBTC", symbol: "RBTC", decimals: 18 },
    rpcUrls: { default: { http: [cfg.rpcUrl] } },
  });
  const account = privateKeyToAccount(cfg.privateKey);
  const transport = http(cfg.rpcUrl);
  return {
    pub: createPublicClient({ chain, transport }) as PublicClient,
    wallet: createWalletClient({ chain, transport, account }),
    account,
    me: account.address,
  };
}

export async function balanceOf(c: Chain, token: Address, who: Address = c.me): Promise<bigint> {
  return c.pub.readContract({ address: token, abi: erc20Abi, functionName: "balanceOf", args: [who] });
}

export async function previewFill(
  c: Chain,
  lens: Address,
  order: Order,
  fillAmount: bigint,
): Promise<{ delta: bigint; received: readonly bigint[]; paid: readonly bigint[] }> {
  const [delta, received, paid] = (await c.pub.readContract({
    address: lens,
    abi: SETTLEMENT_LENS_ABI,
    functionName: "previewFill",
    args: [packOrder(order) as never, fillAmount, c.me, "0x"],
  })) as readonly [bigint, readonly bigint[], readonly bigint[]];
  return { delta, received, paid };
}

export async function previewBump(c: Chain, lens: Address, order: Order): Promise<bigint> {
  return (await c.pub.readContract({
    address: lens,
    abi: SETTLEMENT_LENS_ABI,
    functionName: "previewBump",
    args: [packOrder(order) as never, c.me, "0x"],
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

/**
 * Make sure `spender` may pull at least `needed` of `token` from us. Approves a
 * bounded `target` (never unlimited), resetting to 0 first for tokens that refuse
 * a non-zero → non-zero change.
 */
export async function ensureAllowance(
  c: Chain,
  token: Address,
  spender: Address,
  needed: bigint,
  target: bigint,
  dryRun: boolean,
  log: (m: string) => void,
): Promise<void> {
  const current = await c.pub.readContract({
    address: token,
    abi: erc20Abi,
    functionName: "allowance",
    args: [c.me, spender],
  });
  if (current >= needed) return;
  const amount = target > needed ? target : needed;
  if (amount === maxUint256) throw new Error("refusing an unlimited approval");
  if (dryRun) {
    log(`[dry-run] would approve ${spender} for ${amount} of ${token}`);
    return;
  }
  if (current > 0n) await send(c, { address: token, abi: erc20Abi, functionName: "approve", args: [spender, 0n] }, log);
  await send(c, { address: token, abi: erc20Abi, functionName: "approve", args: [spender, amount] }, log);
}

/** Simulate, then broadcast and wait for a successful receipt. */
export async function send(c: Chain, call: Parameters<PublicClient["simulateContract"]>[0], log: (m: string) => void, value?: bigint): Promise<Hex> {
  const { request } = await c.pub.simulateContract({ ...call, account: c.account, ...(value ? { value } : {}) } as never);
  const hash = await c.wallet.writeContract(request as never);
  const receipt = await c.pub.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`tx ${hash} reverted`);
  log(`tx ${hash} mined in block ${receipt.blockNumber}`);
  return hash;
}
