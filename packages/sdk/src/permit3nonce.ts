/**
 * Permit3 nonce allocation, namespaced by MESSAGE TYPE.
 *
 * ## Why this exists
 *
 * `UnorderedNonces` keeps **one bitmap per owner**, shared by every signed
 * Permit3 flow — `permitBatchWithWitness*`, `permitTake*` and
 * `permitTransferFrom` all draw from the same space. That is deliberate on the
 * contract side: it makes `invalidateUnorderedNonces` a complete kill switch over
 * a nonce range whatever flow signed against it, and removes any chance of
 * replaying a message through a different flow.
 *
 * The cost lands off-chain, and the contract says so: *"nonce allocation must be
 * per-owner, not per-message-type."* Nothing enforced it. An owner who signed a
 * `PermitBatch` and a `PermitTake` at the same coordinate had two live messages
 * racing for one bit, and only one could ever land — while
 * `permitBatchWithWitnessIfNeeded` returns silently on a spent bit (the S-1
 * remediation) and `permitTake` / `permitTransferFrom` **revert**. So anyone
 * holding either unrelayed message could burn the coordinate and DoS the other.
 * That is the shape of §F17 one layer down: a safety property resting on the
 * caller allocating carefully rather than on anything that checks.
 *
 * ## The allocation
 *
 * The message kind occupies the top byte, the sequence the remaining 248 bits:
 *
 * ```
 *   nonce = (kind << 248) | seq        seq < 2^248
 * ```
 *
 * Two messages of different kinds can then never collide, whatever sequence each
 * allocator picks, and a spent-bit race is confined to messages of the same kind
 * — where it is the owner deliberately reusing a coordinate, which is what
 * cancel-and-replace wants.
 *
 * `Batch` is deliberately kind **0**, so a small legacy nonce reads as
 * batch-namespaced and keeps working. That costs nothing: the DoS needs two
 * DIFFERENT kinds on one coordinate, and a legacy batch nonce can never collide
 * with a properly allocated `Take` or `Transfer` one. Only the two flows that
 * REVERT on a spent bit have to be explicit.
 *
 * Nothing about the on-chain kill switch changes: `invalidateUnorderedNonces`
 * still takes a raw `(word, mask)` and still reaches every namespace. Use
 * {@link permit3NonceWord} to aim it at one kind.
 *
 * ⚠ This is only worth anything because the builders CALL it —
 * {@link permitBatch} and {@link permitTake} assert their nonce carries the right
 * tag. A helper nobody invokes reads as a guarantee and is not one; that is the
 * lesson the `assertOrderNonce` row of §F23 was recorded for.
 */

/** Bits reserved at the top of a Permit3 nonce for the message kind. */
export const PERMIT3_KIND_SHIFT = 248n;

/** The signed Permit3 flows that share one owner bitmap. */
export const Permit3MessageKind = {
  /** `permitBatchWithWitness*` / `permitBatchIfNeeded` — allowance grants. */
  Batch: 0,
  /** `permitTake*` — one-shot taker dispatch. */
  Take: 1,
  /** `permitTransferFrom` — one-shot signature transfer. */
  Transfer: 2,
} as const;

export type Permit3MessageKind = (typeof Permit3MessageKind)[keyof typeof Permit3MessageKind];

const MAX_SEQ = (1n << PERMIT3_KIND_SHIFT) - 1n;
const KIND_NAMES: Record<number, string> = { 0: "Batch", 1: "Take", 2: "Transfer" };

/**
 * The nonce for message `kind`, sequence `seq`.
 *
 * `seq` is yours to allocate however you like — a counter, a hash, a timestamp —
 * within one kind. Reusing one across two messages of the SAME kind is the
 * cancel-and-replace idiom and is allowed; the namespace only stops the
 * accidental cross-kind case, which is never intentional.
 */
export function permit3Nonce(kind: Permit3MessageKind, seq: bigint): bigint {
  if (seq < 0n || seq > MAX_SEQ) {
    throw new Error(`permit3Nonce: seq out of range (must be < 2^248): ${seq}`);
  }
  return (BigInt(kind) << PERMIT3_KIND_SHIFT) | seq;
}

/** The message kind a nonce was allocated for, or `null` if it is untagged. */
export function permit3NonceKind(nonce: bigint): Permit3MessageKind | null {
  const kind = Number(nonce >> PERMIT3_KIND_SHIFT);
  return kind in KIND_NAMES ? (kind as Permit3MessageKind) : null;
}

/**
 * Throw unless `nonce` was allocated for `kind`. Called by the builders, so an
 * un-namespaced or mis-namespaced nonce cannot reach a signature.
 */
export function assertPermit3Nonce(nonce: bigint, kind: Permit3MessageKind): bigint {
  if (nonce < 0n) throw new Error(`permit3 nonce out of range: ${nonce}`);
  const got = permit3NonceKind(nonce);
  if (got !== kind) {
    const want = KIND_NAMES[kind];
    const desc = got === null ? `is not namespaced` : `is namespaced for ${KIND_NAMES[got]}`;
    throw new Error(
      `permit3 nonce ${nonce} ${desc}, expected ${want}. All signed Permit3 flows share ONE ` +
        `bitmap per owner, so an untagged nonce can collide with a message of another kind and ` +
        `whoever holds either can burn the coordinate. Allocate with permit3Nonce(Permit3MessageKind.${want}, seq).`,
    );
  }
  return nonce;
}

/**
 * The bitmap word a nonce falls in — the `wordPos` for
 * `invalidateUnorderedNonces(wordPos, mask)`.
 */
export function permit3NonceWord(nonce: bigint): bigint {
  return nonce >> 8n;
}

/** The mask selecting `nonce`'s single bit within {@link permit3NonceWord}. */
export function permit3NonceMask(nonce: bigint): bigint {
  return 1n << (nonce & 0xffn);
}
