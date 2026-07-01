// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order} from "@core/settlement/UniversalSettlement.sol";

import {ISpokeV4} from "../../src/interfaces/IAaveV4.sol";
import {AaveV4ModulesBase} from "../shared/AaveV4ModulesBase.t.sol";

/// @dev Aave v4 deposit X + borrow Y in one order: maker deposits 1 WETH as
/// collateral and borrows USDC against it. The solver funds the WETH collateral
/// and receives the borrow proceeds in exchange.
///
///   tokenIn  = USDC   (maker gives — sourced from the borrow item)
///   tokenOut = WETH   (solver gives → forwarded into the deposit item)
///
/// Items:
///   [0] MAKE  AaveV4DepositModule   supply WETH via GiverPositionManager
///   [1] TAKE  AaveV4BorrowModule    borrow USDC via TakerPositionManager
contract DepositBorrowV4Test is AaveV4ModulesBase {
    function test_depositX_borrowY_aaveV4() public {
        uint256 collateralIn = 1 ether; //    maker receives + deposits
        uint256 borrowOut = 1_500e6; //        maker borrows → solver receives

        deal(WETH, solver, collateralIn);

        _approveMakerDepositBorrowSide(collateralIn, borrowOut);
        _approveSolverSide(collateralIn, WETH);

        Order memory order = _buildV4DepositBorrowOrder(collateralIn, borrowOut);
        bytes memory sig = _sign(order);

        uint256 suppliedBefore = ISpokeV4(MAIN_SPOKE).getUserSuppliedAssets(wethReserveId, maker);
        uint256 debtBefore = ISpokeV4(MAIN_SPOKE).getUserTotalDebt(usdcReserveId, maker);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, borrowOut)[0];

        assertEq(paid, collateralIn, "solver paid 1 WETH of collateral");

        // Maker: fresh ~1 WETH collateral and ~1500 USDC of debt on the spoke.
        assertApproxEqAbs(
            ISpokeV4(MAIN_SPOKE).getUserSuppliedAssets(wethReserveId, maker) - suppliedBefore,
            collateralIn,
            2,
            "maker collateral up"
        );
        assertApproxEqAbs(
            ISpokeV4(MAIN_SPOKE).getUserTotalDebt(usdcReserveId, maker) - debtBefore, borrowOut, 2, "maker debt up"
        );

        // Solver: spent WETH, received USDC.
        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver WETH spent");
        assertEq(IERC20(USDC).balanceOf(solver), borrowOut, "solver received USDC");

        // Wallet balances unchanged — neither leg's asset sat in the maker's EOA.
        assertEq(IERC20(WETH).balanceOf(maker), 0, "maker WETH forwarded into deposit");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "maker USDC forwarded out via borrow");

        // Settlement & modules end empty.
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(WETH).balanceOf(address(depositModule)), 0, "deposit module WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(borrowModule)), 0, "borrow module USDC drained");
    }
}
