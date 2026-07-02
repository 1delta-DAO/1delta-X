// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order} from "./SettlementStructs.sol";

/// @title DutchAuction
/// @notice Per-output-leg dutch decay pricing. Every output leg shares one
///         clock (`decayStartTime`/`decayDuration`) but decays between its own
///         `startAmountOut[j]` → `endAmountOut[j]` bounds. The auction prices
///         only the output legs; inputs and lending items are fixed.
library DutchAuction {
    error AuctionNotStarted();
    error InvalidAuctionParams();

    /// @notice Current auction tick for output leg `j`.
    function currentAmountOutAt(Order calldata order, uint256 j) internal view returns (uint256) {
        uint256 startOut = order.startAmountOut[j];
        uint256 endOut = order.endAmountOut[j];
        if (startOut < endOut) revert InvalidAuctionParams();

        if (order.decayDuration == 0 || startOut == endOut) {
            return startOut;
        }

        if (block.timestamp < order.decayStartTime) revert AuctionNotStarted();

        uint256 elapsed = block.timestamp - order.decayStartTime;
        if (elapsed >= order.decayDuration) return endOut;

        uint256 decay = (startOut - endOut) * elapsed / order.decayDuration;
        return startOut - decay;
    }

    /// @notice Current auction tick for every output leg.
    function currentAmountOut(Order calldata order) internal view returns (uint256[] memory outs) {
        uint256 n = order.tokenOut.length;
        outs = new uint256[](n);
        for (uint256 j; j < n; j++) {
            outs[j] = currentAmountOutAt(order, j);
        }
    }
}
