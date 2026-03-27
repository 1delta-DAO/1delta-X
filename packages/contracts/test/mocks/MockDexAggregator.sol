// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IDexAggregator} from "../../src/interfaces/IDexAggregator.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Mock DEX aggregator for testing.
///         Swaps at a configurable fixed rate. Must be pre-funded with output tokens.
contract MockDexAggregator is IDexAggregator {
    /// @notice tokenIn → tokenOut → exchange rate (amountOut per 1e18 amountIn)
    mapping(address => mapping(address => uint256)) public rates;

    function setRate(address tokenIn, address tokenOut, uint256 ratePerUnit) external {
        rates[tokenIn][tokenOut] = ratePerUnit;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256, /* minAmountOut */ bytes calldata)
        external
        override
        returns (uint256 amountOut)
    {
        uint256 rate = rates[tokenIn][tokenOut];
        require(rate > 0, "no rate set");

        amountOut = (amountIn * rate) / 1e18;

        MockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        MockERC20(tokenOut).transfer(msg.sender, amountOut);
    }
}
