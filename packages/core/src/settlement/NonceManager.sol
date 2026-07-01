// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title NonceManager
/// @notice Maker self-service order cancellation via a per-maker nonce bitmap.
///         An order's `nonce` is cancelled by setting its bit; a cancelled
///         nonce can never be filled. Word-level invalidation cancels 256
///         nonces at once. Inherited by the settler so `nonceBitmap` occupies
///         the first storage slot.
abstract contract NonceManager {
    /// @notice maker → word index → bitmap of cancelled nonces
    mapping(address => mapping(uint256 => uint256)) public nonceBitmap;

    event OrdersCancelled(address indexed maker, uint256[] nonces);

    /// @notice Cancel a list of the caller's order nonces.
    function cancelOrders(uint256[] calldata noncesToCancel) external {
        for (uint256 i; i < noncesToCancel.length; i++) {
            _cancelNonce(msg.sender, noncesToCancel[i]);
        }
        emit OrdersCancelled(msg.sender, noncesToCancel);
    }

    /// @notice Cancel all 256 nonces in `wordIndex` at once.
    function invalidateNonceWord(uint256 wordIndex) external {
        nonceBitmap[msg.sender][wordIndex] = type(uint256).max;
    }

    function isNonceCancelled(address maker, uint256 nonce) external view returns (bool) {
        return _isNonceCancelled(maker, nonce);
    }

    function _cancelNonce(address maker, uint256 nonce) internal {
        nonceBitmap[maker][nonce >> 8] |= (1 << (nonce & 0xff));
    }

    function _isNonceCancelled(address maker, uint256 nonce) internal view returns (bool) {
        return (nonceBitmap[maker][nonce >> 8] & (1 << (nonce & 0xff))) != 0;
    }
}
