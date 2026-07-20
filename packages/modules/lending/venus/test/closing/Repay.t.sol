// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {DustHandler} from "@core/dust/DustHandler.sol";

import {VenusModulesBase} from "../shared/VenusModulesBase.t.sol";

/// @dev Repay with over-repay dust refund: the maker has an open USDC borrow on
/// Venus and signs a repay amount that intentionally over-shoots
/// (`currentDebt + buffer`) so the repay lands fully regardless of accrual
/// between signing and fill. The module reads the live debt, repays exactly
/// `min(amount, debt)` via `repayBorrowBehalf`, and never pulls the unused buffer
/// (SweepToUser) — so no surplus is left for a caller to redirect.
///
///   tokenIn  = WETH  (maker gives — pays solver)
///   tokenOut = USDC  (solver gives — funds the repay leg)
///   [0] MAKE VenusRepayModule  repay up to `buffered` USDC
contract VenusRepayTest is VenusModulesBase {
    function test_repay_with_dust_refund_venus() public {
        uint256 debtAmount = 1_000e6;
        uint256 buffer = 50e6; //               over-repay buffer for accrual
        uint256 buffered = debtAmount + buffer;
        uint256 wethForSolver = 0.1 ether;

        _openVenusPosition(1 ether, debtAmount);

        deal(WETH, maker, wethForSolver); // maker's tokenIn leg to the solver
        deal(USDC, solver, buffered); //      solver funds the repay

        vm.startPrank(maker);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(repayModule), USDC, uint160(buffered), 0);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), WETH, uint160(wethForSolver), 0);
        vm.stopPrank();
        _approveSolverSide(buffered, USDC);

        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);
        uint256 makerDebtBefore = _usdcDebt(maker);
        assertGt(makerDebtBefore, 0, "pre: maker should have debt");

        // data = abi.encode(vUSDC, USDC), 64 bytes ⇒ SweepToUser. (The repay maker
        // takes bare market data — not the op-prefixed taker encoding.)
        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.MAKE, address(repayModule), buffered, address(0), abi.encode(address(VUSDC), USDC));
        Order memory order = _order(maker, 1, WETH, USDC, wethForSolver, buffered, items);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, wethForSolver)[0];
        assertEq(paid, buffered, "solver paid buffered USDC");

        // Debt fully closed (Compound rounding tolerated).
        assertApproxEqAbs(_usdcDebt(maker), 0, 2, "debt zeroed");

        // The unused buffer was never pulled — it stays in the solver-funded flow
        // and is refunded to the maker (SweepToUser), not parked in the module.
        uint256 makerUsdcDelta = IERC20(USDC).balanceOf(maker) - makerUsdcBefore;
        uint256 expectedDust = buffered - makerDebtBefore;
        assertApproxEqAbs(makerUsdcDelta, expectedDust, 1e6, "dust refunded to maker");
        assertGt(makerUsdcDelta, 0, "some dust exists given the buffer");

        // Solver spent USDC, gained WETH.
        assertEq(IERC20(USDC).balanceOf(solver), 0, "solver USDC spent");
        assertEq(IERC20(WETH).balanceOf(solver), wethForSolver, "solver received WETH");

        // Module + settlement end empty.
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "repay module USDC drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
    }

    /// @dev Same over-repay setup, but the maker-signed `data` opts into
    /// `DustAction.Recycle`: the surplus is re-minted into the maker's Venus
    /// position as vUSDC collateral (best-effort, sweep fallback) instead of
    /// landing in the wallet.
    function test_repay_with_dust_recycle_venus() public {
        uint256 debtAmount = 1_000e6;
        uint256 buffer = 50e6;
        uint256 buffered = debtAmount + buffer;
        uint256 wethForSolver = 0.1 ether;

        _openVenusPosition(1 ether, debtAmount);

        deal(WETH, maker, wethForSolver);
        deal(USDC, solver, buffered);

        vm.startPrank(maker);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(repayModule), USDC, uint160(buffered), 0);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), WETH, uint160(wethForSolver), 0);
        vm.stopPrank();
        _approveSolverSide(buffered, USDC);

        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);
        uint256 vUsdcBefore = VUSDC.balanceOf(maker);

        Item[] memory items = new Item[](1);
        items[0] = Item(
            ItemOp.MAKE,
            address(repayModule),
            buffered,
            address(0),
            abi.encode(address(VUSDC), USDC, uint8(DustHandler.DustAction.Recycle))
        );
        Order memory order = _order(maker, 1, WETH, USDC, wethForSolver, buffered, items);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, wethForSolver);

        assertApproxEqAbs(_usdcDebt(maker), 0, 2, "debt zeroed");

        // Surplus recycled into the position (vUSDC collateral up), wallet unchanged.
        assertApproxEqAbs(IERC20(USDC).balanceOf(maker), makerUsdcBefore, 2, "wallet unchanged (no sweep)");
        assertGt(VUSDC.balanceOf(maker), vUsdcBefore, "dust recycled as vUSDC collateral");

        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "repay module USDC drained");
    }
}
