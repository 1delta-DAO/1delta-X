// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {LimitOrder} from "@core/settlement/LimitOrderSettlement.sol";

import {ISpokeV4} from "../../src/interfaces/IAaveV4.sol";
import {AaveV4ModulesBase} from "../shared/AaveV4ModulesBase.t.sol";

/// @dev Leverage loop via flash loan + DEX (no solver inventory). The
/// `flash_loan → deposit → borrow → swap → repay_flash` flow on Aave v4:
///
///   1. Flash-loans `collateralIn` WETH from Balancer v2.
///   2. Settlement pulls it via Permit3 → maker → AaveV4DepositModule supplies it
///      as collateral via the GiverPositionManager.
///   3. AaveV4BorrowModule borrows USDC via the TakerPositionManager; proceeds land
///      at the solver.
///   4. Solver swaps the USDC back to WETH on Uniswap v3.
///   5. Solver repays the flash loan; residual WETH is profit.
contract FlashLoanLeverageV4Test is AaveV4ModulesBase {
    function test_leverage_via_flashLoan_aaveV4() public {
        uint256 collateralIn = 1 ether;
        uint256 borrowOut = 5_000e6; // big enough that USDC→WETH covers the 1 WETH flash

        // Seed a healthy initial collateral position so the +1 WETH deposit + borrow
        // stays under the spoke's collateral factor.
        _seedV4WethPosition(10 ether);

        _approveMakerDepositBorrowSide(collateralIn, borrowOut);
        leverageSolver.setupTokenApproval(WETH);

        LimitOrder memory order = _buildV4DepositBorrowOrder(collateralIn, borrowOut);
        order.nonce = 99; // avoid colliding with the deposit+borrow test
        bytes memory sig = _sign(order);

        uint256 suppliedBefore = ISpokeV4(MAIN_SPOKE).getUserSuppliedAssets(wethReserveId, maker);
        uint256 debtBefore = ISpokeV4(MAIN_SPOKE).getUserTotalDebt(usdcReserveId, maker);

        leverageSolver.executeFill(WETH, collateralIn, order, sig, borrowOut, 500, 0);

        assertApproxEqAbs(
            ISpokeV4(MAIN_SPOKE).getUserSuppliedAssets(wethReserveId, maker) - suppliedBefore,
            collateralIn,
            2,
            "maker collateral up ~1 WETH"
        );
        assertApproxEqAbs(
            ISpokeV4(MAIN_SPOKE).getUserTotalDebt(usdcReserveId, maker) - debtBefore, borrowOut, 2, "maker debt up"
        );

        assertEq(IERC20(USDC).balanceOf(address(leverageSolver)), 0, "solver USDC fully swapped");
        assertGe(IERC20(WETH).balanceOf(address(leverageSolver)), 0, "solver WETH non-negative");

        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(WETH).balanceOf(address(depositModule)), 0, "deposit module WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(borrowModule)), 0, "borrow module USDC drained");
    }
}
