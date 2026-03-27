// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal DEX aggregator interface (1inch / 0x style)
interface IDexAggregator {
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, bytes calldata routeData)
        external
        returns (uint256 amountOut);
}
