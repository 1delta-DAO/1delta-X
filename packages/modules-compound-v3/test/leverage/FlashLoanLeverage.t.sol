// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {LimitOrder} from "@core/settlement/LimitOrderSettlement.sol";

import {CompoundV3ModulesBase} from "../shared/CompoundV3ModulesBase.t.sol";

/// @dev Leverage via flash loan + DEX (no inventory). Same maker intent as
/// DepositBorrow, but the solver owns zero WETH and zero USDC. The
/// LimitOrderLeverageSolver:
///
///   1. Flash-loans `collateralIn` WETH from Balancer v2.
///   2. Settlement pulls that WETH via Permit3 → maker → deposit module supplies
///      it as collateral on the USDC Comet.
///   3. Borrow module withdraws maker's USDC base (a borrow); proceeds land at
///      the solver.
///   4. Solver swaps the USDC back to WETH on Uniswap v3.
///   5. Solver repays the flash loan. Residual WETH is profit.
///
/// The maker's order is *identical* in shape to the deposit+borrow test —
/// nothing on-chain distinguishes leverage from plain deposit+borrow. The
/// difference lives entirely in how the solver sources the tokenOut inventory.
contract FlashLoanLeverageTest is CompoundV3ModulesBase {
    function test_leverage_via_flashLoan_cometV3() public {
        uint256 collateralIn = 1 ether; //     deposit leg (flash-loaned by solver)
        uint256 borrowOut = 5_000e6; //         borrow leg — sized so the 5000 USDC swap
        //                                      covers 1 WETH repayment at any ETH price
        //                                      ≲ $5000 (with some slippage margin).

        // Seed maker with a healthy initial collateral position so the +1 WETH
        // deposit + borrow doesn't breach the collateral factor.
        _seedWethCollateral(10 ether);

        // Register maker-side authorisations.
        _approveMakerDepositBorrowSide(collateralIn, borrowOut);

        // Solver-side: register ERC20 + Permit3 allowance for WETH.
        //   (The solver's WETH originates from the flash loan inside executeFill,
        //    so it's present exactly during the Settlement pull.)
        leverageSolver.setupTokenApproval(WETH);

        // Build the order — same schema as deposit+borrow.
        LimitOrder memory order = _buildDepositBorrowOrder(collateralIn, borrowOut);
        // Bump nonce so it doesn't collide with the deposit+borrow test's nonce 2.
        order.nonce = 99;
        bytes memory sig = _sign(order);

        uint256 makerCollatBefore = _wethCollateral(maker);
        uint256 makerDebtBefore = _usdcDebt(maker);

        // Anyone can call — no operator gate.
        leverageSolver.executeFill(
            WETH,
            collateralIn,
            order,
            sig,
            borrowOut,
            500, //                         Uniswap V3 0.05% pool (USDC/WETH)
            0 //                            minSwapOut — permissive for this reference test
        );

        // Maker: +1 WETH collateral, +borrowOut USDC debt.
        assertApproxEqAbs(_wethCollateral(maker) - makerCollatBefore, collateralIn, 2, "maker collateral up");
        assertApproxEqAbs(_usdcDebt(maker) - makerDebtBefore, borrowOut, 2, "maker debt up");

        // Solver holds no USDC post-swap; any WETH is profit (non-negative).
        assertEq(IERC20(USDC).balanceOf(address(leverageSolver)), 0, "solver USDC fully swapped");
        assertGe(IERC20(WETH).balanceOf(address(leverageSolver)), 0, "solver WETH non-negative");

        // Nothing stuck anywhere else.
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(WETH).balanceOf(address(depositModule)), 0, "deposit module WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(takerModule)), 0, "taker module USDC drained");
    }
}
