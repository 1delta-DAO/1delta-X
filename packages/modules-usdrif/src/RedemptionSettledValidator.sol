// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IOrderValidator} from "@core/interfaces/IOrderValidator.sol";
import {LimitOrder} from "@core/settlement/LimitOrderSettlement.sol";

import {IMocQueue} from "./interfaces/IMoc.sol";

/// @title RedemptionSettledValidator
/// @notice Pre-execution gate: a USDRIF→USDT0 exit order may only fill once the
///         maker's MoC redemption has actually settled with sufficient RIF
///         backing. The Permit3 RIF pull in the fill already enforces this
///         implicitly (no RIF → pull reverts), but this validator gives a clean,
///         explicit revert and lets the seller bind the exact `opId`.
///
///         Settlement detection is FIFO-based: MoC executes queued operations in
///         order, advancing `firstOperId`, so `opId < firstOperId()` means the
///         op has been dequeued. Combined with an explicit RIF balance floor it
///         also covers the case where the op was dequeued but errored (no RIF
///         delivered).
///
/// @dev    `data = abi.encode(address mocQueue, uint256 opId, address user, uint256 minRif)`.
///         RIF is fixed per deployment (immutable), matching the plan's data shape.
contract RedemptionSettledValidator is IOrderValidator {
    /// @notice The RIF asset-collateral token (redemption output).
    address public immutable rif;

    constructor(address rif_) {
        rif = rif_;
    }

    function validate(LimitOrder calldata, bytes calldata data) external view override returns (bool) {
        (address mocQueue, uint256 opId, address user, uint256 minRif) =
            abi.decode(data, (address, uint256, address, uint256));

        // Executed/dequeued iff its id is below the queue head.
        bool settled = IMocQueue(mocQueue).firstOperId() > opId;

        return settled && IERC20(rif).balanceOf(user) >= minRif;
    }
}
