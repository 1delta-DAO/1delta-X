// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOrderValidator} from "../interfaces/IOrderValidator.sol";
import {Order, OrderSide} from "./Structs.sol";
import {PackedArrays} from "./PackedArrays.sol";
import {DutchAuction} from "./DutchAuction.sol";

/// @title OrderGates
/// @notice The order-level rules that BOTH the settler and {SettlementLens} have to
///         apply, in one place so they cannot answer differently.
///
///  Why this exists
///  ───────────────
///  The lens is a separate deployed contract — it cannot inherit {Settlement}, which
///  is already near the EIP-170 cap — so it re-implemented the settler's gates. The
///  2026-08 audit found that two of those copies had ALREADY drifted, silently:
///
///    • `_anchorTotal` — the settler added an empty-blob guard ({NoAnchorLeg}) when
///      the legs moved to a packed encoding, because a blob is not an array: an
///      out-of-range read does not revert, `calldataload` pads past the end and
///      yields ZERO. The lens copy never got it, so an order with no legs and no
///      `fillTotal` produced a denominator of 0 where the settler reverts — an
///      underflow panic in `remaining()` and a misleading {OverFill} in `previewFill`.
///    • `_verifySignature` — the settler skips re-verification once
///      `filled[orderHash] != 0` (a non-zero counter already proves some earlier fill
///      presented valid authorization for that maker-committing hash). The lens copy
///      did not, so it was STRICTER than the settler and an orderbook would drop
///      live, fillable size. (That one stays in {SettlementLens}: it reads settler
///      STORAGE, which this pure/view library has no handle on.)
///
///  Neither was a theft path, and that is rather the point — a preflight that
///  disagrees with the settler fails quietly, in whichever direction, and nothing
///  catches it. So the rules that CAN be shared are shared here, and the errors are
///  declared alongside them rather than in each caller.
///
/// @dev All functions are `internal`, so they inline into the caller exactly as the
///      private copies they replace did — this is a de-duplication, not a
///      restructuring, and it is expected to be gas-neutral. The error SELECTORS are
///      unchanged (an error's selector is derived from its name and argument types,
///      never from the scope that declares it), so callers still decode identically.
library OrderGates {
    using DutchAuction for Order;

    /// @dev A non-exclusive filler tried to fill inside the exclusivity window of an
    ///      order that grants no soft-exclusivity override.
    error NotExclusiveFiller();
    /// @dev `order.exclusivityOverrideBps` exceeds 100%. Above `BPS` the input-side
    ///      discount in {Pricing.inputOwed} underflows, so the order would be
    ///      unfillable by any non-exclusive filler; reject it explicitly rather than
    ///      surfacing an arithmetic panic.
    error InvalidOverrideBps();
    /// @dev The order derives its fill denominator from leg 0 of the fixed side, but
    ///      that side is empty. Such an order must carry an explicit `fillTotal`.
    error NoAnchorLeg();

    /// @notice Exclusivity gate. Inside the window only the nominated filler fills
    ///         for free; a non-exclusive filler is blocked (hard exclusivity) or
    ///         allowed against an `exclusivityOverrideBps` price improvement it must
    ///         pay the maker (soft exclusivity). Returns the override, 0 otherwise.
    function exclusivityOverride(Order calldata order, address filler) internal view returns (uint256 overrideBps) {
        if (
            order.exclusiveFiller != address(0) && block.timestamp < order.exclusivityEndTime()
                && filler != order.exclusiveFiller
        ) {
            if (order.exclusivityOverrideBps == 0) revert NotExclusiveFiller();
            if (order.exclusivityOverrideBps > DutchAuction.BPS) revert InvalidOverrideBps();
            overrideBps = order.exclusivityOverrideBps;
        }
    }

    /// @notice The fill denominator in anchor units: the FIXED side's leg 0 —
    ///         `legsIn[0].start` (SELL) or `legsOut[0].start` (BUY).
    /// @dev    The empty-blob check is NOT optional — see the contract note above.
    function anchorTotal(Order calldata order) internal pure returns (uint256) {
        if (order.side() == OrderSide.BUY) {
            if (PackedArrays.validateFixed(order.legsOut, PackedArrays.LEG_OUT_STRIDE) == 0) revert NoAnchorLeg();
            (, uint256 start,,) = PackedArrays.legOut(order.legsOut, 0);
            return start;
        }
        if (PackedArrays.validateFixed(order.legsIn, PackedArrays.LEG_IN_STRIDE) == 0) revert NoAnchorLeg();
        (, uint256 startIn,) = PackedArrays.legIn(order.legsIn, 0);
        return startIn;
    }

    /// @notice The fill denominator: the maker-signed `fillTotal` when set (module
    ///         orders — no leg access, so it is safe for empty-leg NFT swaps), else
    ///         the leg anchor.
    function fillDenominator(Order calldata order) internal pure returns (uint256) {
        return order.fillTotal != 0 ? order.fillTotal : anchorTotal(order);
    }

    /// @notice Staticcall `target.validate(order, filler, data, takerData)` and return
    ///         whether it passed (call ok AND ≥32 bytes returned AND the bool word ==
    ///         1). The single-word return is read into scratch space, avoiding the
    ///         `bytes memory` return allocation the abstract call would make — and
    ///         capping the return copy at one word, so a hostile validator cannot
    ///         bomb the caller's memory. `data` is the maker-signed per-validator
    ///         config; `takerData` is the shared filler-supplied blob (a validator
    ///         must independently verify it).
    function gatePasses(
        address target,
        Order calldata order,
        address filler,
        bytes calldata data,
        bytes memory takerData
    ) internal view returns (bool pass) {
        bytes memory cd = abi.encodeCall(IOrderValidator.validate, (order, filler, data, takerData));
        /// @solidity memory-safe-assembly
        assembly {
            let ok := staticcall(gas(), target, add(cd, 0x20), mload(cd), 0x00, 0x20)
            pass := and(and(ok, gt(returndatasize(), 31)), eq(mload(0x00), 1))
        }
    }
}
