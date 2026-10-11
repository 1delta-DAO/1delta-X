/**
 * Fork-e2e helper (NOT part of CI): fund a test maker on an anvil Rootstock fork,
 * sign a WRBTC → USDT0 (or, with TOKEN_IN=USDRIF, USDRIF → USDT0) order exactly as
 * the app would, and write it as the `{order, sig}` JSON `beta-filler fill-json` takes.
 *
 *   MODE=direct  delta-verify (timing bit 104) + exclusiveFiller = AGGREGATOR_SOLVER
 *   MODE=pull    plain pull delivery, exclusiveFiller = 0
 *
 * Env: RPC_URL, SETTLEMENT, PERMIT3, AGGREGATOR_SOLVER, MAKER_KEY, MODE, OUT,
 *      AMOUNT_WRBTC (default 0.05), PRICE_PCT (default 97 — the owed output as a %
 *      of the live pool quote, leaving the route its margin),
 *      TOKEN_IN (WRBTC | USDRIF, default WRBTC), AMOUNT_USDRIF (default 100; USDRIF is
 *      funded by impersonating the Oku USDRIF/USDT0 pool, priced on its 500 tier).
 */
import { writeFileSync } from "node:fs";

import {
  OrderSide,
  QUOTER_V2_ABI,
  encodeV3Path,
  hashOrderStruct,
  orderToJson,
  packTiming,
  randomOrderNonce,
  signOrder,
  withDeltaVerifyOutputs,
  type Order,
} from "@1delta-x/sdk";
import { createPublicClient, createWalletClient, erc20Abi, getAddress, http, maxUint256, parseEther, zeroAddress, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";

import { ROOTSTOCK } from "../src/config";

const env = (k: string, d?: string): string => {
  const v = process.env[k] ?? d;
  if (v === undefined) throw new Error(`missing ${k}`);
  return v;
};

const rpc = env("RPC_URL");
const settlement = getAddress(env("SETTLEMENT"));
const permit3 = getAddress(env("PERMIT3"));
const solver = getAddress(env("AGGREGATOR_SOLVER"));
const mode = env("MODE", "direct");
const usdrifIn = env("TOKEN_IN", "WRBTC").toUpperCase() === "USDRIF";
const amountIn = usdrifIn ? parseEther(env("AMOUNT_USDRIF", "100")) : parseEther(env("AMOUNT_WRBTC", "0.05"));
const pricePct = BigInt(env("PRICE_PCT", "97"));
const maker = privateKeyToAccount(env("MAKER_KEY") as Hex);
const chain = { id: 30, name: "rsk-fork", nativeCurrency: { name: "RBTC", symbol: "RBTC", decimals: 18 }, rpcUrls: { default: { http: [rpc] } } } as const;
const pub = createPublicClient({ chain, transport: http(rpc) });
const wallet = createWalletClient({ chain, transport: http(rpc), account: maker });
const WRBTC = ROOTSTOCK.wrbtc as Address;
const USDT0 = ROOTSTOCK.usdt0 as Address;
const USDRIF = ROOTSTOCK.usdrif as Address;
/** The Oku USDRIF/USDT0 0.05 % pool: a USDRIF holder to fund the maker from on the fork. */
const USDRIF_POOL = getAddress("0xd845702af381f0405661747a6a20bde0401a19d6");
const TOKEN = usdrifIn ? USDRIF : WRBTC;
const FEE = usdrifIn ? 500 : 3000;

const WRBTC_ABI = [{ type: "function", name: "deposit", stateMutability: "payable", inputs: [], outputs: [] }] as const;
const PERMIT3_APPROVE_ABI = [
  {
    type: "function",
    name: "approveToken",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "token", type: "address" },
      { name: "amount", type: "uint160" },
      { name: "expiration", type: "uint48" },
    ],
    outputs: [],
  },
] as const;

async function tx(p: Promise<Hex>) {
  const r = await pub.waitForTransactionReceipt({ hash: await p });
  if (r.status !== "success") throw new Error(`setup tx ${r.transactionHash} reverted`);
}

// 1. Fund: wrap RBTC (anvil accounts hold 10,000 RBTC) — or take USDRIF from the pool —
//    and approve Settlement via Permit3.
if (usdrifIn) {
  await pub.request({ method: "anvil_impersonateAccount" as never, params: [USDRIF_POOL] as never });
  await pub.request({ method: "anvil_setBalance" as never, params: [USDRIF_POOL, "0xDE0B6B3A7640000"] as never });
  const pool = createWalletClient({ chain, transport: http(rpc), account: USDRIF_POOL });
  await tx(pool.writeContract({ address: USDRIF, abi: erc20Abi, functionName: "transfer", args: [maker.address, amountIn] }));
  await pub.request({ method: "anvil_stopImpersonatingAccount" as never, params: [USDRIF_POOL] as never });
} else {
  await tx(wallet.writeContract({ address: WRBTC, abi: WRBTC_ABI, functionName: "deposit", value: amountIn }));
}
await tx(wallet.writeContract({ address: TOKEN, abi: erc20Abi, functionName: "approve", args: [permit3, maxUint256] }));
await tx(wallet.writeContract({ address: permit3, abi: PERMIT3_APPROVE_ABI, functionName: "approveToken", args: [settlement, TOKEN, amountIn, 0] }));

// 2. Price the output off the live pool, PRICE_PCT of the quote.
const { result } = await pub.simulateContract({
  address: ROOTSTOCK.quoterV2 as Address,
  abi: QUOTER_V2_ABI,
  functionName: "quoteExactInput",
  args: [encodeV3Path([TOKEN, USDT0], [FEE]), amountIn],
});
const owed = (result[0] * pricePct) / 100n;

// 3. Build + sign, as the app's buildOrder does for a fixed (non-decaying) sell.
const now = (await pub.getBlock()).timestamp;
const direct = mode === "direct";
const order: Order = {
  maker: maker.address,
  side: OrderSide.SELL,
  nonce: randomOrderNonce(0n),
  expiry: now + 3600n,
  legsIn: [{ token: TOKEN, start: amountIn, end: 0n }],
  legsOut: [{ token: USDT0, start: owed, end: 0n, recipient: zeroAddress }],
  timing: direct ? withDeltaVerifyOutputs(packTiming(0, 0, 0)) : packTiming(0, 0, 0),
  exclusiveFiller: direct ? solver : zeroAddress,
  minFillAnchor: 0n,
  exclusivityOverrideBps: 0n,
  curve: [],
  gasBumpBps: 0n,
  gasPriceRef: 0n,
  priorityScale: 0n,
  items: [],
  validators: [],
  invariants: [],
  fillModule: zeroAddress,
  fillTotal: 0n,
  pricingModule: zeroAddress,
};
const sig = await signOrder(maker, order, { chainId: 30, settlement, permit3 });
const before = await pub.readContract({ address: USDT0, abi: erc20Abi, functionName: "balanceOf", args: [maker.address] });
writeFileSync(env("OUT"), JSON.stringify({ order: orderToJson(order), sig }, null, 1));
// Machine-readable last line for the shell driver.
console.log(`ORDER ${hashOrderStruct(order)} mode=${mode} in=${amountIn} owed=${owed} quote=${result[0]} makerUsdt0Before=${before} maker=${maker.address}`);
