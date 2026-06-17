// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC1271} from "../interfaces/IERC1271.sol";

/// @title SignatureVerification
/// @notice Adapted from Uniswap's Permit2
///         (https://github.com/Uniswap/permit2 — src/libraries/SignatureVerification.sol),
///         reordered to the OpenZeppelin `SignatureChecker` pattern so that
///         EIP-7702 accounts are fully supported.
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

    function verify(bytes calldata signature, bytes32 hash, address claimedSigner) internal view {
        // 1. Attempt ECDSA recovery for standard-length signatures. This covers
        //    plain EOAs and EIP-7702 accounts signing with their own key, since
        //    a delegated account's address equals the underlying EOA key's
        //    address. We only short-circuit on a positive match; a mismatch
        //    falls through to the EIP-1271 path so contract wallets that happen
        //    to use 64/65-byte signatures are still honoured.
        if (signature.length == 65 || signature.length == 64) {
            bytes32 r;
            bytes32 s;
            uint8 v;
            if (signature.length == 65) {
                (r, s) = abi.decode(signature, (bytes32, bytes32));
                v = uint8(signature[64]);
            } else {
                // EIP-2098 compact
                bytes32 vs;
                (r, vs) = abi.decode(signature, (bytes32, bytes32));
                s = vs & UPPER_BIT_MASK;
                v = uint8(uint256(vs >> 255)) + 27;
            }
            address signer = ecrecover(hash, v, r, s);
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
