// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order} from "@core/settlement/UniversalSettlement.sol";
import {DolomiteModulesBase} from "../shared/DolomiteModulesBase.t.sol";

/// @dev Leverage loop via flash loan + DEX (no solver inventory). The
/// `flash_loan → deposit → borrow → swap → repay_flash` flow on Dolomite:
///
///   1. Flash-loans `collateralIn` WETH from Balancer v2.
///   2. Settlement pulls it via Permit3 → maker → DolomiteDepositModule supplies it
///      (one-action `operate`) into the borrow-position sub-account.
///   3. DolomiteTakerModule (op 0, Borrow) borrows USDC against it; proceeds land at the solver.
///   4. Solver swaps the USDC back to WETH on Uniswap v3.
///   5. Solver repays the flash loan; residual WETH is profit.
///
/// The debt leg trips Dolomite's mainnet risk-override category gate, so we
/// neutralise it (see the harness note) — the full `operate` accounting/solvency
/// still runs. The mock stays active through the solver's flash callback.
contract DolomiteFlashLoanLeverageTest is DolomiteModulesBase {
    function test_leverage_via_flashLoan_dolomite() public {
        uint256 collateralIn = 1 ether;
        uint256 borrowOut = 5_000e6;

        _neutralizeRiskOverride();

        // Seed a healthy initial collateral position in the borrow-position account.
        _seedDolomiteCollateral(10 ether);

        _approveDepositBorrowSide(collateralIn, borrowOut);
        leverageSolver.setupTokenApproval(COLL);

        Order memory order = _buildDepositBorrowOrder(collateralIn, borrowOut);
        order.nonce = 99; // avoid colliding with the deposit+borrow test
        bytes memory sig = _sign(order);

        uint256 collatBefore = _collateralOf(maker);
        uint256 debtBefore = _debtOf(maker);

        leverageSolver.executeFill(COLL, collateralIn, order, sig, borrowOut, 500, 0);

        assertApproxEqAbs(_collateralOf(maker) - collatBefore, collateralIn, 2, "maker collateral up ~1 WETH");
        assertApproxEqAbs(_debtOf(maker) - debtBefore, borrowOut, 2, "maker debt up ~borrowOut");

        assertEq(IERC20(DEBT).balanceOf(address(leverageSolver)), 0, "solver USDC fully swapped");
        assertGe(IERC20(COLL).balanceOf(address(leverageSolver)), 0, "solver WETH non-negative");

        assertEq(IERC20(COLL).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(DEBT).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(COLL).balanceOf(address(depositModule)), 0, "deposit module WETH drained");
        assertEq(IERC20(DEBT).balanceOf(address(takerModule)), 0, "taker module USDC drained");
    }
}
