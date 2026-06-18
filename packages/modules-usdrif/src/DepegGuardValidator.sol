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
///
///         Freshness note: the classic MoC `peek()` exposes no `updatedAt`, so
///         the provider's own `valid`/`has` flag is the only liveness signal
///         available here. To bound the residual risk we additionally reject a
///         zero price and require a sane band; for feeds exposing AggregatorV3,
///         compose `ChainlinkPriceGte`/`Lte` (which enforce a signed heartbeat)
///         instead of — or in addition to — this guard.
contract DepegGuardValidator is IOrderValidator {
    error InvalidBand();

    function validate(LimitOrder calldata, bytes calldata data) external view override returns (bool) {
        (address priceProvider, uint256 minPrice, uint256 maxPrice) =
            abi.decode(data, (address, uint256, uint256));

        // A reversed band would silently never fill; surface it as an error.
        if (minPrice > maxPrice) revert InvalidBand();

        (bytes32 raw, bool valid) = IPriceProvider(priceProvider).peek();
        if (!valid) return false;

        uint256 price = uint256(raw);
        if (price == 0) return false; // zero ⇒ misconfigured/uninitialised feed, never "in band"
        return price >= minPrice && price <= maxPrice;
    }
}
