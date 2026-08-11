// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISignatureTransfer} from "../interfaces/ISignatureTransfer.sol";
import {SafeTransferLib} from "../utils/SafeTransferLib.sol";
import {SignatureVerification} from "./SignatureVerification.sol";
import {UnorderedNonces} from "./UnorderedNonces.sol";
import {Permit3Hash} from "./libraries/Permit3Hash.sol";

/// @title SignatureTransfer
/// @notice One-shot signed transfers, ported from Permit2's `SignatureTransfer`.
///         The owner signs "`spender` may move at most `amount` of `token`, once,
///         before `deadline`"; the spender consumes it by naming a recipient and
///         an amount at or below the cap. Nothing is written to either allowance
///         book — when the call returns, no authority remains.
///
///         This is the complement to {SignedPermits}: same signature stack, same
///         nonce space, opposite lifetime. Use a signature transfer for a payment
///         that happens now, an allowance permit for a budget drawn down later.
///
/// @dev    THE SIGNED `spender` IS ALWAYS `msg.sender`. It is not a parameter, so
///         a signature that leaks — from a mempool, a failed relay, a logged
///         request — cannot be consumed by anyone other than the spender the owner
///         meant it for. Never add an overload that takes `spender` as an argument.
///
///  PROVENANCE — Permit2 `src/SignatureTransfer.sol` (Uniswap, MIT). The closest
///  ─────────────────────────────────────────────────────────────────────────
///  thing to a straight port in this package.
///
///  FROM PERMIT2, semantics unchanged:
///    • all four entry points — `permitTransferFrom` / `permitWitnessTransferFrom`,
///      single and batched — with the same argument order
///    • the `TokenPermissions` / `PermitTransferFrom` / `PermitBatchTransferFrom`
///      / `SignatureTransferDetails` structs, field for field
///    • BYTE-IDENTICAL EIP-712 type strings and witness stubs (see
///      {Permit3Hash}), so signing tooling needs no changes. Digests still
///      differ: the domain names this contract, so no signature crosses between
///      Permit2 and Permit3 in either direction.
///    • `SignatureExpired` / `InvalidAmount` / `LengthMismatch`, the per-leg cap
///      check, and the zero-`requestedAmount` leg skip in the batch loop
///  CHANGED:
///    • Verify-then-spend-nonce; Permit2 spends the nonce first. Both spend it
///      before the token moves, so neither can be replayed by a re-entrant
///      token; this order matches {SignedPermits}.
///    • Nonces come from the bitmap SHARED with the allowance permits, where
///      Permit2's `nonceBitmap` is private to signature transfers. See
///      {UnorderedNonces}.
///    • `calldata` permit structs (Permit2 takes them in `memory`), and the
///      repo's own `SafeTransferLib` rather than solmate's.
///    • `SignatureExpired` is declared on {ISignatureTransfer}; Permit2 keeps it
///      in a shared `PermitErrors.sol`.
abstract contract SignatureTransfer is ISignatureTransfer, UnorderedNonces {
    using SignatureVerification for bytes;

    // ──────────────────── Single ────────────────────

    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external override {
        _permitTransferFrom(permit, transferDetails, owner, Permit3Hash.hash(permit, msg.sender), signature);
    }

    function permitWitnessTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external override {
        _permitTransferFrom(
            permit,
            transferDetails,
            owner,
            Permit3Hash.hashWithWitness(permit, msg.sender, witness, witnessTypeString),
            signature
        );
    }

    // ──────────────────── Batch ────────────────────

    function permitTransferFrom(
        PermitBatchTransferFrom calldata permit,
        SignatureTransferDetails[] calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external override {
        _permitBatchTransferFrom(permit, transferDetails, owner, Permit3Hash.hash(permit, msg.sender), signature);
    }

    function permitWitnessTransferFrom(
        PermitBatchTransferFrom calldata permit,
        SignatureTransferDetails[] calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external override {
        _permitBatchTransferFrom(
            permit,
            transferDetails,
            owner,
            Permit3Hash.hashWithWitness(permit, msg.sender, witness, witnessTypeString),
            signature
        );
    }

    // ──────────────────── Internal ────────────────────

    /// @dev Expiry, cap, signature, nonce, then transfer. Permit2 spends the
    ///      nonce BEFORE verifying the signature; the swap is deliberate, so that
    ///      every signed flow in this package reads the same way ({SignedPermits}
    ///      verifies first too). It is not a security difference: what matters is
    ///      that the nonce is spent before the token moves, so a token that
    ///      re-enters cannot replay the same permit inside its own callback.
    function _permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 hashStruct,
        bytes calldata signature
    ) private {
        if (block.timestamp > permit.deadline) revert SignatureExpired(permit.deadline);
        uint256 requested = transferDetails.requestedAmount;
        if (requested > permit.permitted.amount) revert InvalidAmount(permit.permitted.amount);

        signature.verify(_hashTypedData(hashStruct), owner);
        _usePermitNonce(owner, permit.nonce);

        SafeTransferLib.safeTransferFrom(permit.permitted.token, owner, transferDetails.to, requested);
    }

    function _permitBatchTransferFrom(
        PermitBatchTransferFrom calldata permit,
        SignatureTransferDetails[] calldata transferDetails,
        address owner,
        bytes32 hashStruct,
        bytes calldata signature
    ) private {
        if (block.timestamp > permit.deadline) revert SignatureExpired(permit.deadline);
        uint256 length = permit.permitted.length;
        // One `TokenPermissions` per leg — a mismatch would let the caller draw a
        // leg against the wrong cap, so it is rejected outright rather than
        // truncated to the shorter array.
        if (length != transferDetails.length) revert LengthMismatch();

        signature.verify(_hashTypedData(hashStruct), owner);
        _usePermitNonce(owner, permit.nonce);

        for (uint256 i; i < length;) {
            TokenPermissions calldata permitted = permit.permitted[i];
            uint256 requested = transferDetails[i].requestedAmount;
            if (requested > permitted.amount) revert InvalidAmount(permitted.amount);
            // A zero-amount leg is a no-op, not an error: it lets a caller sign a
            // fixed-shape batch and skip legs it does not need.
            if (requested != 0) {
                SafeTransferLib.safeTransferFrom(permitted.token, owner, transferDetails[i].to, requested);
            }
            unchecked {
                ++i;
            }
        }
    }
}
