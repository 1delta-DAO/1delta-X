// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IPositionSource
/// @notice A taker module's report of the user's LIVE position behind a signed
///         item — the read that lets a fill be sized from the position instead of
///         from a number the maker had to guess at signing time.
///
///  Implemented by withdraw-side taker modules and consumed by
///  {PositionFillModule}, which returns it to the core as the fill `delta`. The
///  core then scales every leg and every item by `delta / fillTotal`, so the
///  interest accrued between signing and inclusion is SOLD at the maker's signed
///  rate rather than paid back as unconverted dust.
///
///  ⚠ THIS INTERFACE MUST NEVER REACH SETTLEMENT'S COMPILATION UNIT. Same rule as
///  {IFundingSource}, and for the same measured reason: merely declaring that
///  function where the settler compiles measured +7 bytes against an EIP-170
///  budget with double digits to spare. Nothing the settler imports may import
///  this; the fill module reads it from outside.
///
///  Why the module and not the fill module
///  ──────────────────────────────────────
///  The position lives behind the module's own byte map — `data`'s layout is the
///  module's private business, and it changes with the module. A reader that
///  decoded that map from outside would be a second copy of it, which is exactly
///  the failure this codebase keeps finding (a rule re-typed per call site landing
///  on one sibling and missing its neighbour). Reporting it here means the byte
///  map is decoded once, in the file that defines it — and the module's own
///  `BalanceMode.Full` branch SHOULD call this too, so the number a fill is priced
///  against and the number the withdraw actually takes are the same function.
interface IPositionSource {
    /// @notice The user's live position behind `data`.
    ///
    /// @dev MUST return the RAW position, NOT bounded by this module's allowance
    ///      or by anything else that would make the withdraw reachable. If the
    ///      maker's approval is short the fill must revert loudly: resolving to
    ///      the reachable amount instead would quietly sell a fraction AND consume
    ///      the one-shot order, leaving the maker half-exited with nothing left to
    ///      fill. Fail closed, not small. That is the opposite of
    ///      {IFundingSource.fundingSource}, which reports reachability on purpose.
    ///
    ///      MUST revert if `data` names an op this module cannot size — a borrow
    ///      leg, or a position denominated in units it cannot convert to `asset`.
    ///      Returning a wrong-but-plausible number mis-prices the maker's fill;
    ///      reverting is a diagnosable misconfiguration.
    ///
    /// @param user the position owner (`order.maker`, supplied by the fill module).
    /// @param data the item's maker-signed blob, byte-identical to what
    ///             `takeOnBehalf` receives.
    /// @return asset  the token `amount` is denominated in. The fill module
    ///                requires this to equal `legsIn[0].token`, which is what makes
    ///                the resolved number safe to use as the fill numerator.
    /// @return amount the live position, in `asset` units.
    function positionOf(address user, bytes calldata data) external view returns (address asset, uint256 amount);
}
