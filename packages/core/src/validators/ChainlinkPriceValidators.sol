// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOrderValidator} from "../interfaces/IOrderValidator.sol";
import {LimitOrder} from "../settlement/LimitOrderSettlement.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";

/// @title ChainlinkPriceGte
/// @notice Passes when a Chainlink price feed reports a value ≥ threshold.
///         Typical use: take-profit orders — only fill when price rises to X.
/// @dev    `data = abi.encode(address feed, int256 threshold)`
contract ChainlinkPriceGte is IOrderValidator {
    function validate(LimitOrder calldata, bytes calldata data) external view override returns (bool) {
        (address feed, int256 threshold) = abi.decode(data, (address, int256));
        (, int256 price,,,) = IAggregatorV3(feed).latestRoundData();
        return price >= threshold;
    }
}

/// @title ChainlinkPriceLte
/// @notice Passes when a Chainlink price feed reports a value ≤ threshold.
///         Typical use: stop-loss orders — only fill when price drops to X.
/// @dev    `data = abi.encode(address feed, int256 threshold)`
contract ChainlinkPriceLte is IOrderValidator {
    function validate(LimitOrder calldata, bytes calldata data) external view override returns (bool) {
        (address feed, int256 threshold) = abi.decode(data, (address, int256));
        (, int256 price,,,) = IAggregatorV3(feed).latestRoundData();
        return price <= threshold;
    }
}
