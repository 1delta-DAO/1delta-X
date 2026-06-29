// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {LimitOrder} from "@core/settlement/LimitOrderSettlement.sol";
import {EulerV2ModulesBase} from "../shared/EulerV2ModulesBase.t.sol";

/// @dev Leverage loop via flash loan + DEX (no solver inventory). The
/// `flash_loan → deposit → borrow → swap → repay_flash` flow: the
/// LimitOrderLeverageSolver
///
///   1. Flash-loans `collateralIn` WETH from Balancer v2.
///   2. Settlement pulls it via Permit3 → maker → EulerV2DepositModule supplies it
///      into eWETH-2 as collateral.
///   3. EulerV2TakerModule (Borrow) borrows USDC from eUSDC-2 (via the EVC); proceeds
///      land at the solver.
///   4. Solver swaps the USDC back to WETH on Uniswap v3.
///   5. Solver repays the flash loan; residual WETH is profit.
///
/// The maker's order is identical in shape to the plain deposit+borrow test —
/// leverage lives entirely in how the solver sources the tokenOut inventory.
contract EulerFlashLoanLeverageTest is EulerV2ModulesBase {
    function test_leverage_via_flashLoan_eulerV2() public {
        uint256 collateralIn = 1 ether; // deposit leg (flash-loaned by solver)
        uint256 borrowOut = 5_000e6; //   borrow leg — big enough that the USDC→WETH
        //                                swap covers the 1 WETH flash repayment.

        // Seed a healthy initial collateral position so the +1 WETH deposit + borrow
        // stays under the eUSDC-2 collateral factor for eWETH-2.
        _seedEulerCollateral(10 ether);

        _approveDepositBorrowSide(collateralIn, borrowOut);
        leverageSolver.setupTokenApproval(WETH);

        LimitOrder memory order = _buildDepositBorrowOrder(collateralIn, borrowOut);
        order.nonce = 99; // avoid colliding with the deposit+borrow test
        bytes memory sig = _sign(order);

        uint256 collatBefore = _wethCollateral(maker);
        uint256 debtBefore = _usdcDebt(maker);

        // Anyone can call — no operator gate on the solver.
        leverageSolver.executeFill(WETH, collateralIn, order, sig, borrowOut, 500, 0);

        assertApproxEqAbs(_wethCollateral(maker) - collatBefore, collateralIn, 1e12, "maker collateral up ~1 WETH");
        assertApproxEqAbs(_usdcDebt(maker) - debtBefore, borrowOut, 2, "maker debt up ~borrowOut");

        // Solver swapped all USDC; any WETH left is profit (non-negative).
        assertEq(IERC20(USDC).balanceOf(address(leverageSolver)), 0, "solver USDC fully swapped");
        assertGe(IERC20(WETH).balanceOf(address(leverageSolver)), 0, "solver WETH non-negative");

        // Nothing stuck in settlement or modules.
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(WETH).balanceOf(address(depositModule)), 0, "deposit module WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(takerModule)), 0, "taker module USDC drained");
    }
}
