// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order} from "@core/settlement/Structs.sol";
import {PackedArrays} from "@core/settlement/PackedArrays.sol";

/// @title InvariantReceiptGuard
/// @notice The F30 named-filler rule, applied where an END-STATE invariant is the
///         maker's receipt (audit 2026-09-30 VAL-1).
///
///  The problem
///  ───────────
///  {Erc721OwnerInvariant}, {Erc1155BalanceInvariant} and {MinBalanceInvariant} are
///  stateless STATICCALL views: they check that the maker HOLDS something when the
///  fill ends — an end state — and cannot tell THIS fill's delivery apart from any
///  other inflow. When the order carries a fungible output leg that is harmless:
///  the filler must deliver the leg, and the invariant only adds a floor. But on the
///  documented purchase shape — `legsOut` empty, the maker paying through `legsIn`
///  and/or items (none, the maker's own NFT via SETTLE in an NFT-for-NFT swap, …) —
///  the invariant IS the receipt, and an open filler can collect the maker's payment
///  while the "delivery" is something the maker paid for elsewhere: a second
///  uncancelled bid, a Seaport/Blur offer the filler accepts inside its own
///  callback, or the maker simply having bought the NFT at the ask. Once the maker
///  owns the asset, a stale purchase order is a free payout for any bot. F30 closed
///  the same hole for delta-verify orders by making them fillable only by their
///  named `exclusiveFiller`; this is that rule for the invariant-receipt shape,
///  enforced by the invariant itself (zero Settlement bytes).
///
///  The rule
///  ────────
///  If `legsOut` is empty, the fill must come from `order.exclusiveFiller` — for the
///  WHOLE life of the order, regardless of the exclusivity window, exactly like F30.
///  An open order (`exclusiveFiller == 0`) and a filler-SET order (`address(1)`,
///  which can never be a caller) fail closed. Naming a contract moves the trust onto
///  that contract's access control (F31): name an EOA or an operator-GATED solver.
///  Items do not lift the rule: no item op delivers value TO the maker from the
///  filler (SETTLE moves maker→filler, MAKE/TAKE touch only the maker's own
///  positions), so with no output leg nothing but the invariant binds the filler.
///
///  An order with at least one output leg is untouched — the leg is the receipt and
///  the invariant an additional floor (the fee-on-transfer use of
///  {MinBalanceInvariant}).
library InvariantReceiptGuard {
    /// @dev The order's only consideration is an end-state invariant (no output
    ///      leg), and the fill does not come from the order's named `exclusiveFiller`.
    error ReceiptNeedsNamedFiller();

    /// @notice Revert {ReceiptNeedsNamedFiller} when `order` has no output leg and
    ///         `filler` is not its named `exclusiveFiller`.
    function enforce(Order calldata order, address filler) internal pure {
        if (PackedArrays.validateFixed(order.legsOut, PackedArrays.LEG_OUT_STRIDE) != 0) return;
        if (filler == address(0) || filler != order.exclusiveFiller) revert ReceiptNeedsNamedFiller();
    }
}
