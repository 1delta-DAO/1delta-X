// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOrderValidator} from "../interfaces/IOrderValidator.sol";
import {Order} from "../settlement/UniversalSettlement.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";

/// @dev Shared, hardened Chainlink read. Reverts the validator (→ fill aborts)
///      on a stale, incomplete, or non-positive round. `maxStaleness` is signed
///      into the order so each feed binds its own heartbeat.
library ChainlinkRead {
    error StalePrice();
    error IncompleteRound();
    error NonPositivePrice();

    function read(address feed, uint256 maxStaleness) internal view returns (int256) {
        (uint80 roundId, int256 price,, uint256 updatedAt, uint80 answeredInRound) =
            IAggregatorV3(feed).latestRoundData();
        if (price <= 0) revert NonPositivePrice();
        if (answeredInRound < roundId) revert IncompleteRound();
        // updatedAt == 0 ⇒ round not yet answered; otherwise enforce the heartbeat.
        if (updatedAt == 0 || block.timestamp - updatedAt > maxStaleness) revert StalePrice();
        return price;
    }
}

/// @title ChainlinkPriceGte
/// @notice Passes when a Chainlink price feed reports a fresh value ≥ threshold.
///         Typical use: take-profit orders — only fill when price rises to X.
/// @dev    `data = abi.encode(address feed, int256 threshold, uint256 maxStaleness)`
contract ChainlinkPriceGte is IOrderValidator {
    function validate(Order calldata, address, bytes calldata data, bytes calldata) external view override returns (bool) {
        (address feed, int256 threshold, uint256 maxStaleness) = abi.decode(data, (address, int256, uint256));
        return ChainlinkRead.read(feed, maxStaleness) >= threshold;
    }
}

/// @title ChainlinkPriceLte
/// @notice Passes when a Chainlink price feed reports a fresh value ≤ threshold.
///         Typical use: stop-loss orders — only fill when price drops to X.
/// @dev    `data = abi.encode(address feed, int256 threshold, uint256 maxStaleness)`
contract ChainlinkPriceLte is IOrderValidator {
    function validate(Order calldata, address, bytes calldata data, bytes calldata) external view override returns (bool) {
        (address feed, int256 threshold, uint256 maxStaleness) = abi.decode(data, (address, int256, uint256));
        return ChainlinkRead.read(feed, maxStaleness) <= threshold;
    }
}
