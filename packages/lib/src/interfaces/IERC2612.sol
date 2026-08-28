// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IERC2612
/// @notice EIP-2612 permit extension for ERC-20 tokens. Allows approvals to be
///         made via off-chain signatures, so the token holder never needs to send
///         a separate `approve` transaction and can therefore operate gaslessly.
interface IERC2612 {
    /// @notice Set `value` as the allowance of `spender` over `owner`'s tokens,
    ///         given a signed approval by `owner`. Reverts if the signature is
    ///         invalid, expired, or the nonce has already been consumed.
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;

    /// @notice Returns the current permit nonce for `owner`. Must be included in
    ///         the signed message and incremented after each successful permit call.
    function nonces(address owner) external view returns (uint256);

    /// @notice Returns the EIP-712 domain separator used in the permit encoding.
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
