import { PERMIT3_ABI } from "@1delta-x/sdk";
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
]);

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

/** Both funding legs for one (maker, token) — see `lib/funding.ts`. */
export async function readFundingState(
  reader: Reader,
  p: { token: Address; owner: Address; permit3: Address; settlement: Address },
): Promise<FundingState> {
  const [erc20Allowance, grant] = await Promise.all([
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
  ]);
  return { erc20Allowance, grantAmount: grant[0], grantExpiration: Number(grant[1]) };
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
