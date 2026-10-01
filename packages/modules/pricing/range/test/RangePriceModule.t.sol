// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order} from "@core/settlement/Settlement.sol";

import {RangePriceModule} from "../src/RangePriceModule.sol";

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {MockSettlementBase} from "@coretest/shared/MockSettlementBase.t.sol";

/// @title RangePriceModuleTest
/// @notice The LADDER: price varies along the VOLUME axis (`prevFilled / total`)
///         rather than the clock — 1inch's `RangeAmountCalculator`. Because it is
///         measured on `prevFilled`, a solver knows the exact bump before submitting.
///
///  Two halves: the module's own curve, asserted directly on `bump()` (including the
///  rejected descending shape and the boundary guards, which nothing exercised while this
///  contract lived in core), and one end-to-end fill proving the core clamps and
///  applies what it answers.
contract RangePriceModuleTest is MockSettlementBase {
    uint256 constant SELL_IN = 1_000e18;
    uint256 constant OUT_START = 2_000e18;
    uint256 constant OUT_END = 1_000e18;

    function _bump(RangePriceModule m, uint256 prevFilled, uint256 total) internal view returns (uint256) {
        return m.bump(bytes32(0), address(0), address(0), prevFilled, total, 0, "", "", "");
    }

    // ── the curve, read directly ──

    function test_ascending_interpolatesOnProgress() public {
        RangePriceModule m = new RangePriceModule(0, 10_000);
        assertEq(_bump(m, 0, 100), 0, "opens at START");
        assertEq(_bump(m, 25, 100), 2_500, "quarter filled");
        assertEq(_bump(m, 50, 100), 5_000, "half filled");
        assertEq(_bump(m, 100, 100), 10_000, "closes at END");
    }

    /// @dev Audit 2026-09-30 PRICE-3 / PRICE-4. The descending branch (`END < START`,
    ///      the maker's price improving as it fills) used to be accepted: a single
    ///      full fill at progress 0 cleared the whole order at START_BPS, the maker's
    ///      WORST point, and its decrement rounded filler-ward. It is now refused at
    ///      construction. (Replaces `test_descending_interpolatesDownward`, which
    ///      pinned the collapsing behaviour.)
    function test_audit_PRICE_3_descendingLadder_rejected() public {
        vm.expectRevert(abi.encodeWithSignature("DescendingRange()"));
        new RangePriceModule(10_000, 2_000);
        vm.expectRevert(abi.encodeWithSignature("DescendingRange()"));
        new RangePriceModule(1, 0);
    }

    /// @dev PRICE-4: every bump the module can still return rounds toward the maker
    ///      (at or below the exact interpolation). 1/3 of 0→10000 is 3333.33 → 3333.
    function test_audit_PRICE_4_bumpRoundsTowardMaker() public {
        RangePriceModule m = new RangePriceModule(0, 10_000);
        assertEq(_bump(m, 1, 3), 3_333, "floor of 3333.33");
        assertEq(_bump(m, 2, 3), 6_666, "floor of 6666.67");
    }

    /// @dev PRICE-3 end to end: the bump a full fill sees is START_BPS, the maker's
    ///      best point on an ascending ladder — the only direction still deployable.
    function test_audit_PRICE_3_fullFill_pricedAtMakersBestPoint() public {
        RangePriceModule m = new RangePriceModule(2_000, 10_000);
        assertEq(_bump(m, 0, 100), 2_000, "a one-shot fill pays the maker's best ladder point");
        assertLe(_bump(m, 0, 100), _bump(m, 99, 100), "later progress never improves on it for the maker");
    }

    function test_flatRange_isConstant() public {
        RangePriceModule m = new RangePriceModule(3_333, 3_333);
        assertEq(_bump(m, 0, 100), 3_333);
        assertEq(_bump(m, 71, 100), 3_333);
        assertEq(_bump(m, 100, 100), 3_333);
    }

    /// @dev A zero denominator is not this module's to reject — the core already
    ///      resolved it — but dividing by it would revert the fill with an opaque
    ///      panic. It prices an unstarted order at the opening bump instead.
    function test_zeroDenominator_pricesAtStart_ratherThanPanicking() public {
        RangePriceModule m = new RangePriceModule(4_000, 10_000);
        assertEq(_bump(m, 0, 0), 4_000, "zero total");
        assertEq(_bump(m, 5, 0), 4_000, "zero total with progress");
        assertEq(_bump(m, 0, 100), 4_000, "nothing filled yet");
    }

    /// @dev Over-progress cannot run past the far end of the signed ladder.
    function test_progressBeyondTotal_clampsToEnd() public {
        RangePriceModule m = new RangePriceModule(0, 10_000);
        assertEq(_bump(m, 500, 100), 10_000, "clamped to END");
    }

    function test_constructor_rejectsOutOfRangeBps() public {
        vm.expectRevert(RangePriceModule.InvalidRange.selector);
        new RangePriceModule(10_001, 0);
        vm.expectRevert(RangePriceModule.InvalidRange.selector);
        new RangePriceModule(0, 10_001);
    }

    // ── end to end: the core applies what it answers ──

    function test_fill_pricesEachSliceOnProgress() public {
        tA.mint(maker, SELL_IN);
        _makerApprove(address(settlement), address(tA), SELL_IN);
        tB.mint(solver, OUT_START * 2);
        _solverApprove(address(settlement), address(tB), OUT_START * 2);

        RangePriceModule m = new RangePriceModule(0, 10_000);
        Order memory o = _plainOrder(1, address(tA), address(tB), SELL_IN, OUT_START);
        o.legsOut = PackedEncode.oneLegOut(address(tB), OUT_START, OUT_END, address(0));
        o.pricingModule = address(m);
        bytes memory sig = _sign(o);

        // First half: progress 0 ⇒ the full `start` rate.
        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN / 2);
        assertEq(tB.balanceOf(maker) - before_, OUT_START / 2, "first slice at the start rate");

        // Second half: progress is now 50% ⇒ the midpoint rate.
        before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN / 2);
        assertEq(tB.balanceOf(maker) - before_, ((OUT_START + OUT_END) / 2) / 2, "second slice at the midpoint");
    }
}
