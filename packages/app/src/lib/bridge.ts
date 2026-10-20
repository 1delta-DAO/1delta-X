import { erc20Abi, maxUint256, pad, type Address, type Hex } from "viem";

import { APPROVE_GAS_FALLBACK, layerZeroScanMessage, ROOTSTOCK_USDT0, SEND_GAS_FALLBACK, type BridgeSource } from "../config/bridge";

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

/**
 * Headroom on the source-chain gas figure: the gas price moves between quote and send,
 * and on OP-stack chains the L1 data fee is charged on top of `gasUsed × gasPrice`.
 */
export const withGasBuffer = (cost: bigint): bigint => cost + cost / 5n;

/** The reads and writes the panel's steps make; injected so tests drive them without a wallet. */
export interface BridgeClient {
  read<T>(args: { address: Address; abi: readonly unknown[]; functionName: string; args?: readonly unknown[] }): Promise<T>;
  estimateGas(args: { account: Address; address: Address; abi: readonly unknown[]; functionName: string; args: readonly unknown[]; value?: bigint }): Promise<bigint>;
  gasPrice(): Promise<bigint>;
  nativeBalance(owner: Address): Promise<bigint>;
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
  /** Approval txs before the send: 0, 1, or 2 (USDT's zero-reset first). */
  approvals: number;
  /** Source-chain gas for the approvals plus the send, buffered ({@link withGasBuffer}). */
  gasCost: bigint;
  /** Whether the send's gas came from `eth_estimateGas` (else {@link SEND_GAS_FALLBACK}). */
  gasEstimated: boolean;
  /** The sender's native balance on the source chain. */
  nativeBalance: bigint;
}

/** All the source chain's native coin the bridge takes: the LayerZero fee plus gas. */
export const nativeNeeded = (q: Pick<BridgeQuote, "nativeFee" | "gasCost">): bigint => q.nativeFee + q.gasCost;

/** The approval txs `approveForBridge` will send. */
export function approvalsNeeded(approvalRequired: boolean, allowance: bigint, amountLD: bigint): number {
  if (!approvalRequired || allowance >= amountLD) return 0;
  return allowance > 0n ? 2 : 1;
}

/**
 * Everything the confirm step shows, from the source chain: what lands, the LayerZero
 * fee, and the gas the approval(s) and the send will burn. The send's gas is estimated
 * live when it can run (no approval pending); otherwise the measured fallbacks apply.
 */
export async function quoteBridge(c: BridgeClient, src: BridgeSource, owner: Address, amountLD: bigint): Promise<BridgeQuote> {
  const [balance, approvalRequired, nativeBalance, gasPrice] = await Promise.all([
    c.read<bigint>({ address: src.token, abi: erc20Abi, functionName: "balanceOf", args: [owner] }),
    c.read<boolean>({ address: src.oft, abi: OFT_ABI, functionName: "approvalRequired" }).catch(() => true),
    c.nativeBalance(owner),
    c.gasPrice(),
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
  const nativeFee = withFeeBuffer(fee.nativeFee);
  const approvals = approvalsNeeded(approvalRequired, allowance, amountLD);
  let sendGas = SEND_GAS_FALLBACK;
  let gasEstimated = false;
  if (approvals === 0 && balance >= amountLD && nativeBalance >= nativeFee) {
    try {
      sendGas = await c.estimateGas({
        account: owner,
        address: src.oft,
        abi: OFT_ABI,
        functionName: "send",
        args: [sendParamFor(owner, amountLD, minAmountLD), { nativeFee, lzTokenFee: 0n }, owner],
        value: nativeFee,
      });
      gasEstimated = true;
    } catch {
      // A node that will not simulate: the fallback stands.
    }
  }
  const gasCost = withGasBuffer((sendGas + APPROVE_GAS_FALLBACK * BigInt(approvals)) * gasPrice);
  return { amountLD, minAmountLD, nativeFee, approvalRequired, allowance, balance, approvals, gasCost, gasEstimated, nativeBalance };
}

/** Approve exactly `amountLD` to the OFT adapter (only where `approvalRequired`). USDT needs a zero reset first. */
export async function approveForBridge(c: BridgeClient, src: BridgeSource, q: BridgeQuote): Promise<void> {
  if (approvalsNeeded(q.approvalRequired, q.allowance, q.amountLD) === 0) return;
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

// ── Tracing a bridge in flight ────────────────────────────────────────────────────

/**
 * What the panel knows about a sent bridge, from LayerZero Scan's message API
 * ({@link layerZeroScanMessage}) — the SAME source the "Track on LayerZero Scan" link
 * opens, so the panel and the explorer never disagree:
 *   - `sourceConfirmed`: the source tx succeeded AND the DVNs have the confirmations they
 *     wait for (Scan reports the source as SUCCEEDED only then);
 *   - `stage`: "inflight" until Rootstock credits it, "delivered" with the Rootstock tx,
 *     "failed" when Scan reports FAILED / BLOCKED / PAYLOAD_STORED — a message that needs
 *     LayerZero's retry or the user's attention, which the balance poll could never show.
 * The balance poll stays as the fallback when the API is unreachable or has not indexed
 * the tx yet (`traceFromScan` returns null then).
 */
export interface BridgeTrace {
  stage: "inflight" | "delivered" | "failed";
  sourceConfirmed: boolean;
  /** The Rootstock tx that credited the USD₮0 (stage "delivered"). */
  dstTx?: Hex;
  /** Scan's own wording for the status (shown on "failed"). */
  detail?: string;
}

/** The statuses Scan reports that mean "this will not land on its own". */
const STUCK = new Set(["FAILED", "BLOCKED", "PAYLOAD_STORED", "APPLICATION_BURNED", "APPLICATION_SKIPPED", "UNRESOLVABLE_COMMAND"]);

/**
 * Map Scan's `GET /messages/tx/{hash}` body to a {@link BridgeTrace} for the message
 * bound for `dstEid` (a source tx emits one message per OFT send; any other message in
 * the same tx — a compose, another app — is skipped). Null when nothing is indexed yet,
 * or the body is not what Scan documents: the caller falls back to the balance poll,
 * never to a guess.
 */
export function traceFromScan(body: unknown, dstEid: number): BridgeTrace | null {
  const data = (body as { data?: unknown } | null)?.data;
  if (!Array.isArray(data)) return null;
  for (const m of data as Array<Record<string, unknown>>) {
    const pathway = m.pathway as { dstEid?: unknown } | undefined;
    if (pathway?.dstEid !== dstEid) continue;
    const name = String((m.status as { name?: unknown } | undefined)?.name ?? "").toUpperCase();
    const source = m.source as { status?: unknown } | undefined;
    const destination = m.destination as { tx?: { txHash?: unknown } } | undefined;
    const sourceConfirmed = String(source?.status ?? "").toUpperCase() === "SUCCEEDED";
    const detail = (m.status as { message?: unknown } | undefined)?.message;
    if (name === "DELIVERED") {
      const h = destination?.tx?.txHash;
      return { stage: "delivered", sourceConfirmed: true, ...(typeof h === "string" && /^0x[0-9a-fA-F]{64}$/.test(h) ? { dstTx: h as Hex } : {}) };
    }
    if (STUCK.has(name)) return { stage: "failed", sourceConfirmed, detail: typeof detail === "string" ? detail : name };
    return { stage: "inflight", sourceConfirmed };
  }
  return null;
}

/** One poll of the Scan API; null when it is unreachable, rate-limited or has not indexed the tx. */
export async function fetchTrace(txHash: Hex, dstEid: number, fetchFn: typeof fetch = fetch, signal?: AbortSignal): Promise<BridgeTrace | null> {
  try {
    const res = await fetchFn(layerZeroScanMessage(txHash), { signal, headers: { accept: "application/json" } });
    if (!res.ok) return null;
    return traceFromScan(await res.json(), dstEid);
  } catch {
    return null;
  }
}

// ── The pending bridge, kept across a closed panel or a reload ────────────────────

/**
 * A sent bridge, remembered in this browser until it lands: closing the panel, or the
 * tab, must not lose the tx hash (the only handle on the message) nor the balance the
 * arrival check compares against. One per owner — the panel sends one bridge at a time.
 * Amounts are decimal strings (JSON has no bigint).
 */
export interface PendingBridge {
  owner: Address;
  srcKey: string;
  tx: Hex;
  /** The owner's Rootstock USD₮0 balance just before the send. */
  before: string;
  minAmountLD: string;
  amountLD: string;
  /** When the send was accepted by the wallet (ms). */
  at: number;
}

export interface KeyValue {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

const PENDING_KEY = (owner: Address) => `bridge:pending:${owner.toLowerCase()}`;

function storage(): KeyValue | null {
  try {
    return typeof window === "undefined" ? null : window.localStorage;
  } catch {
    return null; // a private window that throws on access
  }
}

export function savePending(p: PendingBridge, kv: KeyValue | null = storage()): void {
  try {
    kv?.setItem(PENDING_KEY(p.owner), JSON.stringify(p));
  } catch {
    // storage full or blocked: the panel still tracks this session
  }
}

export function loadPending(owner: Address, kv: KeyValue | null = storage()): PendingBridge | null {
  try {
    const raw = kv?.getItem(PENDING_KEY(owner));
    if (!raw) return null;
    const p = JSON.parse(raw) as Partial<PendingBridge>;
    if (typeof p.tx !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(p.tx) || typeof p.srcKey !== "string" || typeof p.at !== "number") return null;
    if (![p.before, p.minAmountLD, p.amountLD].every((v) => typeof v === "string" && /^\d+$/.test(v))) return null;
    return { owner, srcKey: p.srcKey, tx: p.tx as Hex, before: p.before!, minAmountLD: p.minAmountLD!, amountLD: p.amountLD!, at: p.at };
  } catch {
    return null;
  }
}

export function clearPending(owner: Address, kv: KeyValue | null = storage()): void {
  try {
    kv?.removeItem(PENDING_KEY(owner));
  } catch {
    // nothing to clear
  }
}

// ── The arrival time, as observed from this browser ───────────────────────────────

const ETA_KEY = (srcKey: string) => `bridge:eta:${srcKey}`;
/** Observations kept per source chain (the median of these is shown). */
const ETA_KEEP = 8;

/** Remember how long a bridge from `srcKey` took, whole minutes (sub-minute = 1). */
export function recordEta(srcKey: string, minutes: number, kv: KeyValue | null = storage()): void {
  if (!Number.isFinite(minutes) || minutes <= 0) return;
  try {
    const seen = readEtas(srcKey, kv);
    seen.push(Math.max(1, Math.round(minutes)));
    kv?.setItem(ETA_KEY(srcKey), JSON.stringify(seen.slice(-ETA_KEEP)));
  } catch {
    // display only
  }
}

function readEtas(srcKey: string, kv: KeyValue | null): number[] {
  try {
    const raw = kv?.getItem(ETA_KEY(srcKey));
    const v = raw ? (JSON.parse(raw) as unknown) : [];
    return Array.isArray(v) ? v.filter((n): n is number => typeof n === "number" && Number.isFinite(n) && n > 0) : [];
  } catch {
    return [];
  }
}

/**
 * The minutes to show for a bridge from `srcKey`: the median of what this browser has
 * seen from that chain, else the table default. `observed` says how many bridges the
 * figure rests on (0 = the default).
 */
export function etaMinutesFor(srcKey: string, fallback: number, kv: KeyValue | null = storage()): { minutes: number; observed: number } {
  const seen = readEtas(srcKey, kv).sort((a, b) => a - b);
  if (seen.length === 0) return { minutes: fallback, observed: 0 };
  const mid = seen.length >> 1;
  const median = seen.length % 2 ? seen[mid]! : Math.round((seen[mid - 1]! + seen[mid]!) / 2);
  return { minutes: median, observed: seen.length };
}
