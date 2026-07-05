// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UniversalSettlement, Order, Item, Validator} from "@core/settlement/UniversalSettlement.sol";
import {MockSettlementBase} from "../shared/MockSettlementBase.t.sol";

/// @dev Property/fuzz coverage for the partial-fill accounting — the trickiest
/// arithmetic in the settler (pro-rata slices + ceil-rounded output delivery).
/// 0x uses randomized inputs for the same purpose; here it's real Foundry
/// fuzzing over the invariants:
///
///   • a full fill pays the solver EXACTLY amountIn and delivers ≥ amountOut;
///   • two partial fills covering the whole order pay the solver exactly amountIn
///     in total and never underpay the maker (ceil rounding);
///   • the per-fill output equals ceil(fillAmountIn · amountOut / amountIn).
contract FillAccountingFuzzTest is MockSettlementBase {
    function setUp() public override {
        super.setUp();
        // Generous, uniform approvals; amounts are minted per-case.
        _makerApprove(address(settlement), address(tA), type(uint160).max);
        _solverApprove(address(settlement), address(tB), type(uint160).max);
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }

    function _order(uint256 amountIn, uint256 amountOut) internal view returns (Order memory) {
        return _plainOrder(1, address(tA), address(tB), amountIn, amountOut);
    }

    function testFuzz_fullFill_exact(uint256 amountIn, uint256 amountOut) public {
        amountIn = bound(amountIn, 1, 1e27);
        amountOut = bound(amountOut, 1, 1e27);

        tA.mint(maker, amountIn);
        tB.mint(solver, amountOut);

        Order memory o = _order(amountIn, amountOut);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        settlement.fill(o, sig, amountIn);

        assertEq(tA.balanceOf(solver), amountIn, "solver paid exactly amountIn");
        assertEq(tB.balanceOf(maker), amountOut, "maker got exactly amountOut at full fill");
    }

    function testFuzz_twoPartialFills_sumInvariant(uint256 amountIn, uint256 amountOut, uint256 firstFill) public {
        amountIn = bound(amountIn, 2, 1e27);
        amountOut = bound(amountOut, 1, 1e27);
        firstFill = bound(firstFill, 1, amountIn - 1);
        uint256 secondFill = amountIn - firstFill;

        tA.mint(maker, amountIn);
        // Ceil rounding can deliver up to 1 extra unit per fill → mint headroom.
        tB.mint(solver, amountOut + 2);

        Order memory o = _order(amountIn, amountOut);
        bytes memory sig = _sign(o);

        vm.startPrank(solver);
        settlement.fill(o, sig, firstFill);
        settlement.fill(o, sig, secondFill);
        vm.stopPrank();

        // Solver paid EXACTLY amountIn across the two fills (tokenIn[0] owed == fill).
        assertEq(tA.balanceOf(solver), amountIn, "solver paid exactly amountIn total");

        // Maker delivered the ceil of each slice, and is NEVER underpaid.
        uint256 expected = _ceilDiv(firstFill * amountOut, amountIn) + _ceilDiv(secondFill * amountOut, amountIn);
        assertEq(tB.balanceOf(maker), expected, "delivered == sum of ceil slices");
        assertGe(tB.balanceOf(maker), amountOut, "maker never underpaid");
        // Ceil overpay is bounded by one unit per fill.
        assertLe(tB.balanceOf(maker) - amountOut, 2, "overpay bounded by 2 units");
    }

    function testFuzz_singlePartial_perFillOutput(uint256 amountIn, uint256 amountOut, uint256 fillAmt) public {
        amountIn = bound(amountIn, 2, 1e27);
        amountOut = bound(amountOut, 1, 1e27);
        fillAmt = bound(fillAmt, 1, amountIn);

        tA.mint(maker, amountIn);
        tB.mint(solver, amountOut + 1);

        Order memory o = _order(amountIn, amountOut);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        uint256[] memory outs = settlement.fill(o, sig, fillAmt);

        assertEq(outs[0], _ceilDiv(fillAmt * amountOut, amountIn), "per-fill output is ceil(fill*out/in)");
        assertEq(tB.balanceOf(maker), outs[0], "maker received the reported output");
        assertEq(tA.balanceOf(solver), fillAmt, "solver paid the fill amount");
    }
}
