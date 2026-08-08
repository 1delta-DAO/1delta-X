// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IOrderValidator} from "@core/interfaces/IOrderValidator.sol";
import {Order} from "@core/settlement/Settlement.sol";

import {IMocQueue} from "./interfaces/IMoc.sol";

/// @title RedemptionSettledValidator
/// @notice Pre-execution gate: a USDRIF→USDT0 exit order may only fill once the
///         maker's MoC redemption has actually settled with sufficient RIF
///         backing. The Permit3 RIF pull in the fill already enforces this
///         implicitly (no RIF → pull reverts), but this validator gives a clean,
///         explicit revert and lets the seller bind the exact `opId`.
///
///         Settlement detection: an op is settled-and-cleared once MoC has
///         executed and *deleted* it, which `opersInfo(opId).operType == 0`
///         reports directly — strictly stronger than the FIFO `firstOperId()`
///         head check, which only proves the op was dequeued (it could have
///         dequeued-but-errored). We still require an explicit RIF balance floor
///         as defence-in-depth.
///
///         Caveat (documented, not silently assumed): MoC exposes no per-op
///         payout record, so even `operType == 0` cannot by itself prove that
///         *this* op delivered RIF to `user` — a dequeued-but-errored op is also
///         deleted. The balance floor is a necessary, not sufficient, signal
///         (the maker may hold RIF for unrelated reasons). The Permit3 RIF pull
///         during the fill remains the sole hard guarantee that backing exists;
///         this validator is a liveness gate, and we now require the op to have
///         actually cleared rather than merely passed the queue head.
///
/// @dev    `data = abi.encode(address mocQueue, uint256 opId, address user, uint256 minRif)`.
///         RIF is fixed per deployment (immutable), matching the plan's data shape.
contract RedemptionSettledValidator is IOrderValidator {
    /// @notice The RIF asset-collateral token (redemption output).
    address public immutable rif;

    constructor(address rif_) {
        rif = rif_;
    }

    function validate(Order calldata, address, bytes calldata data, bytes calldata)
        external
        view
        override
        returns (bool)
    {
        (address mocQueue, uint256 opId, address user, uint256 minRif) =
            abi.decode(data, (address, uint256, address, uint256));

        // opId must already be assigned (guards against an unsubmitted/future id
        // trivially passing once the queue head advances past it).
        if (opId >= IMocQueue(mocQueue).operIdCount()) return false;

        // Settled-and-cleared iff the op has been executed and deleted (type 0).
        (uint8 operType,) = IMocQueue(mocQueue).opersInfo(opId);
        bool settled = operType == 0;

        return settled && IERC20(rif).balanceOf(user) >= minRif;
    }
}
