import { encodeFunctionData, keccak256, type Address, type Hex } from "viem";

import { PERMIT3_ABI, TAKER_MODULE_DESCRIBE_ABI } from "./abi";
import { PERMIT_TAKE_TYPES, permit3Domain } from "./eip712";
import type { TypedDataSigner } from "./orders";
import type {
  Deployment,
  PermitBatch,
  PermitTake,
  SpenderRefPair,
  TokenSpenderPair,
} from "./types";

/**
 * Direct Permit3 helpers — typed-data + calldata for the hub's own surface, which
 * the order/settlement helpers never reach (they only sign a `permitBatch` witness
 * for `fillWithPermit`). This covers on-chain grants, the taker book, the one-shot
 * `permitTake`, strict mode and combined revocation.
 */

// ──────────────────── refs & builders ────────────────────

/** Taker-book position key for a module's `data`: `keccak256(data)`. Equals the
 *  contract's `refFor(data)`. */
export function refFor(data: Hex): Hex {
  return keccak256(data);
}

export function permitTake(module: Address, ref: Hex, amount: bigint, nonce: bigint, deadline: bigint): PermitTake {
  return { module, ref, amount, nonce, deadline };
}

export function tokenSpenderPair(token: Address, spender: Address): TokenSpenderPair {
  return { token, spender };
}

export function spenderRefPair(spender: Address, module: Address, ref: Hex): SpenderRefPair {
  return { spender, module, ref };
}

// ──────────────────── permitTake signing ────────────────────

/**
 * EIP-712 payload for a one-shot `permitTake` (Permit3 domain). `spender` is the
 * address that will submit the `permitTake` call — it is bound into the digest, so
 * a leaked signature is useless to any other caller. Pass the consuming contract
 * (e.g. your settlement/router) as `spender`.
 */
export function permitTakeTypedData(permit: PermitTake, spender: Address, d: Deployment) {
  return {
    domain: permit3Domain(d.chainId, d.permit3),
    types: PERMIT_TAKE_TYPES,
    primaryType: "PermitTake" as const,
    message: {
      module: permit.module,
      ref: permit.ref,
      amount: permit.amount,
      spender,
      nonce: permit.nonce,
      deadline: permit.deadline,
    } as unknown as Record<string, unknown>,
  };
}

/** Sign a one-shot `permitTake` (owner → 65-byte signature). */
export function signPermitTake(
  signer: TypedDataSigner,
  permit: PermitTake,
  spender: Address,
  d: Deployment,
): Promise<Hex> {
  return signer.signTypedData(permitTakeTypedData(permit, spender, d));
}

// ──────────────────── calldata encoders ────────────────────

const enc = (functionName: string, args: readonly unknown[]): Hex =>
  encodeFunctionData({ abi: PERMIT3_ABI, functionName: functionName as never, args: args as never });

// Token book
export const encodeApproveToken = (spender: Address, token: Address, amount: bigint, expiration: number): Hex =>
  enc("approveToken", [spender, token, amount, expiration]);
export const encodeRevokeToken = (spender: Address, token: Address): Hex => enc("revokeToken", [spender, token]);
export const encodeLockdown = (approvals: readonly TokenSpenderPair[]): Hex => enc("lockdown", [approvals]);

// Taker book
export const encodeApproveTaker = (
  spender: Address,
  module: Address,
  ref: Hex,
  amount: bigint,
  expiration: number,
): Hex => enc("approveTaker", [spender, module, ref, amount, expiration]);
export const encodeTake = (module: Address, user: Address, amount: bigint, receiver: Address, data: Hex): Hex =>
  enc("take", [module, user, amount, receiver, data]);
export const encodeRevokeTaker = (spender: Address, module: Address, ref: Hex): Hex =>
  enc("revokeTaker", [spender, module, ref]);
export const encodeLockdownTakers = (approvals: readonly SpenderRefPair[]): Hex => enc("lockdownTakers", [approvals]);

// Strict mode
export const encodeSetStrictMode = (enabled: boolean): Hex => enc("setStrictMode", [enabled]);

// Signed grants / one-shot take
export const encodePermitBatch = (owner: Address, batch: PermitBatch, sig: Hex): Hex =>
  enc("permitBatch", [owner, batch, sig]);
export const encodePermitTake = (permit: PermitTake, owner: Address, receiver: Address, data: Hex, sig: Hex): Hex =>
  enc("permitTake", [permit, owner, receiver, data, sig]);
export const encodeInvalidateUnorderedNonces = (wordPos: bigint, mask: bigint): Hex =>
  enc("invalidateUnorderedNonces", [wordPos, mask]);

// Combined revocation
export const encodeLockdownAll = (
  tokens: readonly TokenSpenderPair[],
  takers: readonly SpenderRefPair[],
  nonceWords: readonly bigint[],
  nonceMasks: readonly bigint[],
): Hex => enc("lockdownAll", [tokens, takers, nonceWords, nonceMasks]);

// ──────────────────── combined "revoke everything" bundler ────────────────────

/** One call the user's account should send (to → calldata). Batch these via
 *  EIP-5792 / a multisend / an EIP-7702 account, or send sequentially. */
export interface RevokeCall {
  to: Address;
  data: Hex;
}

/**
 * Assemble every revocation an integrator wants to fire at once. `lockdownAll`
 * collapses the Permit3 side — token grants, taker grants and signed-permit nonces
 * — into ONE call to the hub; the protocol-native delegations
 * (`approveDelegation` / `comet.allow` / `setAuthorization`) live in their own
 * contracts and can only be revoked there, so the caller supplies those as
 * `protocolRevokes`. This is deliberately caller-driven and NOT an on-chain shared
 * helper: a contract that made arbitrary protocol calls from one address would be a
 * confused deputy. The returned calls all execute from the USER's own account.
 *
 * @returns the ordered calls to send (Permit3 `lockdownAll` first, then the
 *          protocol-native revokes). Empty if there is nothing to revoke.
 */
export function buildRevokeAll(params: {
  permit3: Address;
  tokens?: readonly TokenSpenderPair[];
  takers?: readonly SpenderRefPair[];
  nonces?: readonly { word: bigint; mask: bigint }[];
  protocolRevokes?: readonly RevokeCall[];
}): RevokeCall[] {
  const tokens = params.tokens ?? [];
  const takers = params.takers ?? [];
  const nonces = params.nonces ?? [];
  const protocolRevokes = params.protocolRevokes ?? [];

  const calls: RevokeCall[] = [];
  if (tokens.length || takers.length || nonces.length) {
    calls.push({
      to: params.permit3,
      data: encodeLockdownAll(
        tokens,
        takers,
        nonces.map((n) => n.word),
        nonces.map((n) => n.mask),
      ),
    });
  }
  calls.push(...protocolRevokes);
  return calls;
}

// ──────────────────── human-readable taker descriptions (U-5) ────────────────────

/** Minimal contract-read surface a viem `PublicClient` satisfies. */
export interface ContractReader {
  readContract(args: { address: Address; abi: unknown; functionName: string; args: readonly unknown[] }): Promise<unknown>;
}

/**
 * Best-effort human-readable description of a taker position, by calling a module's
 * OPTIONAL `describe(data)` view — "Borrow 1,000 USDC from Aave v3" for an approval
 * dialog, instead of an opaque `ref`. This is a per-module read the frontend makes
 * directly (it already holds the TAKE item's `data`), rather than an on-chain lens
 * method — batching it on the settlement lens put that size-critical contract over
 * EIP-170. A module that does not implement `describe` (or reverts) yields `null`,
 * so the caller falls back to rendering the raw ref.
 *
 * @param reader a viem `PublicClient` (or anything with `readContract`)
 * @param module the taker module the allowance authorises
 * @param data   the exact bytes the module decodes — `keccak256(data)` is the ref
 */
export async function readTakerDescription(
  reader: ContractReader,
  module: Address,
  data: Hex,
): Promise<string | null> {
  try {
    const s = await reader.readContract({
      address: module,
      abi: TAKER_MODULE_DESCRIBE_ABI,
      functionName: "describe",
      args: [data],
    });
    return typeof s === "string" ? s : null;
  } catch {
    return null;
  }
}
