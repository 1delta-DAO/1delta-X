// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title FeeConfig
/// @notice Pack/unpack helper for an order's optional sourcing fee, stored as a
///         single `bytes32 feeConfig` on the {Order}:
///
///           bits   0..159  → fee recipient (address)     — low 20 bytes
///           bits 160..255  → fee in bps (uint96)         — high 12 bytes
///
///         `bytes32(0)` means "no fee" (recipient zero, bps zero). The fee is
///         skimmed from the maker's `tokenOut` delivery and routed to the
///         recipient — the party that sourced the order — so it is entirely
///         maker-signed, per-order, and optional. There is NO global fee switch.
///
/// @dev    The high bits hold far more than a bps value needs (~14 bits), leaving
///         headroom for future flags. Any such flag would be carved from the top
///         of the fee word and masked here; today the whole high word is the fee
///         and the caller bounds it by `MAX_FEE_BPS`, which keeps stray high bits
///         from ever passing.
library FeeConfig {
    /// @notice Absolute ceiling on the fee, in bps (10% = 1000). A larger value
    ///         is treated as a malformed order and rejected at fill time.
    uint256 internal constant MAX_FEE_BPS = 1_000;

    function unpack(bytes32 feeConfig) internal pure returns (address recipient, uint256 feeBps) {
        uint256 raw = uint256(feeConfig);
        recipient = address(uint160(raw));
        feeBps = raw >> 160;
    }

    function pack(address recipient, uint256 feeBps) internal pure returns (bytes32) {
        return bytes32((feeBps << 160) | uint256(uint160(recipient)));
    }
}
