// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOrderValidator} from "@core/interfaces/IOrderValidator.sol";
import {Order} from "@core/settlement/Settlement.sol";

import {IMocRif} from "./interfaces/IMoc.sol";

/// @title MocPriceBandValidator
/// @notice Gates a fill on the MoC core's live pegged-token price —
///         `IMocRif(core).getPACtp(tp)`, the price MoC REDEEMS AT — sitting inside a
///         maker-signed band. MoC has no AggregatorV3 surface for this price, so the
///         core `ChainlinkPriceGte`/`ChainlinkPriceLte` validators do not apply;
///         where a Chainlink feed exists they are strictly better, because they
///         carry a maker-signed staleness heartbeat.
///
///  WHY THE CORE, NOT A PRICE PROVIDER  (audit 2026-09-30 RIF-3 / VAL-3, BREAKING)
///  ─────────────────────────────────────────────────────────────────────────────
///  This used to read a classic `IPriceProvider.peek()` named in `data`, and the
///  package documented `0x6a5b2C84…` — the provider the RIF bucket used when this
///  was written. MoC has since re-pointed the bucket (`pegContainer(0)` now names
///  `0xaFb1B8C3…`). The old provider is FROZEN and flagged invalid (`has = false`),
///  so every order carrying it failed `ValidationFailed`; the new one reverts
///  "Address is not whitelisted" for any caller but the MoC core, so pointed at it
///  the validator reverted, which {OrderGates.gatePasses} folds into the same
///  `false`. No maker could configure a working band. And even while valid, the
///  old provider's quote had drifted 5–9% from `getPACtp`, so a band signed off it
///  did not bound the rate redemptions actually executed at.
///
///  `getPACtp` is public, is what `redeemTP` prices with, and follows whatever
///  provider MoC governance points the bucket at — the core is the whitelisted
///  caller, so the validator needs no whitelisting of its own.
///
///  WHAT THE PRICE ACTUALLY IS
///  ──────────────────────────
///  The pegged token priced in ASSET-COLLATERAL terms — for the USDRIF bucket,
///  USDRIF per RIF (~8.0e16 on mainnet at the time of the fix): the RIF↔USDRIF
///  redemption rate, which equals RIF's USD price only for as long as USDRIF holds
///  its peg.
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
///  `getPACtp` exposes no `updatedAt`, so a frozen upstream feed reads in-band
///  forever. Treat this as cover against slow drift, not against a fast move priced
///  off a stale quote; a short order expiry is the primary defence there. For an
///  order that lives seconds (a solver filling immediately from inventory) this
///  validator adds nothing the output floor does not already provide — its place
///  is on RESTING orders, on its own or as a leaf inside `ConditionTreeValidator`
///  ("in band OR timeout elapsed").
///
/// @dev `data = abi.encode(address mocCore, address tp, uint256 minPrice, uint256 maxPrice)`.
///
///      A reversed band (`minPrice > maxPrice`) needs no explicit check: no price
///      satisfies both bounds, so the comparison already returns false. A reverting
///      `getPACtp` (the core refusing an invalid upstream price) is folded into
///      `false` by {OrderGates.gatePasses}, like any validator revert.
contract MocPriceBandValidator is IOrderValidator {
    function validate(Order calldata, address, bytes calldata data, bytes calldata)
        external
        view
        override
        returns (bool)
    {
        (address mocCore, address tp, uint256 minPrice, uint256 maxPrice) =
            abi.decode(data, (address, address, uint256, uint256));

        uint256 price = IMocRif(mocCore).getPACtp(tp);
        if (price == 0) return false; // zero ⇒ misconfigured/uninitialised, never "in band"
        return price >= minPrice && price <= maxPrice;
    }
}
