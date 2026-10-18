// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Order, LegOut} from "@core/settlement/Settlement.sol";
import {AggregatorFillSolver, RoutePlan, NO_PATCH, Permit2612} from "@solvers/aggregator/AggregatorFillSolver.sol";

import {AggregatorFillSolverTest, MockRouter} from "./AggregatorFillSolver.t.sol";
import {noGuard} from "./shared/AggDeploy.sol";

/// @title AggregatorPatchAndItemGuardsTest
/// @notice Solver v3 fixes:
///           • task 16 — the live `amountOutOffset` patch writes the priced amount of
///             the ANCHOR output legs, not blindly `pricedOut[0]`. On the pull path
///             that is Σ of every leg in the anchor output token (the core pulls each
///             one from the solver); a fee leg listed first used to make the
///             exact-output word the FEE, and the fill reverted on the core's pull;
///           • task 17 — {AggregatorFillSolver.executeItemFill} refuses a non-default
///             `minBumpBps` / `amountOutOffset` (`ItemFillUnsupported`) instead of
///             silently ignoring them.
contract AggregatorPatchAndItemGuardsTest is AggregatorFillSolverTest {
    address constant ORIGINATOR = address(0x0516);
    uint256 constant FEE = 5e18;

    function _np() internal pure returns (Permit2612[] memory) {
        return new Permit2612[](0);
    }

    /// @dev An exact-output pull route paying the SOLVER, its output word (offset 4)
    ///      patched with the core's live price; the quoted word is a dummy.
    function _patchedExactOut() internal view returns (RoutePlan memory p) {
        p = _exactOutPlan(1, AMOUNT_IN, address(aggSolver));
        p.amountOutOffset = 4;
    }

    function _withLegs(uint256 nonce, LegOut[] memory lo) internal view returns (Order memory o) {
        o = _order(nonce);
        o.legsOut = PackedEncode.legsOut(lo);
    }

    /// Task 16: `legsOut = [tokenIn fee -> originator, tokenOut -> maker]` with the
    /// patch set. Before the fix the word took `pricedOut[0]` = the FEE (5e18 tB), the
    /// route produced 5e18 and the core's pull of 90e18 failed.
    function test_task16_inKindFeeFirst_patchesTheAnchorLeg() public {
        LegOut[] memory lo = new LegOut[](2);
        lo[0] = LegOut(address(tA), FEE, 0, ORIGINATOR);
        lo[1] = LegOut(address(tB), AMOUNT_OUT, 0, address(0));
        Order memory o = _withLegs(1, lo);
        bytes memory sig = _sign(o);
        aggSolver.executeFill(o, sig, AMOUNT_IN, _patchedExactOut(), "", _np());
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "maker paid the anchor leg");
        assertEq(tA.balanceOf(ORIGINATOR), FEE, "in-kind fee kept back and paid");
        assertEq(tB.balanceOf(address(router)), 1_000e18 - AMOUNT_OUT, "route produced exactly the anchor leg");
    }

    /// Task 16: `legsOut = [tokenOut fee -> originator, tokenOut -> maker]` — both legs
    /// are pulled from the solver in the anchor token, so the word is their SUM.
    function test_task16_outputFeeFirst_patchesTheSum() public {
        LegOut[] memory lo = new LegOut[](2);
        lo[0] = LegOut(address(tB), 2e18, 0, ORIGINATOR);
        lo[1] = LegOut(address(tB), AMOUNT_OUT, 0, address(0));
        Order memory o = _withLegs(2, lo);
        bytes memory sig = _sign(o);
        aggSolver.executeFill(o, sig, AMOUNT_IN, _patchedExactOut(), "", _np());
        assertEq(tB.balanceOf(maker), AMOUNT_OUT);
        assertEq(tB.balanceOf(ORIGINATOR), 2e18);
        assertEq(tB.balanceOf(address(router)), 1_000e18 - AMOUNT_OUT - 2e18, "route produced fee + maker leg");
        assertEq(tA.balanceOf(address(this)), AMOUNT_IN - AMOUNT_OUT - 2e18 - 1, "the spread is input residue (less the seeded wei)");
    }

    /// Task 16, direct path unchanged: the word is leg 0's price (the leg the route pays).
    function test_task16_directStillLegZero() public {
        Order memory o = _directOrder(3);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _exactOutPlan(1, AMOUNT_IN, maker);
        p.amountOutOffset = 4;
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        assertEq(tB.balanceOf(maker), AMOUNT_OUT);
    }

    /// Task 17: each non-default field reverts `executeItemFill` before anything moves.
    function test_task17_itemFillRefusesMinBump() public {
        Order memory o = _order(4);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _plan(address(aggSolver), AMOUNT_OUT);
        p.minBumpBps = 1;
        vm.expectRevert(AggregatorFillSolver.ItemFillUnsupported.selector);
        aggSolver.executeItemFill(o, sig, AMOUNT_IN, p, "", 0, _np(), noGuard());
    }

    function test_task17_itemFillRefusesAmountOutOffset() public {
        Order memory o = _order(5);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _plan(address(aggSolver), AMOUNT_OUT);
        p.amountOutOffset = 4;
        vm.expectRevert(AggregatorFillSolver.ItemFillUnsupported.selector);
        aggSolver.executeItemFill(o, sig, AMOUNT_IN, p, "", 0, _np(), noGuard());
    }

    /// Task 17: the defaults (and any bit-255 "no patch" spelling) still fill.
    function test_task17_itemFillDefaultsStillFill() public {
        Order memory o = _order(6);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _plan(address(aggSolver), AMOUNT_OUT);
        p.amountOutOffset = type(uint256).max; // legacy NO_PATCH spelling
        aggSolver.executeItemFill(o, sig, AMOUNT_IN, p, "", 0, _np(), noGuard());
        assertEq(tB.balanceOf(maker), AMOUNT_OUT);
    }
}
