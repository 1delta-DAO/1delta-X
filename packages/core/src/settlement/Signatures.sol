// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SignatureVerification} from "../permit3/SignatureVerification.sol";
import {OrderHash} from "./OrderHash.sol";
import {OrderState} from "./OrderState.sol";
import {FillCtx} from "./Structs.sol";
import {NonceManager} from "./NonceManager.sol";

/// @title Signatures
/// @notice Order AUTHORIZATION verification, isolated: the EIP-712 domain and the
///         `_verifySignature` gate that every fill runs. Two ways to authorize an
///         order are accepted here:
///           1. a signature over the EIP-712 digest — EOA (ecrecover), EIP-1271
///              contract wallets, and EIP-7702 accounts, via {SignatureVerification};
///           2. an EMPTY `sig`, authorized against the maker's on-chain
///              {OrderState.approveOrder} record (the signature-less path).
///
///         The domain separator is cached at deploy and rebuilt only if
///         `block.chainid` changes (a fork), so a signature can never be replayed
///         against the wrong domain. This layer owns NO settlement logic and moves
///         NO tokens — it only answers "is this order authorized by its maker?".
abstract contract Signatures is OrderState {
    /// @dev EIP-712 domain, cached at deploy but recomputed if `block.chainid`
    ///      changes (chain fork) so an order signature can never be replayed
    ///      against the wrong domain after a split. Mirrors Permit3's EIP712 base;
    ///      exposed via the `DOMAIN_SEPARATOR()` view below.
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;
    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _HASHED_NAME = keccak256("Settlement");
    bytes32 private constant _HASHED_VERSION = keccak256("1");

    /// @dev An empty `sig` was supplied for a fill, but the maker has no matching
    ///      on-chain {OrderState.approveOrder} record for this order.
    error OrderNotApproved();
    /// @dev A nomination permit's nonce was not `(signer << 8) | seq`. The
    ///      derivation is MANDATORY, and it is what makes revocation final: because
    ///      every permit for a delegate is forced into that delegate's single bitmap
    ///      word, {OrderState._setOrderSigner} can retire all of them with one
    ///      `SSTORE` when the maker revokes. A permit at a freely-chosen coordinate
    ///      would sit in some other word and survive the revocation — which is
    ///      exactly the resurrection this rule exists to prevent, so the rule cannot
    ///      be a convention the signer is trusted to follow.
    ///
    ///      It also forces `nonce < 2^168`, so a permit can never carry
    ///      {NonceManager.SIGNER_NONCE_NS} in its BARE nonce. Without that, `nonce`
    ///      and `nonce | SIGNER_NONCE_NS` would be two distinct signed permits
    ///      sharing one coordinate.
    error SignerPermitNonceMalformed();
    /// @dev {setOrderSignerWithSig} was presented past its `deadline`. Declared here
    ///      rather than reusing {Base.OrderExpired} because {Base} sits ABOVE this
    ///      layer — and because the two mean different things: an expired order
    ///      versus an expired nomination permit.
    error SignerPermitExpired();

    /// @dev EIP-712 type for a RELAYED delegate nomination. Independent of the
    ///      `Order` type, so adding it leaves the order typehash — and the golden
    ///      hash — untouched.
    bytes32 private constant _ORDER_SIGNER_TYPEHASH =
        keccak256("OrderSignerPermit(address maker,address signer,uint256 expiry,uint256 nonce,uint256 deadline)");

    constructor() {
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator();
    }

    /// @notice EIP-712 domain separator for the current chain. Returns the cached
    ///         value unless `block.chainid` has changed since deployment (fork),
    ///         in which case it is rebuilt so signatures stay domain-bound.
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return block.chainid == _CACHED_CHAIN_ID ? _CACHED_DOMAIN_SEPARATOR : _buildDomainSeparator();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(_DOMAIN_TYPEHASH, _HASHED_NAME, _HASHED_VERSION, block.chainid, address(this)));
    }

    // NOTE: ERC-5267 `eip712Domain()` is deliberately NOT on Settlement. It measured
    // ~750 bytes (the string returns + the empty extensions array) and Settlement is
    // hard against EIP-170 (see the `optimizer_runs` note in foundry.toml). The
    // order-signing domain is fully recoverable from the exposed `DOMAIN_SEPARATOR()`
    // plus the constant name "Settlement"/version "1", and {SettlementLens} mirrors
    // it for tooling. Permit3 — which has bytecode headroom — DOES implement 5267.

    /// @dev `keccak256(abi.encodePacked("\x19\x01", domain, structHash))` built in
    ///      SCRATCH SPACE instead of an allocated 66-byte buffer. `encodePacked`
    ///      allocated + copied on every fill for a fixed 66-byte preimage; this
    ///      writes it at 0x1e..0x60 (borrowing the free-memory-pointer word, then
    ///      restoring it) and hashes in place. Identical digest.
    ///
    ///      EQUIVALENT SOLIDITY:
    ///
    ///          return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    function _hashTypedData(bytes32 structHash) private view returns (bytes32 digest) {
        bytes32 domain = DOMAIN_SEPARATOR();
        /// @solidity memory-safe-assembly
        assembly {
            let fmp := mload(0x40)
            mstore(0x00, 0x1901)
            mstore(0x20, domain)
            mstore(0x40, structHash)
            digest := keccak256(0x1e, 0x42)
            mstore(0x40, fmp) // restore the free-memory pointer
        }
    }

    /// @notice Nominate (or revoke) a delegated order signer with a SIGNATURE
    ///         instead of a transaction, so a maker with no gas can do it — the
    ///         same audience the gasless-order flow exists for. Anyone may relay it;
    ///         the permit carries its own authorization.
    ///
    ///  ⚠ NO RE-DELEGATION. The permit is verified against `maker` through the
    ///  SHARED verifier ({SignatureVerification.verify}), NOT through
    ///  {_verifySignature}'s delegated branch. A delegate therefore cannot appoint
    ///  further delegates, and the nomination graph stays exactly one level deep:
    ///  every delegate in the book was named by the maker whose orders it can sign.
    ///  Do not "simplify" this into `_verifySignature`.
    ///
    ///  Replay protection reuses the maker's ORDER nonce bitmap, but in a RESERVED
    ///  HALF of it: the coordinate actually consumed is `nonce | SIGNER_NONCE_NS`
    ///  (bit 255 forced on), never the bare `nonce`. The maker still SIGNS the bare
    ///  value — the EIP-712 payload is unchanged — so this costs one `or` and no
    ///  tooling change.
    ///
    ///  ⚠ THE NAMESPACE IS THE WHOLE POINT, AND IT FIXES A REAL KILL SWITCH. Sharing
    ///  the coordinate outright made an UNRELAYED nomination permit a latent,
    ///  third-party-triggerable cancel on every order the maker later signed with the
    ///  same nonce. The bit stays CLEAR until the permit is relayed, so the natural
    ///  off-chain "is this nonce free?" check reads it as free; anyone holding the
    ///  signed permit could then relay it at any point before its `deadline` and burn
    ///  the nonce out from under a live order. Nonce reuse is not exotic here either —
    ///  a shared nonce is exactly how an OCO bracket is built (`docs/oco.md`), so the
    ///  order side deliberately reuses the space the permit was drawing from.
    ///
    ///  With the namespace, a permit can only ever consume a coordinate at or above
    ///  2^255. Order nonces below that — every nonce any builder allocates today —
    ///  are now unreachable from this function. The other half of the rule is stated
    ///  in {NonceManager}: an ORDER must not use a nonce with bit 255 set, and every
    ///  fill enforces it ({Base._gateOrderPost} reverts {Base.OrderNonceReserved}).
    ///
    ///  Two consequences of the reservation, both deliberate:
    ///    • pre-emptively killing an unrelayed nomination is still possible with the
    ///      primitives the maker already has, but it must name the NAMESPACED
    ///      coordinate: `cancelOrders([nonce | 1 << 255])`, or the matching
    ///      {NonceManager.invalidateNonceWord}. The SDK mirrors the constant as
    ///      `SIGNER_NONCE_NS`.
    ///    • {NonceManager.rollbackNonces} no longer reaches nominations at all — a
    ///      floor would have to exceed 2^255. That is the better behaviour, not a
    ///      regression: a rollback aimed at retiring a ladder of orders should not
    ///      silently revoke the desk's signing key as well.
    ///
    ///  A gasless REVOCATION (`expiry == 0`) is accepted too, but note it depends on
    ///  someone relaying it. The direct {OrderState.setOrderSigner} needs no relayer
    ///  — but do NOT read that as unconditional. It clears the registry entry that
    ///  {_verifySignature} consults, and that lookup sits BEHIND the first-fill skip,
    ///  so revocation does not reach the remainder of an order the delegate already
    ///  part-filled. That is the documented delegate caveat, pinned by
    ///  `test_revocation_doesNotBindAfterAPartialFill`; see
    ///  {OrderState.orderSignerExpiry}. Contrast {OrderState.revokeOrderApproval},
    ///  which escalates a touched order to a full cancel — it has to, because the
    ///  sigless path's authorization IS that revocable record, whereas a revoked
    ///  delegate's signature remains a real signature over a maker-committing hash.
    ///
    ///  The kill switches that DO bind mid-order are the order-level ones, and they
    ///  run on every fill through {Base._gateOrderPost} / {OrderState._gateFillState}
    ///  regardless of which authorization branch the filler steers into:
    ///  {OrderState.cancelOrder}, nonce cancellation, deadlines, Permit3 revocation.
    ///
    /// @param maker    the delegator, and the address the permit must be signed by.
    /// @param signer   the delegate being nominated (or revoked with `expiry == 0`).
    /// @param expiry   unix time the delegation lapses at; see {orderSignerExpiry}.
    /// @param nonce    the permit's nonce. Consumed at `nonce | SIGNER_NONCE_NS`, so
    ///                 it can never collide with an ORDER nonce below 2^255.
    /// @param deadline unix time after which this permit may no longer be relayed.
    function setOrderSignerWithSig(
        address maker,
        address signer,
        uint256 expiry,
        uint256 nonce,
        uint256 deadline,
        bytes calldata sig
    ) external {
        if (block.timestamp > deadline) revert SignerPermitExpired();
        // The coordinate must be the delegate's own. See {SignerPermitNonceMalformed}:
        // this is the line that turns "revocation is final" from a caller discipline
        // into a property of the contract.
        if (nonce >> 8 != uint256(uint160(signer))) revert SignerPermitNonceMalformed();
        // The digest binds the BARE `nonce` — the maker signs what they always
        // signed, so no tooling changes.
        bytes32 digest =
            _hashTypedData(keccak256(abi.encode(_ORDER_SIGNER_TYPEHASH, maker, signer, expiry, nonce, deadline)));
        // The bitmap, however, is read and written at the RESERVED coordinate — see
        // the namespace note above. Derived ONCE and reused, so the check and the
        // consume cannot drift apart. (Measured: folding it into the local costs 7
        // bytes of Settlement, against two inline `or`s at 9. The 15-byte budget that
        // made those 2 bytes matter is gone — merging the `TAKE`/`TAKE_FOR` dispatch
        // into {Base._dispatchTake} returned 42 — but the single-local form is still
        // the one to keep: it is what makes the check and the consume provably the
        // same coordinate.)
        nonce |= NonceManager.SIGNER_NONCE_NS;
        if (_isNonceCancelled(maker, nonce)) revert NonceCancelled();
        // Against `maker` ONLY — see the no-re-delegation note above.
        SignatureVerification.verify(sig, digest, maker);
        _cancelNonce(maker, nonce); // consume before the write; nothing external runs here
        // A LAPSED NOMINATION IS REFUSED, NOT NORMALISED. The direct setter reads a
        // past `expiry` as a revocation ({OrderState.setOrderSigner}); this path used
        // to mirror that — and because the RELAYER picks when a permit lands, a
        // nomination relayed after its own `expiry` (but before its `deadline`) then
        // became a revocation that burned the delegate's permit word AND cleared a
        // CURRENT direct nomination the maker had made in the meantime. Anyone holding
        // a stale nomination could revoke a live desk key (F29 finding 7). A permit
        // that says "nominate until T" and arrives after T authorises nothing, so it
        // does nothing: reverted under the same selector as a lapsed `deadline`. A
        // gasless revocation is still spelled `expiry == 0` explicitly.
        //
        // AND A RELAYED NOMINATION ONLY EVER EXTENDS (re-audit 2026-09-29). The check
        // above covered a permit landing after its own `expiry`, not one landing
        // before it: an unrelayed "until T+1h" permit relayed after the maker had
        // nominated the same delegate directly "until T+365d" overwrote it, cutting a
        // live desk key short — and the RELAYER picks when a permit lands. So a
        // permit may not lower the stored expiry either; shortening a delegate is the
        // maker's own call to {setOrderSigner}, and ending one is a revocation. Same
        // selector as a lapsed permit: in both cases it is stale.
        if (expiry != 0 && (expiry < block.timestamp || expiry < orderSignerExpiry[maker][signer])) {
            revert SignerPermitExpired();
        }
        _setOrderSigner(maker, signer, expiry);
    }

    /// @dev Authorize `orderHash` for `expected` (the order's maker). Either the
    ///      empty-sig on-chain-approval path or a real signature over the domain-
    ///      bound digest; reverts if neither authorizes.
    ///
    ///      FIRST-FILL ONLY, FOR REAL SIGNATURES. The skip reads `ctx.prevFilled`,
    ///      seeded by {OrderState._gateFillState}. The invariant it rests on: EVERY
    ///      WRITER OF A NON-SENTINEL `filled[orderHash]` HAS AUTHENTICATED THE MAKER FOR
    ///      THIS HASH (and the hash commits to `maker`). The only such writer is
    ///      {OrderState._openFill}. Most entries reach it after this gate;
    ///      {Core.fillWithPermit} after its `SettlementOrder{settlement, order}`
    ///      Permit3 witness; {Core.fillWithPermitTake} writes it BEFORE its
    ///      `PermitTake` witness is checked (inside the item dispatch), but a write
    ///      survives only if that check ran — {Base.PermitTakeNotConsumed} reverts
    ///      the whole fill otherwise. So every write that PERSISTS was authenticated.
    ///      {cancelOrder} and {revokeOrderApproval} write only the `type(uint256).max`
    ///      sentinel, which {_gateFillState} rejects ({OrderCancelled}) before this
    ///      gate is reached. So a non-zero counter proves some earlier fill presented
    ///      valid authorization for this exact hash, and re-deriving the digest and
    ///      re-running `ecrecover` on every partial fill proves nothing new. Ported
    ///      from 1inch LOP v4, which gates on `remaining == makingAmount` for the same
    ///      reason.
    ///
    ///      COST, measured when this gate still did its own SLOAD of `filled`: net
    ///      **+150 gas on a first / single fill**, **−2,860 on every fill after it**
    ///      (−14,531 across a TWAP schedule). The read now lives in
    ///      {OrderState._gateFillState}, which every path needs anyway, so the skip
    ///      itself is one memory compare.
    ///
    ///      The skip applies ONLY to the signature branch. The on-chain-approval
    ///      ({approveOrder}) path is re-checked on every fill, because that record is
    ///      revocable and a maker is entitled to expect {revokeOrderApproval} to bind
    ///      mid-order — see the branch itself.
    ///
    ///      ⚠ SEMANTIC CHANGE for CONTRACT signers. An EIP-1271 wallet (Safe, 7702
    ///      delegate) that would start returning `false` — approval revoked, owners
    ///      rotated — no longer blocks the REMAINDER of an order it already part-filled.
    ///      EOA signatures are unaffected (a signature over a fixed digest cannot be
    ///      withdrawn anyway), and the maker's real kill switches are unchanged and
    ///      still checked on every fill: {cancelOrder}, nonce cancellation /
    ///      {rollbackNonces}, the deadline, and revoking the Permit3 allowances that
    ///      fund the fill. A contract maker that needs signature revocation to bind
    ///      mid-order must use {cancelOrder}.
    function _verifySignature(bytes32 orderHash, bytes calldata sig, address expected, FillCtx memory ctx)
        internal
        view
    {
        // Signature-less path: an EMPTY `sig` authorizes against the maker's on-chain
        // {approveOrder} record instead of a signature. No valid signature has zero
        // length (the shared verifier rejects it), so the sentinel can never collide
        // with a real one. This lets a maker that cannot sign — e.g. a multisig
        // without EIP-1271 — still place orders. Every other fill gate is unchanged.
        //
        // Checked BEFORE the first-fill skip below, and deliberately so: unlike a
        // signature — an immutable commitment over a fixed digest — this record is
        // MUTABLE and the maker is told they may withdraw it ({revokeOrderApproval}).
        // Skipping it after the first fill would silently turn revocation into a
        // no-op for a partially filled order. Costs nothing on the hot path: this
        // branch never ran an `ecrecover`, and sigless orders are the rare case.
        if (sig.length == 0) {
            if (!orderApproved[expected][orderHash]) revert OrderNotApproved();
            return;
        }
        if (ctx.prevFilled != 0) return; // already authorized once — see above (seeded by {_gateFillState})
        bytes32 digest;
        bytes calldata sigBody = sig;
        // BULK (Merkle) signature — ONE signature authorizing every order whose hash is
        // a leaf of a signed root. What a 50-slice ladder, an N-way bracket or a market
        // maker's quote refresh needs, and what Seaport's bulk orders and
        // ComposableCoW's O(1) root both do: the maker signs `OrderRoot(root)` once and
        // each order carries its own inclusion proof.
        //
        //     sig = innerSig(65) ‖ bytes32[] proof ‖ 0xB0
        //
        //  This branch only swaps in a DIFFERENT DIGEST and a 65-byte body; the
        //  acceptance rules below then run on that body. That is deliberate:
        //  verifying the root inline with its own copy of the signer set measured
        //  **+1,343 bytes** of Settlement (2026-08-12, against a 404-byte budget),
        //  because `tryRecoverSigner` and `verify` are library internals the
        //  optimizer inlines per site. A bulk signature grants exactly the authority
        //  a single signature would, no more.
        //
        //  NOT EVERY RULE IS REACHABLE, because the body is FIXED at 65 bytes: the
        //  maker's own ECDSA key and an ECDSA delegate apply unchanged, but the
        //  contract-delegate envelope (`address ‖ innerSig`, never 65 bytes) cannot
        //  be expressed, and a 1271 maker can bulk-sign only if its wallet's
        //  signature is exactly 65 bytes (a threshold-1 Safe is; most multisig and
        //  passkey payloads are not). Liveness only — such signers still sign
        //  orders one by one, or use {approveOrder}.
        //
        //  ⚠ SHAPE, AND WHY IT CANNOT AUTHORIZE ANYTHING IT SHOULDN'T. `length >= 98`,
        //  `(length - 66) % 32 == 0`, trailing `0xB0`. No ECDSA signature (64/65 bytes)
        //  can match. This IS a liveness edge, never a bypass: any signature that
        //  matches the three predicates is re-read against a root the maker never
        //  signed and REVERTS. Two shapes can collide, and both are liveness-only:
        //    • a delegate envelope (`address ‖ innerSig`) — builders control their own
        //      envelope, so it is avoidable off-chain; and
        //    • a plain CONTRACT-MAKER 1271 blob whose own length lands on `2 mod 32`
        //      (98, 130, 162 …) and whose last byte is `0xB0`. This one the maker does
        //      NOT choose — it is whatever the wallet emits — so it is not "avoidable
        //      off-chain" for every wallet. Vanilla Safes are immune (the trailing byte
        //      of a static ECDSA part is `v ∈ {0,1,27,28}`); the exposure is wallets
        //      with attacker-influenceable trailing bytes (dynamic-part Safe signatures,
        //      some passkey/WebAuthn encodings), at ~1/256 per matching length. Such a
        //      maker still has the empty-`sig` {approveOrder} path and {cancelOrder}, so
        //      no order is stuck; a future envelope revision (a length field, a reserved
        //      trailer namespace) would remove even the liveness edge.
        //
        //  The proof folds with SORTED pairs (the OpenZeppelin convention), so a leaf
        //  is just an order hash and the tree carries no position bits. Passing an
        //  internal node off as an order would require finding an order whose EIP-712
        //  struct hash equals a chosen 256-bit node — a second-preimage search.
        uint256 n = sig.length;
        if (n >= 98 && (n - 66) % 32 == 0 && _lastByte(sig) == 0xB0) {
            bytes32 rootTypeHash = OrderHash.ORDER_ROOT_TYPEHASH;
            // `n >= 98` was proven above, so `sig[65:n - 1]` and `sig[:65]` are in bounds.
            bytes calldata proof;
            /// @solidity memory-safe-assembly
            assembly {
                proof.offset := add(sig.offset, 65)
                proof.length := sub(n, 66)
            }
            bytes32 root = _foldProof(orderHash, proof);
            bytes32 structHash;
            /// @solidity memory-safe-assembly
            assembly {
                // `keccak256(abi.encode(ORDER_ROOT_TYPEHASH, root))` in scratch space.
                mstore(0x00, rootTypeHash)
                mstore(0x20, root)
                structHash := keccak256(0x00, 0x40)
            }
            digest = _hashTypedData(structHash);
            /// @solidity memory-safe-assembly
            assembly {
                sigBody.length := 65
            }
        } else {
            digest = _hashTypedData(orderHash);
        }
        // Recover ONCE, then decide. The maker's own signature — the overwhelming
        // majority — takes the first branch and pays exactly what it paid before
        // delegation existed: one `ecrecover` and one compare, which is precisely
        // the work {SignatureVerification.verify} would have done. The registry
        // SLOAD sits behind a mismatch, so an ordinary fill never touches it.
        (bool standardLength, address signer) = SignatureVerification.tryRecoverSigner(sigBody, digest);
        if (standardLength && signer != address(0)) {
            if (signer == expected) return;
            // Not the maker — but the maker may have nominated this key. The lookup
            // is keyed by the ORDER'S maker, so a delegate can only ever authorize
            // orders that name the maker who nominated it. See
            // {OrderState.orderSignerExpiry} for why that bound is the whole trust
            // model.
            uint256 expiry = orderSignerExpiry[expected][signer];
            if (expiry != 0 && block.timestamp <= expiry) return;
        }
        // A CONTRACT delegate — a Safe, a passkey/P256 wallet, any EIP-1271 signer.
        // The registry probe above cannot reach one: it keys on the address
        // `ecrecover` produced, and a contract signature has no such address. The
        // filler therefore NAMES the delegate, in an envelope prepended to the
        // signature:
        //
        //     sig = abi.encodePacked(address delegate, bytes innerSig)
        //
        //  ⚠ WHY THIS CANNOT COLLIDE WITH A REAL SIGNATURE. The branch is reached
        //  only when ALL of the following hold, which is a state that TODAY always
        //  reverts {SignatureVerification.InvalidSignatureLength}:
        //    • the signature is not 64/65 bytes (`!standardLength`), so it is not
        //      an ECDSA signature the branch above could have handled; and
        //    • the maker has NO CODE, so it has no `isValidSignature` of its own and
        //      the payload cannot be a 1271 signature meant for the maker.
        //  A CONTRACT maker never reaches here — it falls straight through to its
        //  own 1271 check below, exactly as before. That is deliberate and costs
        //  nothing: a contract maker manages its own signer set internally and has
        //  no need of this registry.
        //
        //  The filler choosing `delegate` grants it nothing. The registry lookup is
        //  keyed by the ORDER'S maker, so the only addresses that pass are the ones
        //  that maker nominated — naming any other is just a failed lookup.
        //
        //  An envelope whose TOTAL length lands on 64 or 65 bytes is unreachable
        //  (it would be read as a plain ECDSA signature above); builders must not
        //  emit an `innerSig` of 44 or 45 bytes. No real signature scheme produces
        //  one.
        if (!standardLength && sigBody.length > 20 && expected.code.length == 0) {
            // `sigBody.length > 20` is the guard above, so both halves are in bounds.
            address contractSigner;
            bytes calldata inner;
            /// @solidity memory-safe-assembly
            assembly {
                contractSigner := shr(96, calldataload(sigBody.offset))
                inner.offset := add(sigBody.offset, 20)
                inner.length := sub(sigBody.length, 20)
            }
            uint256 expiry = orderSignerExpiry[expected][contractSigner];
            if (expiry != 0 && block.timestamp <= expiry) {
                SignatureVerification.verify(inner, digest, contractSigner);
                return;
            }
        }

        // Everything else: EIP-1271 contract wallets, EIP-7702 accounts delegated to
        // a 1271 wallet, and every failure — routed to the shared verifier so the
        // revert reason stays exactly as precise as it was.
        //
        // COST NOTE: a CONTRACT maker whose 1271 signature happens to be 64 or 65
        // bytes pays one extra (cold) SLOAD for the registry probe above before
        // landing here. Safe wallets and the rest produce longer payloads, which
        // `tryRecoverSigner` rejects on length alone, so they skip it entirely.
        SignatureVerification.verify(sigBody, digest, expected);
    }

    /// @dev `uint8(b[b.length - 1])` without the index bounds check — only called once
    ///      the caller has proven `b.length >= 98`.
    function _lastByte(bytes calldata b) private pure returns (uint256 r) {
        /// @solidity memory-safe-assembly
        assembly {
            r := byte(0, calldataload(add(b.offset, sub(b.length, 1))))
        }
    }

    /// @dev Fold an inclusion proof into its Merkle root, hashing SORTED pairs (the
    ///      OpenZeppelin convention, so any standard tree builder produces compatible
    ///      proofs). Hashed in scratch space — a `bytes32[] calldata` decode plus
    ///      `abi.encodePacked` per level would allocate on every level for a fixed
    ///      64-byte preimage.
    function _foldProof(bytes32 leaf, bytes calldata proof) private pure returns (bytes32 h) {
        h = leaf;
        uint256 levels = proof.length / 32;
        for (uint256 i; i < levels;) {
            /// @solidity memory-safe-assembly
            assembly {
                let p := calldataload(add(proof.offset, mul(i, 32)))
                switch lt(h, p)
                case 1 {
                    mstore(0x00, h)
                    mstore(0x20, p)
                }
                default {
                    mstore(0x00, p)
                    mstore(0x20, h)
                }
                h := keccak256(0x00, 0x40)
            }
            unchecked {
                ++i;
            }
        }
    }
}
