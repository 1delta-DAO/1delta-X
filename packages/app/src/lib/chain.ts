import { isFillOnce, PERMIT3_ABI, type Order } from "@1delta-x/sdk";
import { erc20Abi, isAddressEqual, parseAbi, type Address } from "viem";

import type { FundingState } from "./funding";

/**
 * The on-chain reads the sign path depends on, over any `readContract`
 * surface (a viem PublicClient on the wallet's provider satisfies it).
 */
export interface Reader {
  readContract(args: {
    address: Address;
    abi: readonly unknown[];
    functionName: string;
    args?: readonly unknown[];
  }): Promise<unknown>;
}

const SETTLEMENT_READS = parseAbi([
  "function PERMIT3() view returns (address)",
  "function minValidNonce(address) view returns (uint256)",
  "function nonceBitmap(address,uint256) view returns (uint256)",
  "function filled(bytes32) view returns (uint256)",
  "function isNonceCancelled(address,uint256) view returns (bool)",
]);

/**
 * `Settlement.filled(orderHash)`: cumulative filled amount in the order's ANCHOR
 * units; `type(uint256).max` = cancelled on-chain (OrderState.sol). The key is the
 * SDK's struct hash (`SignedOrder.hash`).
 */
export async function readFilled(reader: Reader, settlement: Address, orderHash: `0x${string}`): Promise<bigint> {
  return (await reader.readContract({
    address: settlement,
    abi: SETTLEMENT_READS,
    functionName: "filled",
    args: [orderHash],
  })) as bigint;
}

/**
 * What the chain says about one signed order (see `chainFillOutcome` in
 * lib/orderLifecycle.ts for how it is read):
 *   • `filled` — `Settlement.filled(hash)` (anchor wei; max = cancelled by hash);
 *   • `nonceConsumed` — for a FILL-ONCE order only (`timing` bit 100):
 *     `isNonceCancelled(maker, nonce)`. Such an order's fill sets the nonce bit
 *     INSTEAD of writing `filled`, which stays 0 — the bit is the only on-chain
 *     trace of the fill, and a nonce cancel leaves the very same trace.
 */
export interface ChainFillState {
  filled: bigint;
  nonceConsumed: boolean;
}

/** `filled(hash)`, plus the nonce bit for a fill-once order (one extra read, only then). */
export async function readFillState(
  reader: Reader,
  settlement: Address,
  order: Pick<Order, "maker" | "nonce" | "timing">,
  orderHash: `0x${string}`,
): Promise<ChainFillState> {
  const once = isFillOnce(order as Order);
  const [filled, nonceConsumed] = await Promise.all([
    readFilled(reader, settlement, orderHash),
    once
      ? (reader.readContract({
          address: settlement,
          abi: SETTLEMENT_READS,
          functionName: "isNonceCancelled",
          args: [order.maker, order.nonce],
        }) as Promise<boolean>)
      : Promise.resolve(false),
  ]);
  return { filled, nonceConsumed };
}

/**
 * Throw unless the configured Settlement really is wired to the configured
 * Permit3.
 *
 * The approval the app asks for names `permit3` from VITE_DEPLOYMENTS; a typo
 * there would have every user approve an arbitrary address. Settlement's own
 * immutable `PERMIT3()` is the authority, so the app checks it before it
 * offers any approval (G-TS_SIGN-14).
 */
export async function verifyDeployment(
  reader: Reader,
  d: { settlement: Address; permit3: Address },
): Promise<void> {
  const wired = (await reader.readContract({
    address: d.settlement,
    abi: SETTLEMENT_READS,
    functionName: "PERMIT3",
  })) as Address;
  if (!isAddressEqual(wired, d.permit3)) {
    throw new Error(`deployment mismatch: Settlement uses Permit3 ${wired}, config names ${d.permit3}`);
  }
}

/** The maker's nonce watermark: order nonces below it are dead. */
export async function readMinValidNonce(reader: Reader, settlement: Address, maker: Address): Promise<bigint> {
  return (await reader.readContract({
    address: settlement,
    abi: SETTLEMENT_READS,
    functionName: "minValidNonce",
    args: [maker],
  })) as bigint;
}

/**
 * The maker's nonce-bitmap word `wordPos`: bit `b` set ⇔ order nonce `(wordPos << 8) | b`
 * is cancelled (or consumed by a fill-once fill). NonceManager's public mapping getter.
 */
export async function readNonceWord(reader: Reader, settlement: Address, maker: Address, wordPos: bigint): Promise<bigint> {
  return (await reader.readContract({
    address: settlement,
    abi: SETTLEMENT_READS,
    functionName: "nonceBitmap",
    args: [maker, wordPos],
  })) as bigint;
}

/** Both funding legs for one (maker, token) — see `lib/funding.ts`. */
export async function readFundingState(
  reader: Reader,
  p: { token: Address; owner: Address; permit3: Address; settlement: Address },
): Promise<FundingState> {
  const [erc20Allowance, grant, directAllowance, strict] = await Promise.all([
    reader.readContract({
      address: p.token,
      abi: erc20Abi,
      functionName: "allowance",
      args: [p.owner, p.permit3],
    }) as Promise<bigint>,
    reader.readContract({
      address: p.permit3,
      abi: PERMIT3_ABI,
      functionName: "tokenAllowance",
      args: [p.owner, p.settlement, p.token],
    }) as Promise<readonly [bigint, number]>,
    // The second funding surface: a DIRECT ERC-20 allowance to Settlement, which a
    // relayed ERC-2612 permit creates (lib/permit.ts) and Settlement's pull falls
    // back to unless the maker is in Permit3 strict mode.
    reader.readContract({
      address: p.token,
      abi: erc20Abi,
      functionName: "allowance",
      args: [p.owner, p.settlement],
    }) as Promise<bigint>,
    reader.readContract({
      address: p.permit3,
      abi: PERMIT3_ABI,
      functionName: "isStrict",
      args: [p.owner, p.token],
    }) as Promise<boolean>,
  ]);
  return { erc20Allowance, grantAmount: grant[0], grantExpiration: Number(grant[1]), directAllowance, strict };
}

/** The non-contract reads the market floor needs (a viem PublicClient satisfies it). */
export interface GasReader {
  getGasPrice(): Promise<bigint>;
  getBlock?(args: { blockTag: "latest" }): Promise<unknown>;
}

/** rskj's `eth_gasPrice` = bestBlock.minimumGasPrice × 1.1 (`rpc.minGasPriceMultiplier`). */
const RSKJ_ETH_GAS_PRICE_NUM = 11n;
const RSKJ_ETH_GAS_PRICE_DEN = 10n;

/** A JSON-RPC quantity (hex / decimal string, bigint, safe integer) → bigint, else undefined. */
function quantity(v: unknown): bigint | undefined {
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
 * The gas price the beta filler SENDS at — ⌈latestBlock.minimumGasPrice × multBps /
 * 10000⌉ (packages/beta-filler chain.ts `readSendGasPrice`; `multBps` =
 * FILLER_GAS_PRICE_MIN_MULT_BPS) — which sizes small market tickets' floor
 * (lib/marketFloor.ts). Without the block field (not Rootstock, a provider that strips
 * it): `eth_gasPrice` / 1.1 (rskj's buffer) × the same multiplier. `null` when both
 * reads fail or answer nonsense; the caller then uses the chain's fallback, never zero
 * (a zero gas price would quietly drop the gas term and sign an unfillable floor).
 */
export async function readGasPrice(reader: GasReader, multBps: number): Promise<bigint | null> {
  const mult = BigInt(multBps);
  const scale = (min: bigint) => (min * mult + 9_999n) / 10_000n;
  if (reader.getBlock) {
    try {
      const block = (await reader.getBlock({ blockTag: "latest" })) as { minimumGasPrice?: unknown } | null;
      const min = quantity(block?.minimumGasPrice);
      if (min !== undefined && min > 0n) return scale(min);
    } catch {
      // eth_gasPrice below
    }
  }
  try {
    const wei = await reader.getGasPrice();
    if (typeof wei !== "bigint" || wei <= 0n) return null;
    const min = (wei * RSKJ_ETH_GAS_PRICE_DEN) / RSKJ_ETH_GAS_PRICE_NUM;
    return min > 0n ? scale(min) : null;
  } catch {
    return null;
  }
}

/**
 * Multiplier for the app's OWN transactions (wrap, approve, Permit3 grant, unwrap,
 * on-chain cancel) on Rootstock: the block `minimumGasPrice` + 1 %. Rootstock has no
 * fee auction — a block includes every tx at or above its minimum, so paying more
 * buys nothing unless blocks are full — and consensus lets the minimum move at most
 * ±1 % per block (RSKIP-09), so +1 % survives one maximal rise between read and
 * inclusion. Wallets otherwise send at `eth_gasPrice` = minimum + 10 %.
 */
export const USER_GAS_PRICE_MULT_BPS = 10_100;

/** Rootstock mainnet / testnet: the chains whose blocks carry `minimumGasPrice`. */
const MIN_GAS_PRICE_CHAINS = new Set([30, 31]);

/**
 * Gas-price fields to spread into a wallet `sendTransaction` / `writeContract`:
 * `{ type: "legacy", gasPrice }` at the Rootstock floor + 1 %, or `{}` (let the wallet
 * price it) on other chains or when the price cannot be read.
 */
export async function userTxGas(reader: GasReader, chainId: number): Promise<{ type: "legacy"; gasPrice: bigint } | Record<string, never>> {
  if (!MIN_GAS_PRICE_CHAINS.has(chainId)) return {};
  const gasPrice = await readGasPrice(reader, USER_GAS_PRICE_MULT_BPS);
  return gasPrice ? { type: "legacy", gasPrice } : {};
}
