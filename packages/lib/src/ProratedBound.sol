// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ProratedBound
/// @notice Scales an ABSOLUTE, maker-signed slippage ceiling with the fill slice.
///
///  The defect this exists to close (F26)
///  ─────────────────────────────────────
///  `Base._executeItems` pro-rates an item's `amount` per fill but hands the
///  module `item.data` byte-for-byte. {FullFillGuard} was written for the case
///  where a constant in `data` is an AMOUNT. The same reasoning applies, and was
///  never applied, when the constant is a BOUND:
///
///    maker signs  "borrow 10,000, and I refuse to owe more than 11,000"
///    filler fills 10 x 1,000
///    each slice   borrowAtMaturity(m, 1_000, 11_000, ...) -- Exactly checks
///                 `assetsOwed <= 11_000` PER CALL
///
///  The borrow shrank by 10x and the ceiling did not, so the maker's signed
///  slippage tolerance is multiplied by N — and the FILLER chooses N. Unlike most
///  findings in this repo the victim here did nothing wrong: they signed a correct
///  order, and an input they never consented to (the slice count) dilutes their
///  protection.
///
///  ⚠ ONLY FOR *MAX* BOUNDS. A ceiling applied unscaled to a slice fails OPEN and
///  must be scaled. A FLOOR (`minAssetsRequired`, `minCollateralOut`) applied
///  unscaled to a slice is STRICTER than the maker asked for, so it fails CLOSED —
///  scaling it would loosen a guard that is currently safe. Do not "fix" those
///  with this library without deciding, separately, that enabling partial fills on
///  that leg is wanted.
///
///  Rounding is FLOOR, deliberately: `sum(floor(bound * aᵢ / total)) <= bound`, so
///  the maker's ceiling holds across the whole order however the filler slices it.
///  A ceil would admit up to one unit per slice above the signed total.
///
///  The scale-free alternative is better where the protocol accepts it: a bound
///  expressed as a RATE (`RiverTakerModule`'s `maxFeePercentage`) cannot be diluted
///  by slicing at all, and needs no total and no arithmetic. Prefer that; use this
///  where the protocol's API takes an absolute (Exactly's `maxAssets`, Liquity's
///  `maxUpfrontFee`).
library ProratedBound {
    /// @dev The maker-signed item total is absent or zero. Fail closed rather than
    ///      silently treating the slice as a full fill — an order that omits the
    ///      field is exactly the order that was unprotected before this existed.
    error BoundTotalMissing();

    /// @param bound       the maker's absolute ceiling, sized for the WHOLE item
    /// @param amount      this fill's pro-rated slice
    /// @param totalAmount the item's full maker-signed amount, carried in `data`
    function scale(uint256 bound, uint256 amount, uint256 totalAmount) internal pure returns (uint256) {
        if (totalAmount == 0) revert BoundTotalMissing();
        // `type(uint256).max` is the conventional "no ceiling" sentinel and MUST pass
        // through untouched: an unbounded ceiling is unbounded at any slice size, and
        // scaling it would overflow the multiply below and revert a legitimate fill.
        // (Caught by `liquity-v2/test/leverage/Leverage.t.sol`, which signs exactly
        // that sentinel — the first version of this library bricked it.)
        if (bound == type(uint256).max) return bound;
        // Full fill (or an over-fill the core already rejects) needs no arithmetic,
        // which keeps the dominant path free of a multiply that could overflow.
        if (amount >= totalAmount) return bound;
        // Checked: an overflow here reverts, which is the fail-closed direction.
        return bound * amount / totalAmount;
    }
}
