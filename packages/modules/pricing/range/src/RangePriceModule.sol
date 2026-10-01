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
///         `bump = START_BPS + (END_BPS - START_BPS) · prevFilled / total`, with
///         `START_BPS <= END_BPS`: START_BPS is the bump at 0% filled and END_BPS the
///         bump at 100%, so the maker's price gets worse as the order fills (sell
///         into strength — the usual ladder, and the only direction 1inch's
///         calculator supports).
///
///         ONE instance per (start, end) pair, shared by every maker who wants that
///         shape — the configuration is immutable and the order commits to it by
///         signing this address.
///
/// @dev    Progress is measured on `prevFilled`, the state BEFORE this fill, so a
///         single fill is priced at one uniform bump rather than integrated across
///         the slice it consumes ({IPriceModule} is never told the fill's size). On
///         an ASCENDING ladder that is the maker-favourable, filler-predictable
///         choice: a solver quoting a fill knows the exact bump before submitting, a
///         large fill is priced where it STARTED (the maker's best remaining point),
///         and splitting can only move later slices toward the prices the maker
///         signed for them.
///
///         ⚠ A DESCENDING ladder (`START_BPS > END_BPS`, "the maker's price improves
///         as it fills") is REJECTED at construction (audit 2026-09-30 PRICE-3). With
///         prevFilled sampling it collapses: a fill at progress 0 is priced at
///         START_BPS — the maker's WORST point — for its whole size, so a rational
///         filler takes 100% in one fill and the ladder never descends. Pricing it
///         correctly needs the fill's size (an integral over the slice), which is an
///         {IPriceModule} ABI change in core. Rejecting it also retires the
///         descending branch's filler-ward rounding (PRICE-4).
contract RangePriceModule is IPriceModule {
    uint256 internal constant BPS = 10_000;

    uint256 public immutable START_BPS;
    uint256 public immutable END_BPS;

    error InvalidRange();
    /// @dev `START_BPS > END_BPS`: a descending ladder, which prevFilled sampling
    ///      cannot price (see the contract note).
    error DescendingRange();

    constructor(uint256 startBps, uint256 endBps) {
        if (startBps > BPS || endBps > BPS) revert InvalidRange();
        if (startBps > endBps) revert DescendingRange();
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
        // Floor division lowers the bump: rounds toward the maker.
        return START_BPS + ((END_BPS - START_BPS) * prevFilled) / total;
    }
}
