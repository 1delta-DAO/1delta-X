// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ITakeFloor
/// @notice An OPTIONAL module self-check the lens runs on a `TAKE` item whose proceeds
///         land on the settler: "does the floor the maker signed in `data` bound what
///         the core can bill to the maker's WALLET for this item?" Read-only;
///         `SettlementLensChecks.validateOrder` calls it, `Settlement` never does.
///
///  WHY THE MODULE ANSWERS, NOT THE LENS. A `TAKE` item's proceeds are credited by
///  MEASUREMENT ({Core._payInputsToSolver} reads the balance delta of the input leg's
///  token), and whatever falls short of the leg's `owed` is pulled from the maker's
///  wallet. For most venues the delivery is exact-or-revert, so there is no shortfall
///  to bound. A few venues under-deliver BY DESIGN and carry a maker-signed floor in
///  their own blob layout, in their own units:
///
///    • `ListaSmartTakerModule` — `item.amount` is LP units, the leg is coin units,
///      and `minOutRateE18` is the only bridge between them (review 2026-10-06 M3);
///    • `ExactlyTakerModule` — a pre-maturity fixed withdraw pays a discounted
///      amount and `minAssetsRequired` is the only cap on the discount.
///
///  The rule differs per venue (Lista: the floor must cover the leg; Exactly: a floor
///  must exist at all, the discount itself is legitimate), and only the module can
///  read its own layout — so the module judges, and the lens only reports. This is
///  how the lens recognises such a module: by the interface answering, never by a
///  hard-coded address. Same posture as {IProceedsAsset} / {IFundingSource}.
///
///  NOT A FILL GATE. A maker may deliberately accept a wallet draw (or an order the
///  lens flags may still fill); this is a preflight a UI or book runs before a
///  signature exists, exactly like the rest of `validateOrder`.
interface ITakeFloor {
    /// @dev MUST NOT REVERT on a well-formed `data`. A module that does not implement
    ///      this, or reverts, or returns fewer than 32 bytes, is SKIPPED by the lens —
    ///      never failed; silence leaves the caller where it was. A returned word of
    ///      zero is read as `false` (flagged); any non-zero word as `true`.
    ///
    /// @param amount   the item's FULL signed amount (`item.amount`) — the whole-order
    ///                 slice, so the comparison is the full-fill one.
    /// @param legToken `legsIn[0].token` — the token the core measures and prices.
    /// @param legStart `legsIn[0].start` — the least the leg is ever `owed` at full fill.
    /// @param data     the item's maker-signed blob, byte-identical to what
    ///                 `takeOnBehalf` receives.
    /// @return floored `true` when the signed floor bounds the wallet draw the way
    ///                 this module requires; `false` flags the order as malformed.
    function takeFloored(uint256 amount, address legToken, uint256 legStart, bytes calldata data)
        external
        view
        returns (bool floored);
}
