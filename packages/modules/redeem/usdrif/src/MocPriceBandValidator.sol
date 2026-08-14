// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOrderValidator} from "@core/interfaces/IOrderValidator.sol";
import {Order} from "@core/settlement/Settlement.sol";

import {IPriceProvider} from "./interfaces/IMoc.sol";

/// @title MocPriceBandValidator
/// @notice Gates a fill on a classic MoC `IPriceProvider.peek()` quote sitting
///         inside a maker-signed band. Targets MoC providers, which have no
///         AggregatorV3 surface (verified: `latestRoundData()` reverts on the
///         USDRIF bucket's provider) — where one exists, the core
///         `ChainlinkPriceGte`/`ChainlinkPriceLte` validators are strictly better,
///         because they carry a maker-signed staleness heartbeat.
///
///  WHAT THE FEED ACTUALLY IS  (was `DepegGuardValidator`; renamed for this)
///  ────────────────────────────────────────────────────────────────────────
///  A MoC pegged-token provider quotes the TP in ASSET-COLLATERAL terms — for the
///  USDRIF bucket, USDRIF per RIF, the same rate `IMocRif.getPACtp` exposes. Live
///  mainnet `peek()` on 0x6a5b2C84… returns ~7.09e16 (~6.85e16 at the fork tests'
///  pinned block): the RIF↔USDRIF redemption rate, which equals RIF's USD price
///  only for as long as USDRIF holds its peg.
///
///  So the quote is DENOMINATED IN USDRIF and a USDRIF depeg is invisible here —
///  USDRIF 10% down and RIF 10% up read identically. This bands the collateral
///  price, nothing more. A genuine depeg guard needs a USDRIF/USD source, and the
///  decision it would inform ("redeem at all?") is taken before the redemption is
///  queued — one step earlier than any order validator can run.
///
///  WHICH HALF OF THE BAND DOES WORK
///  ────────────────────────────────
///  On a sell order `minPrice` is near-redundant: the maker's signed output floor
///  already makes a fill at a collapsed collateral price unprofitable for the
///  solver, so the order simply stops filling. `maxPrice` is the half that earns
///  its gas — it caps the free option a resting order hands solvers when the
///  collateral rallies after signing and the signed price goes stale.
///
///  ⚠ NO FRESHNESS SIGNAL
///  ─────────────────────
///  Classic `peek()` exposes no `updatedAt` — only the provider's own validity
///  flag — so a FROZEN feed reads in-band forever, which is exactly the state a
///  stale-price guard exists to catch. Treat this as cover against slow drift, not
///  against a fast move priced off a stale quote; a short order expiry is the
///  primary defence there. For an order that lives seconds (a solver filling
///  immediately from inventory) this validator adds nothing the output floor does
///  not already provide — its place is on RESTING orders, on its own or as a leaf
///  inside `ConditionTreeValidator` ("in band OR timeout elapsed").
///
/// @dev `data = abi.encode(address priceProvider, uint256 minPrice, uint256 maxPrice)`.
///
///      A reversed band (`minPrice > maxPrice`) needs no explicit check: no price
///      satisfies both bounds, so the comparison already returns false. The
///      previous `InvalidBand` revert could never serve as a distinct signal —
///      {OrderGates.gatePasses} staticcalls this and folds ANY revert into
///      `false`, so the caller saw the ordinary `ValidationFailed(i)` either way.
contract MocPriceBandValidator is IOrderValidator {
    function validate(Order calldata, address, bytes calldata data, bytes calldata)
        external
        view
        override
        returns (bool)
    {
        (address priceProvider, uint256 minPrice, uint256 maxPrice) = abi.decode(data, (address, uint256, uint256));

        (bytes32 raw, bool valid) = IPriceProvider(priceProvider).peek();
        if (!valid) return false;

        uint256 price = uint256(raw);
        if (price == 0) return false; // zero ⇒ misconfigured/uninitialised feed, never "in band"
        return price >= minPrice && price <= maxPrice;
    }
}
