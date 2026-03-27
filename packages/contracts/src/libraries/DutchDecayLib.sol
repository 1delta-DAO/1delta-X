// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ConversionItem} from "../types/DataTypes.sol";

/// @title DutchDecayLib
/// @notice Calculates the current required output amount for a dutch-auction conversion.
///         The amount decays linearly from startAmountOut (best for maker) to
///         endAmountOut (worst for maker) over the decay duration.
library DutchDecayLib {
    error AuctionNotStarted();
    error InvalidAuctionParams();

    /// @notice Returns the minimum output amount the maker must receive at the current time
    /// @param conversion The conversion item with auction parameters
    /// @return amountOut The required output amount at block.timestamp
    function currentAmountOut(ConversionItem calldata conversion) internal view returns (uint256 amountOut) {
        if (conversion.startAmountOut < conversion.endAmountOut) revert InvalidAuctionParams();
        if (block.timestamp < conversion.decayStartTime) revert AuctionNotStarted();

        uint256 elapsed = block.timestamp - conversion.decayStartTime;

        if (elapsed >= conversion.decayDuration) {
            return conversion.endAmountOut;
        }

        uint256 decay = (conversion.startAmountOut - conversion.endAmountOut) * elapsed / conversion.decayDuration;
        return conversion.startAmountOut - decay;
    }
}
