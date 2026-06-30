// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order} from "@core/settlement/UniversalSettlement.sol";

import {ISpokeV4} from "../../src/interfaces/IAaveV4.sol";
import {AaveV4ModulesBase} from "../shared/AaveV4ModulesBase.t.sol";

/// @dev Aave v4 repay with over-repay dust refund: maker has an open USDC debt
/// and signs a repay amount that intentionally over-shoots (`currentDebt +
/// buffer`) so the repay lands fully no matter what interest accrues between
/// signing and fill. The module sweeps the unused portion back to the maker.
///
///   tokenIn  = WETH  (maker gives — pays solver)
///   tokenOut = USDC  (solver gives — funds the repay leg)
///
/// Items:
///   [0] MAKE  AaveV4RepayModule   repay up to `bufferedAmount` USDC via GiverPM
contract RepayV4Test is AaveV4ModulesBase {
    function test_repay_with_dust_refund_aaveV4() public {
        uint256 debtAmount = 3_000e6;
        uint256 buffer = 50e6; //              over-repay buffer for accrual
        uint256 bufferedAmount = debtAmount + buffer;
        uint256 wethForSolver = 1 ether;

        _openV4UsdcDebt(debtAmount);

        // Fund solver side.
        deal(USDC, solver, bufferedAmount);

        _approveMakerRepaySide(bufferedAmount, wethForSolver);
        _approveSolverSide(bufferedAmount, USDC);

        // Record pre-state.
        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);
        uint256 makerWethBefore = IERC20(WETH).balanceOf(maker);
        uint256 makerDebtBefore = ISpokeV4(MAIN_SPOKE).getUserTotalDebt(usdcReserveId, maker);
        assertGt(makerDebtBefore, 0, "pre: maker should have debt");

        Order memory order = _buildV4RepayOrder(bufferedAmount, wethForSolver);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, wethForSolver);

        assertEq(paid, bufferedAmount, "solver paid buffered USDC");

        // Debt fully closed.
        assertEq(ISpokeV4(MAIN_SPOKE).getUserTotalDebt(usdcReserveId, maker), 0, "debt zeroed");

        // Dust refunded to maker.
        uint256 actualRepaid = makerDebtBefore; //                 ≈ debtAmount + tiny accrual
        uint256 expectedDust = bufferedAmount - actualRepaid;
        uint256 makerUsdcDelta = IERC20(USDC).balanceOf(maker) - makerUsdcBefore;
        assertApproxEqAbs(makerUsdcDelta, expectedDust, 1e6, "dust refunded to maker");
        assertGt(makerUsdcDelta, 0, "some dust exists given the buffer");

        // Solver spent USDC, gained WETH.
        assertEq(IERC20(USDC).balanceOf(solver), 0, "solver USDC spent");
        assertEq(IERC20(WETH).balanceOf(solver), wethForSolver, "solver received WETH");
        assertEq(IERC20(WETH).balanceOf(maker), makerWethBefore - wethForSolver, "maker WETH spent");

        // Module holds nothing — residual was swept, dust returned to maker.
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "repay module USDC drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
    }
}
