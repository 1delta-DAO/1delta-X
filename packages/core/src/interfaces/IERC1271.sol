// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IERC1271
/// @notice Standard interface for contract (smart-account) signature
///         validation, per EIP-1271.
interface IERC1271 {
    /// @dev Should return whether the signature provided is valid for the
    ///      provided hash. MUST return the bytes4 magic value
    ///      0x1626ba7e (i.e. `IERC1271.isValidSignature.selector`) when valid.
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4 magicValue);
}
