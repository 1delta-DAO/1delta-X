// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ITimelockERC4626
/// @notice Minimal interface for an ERC-4626 vault that enforces a time-lock
///         between redeem request and asset release.
///
///  Expected vault behaviour
///  ────────────────────────
///  1. `requestRedeem(shares)` — caller transfers `shares` to the vault and
///     receives back a unique `requestId`. The vault records `block.timestamp`
///     as the start of the lock window.
///  2. After `lockDuration` seconds, `claimRedeem(requestId, receiver)` may
///     be called **by the same address that submitted the request** (or by
///     an operator if the vault supports delegation — out of scope here).
///     The vault burns the shares and sends the underlying asset to `receiver`.
///
///  The lock is enforced by the vault. The module adds an independent early-
///  exit check using the `unlocksAt` timestamp it records at request time,
///  so callers receive a descriptive error before spending gas on the vault call.
interface ITimelockERC4626 {
    /// @notice Submit a redeem request. The vault pulls `shares` from `msg.sender`
    ///         (caller must have approved the vault) and queues the withdrawal.
    /// @return requestId Opaque identifier for this request; used to claim later.
    function requestRedeem(uint256 shares) external returns (uint256 requestId);

    /// @notice Claim a matured redeem request. Only callable by the original
    ///         requester. Reverts if `lockDuration` has not yet elapsed.
    /// @return assets Amount of underlying token sent to `receiver`.
    function claimRedeem(uint256 requestId, address receiver) external returns (uint256 assets);

    /// @notice Minimum seconds that must pass between request and claim.
    function lockDuration() external view returns (uint256);

    /// @notice ERC-4626 underlying asset address.
    function asset() external view returns (address);
}
