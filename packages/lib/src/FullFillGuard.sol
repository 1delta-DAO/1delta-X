// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title FullFillGuard
/// @notice Rejects a partially-filled slice for COMPOSITE items — the ones that
///         perform a multi-leg position operation (deposit + borrow, repay +
///         withdraw) in a single module call.
///
///  The problem
///  ───────────
///  `Base._executeItems` pro-rates `item.amount` across fills, so a module's
///  `amount` argument is this fill's SLICE. But a composite module's second leg
///  (`sideAmount` — the collateral to supply, the debt to repay) lives inside
///  `item.data`, which is CONSTANT across fills. The core has no way to scale it:
///  the amount is encoded in a module-specific blob the core deliberately does not
///  decode.
///
///  So every slice re-executed the side leg IN FULL. A maker signing "borrow 1000,
///  post 500 collateral" and granting the module the usual standing Permit3 token
///  allowance would have 500 pulled again on EVERY partial fill — N × 500 for an
///  N-slice fill, bounded only by their allowance and wallet balance, at a leverage
///  ratio they never signed. The solver chooses N, so this is reachable by any
///  filler at negligible cost. It also contradicts the modules' own claim that the
///  Permit3 allowance bounds the per-fill amount: the taker allowance gates only
///  the borrow leg, never the side leg.
///
///  Why reject rather than pro-rate
///  ───────────────────────────────
///  Pro-rating the side leg would fix the accounting, but a partially-filled
///  composite OPEN is not meaningful in the first place for at least two of the
///  protocols involved: Fluid mints a SEPARATE position NFT per slice (`nftId == 0`
///  opens a new one), and Liquity-style troves revert on the second slice because
///  the trove is already active. Splitting one leveraged position across N slices
///  is not a partial fill of the maker's intent, it is N different positions.
///
///  Rejecting is therefore both uniformly correct and fail-closed: a maker whose
///  order is not sized for a single fill learns at fill time instead of ending up
///  over-collateralised or with a half-open position. Genuine partial-fill support
///  for composite opens needs its own design (a pro-rated side leg AND a
///  position-identity rule), not a patch here.
///
///  Usage: the module carries the item's FULL signed amount in its `data` as
///  `totalAmount` (maker-signed, and part of `ref = keccak256(data)` for a TAKE
///  item, so a filler cannot alter it) and asserts the slice equals it.
library FullFillGuard {
    /// @dev This fill's slice is not the whole item. `totalAmount == 0` also lands
    ///      here — a maker who omits the field gets a revert rather than a silently
    ///      unguarded pull.
    error PartialFillUnsupported(uint256 amount, uint256 totalAmount);
    /// @dev A `Full`-mode withdraw produced less than the maker's signed amount.
    error ShortWithdraw(uint256 received, uint256 amount);

    /// @param amount      this fill's pro-rated slice, as passed to the module
    /// @param totalAmount the item's full maker-signed amount, carried in `data`
    function requireFullFill(uint256 amount, uint256 totalAmount) internal pure {
        if (amount != totalAmount || totalAmount == 0) revert PartialFillUnsupported(amount, totalAmount);
    }

    /// @notice Variant for modules that carry the total as a TRAILING word rather
    ///         than a named struct field — the `BalanceMode.Full` taker legs.
    ///
    ///  `Full` mode has the same defect as a composite item for a different reason:
    ///  it reads the user's ENTIRE live protocol balance and liquidates all of it,
    ///  independent of the slice. A 1-unit fill therefore force-closes the whole
    ///  position and, because the balance is then zero, bricks every later fill of
    ///  the same order. No theft — the excess always routes back to the user — but
    ///  any filler could unwind a maker's position for one unit of allowance.
    ///
    ///  The modules cannot detect this themselves: `Full` is resolved from live
    ///  protocol state, so there is nothing to pro-rate against. The maker signs the
    ///  total alongside the mode and the slice is required to equal it.
    ///
    /// @param data    the module's full `data` blob
    /// @param offset  byte offset of the trailing total (after the mode slot)
    /// @param amount  this fill's slice
    function requireFullFillFromData(bytes calldata data, uint256 offset, uint256 amount) internal pure {
        // Absent ⇒ fail closed. A `Full` order that predates this field is exactly
        // the order that was vulnerable, so it must not keep working silently.
        if (data.length < offset + 32) revert PartialFillUnsupported(amount, 0);
        requireFullFill(amount, uint256(bytes32(data[offset:offset + 32])));
    }

    /// @notice Require a `Full`-mode withdraw to have produced the signed amount.
    ///
    /// @dev ⚠ THIS RESTORES A BOUND THE VENUE USED TO ENFORCE, AND IT IS NOT THE
    ///      GATE THAT WAS DELETED. Before the withdraw-once-then-split rewrite the
    ///      venue call itself was sized at `amount`, so a position short of it
    ///      reverted inside the venue — "fail closed, no gate needed". The rewrite
    ///      withdraws the whole position and splits it, so nothing reverts on a
    ///      short any more, and the substitute the posture note cited (Settlement's
    ///      output validation) does not cover this side of the ledger: a withdraw
    ///      item funds an INPUT leg, and {Core._payInputsToSolver} silently pulls
    ///      `owed - proceeds` out of the MAKER'S WALLET.
    ///
    ///      Safe to apply only on `Full` legs, which is why it lives beside
    ///      {requireFullFill}: there `amount == totalAmount` is the maker's signed
    ///      TOTAL, not a pro-rated slice, so the comparison cannot misfire on a
    ///      partial fill. Do NOT add it to an `Exact` branch, where `amount` is a
    ///      slice and a short delivery is the core's business, not the module's.
    function requireDelivered(uint256 received, uint256 amount) internal pure {
        if (received < amount) revert ShortWithdraw(received, amount);
    }
}
