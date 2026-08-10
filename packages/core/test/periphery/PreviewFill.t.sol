// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OrderGates} from "@core/settlement/OrderGates.sol";
import {PackedEncode} from "../shared/PackedEncode.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {SettlementLens} from "@core/periphery/SettlementLens.sol";
import {Order, LegIn, OrderSide} from "@core/settlement/Settlement.sol";

import {MockSettlementBase, MockERC20} from "../shared/MockSettlementBase.t.sol";

/// @title PreviewFill
/// @notice `SettlementLens.previewFill` must equal `Settlement.fillUpTo` executed
///         in the same block — the aggregator quote guarantee — including the
///         clamp, the auction tick, and the exclusivity gate. Plus the
///         `_makerFillableCap` direct-allowance fix: a maker funding fills through
///         a plain ERC20 approval (the {Permit3TransferLib} fallback) must preview
///         as fillable, not zero.
contract PreviewFillTest is MockSettlementBase {
    uint256 constant IN_ = 1_000e18;
    uint256 constant OUT_ = 2e18;

    function _fund(uint256 makerIn, uint256 solverOut) internal {
        tA.mint(maker, makerIn);
        tB.mint(solver, solverOut);
        _makerApprove(address(settlement), address(tA), makerIn);
        _solverApprove(address(settlement), address(tB), solverOut);
    }

    /// @dev Quote then execute in the same block: the triple must match exactly,
    ///      on a decaying order mid-auction with a pre-fill in place.
    function test_previewFill_equalsExecution_midDecay() public {
        _fund(IN_, 2 * OUT_);
        Order memory order = _plainOrder(1, address(tA), address(tB), IN_, OUT_);
        order.legsOut = PackedEncode.setLegOutEnd(order.legsOut, 0, OUT_ / 2); // SELL output decays 2 → 1
        _setDecayStart(order, block.timestamp);
        _setDecayDuration(order, 1000);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, IN_ / 4); // competing pre-fill

        vm.warp(block.timestamp + 300); // mid-auction

        (uint256 pDelta, uint256[] memory pReceived, uint256[] memory pPaid) = lens.previewFill(order, IN_, solver, "");

        vm.prank(solver);
        (uint256 delta, uint256[] memory received, uint256[] memory paid) =
            settlement.fillUpTo(order, sig, IN_, address(0), "");

        assertEq(pDelta, delta, "delta");
        assertEq(pReceived[0], received[0], "received");
        assertEq(pPaid[0], paid[0], "paid");
        assertEq(pDelta, IN_ - IN_ / 4, "and the preview already clamped to remaining");
    }

    function test_previewFill_hardExclusivity_revertsForOutsider() public {
        Order memory order = _plainOrder(2, address(tA), address(tB), IN_, OUT_);
        order.exclusiveFiller = address(0xE0);
        _setExclusivityEnd(order, block.timestamp + 1 hours);

        vm.expectRevert(OrderGates.NotExclusiveFiller.selector);
        lens.previewFill(order, IN_, solver, "");
    }

    function test_previewFill_cancelled_reverts() public {
        Order memory order = _plainOrder(3, address(tA), address(tB), IN_, OUT_);
        vm.prank(maker);
        settlement.cancelOrder(order);

        vm.expectRevert(SettlementLens.OrderCancelled.selector);
        lens.previewFill(order, 1, solver, "");
    }

    /// @dev The `_makerFillableCap` fix: a maker with NO Permit3 allowance but a
    ///      direct ERC20 approval to the settlement (the transfer-fallback path)
    ///      must preview its full remaining size — before the fix this reported 0.
    function test_relevantState_makerCap_countsDirectAllowance() public {
        tA.mint(maker, IN_);
        vm.prank(maker);
        tA.approve(address(settlement), IN_); // direct approval ONLY — no Permit3

        Order memory order = _plainOrder(4, address(tA), address(tB), IN_, OUT_);
        bytes memory sig = _sign(order);

        (SettlementLens.OrderStatus status, uint256 fillable, bool sigOk,) =
            lens.getOrderRelevantState(order, sig, solver, "");

        assertEq(uint8(status), uint8(SettlementLens.OrderStatus.Fillable), "fillable status");
        assertTrue(sigOk, "signature valid");
        assertEq(fillable, IN_, "direct allowance counts as live capacity");
    }

    /// @dev Balance still caps below the allowance, whichever book granted it.
    function test_relevantState_makerCap_balanceStillBinds() public {
        tA.mint(maker, IN_ / 2);
        vm.prank(maker);
        tA.approve(address(settlement), type(uint256).max);

        Order memory order = _plainOrder(5, address(tA), address(tB), IN_, OUT_);
        (, uint256 fillable,,) = lens.getOrderRelevantState(order, _sign(order), solver, "");
        assertEq(fillable, IN_ / 2, "balance-bound");
    }
}
