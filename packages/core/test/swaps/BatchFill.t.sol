// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "@core/settlement/Base.sol";
import {Settlement, Order, Item, Validator} from "@core/settlement/Settlement.sol";
import {MockSettlementBase} from "../shared/MockSettlementBase.t.sol";

/// @dev Port of 0x's `batch_fill_native_orders_test.ts` against our `batchFill`:
/// fill many orders, partial amounts, skip-unfillable, and the `revertIfIncomplete`
/// all-or-nothing flag (reverts on an unfillable order AND on an incomplete fill).
///
/// N/A (by design): ETH-refund variants (we are ERC20/Permit3-only).
contract BatchFillTest is MockSettlementBase {
    uint256 constant AMOUNT_IN = 100e18;
    uint256 constant AMOUNT_OUT = 300e18;

    function setUp() public override {
        super.setUp();
        tA.mint(maker, 1_000e18);
        tB.mint(solver, 10_000e18);
        _makerApprove(address(settlement), address(tA), type(uint160).max);
        _solverApprove(address(settlement), address(tB), type(uint160).max);
    }

    function _order(uint256 nonce) internal view returns (Order memory) {
        return _plainOrder(nonce, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
    }

    function _batch(uint256 n)
        internal
        view
        returns (Order[] memory orders, bytes[] memory sigs, uint256[] memory amounts)
    {
        orders = new Order[](n);
        sigs = new bytes[](n);
        amounts = new uint256[](n);
        for (uint256 i; i < n; i++) {
            orders[i] = _order(i);
            sigs[i] = _sign(orders[i]);
            amounts[i] = AMOUNT_IN;
        }
    }

    function test_batchFill_allFull() public {
        (Order[] memory orders, bytes[] memory sigs, uint256[] memory amounts) = _batch(3);

        vm.prank(solver);
        (, bool[] memory success) = settlement.batchFill(orders, sigs, amounts, false);

        assertTrue(success[0] && success[1] && success[2], "all filled");
        assertEq(tA.balanceOf(solver), AMOUNT_IN * 3, "solver got all tokenIn");
        assertEq(tB.balanceOf(maker), AMOUNT_OUT * 3, "maker got all tokenOut");
    }

    function test_batchFill_partialAmounts() public {
        (Order[] memory orders, bytes[] memory sigs, uint256[] memory amounts) = _batch(3);
        amounts[0] = AMOUNT_IN / 2;
        amounts[1] = AMOUNT_IN / 4;
        // amounts[2] full

        vm.prank(solver);
        settlement.batchFill(orders, sigs, amounts, false);
        assertEq(tA.balanceOf(solver), AMOUNT_IN / 2 + AMOUNT_IN / 4 + AMOUNT_IN, "sum of partials");
    }

    function test_batchFill_skipsUnfillable() public {
        (Order[] memory orders, bytes[] memory sigs, uint256[] memory amounts) = _batch(3);
        // Cancel the middle order → it must be skipped, others still fill.
        uint256[] memory nonces = new uint256[](1);
        nonces[0] = 1;
        vm.prank(maker);
        settlement.cancelOrders(nonces);

        vm.prank(solver);
        (, bool[] memory success) = settlement.batchFill(orders, sigs, amounts, false);

        assertTrue(success[0], "0 filled");
        assertFalse(success[1], "1 skipped (cancelled)");
        assertTrue(success[2], "2 filled");
        assertEq(tA.balanceOf(solver), AMOUNT_IN * 2, "only two settled");
    }

    function test_batchFill_revertIfIncomplete_revertsOnUnfillable() public {
        (Order[] memory orders, bytes[] memory sigs, uint256[] memory amounts) = _batch(3);
        uint256[] memory nonces = new uint256[](1);
        nonces[0] = 1;
        vm.prank(maker);
        settlement.cancelOrders(nonces);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.BatchFillIncomplete.selector, 1));
        settlement.batchFill(orders, sigs, amounts, true);
    }

    function test_batchFill_revertIfIncomplete_revertsOnPartialShortfall() public {
        // Pre-fill order 0 halfway, then ask the batch for the FULL amount with
        // revertIfIncomplete → the fill overshoots remaining and reverts.
        (Order[] memory orders, bytes[] memory sigs, uint256[] memory amounts) = _batch(2);
        vm.prank(solver);
        settlement.fill(orders[0], sigs[0], AMOUNT_IN / 2);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.BatchFillIncomplete.selector, 0));
        settlement.batchFill(orders, sigs, amounts, true); // amounts[0] = full > remaining
    }

    function test_batchFill_revertIfIncomplete_happy() public {
        (Order[] memory orders, bytes[] memory sigs, uint256[] memory amounts) = _batch(3);
        vm.prank(solver);
        (, bool[] memory success) = settlement.batchFill(orders, sigs, amounts, true);
        assertTrue(success[0] && success[1] && success[2], "all filled, no revert");
    }

    function test_batchFill_selfCallGate() public {
        // fillSelf is onlySelf — external callers are rejected.
        Order memory o = _order(0);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(Base.OnlySelf.selector);
        settlement.fillSelf(o, sig, AMOUNT_IN, solver, "");
    }
}
