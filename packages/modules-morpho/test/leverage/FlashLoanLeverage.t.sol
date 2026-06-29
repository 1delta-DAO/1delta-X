// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {LimitOrder} from "@core/settlement/LimitOrderSettlement.sol";
import {MorphoModulesBase} from "../shared/MorphoModulesBase.t.sol";

/// @dev Leverage loop via flash loan + DEX (no solver inventory). The
/// `flash_loan → supply → borrow → swap → repay_flash` flow on Morpho Blue:
///
///   1. Flash-loans `collateralIn` wstETH from Balancer v2.
///   2. Settlement pulls it via Permit3 → maker → MorphoBlueSupplyCollateralModule
///      supplies it as collateral on the wstETH/USDC market.
///   3. MorphoBlueTakerModule (op=Borrow) borrows USDC against it; proceeds land at the solver.
///   4. Solver swaps the USDC back to wstETH on Uniswap v3 (USDC/wstETH 0.05% pool).
///   5. Solver repays the flash loan; residual wstETH is profit.
contract MorphoFlashLoanLeverageTest is MorphoModulesBase {
    function test_leverage_via_flashLoan_morpho() public {
        uint256 collateralIn = 1 ether; // 1 wstETH
        uint256 borrowOut = 5_000e6; //    big enough that USDC→wstETH covers the flash

        // Seed a healthy initial collateral position so the +1 wstETH supply + borrow
        // stays under the market's 86% LLTV.
        _seedCollateral(10 ether);

        _approveMakerSupplyBorrowSide(collateralIn, borrowOut);
        leverageSolver.setupTokenApproval(WSTETH);

        LimitOrder memory order = _buildSupplyBorrowOrder(collateralIn, borrowOut);
        order.nonce = 99; // avoid colliding with the supply+borrow test
        bytes memory sig = _sign(order);

        uint256 collatBefore = _collateral(maker);
        uint256 debtBefore = _borrowAssets(maker);

        leverageSolver.executeFill(WSTETH, collateralIn, order, sig, borrowOut, 500, 0);

        assertApproxEqAbs(_collateral(maker) - collatBefore, collateralIn, 2, "maker collateral up ~1 wstETH");
        assertApproxEqAbs(_borrowAssets(maker) - debtBefore, borrowOut, 2, "maker debt up ~borrowOut");

        assertEq(IERC20(USDC).balanceOf(address(leverageSolver)), 0, "solver USDC fully swapped");
        assertGe(IERC20(WSTETH).balanceOf(address(leverageSolver)), 0, "solver wstETH non-negative");

        assertEq(IERC20(WSTETH).balanceOf(address(settlement)), 0, "settlement wstETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(WSTETH).balanceOf(address(supplyModule)), 0, "supply module wstETH drained");
        assertEq(IERC20(USDC).balanceOf(address(takerModule)), 0, "taker module USDC drained");
    }
}
