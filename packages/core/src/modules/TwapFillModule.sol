// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFillModule} from "../interfaces/IFillModule.sol";
import {Order} from "../settlement/SettlementStructs.sol";

/// @title TwapFillModule
/// @notice A time-weighted (TWAP) fill schedule as a fill module: one signed
///         order is released in N equal, time-sliced parts, and a fill can only
///         advance the order up to the parts whose window has opened. The
///         scheduling half of a CoW-style TWAP, with no watchtower or generated
///         sub-orders — a solver just calls `fill` in each window and the module
///         admits the right slice. The core still keeps the over-fill cap and
///         the single-fraction scaling; this module only gates the delta by time.
///
///         The schedule rides existing maker-signed `Order` fields (no dedicated
///         config field needed):
///
///           fillTotal       = total amount to trade (the denominator)
///           minFillAnchor   = part size  ⇒ parts = fillTotal / minFillAnchor
///           decayStartTime  = TWAP start (unix)
///           decayDuration   = total window ⇒ partDuration = decayDuration / parts
///
///         Behavior:
///           • Part `k` (1-indexed) opens at `start + (k-1)·partDuration`.
///           • `resolveFill` releases `partsOpen·partSize − prevFilled` — so a
///             fill can never run AHEAD of the schedule, one part per window is
///             the steady state, and a solver that skipped windows can CATCH UP
///             on the accrued parts in one fill.
///           • A solver may take FEWER whole parts than are open (pass a smaller
///             `fillAmount`, rounded down to a part boundary) — e.g. to source
///             just one part's liquidity per fill.
///           • Nothing new open (before start, or already caught up) reverts, so
///             the fill fails cleanly.
///
///         Pricing is orthogonal (kept in `DutchAuction`): a fixed-price order
///         (`start == end` legs) gives a fixed limit per part; a market-tracking
///         limit is layered on with an oracle validator over the `takerData`
///         seam. This module only schedules; it does not price.
///
/// @dev    `view`/pure — invoked as a STATICCALL by the settlement, so it can
///         neither mutate state nor reenter. Requires `fillTotal % minFillAnchor
///         == 0` (equal parts, no dust remainder that would trip the core's
///         `delta >= minFillAnchor` floor on the last part).
contract TwapFillModule is IFillModule {
    error TwapNotConfigured();
    error TwapPartUnavailable();

    /// @inheritdoc IFillModule
    function resolveFill(Order calldata order, uint256 prevFilled, uint256 fillAmount, bytes calldata)
        external
        view
        returns (uint256 delta)
    {
        uint256 total = order.fillTotal;
        uint256 partSize = order.minFillAnchor;
        uint256 start = order.decayStartTime;
        uint256 duration = order.decayDuration;
        // Equal parts only; a dust final part < partSize would trip the core's
        // minFillAnchor floor. total/partSize must divide evenly.
        if (total == 0 || partSize == 0 || duration == 0 || total % partSize != 0) revert TwapNotConfigured();

        uint256 parts = total / partSize;
        uint256 partDuration = duration / parts;
        if (partDuration == 0) revert TwapNotConfigured();

        // Parts whose window has opened by now (1-indexed; nothing before start).
        if (block.timestamp < start) revert TwapPartUnavailable();
        uint256 partsOpen = (block.timestamp - start) / partDuration + 1;
        if (partsOpen > parts) partsOpen = parts;

        uint256 openAmount = partsOpen * partSize; // total unlocked by now (≤ total)
        if (openAmount <= prevFilled) revert TwapPartUnavailable(); // already caught up
        uint256 available = openAmount - prevFilled; // prevFilled is always a part multiple

        // Let the solver take fewer WHOLE parts than are open (never a fraction).
        delta = available;
        if (fillAmount != 0 && fillAmount < available) {
            uint256 wholeParts = fillAmount / partSize;
            if (wholeParts == 0) revert TwapPartUnavailable(); // requested less than a part
            delta = wholeParts * partSize;
        }
    }
}
