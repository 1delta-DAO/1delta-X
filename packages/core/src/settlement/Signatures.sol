// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SignatureVerification} from "../permit3/SignatureVerification.sol";
import {OrderState} from "./OrderState.sol";

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

    /// @dev Authorize `orderHash` for `expected` (the order's maker). Either the
    ///      empty-sig on-chain-approval path or a real signature over the domain-
    ///      bound digest; reverts if neither authorizes.
    ///
    ///      FIRST-FILL ONLY, FOR REAL SIGNATURES. A non-zero `filled[orderHash]` can only have been written
    ///      by {OrderState._openFill}, which every entry path reaches AFTER this gate
    ///      — so the counter being non-zero is itself proof that some earlier fill
    ///      presented valid authorization for this exact hash (and the hash commits to
    ///      `maker`). Re-deriving the digest and re-running `ecrecover` on every
    ///      partial fill therefore proves nothing new. Ported from 1inch LOP v4, which
    ///      gates on `remaining == makingAmount` for the same reason.
    ///
    ///      COST, measured: the added read is NOT free, but it is nearly so —
    ///      {_openFill} SLOADs the same slot moments later, so this only moves the
    ///      cold access earlier and leaves that one warm. Net **+150 gas on a first /
    ///      single fill**, **−2,860 on every fill after it** (−14,531 across a TWAP
    ///      schedule). A path that reverts BEFORE `_openFill` (a failing validator, a
    ///      cancelled nonce) pays the ~2,100 cold read for nothing — the +2,374…+4,374
    ///      seen on revert-path tests. Worth it: fillers simulate before submitting, so
    ///      reverts are off the real hot path, and any order filled more than once
    ///      repays the 150 nineteen times over.
    ///      The cancelled sentinel (`type(uint256).max`) also skips — {_openFill}
    ///      rejects it a moment later with the precise {OrderCancelled}.
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
    function _verifySignature(bytes32 orderHash, bytes calldata sig, address expected) internal view {
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
        if (filled[orderHash] != 0) return; // already authorized once — see above
        bytes32 digest = _hashTypedData(orderHash);
        // Shared verifier: EOA (ecrecover), EIP-1271 contract wallets, and
        // EIP-7702 accounts (raw-key or delegated-1271) are all accepted.
        SignatureVerification.verify(sig, digest, expected);
    }

    /// @dev EOA-only authorization from an EIP-2098 COMPACT signature passed as two
    ///      bare words. The `bytes sig` form costs an offset word, a length word and
    ///      65 bytes padded to 96 — 160 bytes of calldata against 64 here, and the
    ///      saving is pure calldata, which is what dominates cost on rollups.
    ///
    ///      Deliberately NO EIP-1271 fallback: a contract wallet's signature is not
    ///      65 bytes, so it could never take this path anyway. Contract signers,
    ///      7702-delegated-1271 accounts and the empty-sig {approveOrder} path all
    ///      keep using the `bytes` entrypoints. Same split 1inch draws between
    ///      `fillOrder` and `fillContractOrder`.
    ///
    ///      Same first-fill-only skip as {_verifySignature}, for the same reason.
    function _verifySignatureCompact(bytes32 orderHash, bytes32 r, bytes32 vs, address expected) internal view {
        if (filled[orderHash] != 0) return; // already authorized once
        // EIP-2098: `vs` carries `s` in its low 255 bits and `v - 27` in the top bit.
        address signer = ecrecover(
            _hashTypedData(orderHash), uint8(uint256(vs >> 255)) + 27, r, vs & SignatureVerification.UPPER_BIT_MASK
        );
        if (signer == address(0) || signer != expected) revert SignatureVerification.InvalidSigner();
    }
}
