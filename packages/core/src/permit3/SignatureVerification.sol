// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC1271} from "../interfaces/IERC1271.sol";

/// @title SignatureVerification
/// @notice PROVENANCE — adapted from Uniswap's Permit2
///         (https://github.com/Uniswap/permit2 — src/libraries/SignatureVerification.sol).
///         The error set, the EIP-2098 handling and the 1271 magic-value check
///         are Permit2's. Deviations: the ECDSA and 1271 branches are reordered
///         to the OpenZeppelin `SignatureChecker` pattern so EIP-7702 accounts
///         are fully supported (Permit2 predates 7702 and dispatches purely on
///         signature length), and the signature words are read straight from
///         calldata instead of being copied to memory first.
///
///         Verification is attempted ECDSA-first, then falls back to EIP-1271:
///           - plain EOAs                         → recover via ecrecover
///           - EIP-7702 accounts signing with     → recover via ecrecover
///             their own key (the delegated          (a 7702 account's address
///             account address == the EOA            still equals its key's
///             key's address)                        address)
///           - smart-contract wallets             → EIP-1271 isValidSignature
///           - EIP-7702 accounts delegated to a   → EIP-1271 isValidSignature
///             wallet implementing isValidSignature
///
///         Accepts both 65-byte and 64-byte (EIP-2098 compact) ECDSA
///         signatures; EIP-1271 signatures may be any length.
library SignatureVerification {
    /// @notice Thrown when the passed in signature is not a valid length
    error InvalidSignatureLength();

    /// @notice Thrown when the recovered signer is equal to the zero address
    error InvalidSignature();

    /// @notice Thrown when the recovered signer does not equal the claimedSigner
    error InvalidSigner();

    /// @notice Thrown when the recovered contract signature is incorrect
    error InvalidContractSignature();

    // 0x7f followed by 31 bytes of 0xff — clears only the top bit (EIP-2098 `s`).
    bytes32 constant UPPER_BIT_MASK = (0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);

    /// @notice Recover the ECDSA signer of a standard-length signature.
    /// @dev Split out of {verify} so a caller that needs to know WHO signed —
    ///      rather than merely whether a named party did — can ask without
    ///      duplicating the recovery, and without the two copies drifting. Used by
    ///      {Signatures._verifySignature} for maker-delegated order signing.
    /// @return standardLength whether the signature was 64/65 bytes, i.e. whether
    ///         ECDSA recovery was attempted at all. Callers MUST check it:
    ///         `signer == address(0)` alone cannot distinguish "not an ECDSA
    ///         signature" from "an ECDSA signature that recovered to nothing", and
    ///         {verify} takes a different branch for each.
    /// @return signer the recovered address, or `address(0)`.
    function recoverCalldata(bytes calldata signature, bytes32 hash)
        internal
        pure
        returns (bool standardLength, address signer)
    {
        if (signature.length != 65 && signature.length != 64) return (false, address(0));
        bytes32 r;
        bytes32 s;
        uint8 v;
        // Read the words STRAIGHT OUT OF CALLDATA. `abi.decode` on a `bytes
        // calldata` copies the payload into a fresh memory buffer and decodes it
        // back out; the words are already 32-byte aligned at `signature.offset`,
        // so the copy was pure overhead — on a path every fill and every permit
        // runs. `signature[64]` likewise carried a bounds check the enclosing
        // length test has already made redundant.
        if (signature.length == 65) {
            /// @solidity memory-safe-assembly
            assembly {
                r := calldataload(signature.offset)
                s := calldataload(add(signature.offset, 0x20))
                v := byte(0, calldataload(add(signature.offset, 0x40)))
            }
        } else {
            // EIP-2098 compact
            bytes32 vs;
            /// @solidity memory-safe-assembly
            assembly {
                r := calldataload(signature.offset)
                vs := calldataload(add(signature.offset, 0x20))
            }
            s = vs & UPPER_BIT_MASK;
            v = uint8(uint256(vs >> 255)) + 27;
        }
        return (true, ecrecover(hash, v, r, s));
    }

    function verify(bytes calldata signature, bytes32 hash, address claimedSigner) internal view {
        // 1. Attempt ECDSA recovery for standard-length signatures. This covers
        //    plain EOAs and EIP-7702 accounts signing with their own key, since
        //    a delegated account's address equals the underlying EOA key's
        //    address. We only short-circuit on a positive match; a mismatch
        //    falls through to the EIP-1271 path so contract wallets that happen
        //    to use 64/65-byte signatures are still honoured.
        (bool standardLength, address signer) = recoverCalldata(signature, hash);
        if (standardLength) {
            if (signer != address(0) && signer == claimedSigner) return;
            // A standard-length signature that does not recover to the signer
            // is only salvageable via EIP-1271; for a plain EOA it is final.
            if (claimedSigner.code.length == 0) revert InvalidSigner();
        } else if (claimedSigner.code.length == 0) {
            // A non-standard length can never be a valid ECDSA signature, and an
            // EOA has no isValidSignature to fall back to.
            revert InvalidSignatureLength();
        }

        // 2. Fall back to EIP-1271 for contract signers — smart-contract wallets
        //    and EIP-7702 accounts delegated to a wallet that implements it.
        bytes4 magicValue = IERC1271(claimedSigner).isValidSignature(hash, signature);
        if (magicValue != IERC1271.isValidSignature.selector) revert InvalidContractSignature();
    }
}
