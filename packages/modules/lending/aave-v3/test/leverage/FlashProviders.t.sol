// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order} from "@core/settlement/Settlement.sol";
import {AaveV3FlashSolver} from "@solvers/single-input/AaveV3FlashSolver.sol";
import {EulerFlashSolver} from "@solvers/single-input/EulerFlashSolver.sol";
import {MorphoFlashSolver} from "@solvers/single-input/MorphoFlashSolver.sol";

import {AaveModulesBase} from "../shared/AaveModulesBase.t.sol";

/// @dev The whole leverage-fill solver family shares ONE entrypoint, so the test
///      body is provider-agnostic.
interface ILeverageFlashSolver {
    function setupTokenApproval(address token) external;
    function executeFill(
        address flashSource,
        uint256 flashAmount,
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmountIn,
        uint24 dexFee,
        uint256 minSwapOut
    ) external;
}

/// @dev The same WETH-collateral / USDC-debt leverage loop sourced from THREE
/// different flash-loan providers, proving the `BaseFlashSolver` family is
/// interchangeable "across the board". The maker intent and the Aave deposit/borrow
/// legs are identical to the Balancer `FlashLoanLeverage` test — only the solver
/// (and thus the flash source + repayment convention) changes:
///
///   • Aave v3   — `flashLoanSimple`, repay `amount + 0.05% premium` (approve-pull).
///   • Euler EVK — `flashLoan` from the eWETH vault, repay by transfer (fee-free).
///   • Morpho    — singleton `flashLoan`, repay by approve-pull (fee-free).
///
/// Euler flashes from its eWETH vault (NOT the Aave pool we deposit into), so the
/// flash source and the leverage target never share a reentrancy lock.
contract AaveFlashProvidersTest is AaveModulesBase {
    /// @dev Uniswap v3 SwapRouter (mainnet) — the repayment-swap venue.
    address constant UNI_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    /// @dev Morpho Blue singleton (mainnet).
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    /// @dev Euler eWETH-2 vault (mainnet) — a fee-free WETH flash source.
    address constant EULER_WETH_VAULT = 0xD8b27CF359b7D15710a5BE299AF6e7Bf904984C2;

    function test_leverage_via_aaveV3_flash() public {
        AaveV3FlashSolver solver = new AaveV3FlashSolver(address(permit3), address(settlement), AAVE_POOL, UNI_ROUTER);
        _runLeverageVia(address(solver), WETH); // Aave flashes the asset itself
    }

    function test_leverage_via_euler_flash() public {
        EulerFlashSolver solver = new EulerFlashSolver(address(permit3), address(settlement), UNI_ROUTER);
        _runLeverageVia(address(solver), EULER_WETH_VAULT); // Euler flashes from a vault
    }

    function test_leverage_via_morpho_flash() public {
        MorphoFlashSolver solver = new MorphoFlashSolver(address(permit3), address(settlement), MORPHO, UNI_ROUTER);
        _runLeverageVia(address(solver), WETH); // Morpho flashes the asset itself
    }

    /// @dev Provider-agnostic leverage loop: flash 1 WETH, supply it as the maker's
    ///      Aave collateral, borrow 5k USDC, swap back to WETH, repay the flash.
    function _runLeverageVia(address solver, address flashSource) internal {
        uint256 collateralIn = 1 ether;
        uint256 borrowOut = 5_000e6; // covers 1 WETH + any premium at ETH ≲ $5k

        _seedAWethPosition(10 ether);
        _approveMakerDepositBorrowSide(collateralIn, borrowOut);
        ILeverageFlashSolver(solver).setupTokenApproval(WETH);

        Order memory order = _buildDepositBorrowOrder(collateralIn, borrowOut);
        order.nonce = 99;
        bytes memory sig = _sign(order);

        uint256 makerAWethBefore = IERC20(aWETH).balanceOf(maker);
        uint256 makerDebtBefore = IERC20(usdcDebtToken).balanceOf(maker);

        ILeverageFlashSolver(solver).executeFill(flashSource, collateralIn, order, sig, borrowOut, 500, 0);

        // Collateral up ~1 WETH. Tolerance absorbs aToken interest accrual: an Aave
        // flash bumps the WETH reserve's liquidity index, crediting a few gwei to
        // the existing collateral (the off-Aave providers leave it exact).
        assertApproxEqAbs(IERC20(aWETH).balanceOf(maker) - makerAWethBefore, collateralIn, 1e13, "maker aWETH up ~1 WETH");
        assertApproxEqAbs(IERC20(usdcDebtToken).balanceOf(maker) - makerDebtBefore, borrowOut, 2, "maker debt up");

        // Solver ends with no USDC (all swapped) and the flash repaid; WETH is profit.
        assertEq(IERC20(USDC).balanceOf(solver), 0, "solver USDC fully swapped");
        assertGe(IERC20(WETH).balanceOf(solver), 0, "solver WETH non-negative");
    }
}
