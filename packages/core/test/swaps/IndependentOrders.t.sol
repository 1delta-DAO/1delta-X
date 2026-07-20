// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OrderState} from "@core/settlement/OrderState.sol";
import {Base} from "@core/settlement/Base.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item} from "@core/settlement/Settlement.sol";
import {Settlement} from "@core/settlement/Settlement.sol";

import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @dev "Independent per-leg fills" — the recommended way to let each asset
///      fill at its own rate and fraction is to sign SEPARATE orders, not to
///      decouple legs inside one order. Each order has its own hash, nonce, and
///      fill counter, so a solver fills any subset independently and cancelling
///      one leaves the others untouched. No multi-asset basket, no contract
///      change — this file is the executable spec for that pattern.
///
///      Two independent orders, both paying the maker in WETH:
///        A: sell 2000 USDC → 1 WETH   (nonce 100)
///        B: sell 3000 DAI  → 1.5 WETH (nonce 101)
contract IndependentOrdersTest is CoreSettlementBase {
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    uint256 constant NONCE_A = 100;
    uint256 constant NONCE_B = 101;
    uint256 constant USDC_IN = 2_000e6;
    uint256 constant WETH_OUT_A = 1 ether;
    uint256 constant DAI_IN = 3_000e18;
    uint256 constant WETH_OUT_B = 1.5 ether;

    function setUp() public override {
        super.setUp();
        vm.label(DAI, "DAI");
        // Maker bare-approves DAI to Permit3 (base only wires WETH/USDC).
        vm.prank(maker);
        IERC20(DAI).approve(address(permit3), type(uint256).max);
    }

    function _fund() internal {
        deal(USDC, maker, USDC_IN);
        deal(DAI, maker, DAI_IN);
        deal(WETH, solver, WETH_OUT_A + WETH_OUT_B);

        _approveMakerToSettlement(USDC, USDC_IN);
        _approveMakerToSettlement(DAI, DAI_IN);
        _approveSolverSide(WETH_OUT_A + WETH_OUT_B, WETH);
    }

    function _orderA() internal view returns (Order memory) {
        return _order(maker, NONCE_A, USDC, WETH, USDC_IN, WETH_OUT_A, new Item[](0));
    }

    function _orderB() internal view returns (Order memory) {
        return _order(maker, NONCE_B, DAI, WETH, DAI_IN, WETH_OUT_B, new Item[](0));
    }

    /// @dev The two orders fill at completely independent fractions: A at 50%,
    ///      B at 100%. Neither fill affects the other's remaining amount.
    function test_independentOrders_fillAtDifferentFractions() public {
        _fund();
        Order memory a = _orderA();
        Order memory b = _orderB();
        bytes memory sigA = _sign(a);
        bytes memory sigB = _sign(b);

        // Fill A halfway.
        vm.prank(solver);
        uint256 paidA = settlement.fill(a, sigA, USDC_IN / 2)[0];
        assertEq(paidA, WETH_OUT_A / 2, "A pays half its WETH");
        assertEq(lens.remaining(a), USDC_IN / 2, "A half remaining");
        assertEq(lens.remaining(b), DAI_IN, "B untouched by A's fill");

        // Fill B fully — independent of A's state.
        vm.prank(solver);
        uint256 paidB = settlement.fill(b, sigB, DAI_IN)[0];
        assertEq(paidB, WETH_OUT_B, "B pays full WETH");
        assertEq(lens.remaining(b), 0, "B fully filled");
        assertEq(lens.remaining(a), USDC_IN / 2, "A still half after B fully fills");

        // Maker received WETH from both; solver received each input token.
        assertEq(IERC20(WETH).balanceOf(maker), WETH_OUT_A / 2 + WETH_OUT_B, "maker WETH = A(half)+B(full)");
        assertEq(IERC20(USDC).balanceOf(solver), USDC_IN / 2, "solver got half the USDC");
        assertEq(IERC20(DAI).balanceOf(solver), DAI_IN, "solver got all the DAI");
    }

    /// @dev Cancelling one order's nonce disables only that order; the other
    ///      stays fully fillable.
    function test_independentOrders_cancelOneKeepsOther() public {
        _fund();
        Order memory a = _orderA();
        Order memory b = _orderB();
        bytes memory sigA = _sign(a);
        bytes memory sigB = _sign(b);

        // Maker cancels order A only.
        uint256[] memory toCancel = new uint256[](1);
        toCancel[0] = NONCE_A;
        vm.prank(maker);
        settlement.cancelOrders(toCancel);

        // A can no longer be filled.
        vm.prank(solver);
        vm.expectRevert(OrderState.NonceCancelled.selector);
        settlement.fill(a, sigA, USDC_IN);

        // B is unaffected — fills normally.
        vm.prank(solver);
        uint256 paidB = settlement.fill(b, sigB, DAI_IN)[0];
        assertEq(paidB, WETH_OUT_B, "B fills despite A cancelled");
        assertEq(IERC20(DAI).balanceOf(solver), DAI_IN, "solver got the DAI");
    }
}
