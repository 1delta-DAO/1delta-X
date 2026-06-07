// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {LimitOrder, Item, ItemOp} from "@core/settlement/LimitOrderSettlement.sol";

import {Chains, Lenders} from "@coretest/data/LenderRegistry.sol";
import {IAaveCreditDelegation} from "../shared/Modules.sol";
import {AaveModulesBase} from "../shared/AaveModulesBase.t.sol";

/// @dev Deposit X + borrow Y in one order: maker deposits 1 WETH as collateral
/// and borrows USDC against it. The solver funds the WETH collateral and
/// receives the borrow proceeds in exchange. (No swap of the borrowed asset back
/// into collateral — this is deposit+borrow, not a levered position; see
/// FlashLoanLeverage for the levered variant.)
///
///   tokenIn  = USDC   (maker gives — sourced from the borrow item)
///   tokenOut = WETH   (solver gives → forwarded into the deposit item)
///
/// Items:
///   [0] MAKE  AaveV3DepositModule   supply WETH
///   [1] TAKE  AaveV3BorrowModule    borrow USDC (variable rate)
contract DepositBorrowTest is AaveModulesBase {
    // ──────────────────── Direct fill ────────────────────

    function test_depositX_borrowY_aaveV3() public {
        uint256 collateralIn = 1 ether; //    maker receives + deposits
        uint256 borrowOut = 1_500e6; //        maker borrows → solver receives

        address usdcDebtToken = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][USDC].debt;

        deal(WETH, solver, collateralIn);

        _approveMakerDepositBorrowSide(collateralIn, borrowOut, usdcDebtToken);
        _approveSolverSide(collateralIn, WETH);

        LimitOrder memory order = _buildDepositBorrowOrder(collateralIn, borrowOut);
        bytes memory sig = _sign(order);

        uint256 makerAWethBefore = IERC20(aWETH).balanceOf(maker);
        uint256 makerDebtBefore = IERC20(usdcDebtToken).balanceOf(maker);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, borrowOut);

        assertEq(paid, collateralIn, "solver paid 1 WETH of collateral");

        // Maker: has a fresh ~1 aWETH collateral position and ~1500 USDC of debt.
        assertApproxEqAbs(IERC20(aWETH).balanceOf(maker) - makerAWethBefore, collateralIn, 2, "maker aWETH up");
        assertApproxEqAbs(IERC20(usdcDebtToken).balanceOf(maker) - makerDebtBefore, borrowOut, 2, "maker debt up");

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

    // ──────────────────── Single-signature permit fill ────────────────────

    function test_permit_deposit_and_borrow() public {
        uint256 collateralIn = 1 ether;
        uint256 borrowOut = 1_500e6;

        address usdcDebtToken = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][USDC].debt;

        deal(WETH, solver, collateralIn);

        // Credit delegation: Aave-native, separate from Permit3.
        vm.prank(maker);
        IAaveCreditDelegation(usdcDebtToken).approveDelegation(address(borrowModule), type(uint256).max);

        bytes memory borrowData = abi.encode(AAVE_POOL, USDC, uint256(2));

        Item[] memory items = new Item[](2);
        items[0] = Item(ItemOp.MAKE, address(depositModule), collateralIn, address(0), abi.encode(AAVE_POOL, WETH));
        items[1] = Item(ItemOp.TAKE, address(borrowModule), borrowOut, address(0), borrowData);

        LimitOrder memory order = _order(maker, 2, USDC, WETH, borrowOut, collateralIn, items);

        IPermit3.TokenPermit[] memory tp = new IPermit3.TokenPermit[](2);
        tp[0] = IPermit3.TokenPermit(address(settlement), USDC, uint160(borrowOut), uint48(order.deadline));
        tp[1] = IPermit3.TokenPermit(address(depositModule), WETH, uint160(collateralIn), uint48(order.deadline));

        IPermit3.PermitBatch memory batch =
            _buildBatch(tp, _takerPermits1(address(borrowModule), keccak256(borrowData), borrowOut), 1, order.deadline);

        bytes memory sig = _signPermitWitness(batch, _hashOrder(order));

        vm.prank(solver);
        settlement.fillWithPermit(order, batch, sig, borrowOut);

        assertApproxEqAbs(IERC20(aWETH).balanceOf(maker), collateralIn, 2, "maker aWETH up");
        assertApproxEqAbs(IERC20(usdcDebtToken).balanceOf(maker), borrowOut, 2, "maker debt up");
        assertEq(IERC20(USDC).balanceOf(solver), borrowOut, "solver received borrow proceeds");
    }
}
