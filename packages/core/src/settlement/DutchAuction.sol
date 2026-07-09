// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order, CurvePoint} from "./SettlementStructs.sol";

/// @title DutchAuction
/// @notice Dutch decay pricing. Every leg shares ONE clock and ONE normalized
///         decay `bumpBps ∈ [0, 10000]` (0 = the `start` price / best for maker,
///         10000 = the `end` price / worst). Each leg maps that shared bump
///         through its own `start`/`end` bounds. The shape of the bump over time
///         is either a single linear segment (`decayStartTime`/`decayDuration`)
///         or, if `curve` is non-empty, a piecewise-linear interpolation over the
///         signed `CurvePoint[]`. An optional gas bump adds decay proportional to
///         `block.basefee`, so the maker clears for less when gas is high.
///
///         SELL orders decay the OUTPUT legs (falling); BUY orders decay the
///         INPUT legs (rising). Fixed legs (`start == end`) ignore the bump.
library DutchAuction {
    error AuctionNotStarted();
    error InvalidAuctionParams();

    uint256 internal constant BPS = 10_000;

    /// @notice The shared normalized decay for this order at the current time,
    ///         in [0, 10000]. Piecewise if `curve` is set, else a single linear
    ///         segment; then the optional gas bump is added and the sum clamped.
    function bumpBps(Order calldata order) internal view returns (uint256 bps) {
        CurvePoint[] calldata curve = order.curve;
        uint256 n = curve.length;

        if (n == 0) {
            // Classic single linear segment.
            if (order.decayDuration != 0) {
                if (block.timestamp < order.decayStartTime) revert AuctionNotStarted();
                uint256 elapsed = block.timestamp - order.decayStartTime;
                bps = elapsed >= order.decayDuration ? BPS : (BPS * elapsed) / order.decayDuration;
            }
            // decayDuration == 0 ⇒ bps stays 0 (start price, no time decay).
        } else {
            // Piecewise-linear curve, timeDeltas relative to decayStartTime.
            if (block.timestamp < order.decayStartTime) revert AuctionNotStarted();
            uint256 elapsed = block.timestamp - order.decayStartTime;
            if (elapsed <= curve[0].timeDelta) {
                bps = curve[0].bumpBps;
            } else if (elapsed >= curve[n - 1].timeDelta) {
                bps = curve[n - 1].bumpBps;
            } else {
                for (uint256 k; k < n - 1; k++) {
                    uint256 t1 = curve[k + 1].timeDelta;
                    if (elapsed < t1) {
                        uint256 t0 = curve[k].timeDelta;
                        uint256 b0 = curve[k].bumpBps;
                        uint256 b1 = curve[k + 1].bumpBps;
                        uint256 span = t1 - t0; // > 0 for a well-formed (increasing) curve
                        // Interpolate; the curve may rise or fall between points.
                        bps = b1 >= b0
                            ? b0 + ((b1 - b0) * (elapsed - t0)) / span
                            : b0 - ((b0 - b1) * (elapsed - t0)) / span;
                        break;
                    }
                }
            }
        }

        // Gas bump: extra decay proportional to basefee, capped at gasBumpBps.
        uint256 gb = order.gasBumpBps;
        if (gb != 0 && order.gasPriceRef != 0) {
            uint256 gasAdd = (gb * block.basefee) / order.gasPriceRef;
            if (gasAdd > gb) gasAdd = gb;
            bps += gasAdd;
        }
        if (bps > BPS) bps = BPS;
    }

    /// @notice Output tick for leg `j` given a PRECOMPUTED shared `bump` (bps).
    ///         `pure` — the caller computes `bumpBps(order)` once per fill and
    ///         reuses it across every leg (the bump is shared by all legs), so a
    ///         basket doesn't recompute the curve/gas-bump per leg. Fixed legs
    ///         (`start == end`) ignore `bump` entirely.
    function amountOutAt(Order calldata order, uint256 j, uint256 bump) internal pure returns (uint256) {
        uint256 startOut = order.startAmountOut[j];
        uint256 endOut = order.endAmountOut[j];
        if (startOut < endOut) revert InvalidAuctionParams();
        if (startOut == endOut) return startOut; // fixed leg — no bump
        return startOut - ((startOut - endOut) * bump) / BPS;
    }

    /// @notice Current auction tick for output leg `j` (SELL: falling; BUY: fixed).
    function currentAmountOutAt(Order calldata order, uint256 j) internal view returns (uint256) {
        uint256 startOut = order.startAmountOut[j];
        uint256 endOut = order.endAmountOut[j];
        if (startOut < endOut) revert InvalidAuctionParams();
        if (startOut == endOut) return startOut; // fixed leg — no bump (skip bumpBps)

        uint256 decay = ((startOut - endOut) * bumpBps(order)) / BPS;
        return startOut - decay;
    }

    /// @notice Current auction tick for every output leg. Computes the shared
    ///         `bump` at most ONCE (lazily, only if some leg actually decays — so
    ///         an all-fixed order never calls `bumpBps`, preserving its behavior).
    function currentAmountOut(Order calldata order) internal view returns (uint256[] memory outs) {
        uint256 n = order.tokenOut.length;
        outs = new uint256[](n);
        uint256 bump;
        bool bumpSet;
        for (uint256 j; j < n; j++) {
            if (order.startAmountOut[j] != order.endAmountOut[j] && !bumpSet) {
                bump = bumpBps(order);
                bumpSet = true;
            }
            outs[j] = amountOutAt(order, j, bump);
        }
    }

    /// @notice Input tick for leg `i` given a PRECOMPUTED shared `bump` (bps).
    ///         `pure` counterpart of `amountOutAt` — see it for the rationale.
    function amountInAt(Order calldata order, uint256 i, uint256 bump) internal pure returns (uint256) {
        uint256 startIn = order.startAmountIn[i];
        uint256 endIn = order.endAmountIn[i];
        if (startIn > endIn) revert InvalidAuctionParams();
        if (startIn == endIn) return startIn; // fixed leg — no bump
        return startIn + ((endIn - startIn) * bump) / BPS;
    }

    /// @notice Current auction tick for input leg `i` (BUY: rising; SELL: fixed).
    ///         The maker's paid input climbs from `startAmountIn` (best for maker)
    ///         toward `endAmountIn` (the signed ceiling — "pay up to").
    function currentAmountInAt(Order calldata order, uint256 i) internal view returns (uint256) {
        uint256 startIn = order.startAmountIn[i];
        uint256 endIn = order.endAmountIn[i];
        if (startIn > endIn) revert InvalidAuctionParams();
        if (startIn == endIn) return startIn; // fixed leg — no bump (skip bumpBps)

        uint256 rise = ((endIn - startIn) * bumpBps(order)) / BPS;
        return startIn + rise;
    }

    /// @notice Current auction tick for every input leg. Shared `bump` computed at
    ///         most once (lazily), as in `currentAmountOut`.
    function currentAmountIn(Order calldata order) internal view returns (uint256[] memory ins) {
        uint256 n = order.tokenIn.length;
        ins = new uint256[](n);
        uint256 bump;
        bool bumpSet;
        for (uint256 i; i < n; i++) {
            if (order.startAmountIn[i] != order.endAmountIn[i] && !bumpSet) {
                bump = bumpBps(order);
                bumpSet = true;
            }
            ins[i] = amountInAt(order, i, bump);
        }
    }
}
