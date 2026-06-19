// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal Compound V3 (Comet) interface for EIP-712 allow-by-sig.
///         Grants `manager` permission to call `withdrawFrom` on the owner's
///         position without a prior on-chain `allow` call.
interface ICometAllow {
    function allowBySig(
        address owner,
        address manager,
        bool isAllowed,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}
