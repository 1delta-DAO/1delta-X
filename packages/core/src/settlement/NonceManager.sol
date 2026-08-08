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

    /// @notice maker → rollback floor. Any order whose `nonce < minValidNonce`
    ///         is treated as cancelled. Lets a maker invalidate every outstanding
    ///         order below a threshold in ONE write (the 0x `minValidSalt`
    ///         "rollback" primitive), instead of flipping bits one word at a time.
    ///         Monotonic — can only ever advance.
    mapping(address => uint256) public minValidNonce;

    event OrdersCancelled(address indexed maker, uint256[] nonces);
    event NoncesRolledBack(address indexed maker, uint256 minValidNonce);
    /// @notice A maker invalidated all 256 nonces in `wordIndex` via
    ///         {invalidateNonceWord}. Emitted so bulk cancellation is visible to
    ///         indexers on the SAME footing as {OrdersCancelled}/{NoncesRolledBack} —
    ///         without it an orderbook watching only those two events would keep
    ///         serving orders this maker has already cancelled.
    event NonceWordInvalidated(address indexed maker, uint256 wordIndex);

    error RollbackTooLow();

    /// @notice Cancel a list of the caller's order nonces.
    function cancelOrders(uint256[] calldata noncesToCancel) external {
        uint256 len = noncesToCancel.length;
        for (uint256 i; i < len;) {
            _cancelNonce(msg.sender, noncesToCancel[i]);
            unchecked {
                ++i;
            }
        }
        emit OrdersCancelled(msg.sender, noncesToCancel);
    }

    /// @notice Cancel all 256 nonces in `wordIndex` at once.
    function invalidateNonceWord(uint256 wordIndex) external {
        nonceBitmap[msg.sender][wordIndex] = type(uint256).max;
        emit NonceWordInvalidated(msg.sender, wordIndex);
    }

    /// @notice Roll the caller's nonce floor forward to `newMinValidNonce`,
    ///         cancelling every outstanding order with a lower nonce in one write.
    ///         Reverts if it would move the floor backwards.
    function rollbackNonces(uint256 newMinValidNonce) external {
        if (newMinValidNonce < minValidNonce[msg.sender]) revert RollbackTooLow();
        minValidNonce[msg.sender] = newMinValidNonce;
        emit NoncesRolledBack(msg.sender, newMinValidNonce);
    }

    function isNonceCancelled(address maker, uint256 nonce) external view returns (bool) {
        return _isNonceCancelled(maker, nonce);
    }

    function _cancelNonce(address maker, uint256 nonce) internal {
        nonceBitmap[maker][nonce >> 8] |= (1 << (nonce & 0xff));
    }

    function _isNonceCancelled(address maker, uint256 nonce) internal view returns (bool) {
        if (nonce < minValidNonce[maker]) return true;
        return (nonceBitmap[maker][nonce >> 8] & (1 << (nonce & 0xff))) != 0;
    }
}
