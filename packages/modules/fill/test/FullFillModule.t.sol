// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item} from "@core/settlement/Settlement.sol";
import {OrderState} from "@core/settlement/OrderState.sol";

import {FullFillModule} from "../src/FullFillModule.sol";

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";

/// @title FullFillModuleTest
/// @notice The all-or-nothing `IFillModule`: whatever a filler asks for, the module
///         answers "the entire remaining denominator", so a single fill completes the
///         order and there is no second one.
///
///  The core's side of this seam — that it applies the returned delta and enforces
///  the over-fill cap — is proven in core's `FillModule.t.sol` against a local mock.
///  What is proven here is this contract's own answer.
contract FullFillModuleTest is CoreSettlementBase {
    FullFillModule fullFill;

    function setUp() public override {
        super.setUp();
        fullFill = new FullFillModule();
    }

    /// @dev The whole point: the requested `fillAmount` is IGNORED.
    function test_resolveFill_ignoresRequest_returnsRemaining() public view {
        Order memory o = _order(maker, 1, USDC, WETH, 2_000e6, 1 ether, new Item[](0));
        o.fillTotal = 1_000;
        assertEq(fullFill.resolveFill(o, 0, 1, ""), 1_000, "a 1-unit request still takes the lot");
        assertEq(fullFill.resolveFill(o, 0, type(uint256).max, ""), 1_000, "an over-request is not amplified");
        assertEq(fullFill.resolveFill(o, 400, 1, ""), 600, "net of what is already filled");
        assertEq(fullFill.resolveFill(o, 1_000, 1, ""), 0, "nothing left on a complete order");
    }

    function test_fill_isIndivisible_andSecondFillReverts() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);
        _approveMakerToSettlement(USDC, usdcIn);
        _approveSolverSide(wethOut, WETH);

        Order memory o = _order(maker, 1, USDC, WETH, usdcIn, wethOut, new Item[](0));
        o.fillModule = address(fullFill);
        o.fillTotal = 1; // indivisible unit — the fraction is 1/1 at the single fill
        bytes memory sig = _sign(o);

        // A "partial" request is ignored — the module returns the whole total.
        vm.prank(solver);
        settlement.fill(o, sig, 999, "");
        assertEq(IERC20(WETH).balanceOf(maker), wethOut, "full output on the single fill");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "full input on the single fill");

        // The order is COMPLETE, so {OrderState._gateFillState} rejects the next fill
        // before the module is consulted at all.
        vm.prank(solver);
        vm.expectRevert(OrderState.OverFill.selector);
        settlement.fill(o, sig, 1, "");
    }
}
