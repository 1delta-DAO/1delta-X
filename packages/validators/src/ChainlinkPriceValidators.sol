// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOrderValidator} from "@core/interfaces/IOrderValidator.sol";
import {Order} from "@core/settlement/Settlement.sol";
import {DutchAuction} from "@core/settlement/DutchAuction.sol";
import {IAggregatorV3} from "@validators/interfaces/IAggregatorV3.sol";

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
        // updatedAt == 0 ⇒ round not yet answered. `updatedAt > block.timestamp` is a
        // feed reporting the future: it cannot be a fresh round by any reading, and
        // without this test the subtraction below underflows and surfaces a raw
        // Panic(0x11) instead of the typed {StalePrice} the other guards raise.
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxStaleness) {
            revert StalePrice();
        }
        return price;
    }
}

/// @title ChainlinkPriceGte
/// @notice Passes when a Chainlink price feed reports a fresh value ≥ threshold.
///         Typical use: take-profit orders — only fill when price rises to X.
/// @dev    `data = abi.encode(address feed, int256 threshold, uint256 maxStaleness)`
contract ChainlinkPriceGte is IOrderValidator {
    function validate(Order calldata, address, bytes calldata data, bytes calldata)
        external
        view
        override
        returns (bool)
    {
        (address feed, int256 threshold, uint256 maxStaleness) = abi.decode(data, (address, int256, uint256));
        return ChainlinkRead.read(feed, maxStaleness) >= threshold;
    }
}

/// @title ChainlinkPriceLte
/// @notice Passes when a Chainlink price feed reports a fresh value ≤ threshold.
///         Typical use: stop-loss orders — only fill when price drops to X.
/// @dev    `data = abi.encode(address feed, int256 threshold, uint256 maxStaleness)`
contract ChainlinkPriceLte is IOrderValidator {
    function validate(Order calldata, address, bytes calldata data, bytes calldata)
        external
        view
        override
        returns (bool)
    {
        (address feed, int256 threshold, uint256 maxStaleness) = abi.decode(data, (address, int256, uint256));
        return ChainlinkRead.read(feed, maxStaleness) <= threshold;
    }
}

/// @title ChainlinkTickFloorValidator
/// @notice Bounds the order's CURRENT auction tick against a LIVE oracle — the
///         market-limit that makes long-lived schedules (TWAP) and slow decays
///         safe when the market runs away from the signed curve. Passes iff
///
///             currentOut0 · 1e18  >=  currentIn0 · price(feed) · scale / 1e18
///
///         i.e. "the rate this fill would clear at (leg-0 out per leg-0 in, at
///         the live decay/gas-bump tick) is no worse for the maker than the
///         oracle rate times a signed fraction". A {TwapFillModule} order plus
///         this validator is a complete oracle-limited TWAP: the schedule meters
///         the size, this gates every part on the market.
///
/// @dev    `data = abi.encode(address feed, uint256 maxStaleness, uint256 scale)`.
///         `scale` folds EVERYTHING the contract deliberately has no opinion on
///         into one maker-signed number — feed decimals, the two tokens'
///         decimals, feed orientation, and the tolerance — defined by
///         `rate1e18 >= price(feed) · scale`, i.e.
///
///             scale = 1e18 · (10000 − tolBps)/10000 · 10^(dOut − dIn − dFeed)
///
///         (inverted-feed and BUY-side caps fold in the same way — a cap on
///         in-per-out is a floor on out-per-in). The SDK computes it; on-chain
///         stays a single mulDiv against the hardened {ChainlinkRead}.
///         Anchored on leg 0 of BOTH sides — the canonical 1-in/1-out TWAP/limit
///         shape; multi-leg baskets need a bespoke validator. Reverts (aborting
///         the fill) on an empty leg, mirroring the conservative feed guards.
contract ChainlinkTickFloorValidator is IOrderValidator {
    using DutchAuction for Order;

    /// @dev The order pins its bump ({IPriceModule} or a priority auction), so the
    ///      clock tick this validator reads via {DutchAuction.bumpBps} is NOT the price
    ///      the fill clears at — `bumpBps` returns the clock (0/`start`) while the fill
    ///      uses the pinned bump the validator, running before `_openFill` with no bump
    ///      argument, cannot see. Rather than silently pass at the wrong price, refuse:
    ///      this validator is only sound for clock-priced orders. (Preflight then
    ///      reports the order as failing this validator, surfacing the misconfig.)
    error UnsupportedPricingMode();

    function validate(Order calldata order, address, bytes calldata data, bytes calldata)
        external
        view
        override
        returns (bool)
    {
        if (order.pricingModule != address(0) || order.priorityAuction()) revert UnsupportedPricingMode();
        (address feed, uint256 maxStaleness, uint256 scale) = abi.decode(data, (address, uint256, uint256));
        uint256 bump = order.bumpBps();
        uint256 out0 = order.amountOutAt(0, bump);
        uint256 in0 = order.amountInAt(0, bump);
        uint256 ref = uint256(ChainlinkRead.read(feed, maxStaleness));
        // rate1e18 = out0·1e18/in0; pass iff rate1e18 >= ref·scale — kept in the
        // multiplied-out form so there is no division/precision loss.
        return out0 * 1e18 >= in0 * ref * scale;
    }
}
