// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OrderGates} from "@core/settlement/OrderGates.sol";
import {OrderState} from "@core/settlement/OrderState.sol";
import {Proportional} from "@core/settlement/Proportional.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {SettlementLens} from "@periphery/SettlementLens.sol";
import {Order} from "@core/settlement/Settlement.sol";

import {MockSettlementBase} from "@coretest/shared/MockSettlementBase.t.sol";

/// @title LensReaudit0929
/// @notice The lens half of the 2026-09-29 re-audit: the core changed two rules
///         the lens mirrors, and the lens carried two drifts of its own. Each test
///         pins the lens to what the SETTLER does with the same order, not to a
///         restatement of the rule — a preflight that disagrees with the settler
///         fails quietly, in whichever direction (`docs/reference-audits.md` §C13).
///
///   1. `previewFill` trimmed an oversized request on a {Proportional} anchor down to
///      the live balance, after the core stopped doing so (it now reverts
///      `OverFill`) — so it quoted the front-run dust fill as a success.
///   2. A soft-exclusivity override with no leg to carry it is now a HARD window in
///      the core; `validateOrder` did not say so.
///   3. An output leg paid to the settlement's EXECUTOR was not flagged, though the
///      netted path refuses it and on the single path anyone can take it.
///   4. `getOrderRelevantState` reported a proportional order's funding cap as its
///      fillable amount, though anything short of the whole anchor reverts.
contract LensReaudit0929Test is MockSettlementBase {
    uint256 constant IN_ = 1_000e18;
    uint256 constant OUT_ = 2e18;
    address constant EX = address(0xE0); // the named exclusive filler
    address constant THIRD = address(0xFEE); // a non-maker output recipient

    /// @dev "Sell `bps` of my tA balance, capped at `cap`" for a fixed `OUT_` of tB.
    function _propOrder(uint256 nonce, uint256 cap) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), 1, OUT_);
        o.legsIn = PackedEncode.oneLegIn(address(tA), Proportional.encode(10_000), cap);
    }

    function _fundSolver(uint256 amt) internal {
        tB.mint(solver, amt);
        _solverApprove(address(settlement), address(tB), amt);
    }

    // ════════════════════ 1. proportional clamp ════════════════════

    /// The maker front-runs a quoted proportional fill by moving out all but 1 wei.
    /// The fill reverts `OverFill` rather than paying the full output for dust — and
    /// the preview must now say the same thing instead of quoting a 1-wei success.
    /// The explicit `type(uint256).max` opt-in is still trimmed, on both sides alike.
    function test_lens_previewFill_proportionalOversized_revertsOverFill() public {
        uint256 quoted = IN_;
        tA.mint(maker, quoted);
        _makerApprove(address(settlement), address(tA), type(uint160).max);
        _fundSolver(OUT_);
        Order memory o = _propOrder(1, quoted);
        bytes memory sig = _sign(o);

        (uint256 d0,,) = lens.previewFill(o, quoted, solver, "");
        assertEq(d0, quoted, "at the quoted balance the quoted size is exactly whole");

        vm.prank(maker);
        tA.transfer(address(0xdead), quoted - 1);

        vm.expectRevert(SettlementLens.OverFill.selector);
        lens.previewFill(o, quoted, solver, "");
        vm.prank(solver);
        vm.expectRevert(OrderState.OverFill.selector);
        settlement.fillUpTo(o, sig, quoted, address(0), 0, "");

        // `max` = "whatever the balance is": trimmed to the live anchor, identically.
        (uint256 pd, uint256[] memory pr, uint256[] memory pp) = lens.previewFill(o, type(uint256).max, solver, "");
        vm.prank(solver);
        (uint256 fd, uint256[] memory fr, uint256[] memory fp) =
            settlement.fillUpTo(o, sig, type(uint256).max, address(0), 0, "");
        assertEq(pd, 1, "trimmed to the 1-wei anchor");
        assertEq(pd, fd, "delta");
        assertEq(pr[0], fr[0], "received");
        assertEq(pp[0], fp[0], "paid");
    }

    // ════════════════════ 2. soft exclusivity without a carrier ════════════════════

    function _soft(Order memory o) internal view {
        o.exclusiveFiller = EX;
        _setExclusivityEnd(o, block.timestamp + 1 hours);
        o.params = 100; // overrideBps (params bits [0:16))
    }

    /// Whatever `validateOrder` says about the carrier, the settler's gate must agree:
    /// flagged ⇔ an in-window outsider's preview reverts `NotExclusiveFiller`. The
    /// preview runs the core's own {OrderGates.exclusivityOverride}, so this is a
    /// differential against the real rule — and for the headline shape the real
    /// `fill` is checked too.
    function _assertCarrierParity(Order memory o, bool carrier, string memory label) internal {
        (bool ok, string memory why) = lens.validateOrder(o);
        if (carrier) {
            assertTrue(ok, string.concat(label, ": carrier shape validates"));
            lens.previewFill(o, IN_, solver, ""); // outsider admitted at the premium
        } else {
            assertFalse(ok, label);
            assertEq(why, "override has no carrier leg (outsiders are refused in-window)", label);
            vm.expectRevert(OrderGates.NotExclusiveFiller.selector);
            lens.previewFill(o, IN_, solver, "");
        }
        // The exclusive filler itself is never affected either way.
        lens.previewFill(o, IN_, EX, "");
    }

    function test_lens_softExclusivity_noCarrier_refusedAndFlagged() public {
        tA.mint(maker, IN_); // a proportional anchor below must resolve non-zero

        // Swap-and-send: fixed input, the only output paid to a third party. Nothing
        // can carry the premium, so outsiders are refused — preview AND fill.
        Order memory sendOnly = _plainOrder(1, address(tA), address(tB), IN_, OUT_);
        sendOnly.legsOut = PackedEncode.setLegOutRecipient(sendOnly.legsOut, 0, THIRD);
        _soft(sendOnly);
        _assertCarrierParity(sendOnly, false, "swap-and-send");
        bytes memory sig = _sign(sendOnly);
        vm.prank(solver);
        vm.expectRevert(OrderGates.NotExclusiveFiller.selector);
        settlement.fill(sendOnly, sig, IN_);

        // Same order, output back to the maker: a carrier.
        Order memory toMaker = _plainOrder(2, address(tA), address(tB), IN_, OUT_);
        _soft(toMaker);
        _assertCarrierParity(toMaker, true, "output to maker");

        // Output to a third party but an AUCTIONED input (end > start): a carrier.
        Order memory auctioned = _plainOrder(3, address(tA), address(tB), IN_, OUT_);
        auctioned.legsIn = PackedEncode.setLegInEnd(auctioned.legsIn, 0, IN_ * 2);
        auctioned.legsOut = PackedEncode.setLegOutRecipient(auctioned.legsOut, 0, THIRD);
        _soft(auctioned);
        _assertCarrierParity(auctioned, true, "auctioned input");

        // The subtle one: a PROPORTIONAL input has `end != 0` (its cap) but is never
        // priced by the override — {Pricing.inputOwed} returns the pinned anchor.
        Order memory prop = _propOrder(4, IN_);
        prop.legsOut = PackedEncode.setLegOutRecipient(prop.legsOut, 0, THIRD);
        _soft(prop);
        _assertCarrierParity(prop, false, "proportional input");
    }

    // ════════════════════ 3. output leg to the EXECUTOR ════════════════════

    function test_lens_validateOrder_flagsExecutorRecipient() public view {
        Order memory o = _plainOrder(1, address(tA), address(tB), IN_, OUT_);
        (bool ok,) = lens.validateOrder(o);
        assertTrue(ok, "control");

        o.legsOut = PackedEncode.setLegOutRecipient(o.legsOut, 0, address(settlement.EXECUTOR()));
        string memory why;
        (ok, why) = lens.validateOrder(o);
        assertFalse(ok);
        assertEq(why, "recipient is settlement executor (takeable)");

        // The sibling rule is unchanged.
        o.legsOut = PackedEncode.setLegOutRecipient(o.legsOut, 0, address(settlement));
        (ok, why) = lens.validateOrder(o);
        assertEq(why, "recipient is settlement (burn)");
    }

    // ════════════════════ 4. proportional fillable = whole or nothing ════════════════════

    /// Capacity below the resolved anchor is "cannot fill", not "can fill this much":
    /// the only fill a proportional order accepts is the whole anchor from zero.
    function test_lens_orderState_proportionalBelowAnchor_fillableZero() public {
        tA.mint(maker, IN_);
        _fundSolver(2 * OUT_);
        Order memory o = _propOrder(1, type(uint128).max);
        bytes memory sig = _sign(o);

        // Allowance 40% of the balance. The lens used to report 400e18 fillable...
        _makerApprove(address(settlement), address(tA), (IN_ * 4) / 10);
        (SettlementLens.OrderStatus st, uint256 fillable,,) = lens.getOrderRelevantState(o, sig, solver, "");
        assertEq(uint256(st), uint256(SettlementLens.OrderStatus.Fillable));
        assertEq(fillable, 0, "cap below the anchor: nothing fillable");
        // ...and a fill sized to that hint reverts.
        vm.prank(solver);
        vm.expectRevert(Proportional.ProportionalNeedsFullFill.selector);
        settlement.fill(o, sig, (IN_ * 4) / 10);

        // Fully funded: the whole anchor, and it fills.
        _makerApprove(address(settlement), address(tA), type(uint160).max);
        (, fillable,,) = lens.getOrderRelevantState(o, sig, solver, "");
        assertEq(fillable, IN_, "funded: the whole resolved anchor");
        vm.prank(solver);
        settlement.fill(o, sig, IN_);

        // The balance regrows past the recorded progress. `anchor - done` is positive,
        // but no fill can ever start from non-zero progress: fillable must read 0.
        tA.mint(maker, (IN_ * 3) / 2); // anchor 1.5x, recorded progress 1x
        (st, fillable,,) = lens.getOrderRelevantState(o, sig, solver, "");
        assertEq(uint256(st), uint256(SettlementLens.OrderStatus.Fillable));
        assertEq(fillable, 0, "progress recorded: never completable");
        vm.prank(solver);
        vm.expectRevert(Proportional.ProportionalNeedsFullFill.selector);
        settlement.fill(o, sig, IN_ / 2);
    }
}
