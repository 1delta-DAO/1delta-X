/**
 * Gas-simulation order builder (LOCAL ONLY, NOT part of CI) — used by
 * scripts/rsk-gas/sim.sh. It funds a maker on an anvil Rootstock fork and signs a
 * market-shaped order the way the app does today. That means a fill-once order on a
 * packed nonce (so the nonce bitmap is what the fill writes), funded by a DIRECT
 * approval to Settlement, a Permit3 grant, or an ERC-2612 permit carried in the fill.
 * The order is written as the `{order, sig, erc2612Permit?}` JSON `beta-filler
 * fill-json` takes.
 *
 * Env:
 *   RPC_URL, SETTLEMENT, PERMIT3, AGGREGATOR_SOLVER, MAKER_KEY, OUT
 *   MODE      direct | pull
 *   TOKEN_IN  WRBTC | USDRIF | USDT0      TOKEN_OUT  USDT0 | WRBTC | USDRIF | RIF
 *   AMOUNT    human units of TOKEN_IN
 *   FUNDING   direct (approve Settlement) | permit3 (approve Permit3 + grant) | permit2612
 *   NONCE     the order nonce (packed: word = nonce >> 8); a maker's 2nd order in the same word
 *   FUND      1 = deal TOKEN_IN to the maker first (default 1)
 *   PRICE_PCT owed output as % of the live route quote (default 50 — anvil prices gas at 1 gwei)
 */
import { writeFileSync } from "node:fs";

import {
  ERC2612_ABI,
  OrderSide,
  QUOTER_V2_ABI,
  encodeV3Path,
  erc2612DomainOf,
  erc2612PermitToJson,
  erc2612TypedData,
  hashOrderStruct,
  orderToJson,
  packTiming,
  signOrder,
  splitPermitSignature,
  withDeltaVerifyOutputs,
  withFillOnce,
  type Order,
} from "@1delta-x/sdk";
import { createPublicClient, createWalletClient, erc20Abi, getAddress, http, maxUint256, parseUnits, zeroAddress, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";

import { ROOTSTOCK } from "../src/config";

const env = (k: string, d?: string): string => {
  const v = process.env[k] ?? d;
  if (v === undefined) throw new Error(`missing ${k}`);
  return v;
};

const TOKENS: Record<string, { address: Address; decimals: number; holder: Address }> = {
  // A holder to deal from on the fork: the deepest pool of each token.
  WRBTC: { address: ROOTSTOCK.wrbtc as Address, decimals: 18, holder: getAddress("0xaef6fabf3b0c9e5f9d6d5170afc703a633479bbd") },
  USDT0: { address: ROOTSTOCK.usdt0 as Address, decimals: 6, holder: getAddress("0xaef6fabf3b0c9e5f9d6d5170afc703a633479bbd") },
  USDRIF: { address: ROOTSTOCK.usdrif as Address, decimals: 18, holder: getAddress("0xd845702af381f0405661747a6a20bde0401a19d6") },
  RIF: { address: ROOTSTOCK.rif as Address, decimals: 18, holder: getAddress("0x57079b2d3071eb06cce6dbafb9b0306bcc49b020") },
};
/** Quoter paths (swap order) per pair, on the Oku pools. */
const PATHS: Record<string, { tokens: string[]; fees: number[] }> = {
  "WRBTC>USDT0": { tokens: ["WRBTC", "USDT0"], fees: [3000] },
  "USDT0>WRBTC": { tokens: ["USDT0", "WRBTC"], fees: [3000] },
  "USDRIF>USDT0": { tokens: ["USDRIF", "USDT0"], fees: [500] },
  "USDT0>USDRIF": { tokens: ["USDT0", "USDRIF"], fees: [500] },
  "WRBTC>USDRIF": { tokens: ["WRBTC", "USDT0", "USDRIF"], fees: [3000, 500] },
  "USDRIF>WRBTC": { tokens: ["USDRIF", "USDT0", "WRBTC"], fees: [500, 3000] },
  "USDT0>RIF": { tokens: ["USDT0", "RIF"], fees: [3000] },
  "RIF>USDT0": { tokens: ["RIF", "USDT0"], fees: [3000] },
};

const rpc = env("RPC_URL");
const settlement = getAddress(env("SETTLEMENT"));
const permit3 = getAddress(env("PERMIT3"));
const solver = getAddress(env("AGGREGATOR_SOLVER"));
const mode = env("MODE", "direct");
const tIn = TOKENS[env("TOKEN_IN", "WRBTC")]!;
const tOut = TOKENS[env("TOKEN_OUT", "USDT0")]!;
const path = PATHS[`${env("TOKEN_IN", "WRBTC")}>${env("TOKEN_OUT", "USDT0")}`];
if (!path) throw new Error("no quoter path for the pair");
const amountIn = parseUnits(env("AMOUNT", "0.0002"), tIn.decimals);
const funding = env("FUNDING", "direct");
const nonce = BigInt(env("NONCE", "256"));
const pricePct = BigInt(env("PRICE_PCT", "50"));
const maker = privateKeyToAccount(env("MAKER_KEY") as Hex);
const chain = { id: 30, name: "rsk-fork", nativeCurrency: { name: "RBTC", symbol: "RBTC", decimals: 18 }, rpcUrls: { default: { http: [rpc] } } } as const;
const pub = createPublicClient({ chain, transport: http(rpc, { timeout: 300_000 }) });
const wallet = createWalletClient({ chain, transport: http(rpc, { timeout: 300_000 }), account: maker });

async function tx(p: Promise<Hex>) {
  const r = await pub.waitForTransactionReceipt({ hash: await p });
  if (r.status !== "success") throw new Error(`setup tx ${r.transactionHash} reverted`);
}

// 1. Fund (deal from a pool, impersonated) and approve, as the chosen funding does.
if (env("FUND", "1") === "1") {
  await pub.request({ method: "anvil_impersonateAccount" as never, params: [tIn.holder] as never });
  await pub.request({ method: "anvil_setBalance" as never, params: [tIn.holder, "0xDE0B6B3A7640000"] as never });
  const h = createWalletClient({ chain, transport: http(rpc, { timeout: 300_000 }), account: tIn.holder });
  await tx(h.writeContract({ address: tIn.address, abi: erc20Abi, functionName: "transfer", args: [maker.address, amountIn] }));
  await pub.request({ method: "anvil_stopImpersonatingAccount" as never, params: [tIn.holder] as never });
}
const P3 = [
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
const now = (await pub.getBlock()).timestamp;
if (funding === "direct") {
  await tx(wallet.writeContract({ address: tIn.address, abi: erc20Abi, functionName: "approve", args: [settlement, amountIn] }));
} else if (funding === "permit3") {
  await tx(wallet.writeContract({ address: tIn.address, abi: erc20Abi, functionName: "approve", args: [permit3, amountIn] }));
  await tx(wallet.writeContract({ address: permit3, abi: P3, functionName: "approveToken", args: [settlement, tIn.address, amountIn, Number(now + 7200n)] }));
}

// 2. Owed: PRICE_PCT of the live route quote (the gas used does not depend on it).
const { result } = await pub.simulateContract({
  address: ROOTSTOCK.quoterV2 as Address,
  abi: QUOTER_V2_ABI,
  functionName: "quoteExactInput",
  args: [encodeV3Path(path.tokens.map((s) => TOKENS[s]!.address), path.fees), amountIn],
});
const owed = (result[0] * pricePct) / 100n;

// 3. The app's market shape: fixed legs here (a Dutch decay changes no storage), FILL-ONCE
//    on a packed nonce, direct = delta-verify to the solver.
const direct = mode === "direct";
const clock = withFillOnce(packTiming(0, 0, 0));
const order: Order = {
  maker: maker.address,
  side: OrderSide.SELL,
  nonce,
  expiry: now + 3600n,
  legsIn: [{ token: tIn.address, start: amountIn, end: 0n }],
  legsOut: [{ token: tOut.address, start: owed, end: 0n, recipient: zeroAddress }],
  timing: direct ? withDeltaVerifyOutputs(clock) : clock,
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

// 4. ERC-2612: the permit the app signs next to the order (spender = Settlement).
let erc2612Permit: unknown;
if (funding === "permit2612") {
  const domain = erc2612DomainOf(30, tIn.address);
  if (!domain) throw new Error("TOKEN_IN has no pinned ERC-2612 domain");
  const pNonce = (await pub.readContract({ address: tIn.address, abi: ERC2612_ABI, functionName: "nonces", args: [maker.address] })) as bigint;
  const deadline = order.expiry;
  const s = await maker.signTypedData(erc2612TypedData(domain, { owner: maker.address, spender: settlement, value: amountIn, nonce: pNonce, deadline }) as never);
  erc2612Permit = erc2612PermitToJson({ token: tIn.address, spender: settlement, value: amountIn, nonce: pNonce, deadline, ...splitPermitSignature(s) });
}
void maxUint256;
writeFileSync(env("OUT"), JSON.stringify({ order: orderToJson(order), sig, ...(erc2612Permit ? { erc2612Permit } : {}) }, null, 1));
console.log(`ORDER ${hashOrderStruct(order)} mode=${mode} funding=${funding} in=${amountIn} owed=${owed} maker=${maker.address}`);
