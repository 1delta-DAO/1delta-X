// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {DustHandler} from "@core/dust/DustHandler.sol";

import {CompoundV2ModulesBase} from "../shared/CompoundV2ModulesBase.t.sol";

/// @dev Repay with over-repay dust refund: the maker has an open DAI borrow and
/// signs a repay that over-shoots (`debt + buffer`) so it lands fully regardless
/// of accrual. The module reads the live debt and repays exactly `min(amount, debt)`
/// via `repayBorrowBehalf`, never pulling the unused buffer (SweepToUser).
///
///   tokenIn  = USDC  (maker gives — pays solver)
///   tokenOut = DAI   (solver gives — funds the repay leg)
///   [0] MAKE CompoundV2RepayModule  repay up to `buffered` DAI
contract CompoundV2RepayTest is CompoundV2ModulesBase {
    function test_repay_with_dust_refund_compoundV2() public {
        uint256 debtAmount = 200e18;
        uint256 buffer = 5e18; //              over-repay buffer
        uint256 buffered = debtAmount + buffer;
        uint256 usdcForSolver = 210e6;

        _openDaiDebt(2_000e6, debtAmount);

        deal(USDC, maker, usdcForSolver); // maker's tokenIn leg to the solver
        deal(DAI, solver, buffered); //       solver funds the repay

        vm.startPrank(maker);
        IERC20(DAI).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(repayModule), DAI, uint160(buffered), 0);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDC, uint160(usdcForSolver), 0);
        vm.stopPrank();
        _approveSolverSide(buffered, DAI);

        uint256 makerDaiBefore = IERC20(DAI).balanceOf(maker);
        uint256 makerDebtBefore = _daiDebt(maker);
        assertGt(makerDebtBefore, 0, "pre: maker should have debt");

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.MAKE, address(repayModule), buffered, address(0), _repayDaiData());
        Order memory order = _order(maker, 1, USDC, DAI, usdcForSolver, buffered, items);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, usdcForSolver)[0];
        assertEq(paid, buffered, "solver paid buffered DAI");

        // Debt fully closed.
        assertApproxEqAbs(_daiDebt(maker), 0, 1e12, "debt zeroed");

        // The unused buffer was refunded to the maker (SweepToUser), not parked.
        uint256 makerDaiDelta = IERC20(DAI).balanceOf(maker) - makerDaiBefore;
        uint256 expectedDust = buffered - makerDebtBefore;
        assertApproxEqAbs(makerDaiDelta, expectedDust, 1e16, "dust refunded to maker");
        assertGt(makerDaiDelta, 0, "some dust exists given the buffer");

        // Solver spent DAI, gained USDC.
        assertEq(IERC20(DAI).balanceOf(solver), 0, "solver DAI spent");
        assertEq(IERC20(USDC).balanceOf(solver), usdcForSolver, "solver received USDC");

        // Module + settlement end empty.
        assertEq(IERC20(DAI).balanceOf(address(repayModule)), 0, "repay module DAI drained");
        assertEq(IERC20(DAI).balanceOf(address(settlement)), 0, "settlement DAI drained");
    }

    /// @dev Same over-repay setup, but `data` opts into `DustAction.Recycle`: the
    /// surplus is re-minted into the maker's Compound position as cDAI collateral
    /// (mint-to-module then forward the receipt) instead of landing in the wallet.
    function test_repay_with_dust_recycle_compoundV2() public {
        uint256 debtAmount = 200e18;
        uint256 buffer = 5e18;
        uint256 buffered = debtAmount + buffer;
        uint256 usdcForSolver = 210e6;

        _openDaiDebt(2_000e6, debtAmount);

        deal(USDC, maker, usdcForSolver);
        deal(DAI, solver, buffered);

        vm.startPrank(maker);
        IERC20(DAI).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(repayModule), DAI, uint160(buffered), 0);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDC, uint160(usdcForSolver), 0);
        vm.stopPrank();
        _approveSolverSide(buffered, DAI);

        uint256 makerDaiBefore = IERC20(DAI).balanceOf(maker);
        uint256 cDaiBefore = CDAI.balanceOf(maker);

        Item[] memory items = new Item[](1);
        items[0] = Item(
            ItemOp.MAKE,
            address(repayModule),
            buffered,
            address(0),
            abi.encode(address(CDAI), DAI, uint8(DustHandler.DustAction.Recycle))
        );
        Order memory order = _order(maker, 1, USDC, DAI, usdcForSolver, buffered, items);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, usdcForSolver);

        assertApproxEqAbs(_daiDebt(maker), 0, 1e12, "debt zeroed");

        // Surplus recycled into the position (cDAI up), wallet unchanged.
        assertApproxEqAbs(IERC20(DAI).balanceOf(maker), makerDaiBefore, 1e12, "wallet unchanged (no sweep)");
        assertGt(CDAI.balanceOf(maker), cDaiBefore, "dust recycled as cDAI collateral");

        assertEq(IERC20(DAI).balanceOf(address(repayModule)), 0, "repay module DAI drained");
        assertEq(CDAI.balanceOf(address(repayModule)), 0, "repay module cDAI drained");
    }
}
