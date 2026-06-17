// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {LimitOrder} from "@core/settlement/LimitOrderSettlement.sol";
import {EulerV2ModulesBase} from "../shared/EulerV2ModulesBase.t.sol";

/// @dev Deposit WETH collateral + borrow USDC against it in one Euler order.
///   [0] MAKE EulerV2DepositModule  supply WETH into eWETH-2 (direct vault call)
///   [1] TAKE EulerV2BorrowModule   borrow USDC from eUSDC-2 (routed via the EVC)
contract EulerDepositBorrowTest is EulerV2ModulesBase {
    uint256 constant BORROW_OUT = 1_000e6; // comfortably under 84% LTV for 1 WETH

    function test_depositX_borrowY_eulerV2() public {
        uint256 collateralIn = 1 ether;
        uint256 borrowOut = BORROW_OUT;

        deal(WETH, solver, collateralIn);

        _approveDepositBorrowSide(collateralIn, borrowOut);
        _approveSolverSide(collateralIn, WETH);

        LimitOrder memory order = _buildDepositBorrowOrder(collateralIn, borrowOut);
        bytes memory sig = _sign(order);

        uint256 collatBefore = _wethCollateral(maker);
        uint256 debtBefore = _usdcDebt(maker);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, borrowOut);

        assertEq(paid, collateralIn, "solver paid 1 WETH of collateral");
        assertApproxEqAbs(_wethCollateral(maker) - collatBefore, collateralIn, 2, "maker collateral up ~1 WETH");
        assertApproxEqAbs(_usdcDebt(maker) - debtBefore, borrowOut, 2, "maker debt up ~borrowOut");

        // Solver spent WETH, received the USDC borrow proceeds.
        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver WETH spent");
        assertEq(IERC20(USDC).balanceOf(solver), borrowOut, "solver received USDC");

        // Nothing sits in the maker wallet, settlement, or modules.
        assertEq(IERC20(WETH).balanceOf(maker), 0, "maker WETH forwarded into deposit");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "maker USDC forwarded out via borrow");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(WETH).balanceOf(address(depositModule)), 0, "deposit module WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(borrowModule)), 0, "borrow module USDC drained");
    }
}
