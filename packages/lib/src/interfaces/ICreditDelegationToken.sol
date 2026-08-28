// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal Aave V3 variable/stable debt token interface for EIP-712
///         delegation-with-sig. Allows a delegatee to borrow on the delegator's
///         behalf without a prior on-chain `approveDelegation` call.
interface ICreditDelegationToken {
    function delegationWithSig(
        address delegator,
        address delegatee,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function borrowAllowance(address fromUser, address toUser) external view returns (uint256);
}
