// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SignatureVerification} from "./SignatureVerification.sol";
import {AllowanceTransfer} from "./AllowanceTransfer.sol";
import {TakerAllowance} from "./TakerAllowance.sol";
import {UnorderedNonces} from "./UnorderedNonces.sol";
import {Permit3Hash} from "./libraries/Permit3Hash.sol";

/// @title SignedPermits
/// @notice The signature layer over both allowance books: one EIP-712 message
///         grants token allowances and taker allowances together, so a maker can
///         authorise everything an order needs in a single signature.
///
///         `permitBatchWithWitness` binds that grant to an arbitrary caller-defined
///         witness (in practice, an order hash) — the signature that opens the
///         allowances is the same signature that authorises the order consuming
///         them, and it cannot be lifted onto a different order.
///
/// @dev    Sits ABOVE the books and writes them through their internal appliers, so
///         neither book carries any signature surface of its own.
///
///  PROVENANCE — Permit2 `AllowanceTransfer.permit()` (Uniswap, MIT), reworked.
///  ─────────────────────────────────────────────────────────────────────────
///  FROM PERMIT2, in kind:
///    • the idea of a signed message that GRANTS allowances rather than moving
///      tokens, and the `witnessTypeString` convention (which Permit2 applies
///      only to signature transfers — see {SignatureTransfer})
///  CHANGED:
///    • One message type, not two. Permit2 has `PermitSingle` and `PermitBatch`,
///      both scoped to a single spender; Permit3 has only `PermitBatch`, it
///      spans BOTH books, and each leg names its own spender.
///    • Replay protection is the unordered bitmap ({UnorderedNonces}), not
///      Permit2's sequential per-(owner, token, spender) allowance nonce. So
///      there is no `InvalidNonce`-on-mismatch path and no ordering requirement
///      between two in-flight permits.
///    • Witness binding on an ALLOWANCE grant has no Permit2 counterpart: it is
///      what lets one maker signature cover both the allowances and the order
///      that consumes them.
///    • Verify-then-spend-nonce, where Permit2's signature transfers spend the
///      nonce first. Both spend it before any external call; this order is used
///      consistently across {SignedPermits} and {SignatureTransfer}.
abstract contract SignedPermits is UnorderedNonces, AllowanceTransfer, TakerAllowance {
    using SignatureVerification for bytes;

    function permitBatch(address owner, PermitBatch calldata batch, bytes calldata sig) external override {
        if (block.timestamp > batch.deadline) revert PermitExpired();
        _verifyPermitSig(owner, Permit3Hash.hash(batch), sig);
        _usePermitNonce(owner, batch.nonce);
        _applyBatch(owner, batch);
        emit PermitBatchApplied(owner, batch.nonce);
    }

    function permitBatchWithWitness(
        address owner,
        PermitBatch calldata batch,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata sig
    ) external override {
        if (block.timestamp > batch.deadline) revert PermitExpired();
        _verifyPermitSig(owner, Permit3Hash.hashWithWitness(batch, witness, witnessTypeString), sig);
        _usePermitNonce(owner, batch.nonce);
        _applyBatch(owner, batch);
        emit PermitBatchApplied(owner, batch.nonce);
    }

    // ──────────────────── Internal ────────────────────

    function _verifyPermitSig(address owner, bytes32 hashStruct, bytes calldata sig) internal view {
        // SignatureVerification handles EOA (65-byte & EIP-2098 compact),
        // EIP-1271 contract signatures, and EIP-7702 accounts (raw-key or
        // delegated-1271), and enforces length / signer checks.
        sig.verify(_hashTypedData(hashStruct), owner);
    }

    function _applyBatch(address owner, PermitBatch calldata batch) private {
        _applyTokenPermits(owner, batch.tokens);
        _applyTakerPermits(owner, batch.takers);
    }
}
