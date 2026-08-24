// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPriceModule} from "@core/interfaces/IPriceModule.sol";

/// @title RangePriceModule
/// @notice Prices an order along the FILL-PROGRESS axis instead of the clock: the
///         bump is a linear function of how much of the order is already filled, so
///         the first slice clears at one price and later slices at another. This is
///         the range/ladder order — 1inch's `RangeAmountCalculator` — expressed as a
///         bump, which means the maker's signed `start`/`end` band still bounds every
///         fill absolutely (see {IPriceModule}).
///
///         `bump = START_BPS + (END_BPS - START_BPS) · prevFilled / total`, clamped
///         to the direction the deployer configured. START_BPS is the bump at 0%
///         filled and END_BPS the bump at 100%; START < END means the maker's price
///         gets worse as the order fills (sell into strength, the usual ladder), and
///         START > END means it improves (accumulate on the way down).
///
///         ONE instance per (start, end) pair, shared by every maker who wants that
///         shape — the configuration is immutable and the order commits to it by
///         signing this address.
///
/// @dev    Progress is measured on `prevFilled`, the state BEFORE this fill, so a
///         single fill is priced at one uniform bump rather than integrated across
///         the slice it consumes. That is the maker-favourable, filler-predictable
///         choice: a solver quoting a fill knows the exact bump before submitting,
///         and a large fill is priced where it STARTED, not where it ended.
contract RangePriceModule is IPriceModule {
    uint256 internal constant BPS = 10_000;

    uint256 public immutable START_BPS;
    uint256 public immutable END_BPS;

    error InvalidRange();

    constructor(uint256 startBps, uint256 endBps) {
        if (startBps > BPS || endBps > BPS) revert InvalidRange();
        START_BPS = startBps;
        END_BPS = endBps;
    }

    /// @inheritdoc IPriceModule
    function bump(
        bytes32, /*orderHash*/
        address, /*maker*/
        address, /*filler*/
        uint256 prevFilled,
        uint256 total,
        uint256, /*orderTiming*/
        bytes calldata, /*legsIn*/
        bytes calldata, /*legsOut*/
        bytes calldata /*takerData*/
    ) external view returns (uint256) {
        // A zero denominator is not this module's to reject — the core resolved it —
        // but dividing by it here would revert the fill with an opaque panic. Price
        // an unstarted order at its opening bump.
        if (total == 0 || prevFilled == 0) return START_BPS;
        if (prevFilled >= total) return END_BPS;
        if (END_BPS >= START_BPS) {
            return START_BPS + ((END_BPS - START_BPS) * prevFilled) / total;
        }
        return START_BPS - ((START_BPS - END_BPS) * prevFilled) / total;
    }
}
