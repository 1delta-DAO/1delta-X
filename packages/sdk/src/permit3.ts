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
import { assertPermit3Nonce, Permit3MessageKind } from "./permit3nonce";

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

/** ⚠ Nonce must come from `permit3Nonce(Permit3MessageKind.Take, seq)` — see {@link assertPermit3Nonce}. */
export function permitTake(module: Address, ref: Hex, amount: bigint, nonce: bigint, deadline: bigint): PermitTake {
  return { module, ref, amount, nonce: assertPermit3Nonce(nonce, Permit3MessageKind.Take), deadline };
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
/// Per-token strict mode: the same refusal of the direct-approval fallback as
/// {@link encodeSetStrictMode}, scoped to ONE token instead of the whole portfolio.
/// A direct ERC20 approval is itself per-token, so this matches the granularity the
/// exposure actually has — harden the token you hold a standing approval on without
/// giving up the fallback everywhere else. The two flags OR together on-chain.
export const encodeSetStrictModeToken = (token: Address, enabled: boolean): Hex =>
  enc("setStrictModeToken", [token, enabled]);

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
 * ⚠ THERE ARE TWO FUNDING SURFACES, AND CLEARING ONE IS NOT REVOKING.
 * `Permit3TransferLib.transferFromWithFallback` tries the Permit3 leg and, when it
 * fails for ANY reason — missing, capped, expired, or deliberately revoked — falls
 * through to a plain `token.transferFrom`. So for a payer who ALSO granted a direct
 * ERC-20 approval to the settlement, `lockdownAll` alone stops nothing: the fallback
 * funds the very same pull. Pass those tokens as `directApprovals` and they are
 * zeroed in the same bundle. `strictMode: true` additionally makes the Permit3 book
 * the only funding path going forward, so a future direct approval cannot silently
 * re-open the hole — this is the durable fix, and `buildStrictOnboarding` sets it at
 * account setup so a revocation never has to.
 *
 * Order matters and is not cosmetic: strict mode is set FIRST, so that even if the
 * bundle is sent as separate transactions and a fill lands between them, the
 * fallback is already closed.
 *
 * @returns the ordered calls to send. Empty if there is nothing to revoke.
 */
export function buildRevokeAll(params: {
  permit3: Address;
  tokens?: readonly TokenSpenderPair[];
  takers?: readonly SpenderRefPair[];
  nonces?: readonly { word: bigint; mask: bigint }[];
  /** Direct ERC-20 approvals to zero — the fallback funding surface. Each entry is
   *  the `(token, spender)` pair the payer approved, usually spender = settlement. */
  directApprovals?: readonly TokenSpenderPair[];
  /** Also enable Permit3 strict mode, closing the fallback permanently. Recommended
   *  whenever the caller is revoking rather than merely trimming a grant. */
  strictMode?: boolean;
  protocolRevokes?: readonly RevokeCall[];
}): RevokeCall[] {
  const tokens = params.tokens ?? [];
  const takers = params.takers ?? [];
  const nonces = params.nonces ?? [];
  const directApprovals = params.directApprovals ?? [];
  const protocolRevokes = params.protocolRevokes ?? [];

  const calls: RevokeCall[] = [];
  if (params.strictMode) {
    calls.push({ to: params.permit3, data: encodeSetStrictMode(true) });
  }
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
  // One `approve(spender, 0)` per direct grant, sent to the TOKEN, not to the hub —
  // the hub has no authority over an allowance it was never part of.
  for (const { token, spender } of directApprovals) {
    calls.push({
      to: token,
      data: encodeFunctionData({ abi: ERC20_APPROVE_ABI, functionName: "approve", args: [spender, 0n] }),
    });
  }
  calls.push(...protocolRevokes);
  return calls;
}

const ERC20_APPROVE_ABI = [
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "allowance",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

// ──────────────────── funding posture (the two-surface view) ────────────────────

/** What can actually move one of a payer's tokens, across BOTH funding surfaces. */
export interface FundingPosture {
  /** Live Permit3 grant to `spender` (0 if never granted or already lapsed). */
  permit3Amount: bigint;
  /** Permit3 expiry; `0` means never expires (note: the OPPOSITE of Permit2). */
  permit3Expiration: number;
  /** Live direct ERC-20 allowance to `spender` — the fallback surface. */
  directAllowance: bigint;
  /** Whether the payer has opted into strict mode, which disables the fallback. */
  strictMode: boolean;
  /**
   * `true` when the token is still spendable through the direct allowance even
   * though the Permit3 grant is gone or lapsed. THIS is the state a "revoked"
   * badge in a wallet UI would otherwise get wrong.
   */
  fallbackIsLoadBearing: boolean;
}

/**
 * Read both funding surfaces for one `(payer, token, spender)` and say plainly
 * whether revoking Permit3 would actually stop a fill.
 *
 * Deliberately an SDK read rather than a `SettlementLens` method: the lens is
 * hard against EIP-170 (a 237-byte addition already put it over once), and this is
 * three plain `eth_call`s a frontend can batch itself. `SettlementLens`'s own
 * `getOrderRelevantState` already folds the max of the two books into its fillable
 * figure — which is correct for previewing a fill, and precisely why it cannot also
 * answer "did my revoke work?".
 */
export async function readFundingPosture(
  reader: ContractReader,
  params: { permit3: Address; token: Address; owner: Address; spender: Address },
): Promise<FundingPosture> {
  const [grant, direct, strict] = await Promise.all([
    reader.readContract({
      address: params.permit3,
      abi: PERMIT3_ABI,
      functionName: "tokenAllowance",
      args: [params.owner, params.spender, params.token],
    }) as Promise<readonly [bigint, number]>,
    reader.readContract({
      address: params.token,
      abi: ERC20_APPROVE_ABI,
      functionName: "allowance",
      args: [params.owner, params.spender],
    }) as Promise<bigint>,
    reader.readContract({
      address: params.permit3,
      abi: PERMIT3_ABI,
      functionName: "strictMode",
      args: [params.owner],
    }) as Promise<boolean>,
  ]);

  const [amount, expiration] = grant;
  // `expiration === 0` means NEVER EXPIRES in Permit3 (Permit2 means the opposite).
  const lapsed = expiration !== 0 && BigInt(expiration) < BigInt(Math.floor(Date.now() / 1000));
  const permit3Live = lapsed ? 0n : amount;

  return {
    permit3Amount: permit3Live,
    permit3Expiration: expiration,
    directAllowance: direct,
    strictMode: strict,
    fallbackIsLoadBearing: !strict && direct > 0n && permit3Live === 0n,
  };
}

// ──────────────────── onboarding ────────────────────

/**
 * The recommended account setup: enable strict mode, THEN grant through Permit3.
 *
 * Ordering is the point. Strict mode makes the Permit3 book the only path that can
 * move the payer's tokens, so from here on `revokeToken` / `lockdown` / an expiry
 * are real kill switches rather than advisory ones — which is what a user assumes
 * they already are. The flag is read only on an ALREADY-FAILED Permit3 leg, so it
 * costs nothing on the fill hot path and nothing at all for a payer whose grants
 * are in order.
 *
 * The trade, stated so an integrator can decline it deliberately: a payer in strict
 * mode who holds only a direct ERC-20 approval can no longer be filled at all. That
 * is the intended behaviour — it is the difference between "revoked" and "revoked
 * unless you happen to have approved us some other way" — but an integrator
 * migrating existing users should grant through Permit3 in the same bundle, which
 * is exactly what this returns.
 */
export function buildStrictOnboarding(params: {
  permit3: Address;
  spender: Address;
  tokens: readonly { token: Address; amount: bigint; expiration: number }[];
  /** Set `false` to grant without strict mode (not recommended — see above). */
  strictMode?: boolean;
}): RevokeCall[] {
  const calls: RevokeCall[] = [];
  if (params.strictMode !== false) {
    calls.push({ to: params.permit3, data: encodeSetStrictMode(true) });
  }
  for (const t of params.tokens) {
    calls.push({
      to: params.permit3,
      data: encodeApproveToken(params.spender, t.token, t.amount, t.expiration),
    });
  }
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
