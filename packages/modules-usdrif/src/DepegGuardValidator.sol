// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOrderValidator} from "@core/interfaces/IOrderValidator.sol";
import {LimitOrder} from "@core/settlement/LimitOrderSettlement.sol";

import {IPriceProvider} from "./interfaces/IMoc.sol";

/// @title DepegGuardValidator
/// @notice Seller protection: an exit order is only fillable while the relevant
///         MoC price provider reports a price inside a signed band, and the feed
///         is valid. Replaces ZipVault's old built-in circuit breaker with a
///         per-order condition the seller signs into the order.
///
///         Reads a classic MoC `IPriceProvider.peek()` (1e18-scaled price packed
///         in bytes32 + validity flag). For Chainlink-style feeds the existing
///         `ChainlinkPriceGte` / `ChainlinkPriceLte` core validators can be
///         composed instead; this one targets MoC providers that have no
///         AggregatorV3 surface.
///
/// @dev    `data = abi.encode(address priceProvider, uint256 minPrice, uint256 maxPrice)`.
contract DepegGuardValidator is IOrderValidator {
    function validate(LimitOrder calldata, bytes calldata data) external view override returns (bool) {
        (address priceProvider, uint256 minPrice, uint256 maxPrice) =
            abi.decode(data, (address, uint256, uint256));

        (bytes32 raw, bool valid) = IPriceProvider(priceProvider).peek();
        if (!valid) return false;

        uint256 price = uint256(raw);
        return price >= minPrice && price <= maxPrice;
    }
}
