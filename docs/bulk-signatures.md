# Bulk signatures — one signature, N orders

A maker signs a Merkle **root** once; every order whose hash is a leaf of that
root is authorized by it, each carrying its own inclusion proof. This is the
ladder / bracket / quote-refresh primitive: a 50-slice TWAP ladder, an N-way OCO
group, or a market maker's periodic re-quote becomes **one wallet prompt** instead
of fifty.

Prior art: Seaport's bulk orders, ComposableCoW's O(1) conditional-order root,
Fusion+'s Merkle-of-secrets for multi-resolver partial fills.

## The envelope

```
sig = innerSig(65) ‖ bytes32[] proof ‖ 0xB0
```

Recognised in [`Signatures._verifySignature`](../packages/core/src/settlement/Signatures.sol)
when `length >= 98`, `(length − 66) % 32 == 0`, and the last byte is `0xB0`. The
branch then does exactly two things — swap in a different digest and shorten the
signature body to its first 65 bytes:

```
root   = fold(orderHash, proof)                       // sorted-pair keccak
digest = EIP-712( OrderRoot(bytes32 root) )           // Settlement's own domain
```

…after which the acceptance rules below it run on that 65-byte body: the maker's
own key, a live ECDSA delegate from `orderSignerExpiry`, or the maker's EIP-1271
wallet. A bulk signature therefore grants exactly the authority a single signature
would, and no more.

Because the body is **fixed at 65 bytes**, not every signer can use it:

- the **contract-delegate envelope** (`address ‖ innerSig`) is never 65 bytes, so
  a contract delegate cannot sign a root;
- an **EIP-1271 maker** can bulk-sign only if its wallet's signature is exactly 65
  bytes (a threshold-1 Safe is; most multisig and passkey payloads are not).

Both are liveness limits, not authorization gaps: such signers still sign orders
one by one, or use the on-chain `approveOrder` path.

`OrderRoot(bytes32 root)` is hashed in the Settlement EIP-712 domain, so a root is
deployment- and chain-bound like every other signature here.

## Why it cannot authorize something the maker did not sign

- **An order outside the tree** folds to a root the maker never signed → the
  recovered signer is not the maker (or any delegate) → revert.
- **Sorted pairs** mean the tree carries no position bits and a leaf is just an
  order hash. Passing an internal node off as an order would require finding an
  order whose EIP-712 struct hash equals a chosen 256-bit node — a second-preimage
  search, not a grind.
- **No ECDSA signature can enter the branch**: 64/65-byte payloads fail the length
  test.
- **Cancellation is untouched.** A root does not outrank `cancelOrder`, the nonce
  bitmap, `rollbackNonces`, or the deadline — every one of those still binds each
  leaf individually.

### The liveness edges

Two non-bulk shapes can match the envelope test, be re-read as a proof, produce a
root the maker never signed, and **revert** — never a bypass:

- a **delegate envelope** (`address ‖ innerSig`, for contract delegates) whose
  total length is ≥ 98, `≡ 2 (mod 32)`, and ends in `0xB0`. Builders control their
  own envelopes, so it is avoidable off-chain;
- a plain **EIP-1271 maker signature** with the same length and trailing byte. The
  maker does not choose that — it is whatever the wallet emits. Vanilla Safes are
  immune (the trailing byte of a static ECDSA part is `v`); wallets with
  attacker-influenceable trailing bytes are exposed at ~1/256 per matching length,
  and still have `approveOrder` and `cancelOrder`.

## Cost

**+1,368 gas** versus a single signature for a 2-level proof, i.e. roughly the
fold plus one extra `_hashTypedData`. Non-bulk signatures pay nothing: the branch
is three comparisons on a length that is already loaded.

Implementation note: verifying the root inline, with its own copy of
`tryRecoverSigner`/`verify`, measured **+1,343 bytes** of Settlement against a
404-byte EIP-170 budget. Reusing the existing verifier tail by changing its inputs
is what made the feature fit at all — see [lop-parity.md](lop-parity.md) §4.

## Building one off-chain

1. Hash each order (`hashOrderStruct`, or `SettlementLens.hashOrder`).
2. Build a sorted-pair Merkle tree over those hashes (the OpenZeppelin
   convention — any standard builder produces compatible proofs).
3. Sign `OrderRoot(root)` once, in the Settlement domain.
4. Publish each order with `innerSig ‖ its proof ‖ 0xB0` as its signature. Nothing
   downstream changes: the orderbook verifies it locally with the same call, and a
   filler submits it as an ordinary `sig`.

⚠ Trees are **not** self-describing on chain. If a maker wants a bracket where
filling one leg kills the others, that is still [oco.md](oco.md)'s job — a shared
nonce or `OcoGroupModule`. A root only says "I signed all of these".

Related: [delegated-signers.md](delegated-signers.md) (who may sign a root),
[soft-cancel.md](soft-cancel.md) (retiring leaves off-chain).
