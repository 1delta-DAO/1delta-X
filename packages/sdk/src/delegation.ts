import { encodeFunctionData, type Address, type Hex } from "viem";

import { SETTLEMENT_ABI } from "./abi";
import { settlementDomain } from "./eip712";
import type { TypedDataSigner } from "./orders";
import type { ContractReader } from "./permit3";
import { SIGNER_NONCE_NS } from "./types";
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
 *      nonces MUST stay below it; the settler enforces that on every fill
 *      (`OrderNonceReserved`), and {@link assertOrderNonce} refuses it at build time.
 *   2. the `OrderSignerPermit` EIP-712 type, for gasless nomination — and, at
 *      its own reserved `seq`, gasless revocation ({@link ORDER_SIGNER_REVOKE_SEQ}).
 *   3. {@link encodeRevokeOrderSigner} — revocation that actually sticks.
 */

// The reserved nonce half lives in `./types` — the leaf module `packed.ts` can
// import without a cycle (packed → delegation → orders → packed). Re-exported here
// because this is where a reader looks for it.
export { SIGNER_NONCE_NS, isReservedNonce, assertOrderNonce } from "./types";

/**
 * The permit nonce for a given delegate. **The settler ENFORCES this derivation**
 * (`nonce >> 8 === BigInt(delegate)`, else `SignerPermitNonceMalformed`) — it is
 * not a convention this SDK follows by choice, and a permit signed with any other
 * nonce is unrelayable.
 *
 * The reason it is mandatory is revocation. A permit is consumed only when it is
 * RELAYED, so a maker who signs a nomination, never has it relayed, and then
 * revokes was once still exposed: whoever held that message could relay it later
 * and the delegate came back, up to its `deadline`. `setOrderSigner(d, 0)` now
 * burns the delegate's entire bitmap WORD in the same call — which only retires
 * every outstanding permit if every permit is forced into that word. Shifting the
 * address by exactly 8 bits is what puts them there: `seq` is one byte, so all 256
 * coordinates for `d` share the word `SIGNER_NONCE_NS >> 8 | d`.
 *
 * `seq` distinguishes concurrent nominations of the SAME delegate — a rotation
 * where the old permit may still be in flight. It does NOT survive a revocation:
 * once `d` is revoked, every `seq` is spent and `d` can only be re-nominated with
 * a direct `setOrderSigner` call. That is deliberate; a revoked key should be
 * replaced, not resurrected. `0xFF` is the revocation's own slot
 * ({@link ORDER_SIGNER_REVOKE_SEQ}); this derivation accepts it, the nomination
 * builders do not.
 */
export function signerPermitNonce(delegate: Address, seq = 0): bigint {
  if (!Number.isInteger(seq) || seq < 0 || seq > 0xff) {
    throw new Error(`signerPermitNonce: seq out of range (one byte): ${seq}`);
  }
  return (BigInt(delegate) << 8n) | BigInt(seq);
}

/**
 * The bitmap coordinate a permit for `delegate`/`seq` is consumed at — the value
 * to pass to `cancelOrders` to pre-kill or retire it.
 */
export function signerPermitCoordinate(delegate: Address, seq = 0): bigint {
  return signerPermitNonce(delegate, seq) | SIGNER_NONCE_NS;
}

/**
 * The `seq` reserved for gasless REVOCATION. The nomination builders refuse it;
 * {@link buildOrderSignerRevocation} uses nothing else.
 *
 * A revocation is just a permit with `expiry === 0n`, and a permit spends its
 * coordinate when RELAYED. Built at a nomination's `seq` — which the old default
 * of `0` did for both — it lands on a coordinate a nomination may already own:
 *   • that nomination was relayed → the revocation reverts `NonceCancelled`,
 *     every time. A gasless maker cannot revoke unless they know to pick another
 *     `seq`.
 *   • that nomination is still unrelayed → whoever holds it (the delegate, with a
 *     pending renewal) relays it first, the coordinate is spent, the revocation
 *     reverts, and the delegate stays live. A front-run of the revocation.
 * A slot no nomination can use has neither failure. Only the maker can spend it —
 * the bitmap row is the maker's, written by its own signed permit or its own
 * `cancelOrders` — and a nomination relayed AHEAD of the revocation cannot beat
 * it: the revocation still lands, and burns the word that nomination sat in.
 *
 * The settler does not know about the reservation (it accepts any one-byte
 * `seq`), so it binds only permits built here. A permit signed at `seq` 255 by
 * other tooling, or by this SDK before the reservation, occupies the slot —
 * {@link canRevokeOrderSignerGasless} reports that like any other spent slot.
 */
export const ORDER_SIGNER_REVOKE_SEQ = 0xff;

// ──────────────────── OrderSignerPermit (gasless nomination) ────────────────────

/**
 * A maker-signed instruction to nominate (or revoke, with `expiry === 0n`) a
 * delegated order signer, relayable by anyone. Build nominations with
 * {@link buildOrderSignerPermit} and revocations with
 * {@link buildOrderSignerRevocation} — one type, two builders, because the two
 * must never share a `seq`.
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

/** Relay-window options shared by the nomination and revocation builders. */
type PermitWindow = { deadline?: bigint; now?: bigint; ttlSeconds?: bigint };

function permitDeadline(opts?: PermitWindow): bigint {
  const now = opts?.now ?? BigInt(Math.floor(Date.now() / 1000));
  return opts?.deadline ?? now + (opts?.ttlSeconds ?? ORDER_SIGNER_PERMIT_TTL_SECONDS);
}

/**
 * Build a nomination permit. `deadline` defaults to one hour out rather than
 * "never": an unrelayed permit is a standing right to restore this delegate, so
 * an unbounded one is a permanent one.
 *
 * NOMINATIONS ONLY — `expiry === 0n` throws and points at
 * {@link buildOrderSignerRevocation}. Refused rather than rerouted: rerouting
 * would make an explicit `seq` mean one thing for a nomination and be ignored for
 * a revocation, and honouring it would rebuild the very collision the reserved
 * slot removes. {@link ORDER_SIGNER_REVOKE_SEQ} is refused for the mirror reason —
 * a nomination parked there would spend the maker's gasless revocation.
 *
 * A RENEWAL of a delegate whose earlier permit was relayed needs a fresh `seq`
 * (`1`..`254`); the one already relayed is spent and reverts `NonceCancelled`.
 */
export function buildOrderSignerPermit(
  maker: Address,
  delegate: Address,
  expiry: bigint,
  opts?: { seq?: number } & PermitWindow,
): OrderSignerPermit {
  if (expiry === 0n) {
    throw new Error(
      "buildOrderSignerPermit: expiry 0n is a revocation, not a nomination — use buildOrderSignerRevocation, " +
        `which signs at the reserved seq ${ORDER_SIGNER_REVOKE_SEQ} that no nomination can have spent`,
    );
  }
  const seq = opts?.seq ?? 0;
  if (seq === ORDER_SIGNER_REVOKE_SEQ) {
    throw new Error(
      `buildOrderSignerPermit: seq ${seq} is reserved for revocation (ORDER_SIGNER_REVOKE_SEQ); nominate at 0..254`,
    );
  }
  return {
    maker,
    signer: delegate,
    expiry,
    nonce: signerPermitNonce(delegate, seq),
    deadline: permitDeadline(opts),
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

/**
 * Build + sign in one step — the shape a gasless "add a session key" button wants.
 * Same refusals as {@link buildOrderSignerPermit}; the "remove" button is
 * {@link revokeOrderSignerGasless}.
 */
export async function nominateOrderSigner(
  signer: TypedDataSigner,
  maker: Address,
  delegate: Address,
  expiry: bigint,
  d: Deployment,
  opts?: { seq?: number } & PermitWindow,
): Promise<{ permit: OrderSignerPermit; sig: Hex }> {
  const permit = buildOrderSignerPermit(maker, delegate, expiry, opts);
  return { permit, sig: await signOrderSignerPermit(signer, permit, d) };
}

// ──────────────────── OrderSignerPermit (gasless revocation) ────────────────────

/**
 * Build a gasless revocation: an {@link OrderSignerPermit} with `expiry === 0n`
 * at {@link ORDER_SIGNER_REVOKE_SEQ}. Relayed, it does exactly what the direct
 * {@link encodeRevokeOrderSigner} does — both reach the same setter — so it
 * clears the registry entry AND burns the delegate's whole permit word.
 *
 * There is no `seq` option: the fixed slot IS the fix. Two revocations of one
 * delegate therefore share a coordinate, which is harmless — they say the same
 * thing, and whichever lands first retires the other.
 *
 * ⚠ AT MOST ONE GASLESS REVOCATION PER DELEGATE, EVER. Every revocation — this
 * one relayed, or the direct `setOrderSigner(d, 0)` — burns the delegate's word,
 * reserved slot included. A delegate revoked and then re-nominated DIRECTLY (the
 * only way back after a revoke) is live again with no gasless revocation left:
 * this permit reverts `NonceCancelled`, and only the direct
 * {@link encodeRevokeOrderSigner}, paid by the maker, can revoke it. Ask
 * {@link canRevokeOrderSignerGasless} before asking for the signature.
 *
 * ⚠ AN UNRELAYED REVOCATION IS A STANDING RIGHT TO REVOKE, held by anyone with
 * the message, until its `deadline` — the mirror of an unrelayed nomination. To
 * withdraw one early, burn the slot with
 * `encodeBurnSignerPermits(delegate, [ORDER_SIGNER_REVOKE_SEQ])`; that forfeits
 * the gasless route for this delegate, and the direct one remains.
 */
export function buildOrderSignerRevocation(
  maker: Address,
  delegate: Address,
  opts?: PermitWindow,
): OrderSignerPermit {
  return {
    maker,
    signer: delegate,
    expiry: 0n,
    nonce: signerPermitNonce(delegate, ORDER_SIGNER_REVOKE_SEQ),
    deadline: permitDeadline(opts),
  };
}

/** Build + sign a gasless revocation — the "remove session key" twin of {@link nominateOrderSigner}. */
export async function revokeOrderSignerGasless(
  signer: TypedDataSigner,
  maker: Address,
  delegate: Address,
  d: Deployment,
  opts?: PermitWindow,
): Promise<{ permit: OrderSignerPermit; sig: Hex }> {
  const permit = buildOrderSignerRevocation(maker, delegate, opts);
  return { permit, sig: await signOrderSignerPermit(signer, permit, d) };
}

/**
 * Whether a {@link buildOrderSignerRevocation} permit for `delegate` can still
 * land: one `isNonceCancelled` read of the reserved coordinate.
 *
 * `false` means the gasless route is gone for this delegate — an earlier
 * revocation burned the word (including revoke-then-direct-renominate), the maker
 * burned the slot, or foreign tooling nominated at `seq` 255. Fall back to the
 * direct {@link encodeRevokeOrderSigner}, which needs no free coordinate.
 * `true` says nothing about whether the delegate is live; `orderSignerExpiry`
 * does.
 */
export async function canRevokeOrderSignerGasless(
  reader: ContractReader,
  maker: Address,
  delegate: Address,
  d: Deployment,
): Promise<boolean> {
  const spent = await reader.readContract({
    address: d.settlement,
    abi: SETTLEMENT_ABI,
    functionName: "isNonceCancelled",
    args: [maker, signerPermitCoordinate(delegate, ORDER_SIGNER_REVOKE_SEQ)],
  });
  return spent === false;
}

// ──────────────────── Calldata ────────────────────

/** `settlement.setOrderSignerWithSig(...)` — relay a maker-signed nomination or revocation. */
export function encodeSetOrderSignerWithSig(permit: OrderSignerPermit, sig: Hex): Hex {
  return encodeFunctionData({
    abi: SETTLEMENT_ABI,
    functionName: "setOrderSignerWithSig",
    args: [permit.maker, permit.signer, permit.expiry, permit.nonce, permit.deadline, sig],
  });
}

/**
 * `settlement.cancelOrders([...])` over the reserved half — retire permit coordinates.
 * Burning {@link ORDER_SIGNER_REVOKE_SEQ} withdraws an unrelayed gasless
 * revocation, and with it the gasless route to revoking this delegate.
 */
export function encodeBurnSignerPermits(delegate: Address, seqs: readonly number[] = [0]): Hex {
  return encodeFunctionData({
    abi: SETTLEMENT_ABI,
    functionName: "cancelOrders",
    args: [seqs.map((s) => signerPermitCoordinate(delegate, s))],
  });
}

/**
 * Revocation that STICKS — and it is now ONE call.
 *
 * This used to return two: `setOrderSigner(delegate, 0)` cleared the registry but
 * left any unrelayed `OrderSignerPermit` live, so a second `cancelOrders` was
 * needed to burn its coordinate. That made the safety of revocation depend on the
 * caller reaching for this helper rather than the obvious single call — which the
 * SDK did and a wallet, a block explorer or a hand-rolled script did not.
 *
 * The settler now burns the delegate's whole permit word inside
 * `setOrderSigner(d, 0)` itself, retiring every `seq` at once. Every client gets
 * the property, including the ones that never see this file. `seqs` is therefore
 * no longer needed; {@link encodeBurnSignerPermits} remains for the different job
 * of killing a permit WITHOUT revoking (a nomination signed but never wanted).
 *
 * It needs no free permit coordinate, so it is also the fallback whenever
 * {@link canRevokeOrderSignerGasless} says the gasless route is gone.
 *
 * ⚠ It still does not reach an order the delegate has ALREADY part-filled: the
 * settler skips signature re-checks once `filled != 0`. To bind mid-order use
 * `cancelOrder(order)`, nonce cancellation, the deadline, or Permit3 revocation.
 */
export function encodeRevokeOrderSigner(delegate: Address): Hex[] {
  return [encodeFunctionData({ abi: SETTLEMENT_ABI, functionName: "setOrderSigner", args: [delegate, 0n] })];
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
export function encodeRevokeOrderSigners(delegates: readonly Address[]): Hex[] {
  return delegates.flatMap((d) => encodeRevokeOrderSigner(d));
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
