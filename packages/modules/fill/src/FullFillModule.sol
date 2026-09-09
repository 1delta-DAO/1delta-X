// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFillModule} from "@core/interfaces/IFillModule.sol";
import {IFillModuleDescribe} from "@core/interfaces/IFillModuleDescribe.sol";
import {Order} from "@core/settlement/Structs.sol";

/// @title FullFillModule
/// @notice The canonical indivisible / all-or-nothing fill module: an order
///         using it can only be filled in ONE shot, for its entire `fillTotal`.
///         The building block for non-fungible intents (an NFT swap, an auction
///         lot, a single RFQ) whose "amount" has no fractional meaning.
///
///         `resolveFill` returns the whole remaining denominator regardless of
///         the solver's requested `fillAmount`, so the first fill completes the
///         order (`prevFilled == 0 ⇒ delta == fillTotal`). A second fill would
///         compute `delta == 0` and revert `ZeroFill` in the settlement, so the
///         order is single-use by construction. The solver's counterparty side
///         (e.g. "I actually own NFT X") is proven separately by the order's
///         post-execution invariants — this module only fixes the fill unit, it
///         does not match assets, which keeps it reusable across any indivisible
///         intent.
///
/// @dev    Requires `order.fillTotal != 0` (the maker signs the unit, typically
///         `1`). With `fillTotal == 0` the first fill computes `0 - 0 = 0`, which
///         the settlement rejects with `ZeroFill` — fail-closed, so a module
///         order that forgot its total simply cannot fill.
contract FullFillModule is IFillModule, IFillModuleDescribe {
    /// @inheritdoc IFillModule
    function resolveFill(Order calldata order, uint256 prevFilled, uint256, bytes calldata)
        external
        pure
        returns (uint256 delta)
    {
        // Entire remaining denominator ⇒ one fill completes the order.
        return order.fillTotal - prevFilled;
    }

    /// @inheritdoc IFillModuleDescribe
    /// @dev Not dynamic: the delta is `fillTotal - prevFilled`, a signed constant.
    ///      One-shot because that first fill completes the order and a second
    ///      computes 0, which the settlement rejects {ZeroFill}.
    function describeFill() external pure override returns (bytes32 kind, bool dynamicSize, bool oneShot) {
        return ("FULL_FILL", false, true);
    }
}
