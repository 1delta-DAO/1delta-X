import { erc20Abi, maxUint256, pad, type Address, type Hex } from "viem";

import { ROOTSTOCK_USDT0, type BridgeSource } from "../config/bridge";

/** The slice of LayerZero's IOFT (v2) the on-ramp calls. */
export const OFT_ABI = [
  {
    type: "function",
    name: "token",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "address" }],
  },
  {
    type: "function",
    name: "approvalRequired",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "bool" }],
  },
  {
    type: "function",
    name: "peers",
    stateMutability: "view",
    inputs: [{ name: "eid", type: "uint32" }],
    outputs: [{ type: "bytes32" }],
  },
  {
    type: "function",
    name: "quoteOFT",
    stateMutability: "view",
    inputs: [{ name: "sendParam", type: "tuple", components: SEND_PARAM() }],
    outputs: [
      { name: "limit", type: "tuple", components: [{ name: "minAmountLD", type: "uint256" }, { name: "maxAmountLD", type: "uint256" }] },
      { name: "feeDetails", type: "tuple[]", components: [{ name: "feeAmountLD", type: "int256" }, { name: "description", type: "string" }] },
      { name: "receipt", type: "tuple", components: [{ name: "amountSentLD", type: "uint256" }, { name: "amountReceivedLD", type: "uint256" }] },
    ],
  },
  {
    type: "function",
    name: "quoteSend",
    stateMutability: "view",
    inputs: [
      { name: "sendParam", type: "tuple", components: SEND_PARAM() },
      { name: "payInLzToken", type: "bool" },
    ],
    outputs: [{ name: "fee", type: "tuple", components: FEE() }],
  },
  {
    type: "function",
    name: "send",
    stateMutability: "payable",
    inputs: [
      { name: "sendParam", type: "tuple", components: SEND_PARAM() },
      { name: "fee", type: "tuple", components: FEE() },
      { name: "refundAddress", type: "address" },
    ],
    outputs: [
      { name: "msgReceipt", type: "tuple", components: [{ name: "guid", type: "bytes32" }, { name: "nonce", type: "uint64" }, { name: "fee", type: "tuple", components: FEE() }] },
      { name: "oftReceipt", type: "tuple", components: [{ name: "amountSentLD", type: "uint256" }, { name: "amountReceivedLD", type: "uint256" }] },
    ],
  },
] as const;

function SEND_PARAM() {
  return [
    { name: "dstEid", type: "uint32" },
    { name: "to", type: "bytes32" },
    { name: "amountLD", type: "uint256" },
    { name: "minAmountLD", type: "uint256" },
    { name: "extraOptions", type: "bytes" },
    { name: "composeMsg", type: "bytes" },
    { name: "oftCmd", type: "bytes" },
  ] as const;
}

function FEE() {
  return [
    { name: "nativeFee", type: "uint256" },
    { name: "lzTokenFee", type: "uint256" },
  ] as const;
}

export interface SendParam {
  dstEid: number;
  to: Hex;
  amountLD: bigint;
  minAmountLD: bigint;
  extraOptions: Hex;
  composeMsg: Hex;
  oftCmd: Hex;
}

/** An EVM address as LayerZero's left-padded bytes32. */
export const toBytes32 = (a: Address): Hex => pad(a.toLowerCase() as Hex, { size: 32 });

/**
 * A send to `recipient` on Rootstock. Empty options on purpose: USDT0's enforced
 * options set the destination gas, and no native drop or compose is asked for. The
 * recipient is ALWAYS the connected wallet (the panel offers no other field).
 */
export function sendParamFor(recipient: Address, amountLD: bigint, minAmountLD = 0n): SendParam {
  return { dstEid: ROOTSTOCK_USDT0.eid, to: toBytes32(recipient), amountLD, minAmountLD, extraOptions: "0x", composeMsg: "0x", oftCmd: "0x" };
}

/**
 * The minimum the destination must credit: what `quoteOFT` says will arrive. Refused
 * (null) when the quote pays out less than `floorBps` of the amount — USDT0 charges no
 * OFT fee today, so a large haircut means something is wrong, not "fees".
 */
export function minReceived(amountLD: bigint, quotedReceivedLD: bigint, floorBps = 9_950n): bigint | null {
  if (quotedReceivedLD > amountLD) return null;
  if (quotedReceivedLD * 10_000n < amountLD * floorBps) return null;
  return quotedReceivedLD;
}

/** LayerZero recommends headroom over `quoteSend`'s fee; the excess is refunded to the sender. */
export const withFeeBuffer = (nativeFee: bigint): bigint => nativeFee + nativeFee / 10n;

/** The reads and writes the panel's steps make; injected so tests drive them without a wallet. */
export interface BridgeClient {
  read<T>(args: { address: Address; abi: readonly unknown[]; functionName: string; args?: readonly unknown[] }): Promise<T>;
  write(args: { address: Address; abi: readonly unknown[]; functionName: string; args: readonly unknown[]; value?: bigint }): Promise<Hex>;
  waitForReceipt(hash: Hex): Promise<{ status: "success" | "reverted" }>;
}

export interface BridgeQuote {
  amountLD: bigint;
  minAmountLD: bigint;
  /** The fee in the source chain's native coin, buffered (the excess is refunded). */
  nativeFee: bigint;
  /** Whether the OFT needs an ERC-20 allowance (an adapter locking the token: Ethereum). */
  approvalRequired: boolean;
  allowance: bigint;
  balance: bigint;
}

/** Everything the confirm step shows, from the source chain. */
export async function quoteBridge(c: BridgeClient, src: BridgeSource, owner: Address, amountLD: bigint): Promise<BridgeQuote> {
  const [balance, approvalRequired] = await Promise.all([
    c.read<bigint>({ address: src.token, abi: erc20Abi, functionName: "balanceOf", args: [owner] }),
    c.read<boolean>({ address: src.oft, abi: OFT_ABI, functionName: "approvalRequired" }).catch(() => true),
  ]);
  const allowance = approvalRequired ? await c.read<bigint>({ address: src.token, abi: erc20Abi, functionName: "allowance", args: [owner, src.oft] }) : maxUint256;
  const [, , receipt] = await c.read<readonly [unknown, unknown, { amountReceivedLD: bigint }]>({
    address: src.oft,
    abi: OFT_ABI,
    functionName: "quoteOFT",
    args: [sendParamFor(owner, amountLD)],
  });
  const minAmountLD = minReceived(amountLD, receipt.amountReceivedLD);
  if (minAmountLD === null) throw new Error("the bridge quotes an unexpected amount on arrival — not sending");
  const fee = await c.read<{ nativeFee: bigint }>({
    address: src.oft,
    abi: OFT_ABI,
    functionName: "quoteSend",
    args: [sendParamFor(owner, amountLD, minAmountLD), false],
  });
  return { amountLD, minAmountLD, nativeFee: withFeeBuffer(fee.nativeFee), approvalRequired, allowance, balance };
}

/** Approve exactly `amountLD` to the OFT adapter (only where `approvalRequired`). USDT needs a zero reset first. */
export async function approveForBridge(c: BridgeClient, src: BridgeSource, q: BridgeQuote): Promise<void> {
  if (!q.approvalRequired || q.allowance >= q.amountLD) return;
  // Ethereum USDT reverts on approve(x) while a non-zero allowance stands.
  if (q.allowance > 0n) {
    const reset = await c.write({ address: src.token, abi: erc20Abi, functionName: "approve", args: [src.oft, 0n] });
    if ((await c.waitForReceipt(reset)).status !== "success") throw new Error("resetting the allowance failed");
  }
  const tx = await c.write({ address: src.token, abi: erc20Abi, functionName: "approve", args: [src.oft, q.amountLD] });
  if ((await c.waitForReceipt(tx)).status !== "success") throw new Error("the approval failed");
}

/** The send itself. Returns the source-chain tx hash (track it on LayerZero Scan). */
export async function sendToRootstock(c: BridgeClient, src: BridgeSource, owner: Address, q: BridgeQuote): Promise<Hex> {
  return c.write({
    address: src.oft,
    abi: OFT_ABI,
    functionName: "send",
    args: [sendParamFor(owner, q.amountLD, q.minAmountLD), { nativeFee: q.nativeFee, lzTokenFee: 0n }, owner],
    value: q.nativeFee,
  });
}

/** Arrived once the Rootstock balance rose by at least the minimum since the send. */
export const arrived = (before: bigint, now: bigint, minAmountLD: bigint): boolean => now - before >= minAmountLD;
