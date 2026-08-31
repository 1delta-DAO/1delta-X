import { encodeFunctionData, type Address, type Hex } from "viem";

import { SETTLEMENT_ABI } from "./abi";
import { settlementDomain } from "./eip712";
import type { TypedDataSigner } from "./orders";
import type { Deployment } from "./types";

/**
 * Maker-delegated order signing — the client half.
 *
 * A maker nominates another key to produce order signatures on its behalf
 * (`Settlement.setOrderSigner`), bounded so the delegate can author exactly the
 * orders the nominator could have authored itself: the registry is keyed by
 * `msg.sender` on write and by `order.maker` on read, and the order hash commits
 * to `maker`. See `docs/delegated-signers.md`.
 *
 * This module carries the three things the contract expects a client to know and
 * which previously lived only in Solidity comments:
 *
 *   1. {@link SIGNER_NONCE_NS} — the reserved half of the nonce bitmap. Order
 *      nonces MUST stay below it; the settler does not enforce that, on purpose.
 *   2. the `OrderSignerPermit` EIP-712 type, for gasless nomination.
 *   3. {@link encodeRevokeOrderSigner} — revocation that actually sticks.
 */

// ──────────────────── The reserved nonce half ────────────────────

/**
 * `NonceManager.SIGNER_NONCE_NS` — bit 255. An `OrderSignerPermit` is consumed at
 * `nonce | SIGNER_NONCE_NS`, a coordinate an ORDER can therefore never occupy,
 * so relaying a nomination can never pull the nonce out from under a live order.
 * (Shared order nonces are not exotic — that is exactly how an OCO bracket is
 * built — which is why the two artifacts needed disjoint halves.)
 *
 * ⚠ The settler does NOT check that an order's nonce has bit 255 clear: that
 * would put a compare on the hot path of every fill forever, to guard a range no
 * allocator picks. Guarding it is the builder's job — {@link assertOrderNonce}.
 */
export const SIGNER_NONCE_NS = 1n << 255n;

/** Whether `nonce` lands in the reserved (signer-permit) half of the bitmap. */
export function isReservedNonce(nonce: bigint): boolean {
  return (nonce & SIGNER_NONCE_NS) !== 0n;
}

/**
 * Throw unless `nonce` is a legal ORDER nonce. Call this wherever order nonces
 * are allocated: an order signed with bit 255 set shares a bitmap coordinate
 * with a nomination permit, so relaying that permit would silently cancel the
 * order (or vice versa).
 */
export function assertOrderNonce(nonce: bigint): bigint {
  if (nonce < 0n) throw new Error(`order nonce out of range: ${nonce}`);
  if (isReservedNonce(nonce)) {
    throw new Error(
      `order nonce ${nonce} has bit 255 set, which is reserved for OrderSignerPermit ` +
        `(NonceManager.SIGNER_NONCE_NS). Order nonces must be < 2^255.`,
    );
  }
  return nonce;
}

/**
 * The permit nonce for a given delegate, derived DETERMINISTICALLY from the
 * delegate address rather than drawn from a counter.
 *
 * This is what makes revocation reliable. A permit is consumed only when it is
 * RELAYED, so a maker who signs a nomination, never has it relayed, and then
 * revokes with `setOrderSigner(d, 0)` is still exposed: whoever holds that
 * message can relay it later and the delegate is live again, up to its
 * `deadline`. The fix is to burn the permit's bitmap coordinate as part of
 * revoking — which is only possible if the coordinate can be recomputed without
 * bookkeeping. Deriving it from the delegate address makes that true for any
 * client, at any later date, with no stored state.
 *
 * `seq` distinguishes successive nominations of the SAME delegate (each burn
 * retires one coordinate, so re-nominating a previously revoked delegate
 * gaslessly needs the next `seq`).
 */
export function signerPermitNonce(delegate: Address, seq = 0): bigint {
  if (!Number.isInteger(seq) || seq < 0 || seq > 0xffff) {
    throw new Error(`signerPermitNonce: seq out of range: ${seq}`);
  }
  return (BigInt(delegate) << 16n) | BigInt(seq);
}

/**
 * The bitmap coordinate a permit for `delegate`/`seq` is consumed at — the value
 * to pass to `cancelOrders` to pre-kill or retire it.
 */
export function signerPermitCoordinate(delegate: Address, seq = 0): bigint {
  return signerPermitNonce(delegate, seq) | SIGNER_NONCE_NS;
}

// ──────────────────── OrderSignerPermit (gasless nomination) ────────────────────

/**
 * A maker-signed instruction to nominate (or revoke, with `expiry === 0n`) a
 * delegated order signer, relayable by anyone.
 *
 * A maker with no gas is precisely the audience the gasless-order flow serves,
 * and they cannot send `setOrderSigner` themselves.
 *
 * ⚠ NO RE-DELEGATION. The settler verifies this against `maker` directly, never
 * through the delegated branch, so a delegate cannot appoint further delegates.
 * The nomination graph is exactly one level deep.
 */
export interface OrderSignerPermit {
  /** The delegator. The permit must be signed by this address. */
  maker: Address;
  /** The delegate being nominated, or revoked when `expiry` is `0n`. */
  signer: Address;
  /**
   * Unix seconds the delegation lapses at. `0n` revokes; `2^256-1` never lapses.
   * NOTE `0n` means "not a signer" and CANNOT mean "never expires" — the opposite
   * of Permit3's `expiration` convention, which sits one contract away.
   */
  expiry: bigint;
  /**
   * The permit's nonce, signed BARE. The settler consumes it at
   * `nonce | SIGNER_NONCE_NS`. Use {@link signerPermitNonce}.
   */
  nonce: bigint;
  /** Unix seconds after which this permit may no longer be relayed. */
  deadline: bigint;
}

export const ORDER_SIGNER_PERMIT_TYPE = [
  { name: "maker", type: "address" },
  { name: "signer", type: "address" },
  { name: "expiry", type: "uint256" },
  { name: "nonce", type: "uint256" },
  { name: "deadline", type: "uint256" },
] as const;

export const ORDER_SIGNER_PERMIT_TYPES = { OrderSignerPermit: ORDER_SIGNER_PERMIT_TYPE } as const;

/**
 * The literal typestring the settler hashes into `_ORDER_SIGNER_TYPEHASH`.
 * Pinned so a field added to {@link ORDER_SIGNER_PERMIT_TYPE} without updating
 * the contract is caught by a test rather than by a silently-failing signature.
 */
export const ORDER_SIGNER_PERMIT_TYPESTRING =
  "OrderSignerPermit(address maker,address signer,uint256 expiry,uint256 nonce,uint256 deadline)";

/** EIP-712 payload for signing a nomination permit (Settlement domain). */
export function orderSignerPermitTypedData(permit: OrderSignerPermit, d: Deployment) {
  return {
    domain: settlementDomain(d.chainId, d.settlement),
    types: ORDER_SIGNER_PERMIT_TYPES,
    primaryType: "OrderSignerPermit" as const,
    message: {
      maker: permit.maker,
      signer: permit.signer,
      expiry: permit.expiry,
      nonce: permit.nonce,
      deadline: permit.deadline,
    },
  };
}

/** Default relay window for a nomination permit, in seconds. */
export const ORDER_SIGNER_PERMIT_TTL_SECONDS = 3600n;

/**
 * Build a nomination permit. `deadline` defaults to one hour out rather than
 * "never": an unrelayed permit is a standing right to restore this delegate, so
 * an unbounded one is a permanent one.
 */
export function buildOrderSignerPermit(
  maker: Address,
  delegate: Address,
  expiry: bigint,
  opts?: { seq?: number; deadline?: bigint; now?: bigint; ttlSeconds?: bigint },
): OrderSignerPermit {
  const now = opts?.now ?? BigInt(Math.floor(Date.now() / 1000));
  return {
    maker,
    signer: delegate,
    expiry,
    nonce: signerPermitNonce(delegate, opts?.seq ?? 0),
    deadline: opts?.deadline ?? now + (opts?.ttlSeconds ?? ORDER_SIGNER_PERMIT_TTL_SECONDS),
  };
}

/** Sign a nomination permit. MUST be signed by `permit.maker` — see NO RE-DELEGATION. */
export function signOrderSignerPermit(
  signer: TypedDataSigner,
  permit: OrderSignerPermit,
  d: Deployment,
): Promise<Hex> {
  return signer.signTypedData(orderSignerPermitTypedData(permit, d));
}

/** Build + sign in one step — the shape a gasless "add a session key" button wants. */
export async function nominateOrderSigner(
  signer: TypedDataSigner,
  maker: Address,
  delegate: Address,
  expiry: bigint,
  d: Deployment,
  opts?: { seq?: number; deadline?: bigint; now?: bigint; ttlSeconds?: bigint },
): Promise<{ permit: OrderSignerPermit; sig: Hex }> {
  const permit = buildOrderSignerPermit(maker, delegate, expiry, opts);
  return { permit, sig: await signOrderSignerPermit(signer, permit, d) };
}

// ──────────────────── Calldata ────────────────────

/** `settlement.setOrderSignerWithSig(...)` — relay a maker-signed nomination. */
export function encodeSetOrderSignerWithSig(permit: OrderSignerPermit, sig: Hex): Hex {
  return encodeFunctionData({
    abi: SETTLEMENT_ABI,
    functionName: "setOrderSignerWithSig",
    args: [permit.maker, permit.signer, permit.expiry, permit.nonce, permit.deadline, sig],
  });
}

/** `settlement.cancelOrders([...])` over the reserved half — retire permit coordinates. */
export function encodeBurnSignerPermits(delegate: Address, seqs: readonly number[] = [0]): Hex {
  return encodeFunctionData({
    abi: SETTLEMENT_ABI,
    functionName: "cancelOrders",
    args: [seqs.map((s) => signerPermitCoordinate(delegate, s))],
  });
}

/**
 * Revocation that STICKS — the two calls, in order.
 *
 * `setOrderSigner(delegate, 0)` alone clears the registry entry but leaves any
 * unrelayed `OrderSignerPermit` for this delegate live: relaying it re-nominates.
 * The second call burns the permit's bitmap coordinate, which is recomputable
 * precisely because {@link signerPermitNonce} is derived from the delegate.
 *
 * Pass every `seq` ever issued for this delegate (default `[0]`, which is what
 * {@link buildOrderSignerPermit} uses unless told otherwise).
 *
 * ⚠ Neither call reaches an order the delegate has ALREADY part-filled: the
 * settler skips signature re-checks once `filled != 0`. To bind mid-order use
 * `cancelOrder(order)`, nonce cancellation, the deadline, or Permit3 revocation.
 */
export function encodeRevokeOrderSigner(delegate: Address, opts?: { seqs?: readonly number[] }): Hex[] {
  return [
    encodeFunctionData({ abi: SETTLEMENT_ABI, functionName: "setOrderSigner", args: [delegate, 0n] }),
    encodeBurnSignerPermits(delegate, opts?.seqs ?? [0]),
  ];
}

/**
 * Revoke a whole set of delegates. There is no on-chain bulk revoke — no epoch,
 * no `lockdownAll` — so containing a compromised desk means naming every
 * delegate. {@link liveDelegates} recovers that list from chain history so a
 * maker who has lost track of them is not stuck.
 *
 * ⚠ `rollbackNonces` is NOT a substitute. It sets a nonce FLOOR, and a delegate
 * simply signs above it. The only other containment is revoking the Permit3
 * allowances that fund the fills, which stops the maker trading too.
 */
export function encodeRevokeOrderSigners(
  delegates: readonly Address[],
  opts?: { seqs?: readonly number[] },
): Hex[] {
  return delegates.flatMap((d) => encodeRevokeOrderSigner(d, opts));
}

/**
 * Reduce `OrderSignerSet` logs to the delegates currently nominated by `maker`.
 *
 * The event carries `expiry`, and `0` is the revocation value, so the live set is
 * just a last-write-wins fold. Feed it `getLogs({ event: ORDER_SIGNER_SET_EVENT,
 * args: { maker } })` in block order.
 *
 * `now` is compared against each expiry so a lapsed nomination is not reported as
 * live; pass `0n` to get every non-revoked entry regardless of expiry.
 */
export function liveDelegates(
  logs: readonly { args: { signer?: Address; expiry?: bigint } }[],
  now: bigint,
): Address[] {
  // Keyed case-insensitively so a re-nomination logged with different casing
  // still overwrites, but the ADDRESS handed back is the one the caller gave us —
  // returning a lower-cased variant of a checksummed input is a nasty surprise
  // for anything that compares addresses by string.
  const latest = new Map<string, { address: Address; expiry: bigint }>();
  for (const l of logs) {
    if (!l.args.signer || l.args.expiry === undefined) continue;
    latest.set(l.args.signer.toLowerCase(), { address: l.args.signer, expiry: l.args.expiry });
  }
  const out: Address[] = [];
  for (const { address, expiry } of latest.values()) {
    if (expiry !== 0n && (now === 0n || expiry >= now)) out.push(address);
  }
  return out;
}

// ──────────────────── The cancel asymmetry ────────────────────

/**
 * Throw if `caller` cannot cancel `maker`'s orders on-chain.
 *
 * Every authoritative cancel — `cancelOrder`, `cancelOrders`,
 * `invalidateNonceWord`, `rollbackNonces`, `revokeOrderApproval` — is keyed by
 * `msg.sender`. A DELEGATE can sign orders and can retract them from off-chain
 * books (the `SoftCancel` verifier accepts the same signer set the settler
 * does), but it cannot hard-cancel.
 *
 * The nonce-based three are the trap: called by a delegate they do NOT revert.
 * They write the delegate's own bitmap row and emit `OrdersCancelled(delegate,…)`,
 * which to any operator or bot watching events is indistinguishable from a
 * successful cancel that in fact cancelled nothing of the maker's. Call this
 * before building such calldata on a maker's behalf.
 */
export function assertCanCancelOnChain(caller: Address, maker: Address): void {
  if (caller.toLowerCase() !== maker.toLowerCase()) {
    throw new Error(
      `on-chain cancels are keyed by msg.sender: ${caller} cannot cancel for maker ${maker}. ` +
        `A delegated signer can sign orders and soft-cancel them off-chain, but hard cancellation ` +
        `requires the maker's own key. Nonce cancels called by a non-maker do NOT revert — they ` +
        `silently cancel the caller's own nonces.`,
    );
  }
}
