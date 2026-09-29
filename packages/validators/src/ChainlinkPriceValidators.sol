// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOrderValidator} from "@core/interfaces/IOrderValidator.sol";
import {Order} from "@core/settlement/Settlement.sol";
import {DutchAuction} from "@core/settlement/DutchAuction.sol";
import {PackedArrays} from "@core/settlement/PackedArrays.sol";
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
///             currentOut0 · den  >=  currentIn0 · price(feed) · num
///
///         i.e. "the rate this fill would clear at (leg-0 out per leg-0 in, at
///         the live decay/gas-bump tick) is no worse for the maker than the
///         oracle rate times a signed fraction". A {TwapFillModule} order plus
///         this validator is a complete oracle-limited TWAP: the schedule meters
///         the size, this gates every part on the market.
///
/// @dev    `data = abi.encode(address feed, uint256 maxStaleness, uint256 num, uint256 den)`.
///         `num / den` folds EVERYTHING the contract deliberately has no opinion on
///         into one maker-signed RATIONAL — feed decimals, the two tokens'
///         decimals, feed orientation, and the tolerance:
///
///             num / den = (10000 − tolBps) / 10000 · 10^(dOut − dIn − dFeed)
///
///         Both halves are plain integers for EVERY decimal shape: put the power of
///         ten on whichever side makes the exponent non-negative (18-in / 6-out /
///         8-dec feed ⇒ exponent −20 ⇒ `num = 10000 − tolBps`, `den = 10000 · 1e20`).
///         The SDK's `tickFloorRatio` computes it. (Inverted-feed and BUY-side caps
///         fold in the same way — a cap on in-per-out is a floor on out-per-in.)
///
///         ⚠ WHY A RATIONAL, NOT A 1e18 SCALE. The first version signed one
///         `scale = 1e18 · (10000 − tolBps)/10000 · 10^(dOut − dIn − dFeed)` and
///         checked `out0 · 1e18 >= in0 · ref · scale`. For the dominant pair shape
///         (18-decimal input, 6-decimal output, 8-decimal feed) the exponent is
///         −20, so `scale = 0.0098` — an integer of ZERO — and the check read
///         `>= 0`: the market limit never gated, and nothing rejected it. The
///         1inch Aqua `uint32 decayFactor` failure in this codebase's own clothes
///         (docs/reference-bounties.md B1; F29 finding 1). A zero on either side
///         now reverts, which {OrderGates.gatePasses} folds to `false` — fail closed.
///         BREAKING: a three-word blob decodes short and reverts, i.e. also fails
///         closed rather than silently passing.
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
    /// @dev `num == 0` would pass every price; `den == 0` would pass none. Neither is
    ///      a market limit, so neither is accepted.
    error ZeroRatio();
    /// @dev `legsIn` or `legsOut` holds no leg. The tick reads below are unchecked
    ///      packed-blob accessors, so on an empty blob they would read whatever
    ///      maker-signed bytes follow it rather than a leg (re-audit 2026-09-29).
    error EmptyLeg();

    function validate(Order calldata order, address, bytes calldata data, bytes calldata)
        external
        view
        override
        returns (bool)
    {
        if (order.pricingModule != address(0) || order.priorityAuction()) revert UnsupportedPricingMode();
        (address feed, uint256 maxStaleness, uint256 num, uint256 den) =
            abi.decode(data, (address, uint256, uint256, uint256));
        if (num == 0 || den == 0) revert ZeroRatio();
        if (
            PackedArrays.validateFixed(order.legsIn, PackedArrays.LEG_IN_STRIDE) == 0
                || PackedArrays.validateFixed(order.legsOut, PackedArrays.LEG_OUT_STRIDE) == 0
        ) revert EmptyLeg();
        // Its own frame: the four decoded words plus the two tick reads push this
        // function past the legacy-codegen stack limit.
        return _tickAtLeast(order, uint256(ChainlinkRead.read(feed, maxStaleness)) * num, den);
    }

    /// @dev rate = out0/in0; pass iff rate >= (ref·num)/den — kept in the
    ///      multiplied-out form so there is no division/precision loss.
    function _tickAtLeast(Order calldata order, uint256 refNum, uint256 den) private view returns (bool) {
        uint256 bump = order.bumpBps();
        return order.amountOutAt(0, bump) * den >= order.amountInAt(0, bump) * refNum;
    }
}
