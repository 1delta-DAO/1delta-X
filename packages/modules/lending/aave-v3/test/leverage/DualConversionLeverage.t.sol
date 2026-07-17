// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, OrderSide, Item, ItemOp, Validator} from "@core/settlement/UniversalSettlement.sol";

import {IAaveCreditDelegation} from "../../src/interfaces/IAaveV3.sol";
import {AaveModulesBase} from "../shared/AaveModulesBase.t.sol";

/// @dev "Dual conversion + leverage in one go." A single fill both:
///
///   (a) swaps the maker's DAI equity into WETH collateral and deposits it
///       (swap-to-deposit), and
///   (b) opens a levered position — deposits the collateral and borrows USDC
///       against it (deposit + borrow).
///
/// This is only expressible with a MULTI-INPUT order: the solver receives two
/// inputs — the borrow proceeds (USDC) and the maker's equity (DAI) — in
/// exchange for the WETH collateral it fronts. amountIn[0] (the USDC borrow) is
/// the fill denominator.
///
///   tokenIn  = [USDC, DAI]   USDC = borrow proceeds → solver (amountIn[0])
///                            DAI  = maker equity     → solver (amountIn[1])
///   tokenOut = [WETH]        solver → maker → deposited as collateral
///   items:
///     [0] MAKE  AaveV3DepositModule   supply WETH  (funded by the delivered WETH)
///     [1] TAKE  AaveV3BorrowModule    borrow USDC  (proceeds → Settlement → solver)
///
/// Note on solvers: the shipped LimitOrderLeverageSolver rejects multi-input
/// orders (`order.tokenIn.length != 1`), because its flash→swap→repay core only
/// swaps a single debt leg. So this reference exercises the combined intent as a
/// direct solver fill with inventory — the same convention as DepositBorrow's
/// direct-fill test. A flash variant would need a multi-input-capable solver.
contract DualConversionLeverageTest is AaveModulesBase {
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    function _a2(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        r[0] = a;
        r[1] = b;
    }

    function _u2(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }

    function test_dualConversion_swapToDeposit_plusLeverage_aaveV3() public {
        uint256 collateralIn = 1 ether; //   WETH the solver fronts → deposited
        uint256 borrowOut = 1_500e6; //       USDC borrowed → solver (amountIn[0])
        uint256 equityIn = 1_500e18; //       DAI equity the maker contributes → solver

        // Healthy base position so +1 WETH / +1500 USDC stays within LTV.
        _seedAWethPosition(10 ether);

        // Solver fronts the collateral; maker holds the DAI equity.
        deal(WETH, solver, collateralIn);
        deal(DAI, maker, equityIn);

        // Maker authorisations for the leverage legs (deposit pull + credit
        // delegation + borrow taker gate + USDC fallback).
        _approveMakerDepositBorrowSide(collateralIn, borrowOut);
        // Maker authorises Settlement to pull the DAI equity (the second input leg).
        vm.startPrank(maker);
        IERC20(DAI).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), DAI, uint160(equityIn), 0);
        vm.stopPrank();

        // Solver authorises Settlement to pull the WETH it delivers.
        _approveSolverSide(collateralIn, WETH);

        bytes memory borrowData = abi.encode(AAVE_POOL, USDC, uint256(2));
        Item[] memory items = new Item[](2);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(depositModule),
            amount: collateralIn,
            recipient: address(0),
            data: abi.encode(AAVE_POOL, WETH)
        });
        items[1] = Item({
            op: ItemOp.TAKE,
            module: address(borrowModule),
            amount: borrowOut,
            recipient: address(0), // proceeds → Settlement → solver (tokenIn[0])
            data: borrowData
        });

        Order memory order = Order({
            maker: maker,
            side: OrderSide.SELL,
            nonce: 42,
            deadline: block.timestamp + 1 hours,
            tokenIn: _a2(USDC, DAI),
            startAmountIn: _u2(borrowOut, equityIn),
            endAmountIn: _u2(borrowOut, equityIn),
            decayStartTime: 0,
            decayDuration: 0,
            tokenOut: _a1(WETH),
            startAmountOut: _u1(collateralIn),
            endAmountOut: _u1(collateralIn),
            recipientOut: new address[](1),
            exclusiveFiller: address(0),
            exclusivityEndTime: 0,
            minFillAnchor: 0,
            exclusivityOverrideBps: 0,
            curve: _noCurve(),
            gasBumpBps: 0,
            gasPriceRef: 0,
            items: items,
            validators: new Validator[](0),
            invariants: new Validator[](0)
        });
        bytes memory sig = _sign(order);

        uint256 makerAWethBefore = IERC20(aWETH).balanceOf(maker);
        uint256 makerDebtBefore = IERC20(usdcDebtToken).balanceOf(maker);

        // Full fill: fillAmountIn == amountIn[0] (the USDC borrow leg).
        vm.prank(solver);
        uint256[] memory paid = settlement.fill(order, sig, borrowOut);

        // Output: exactly the fronted collateral was delivered (and deposited).
        assertEq(paid.length, 1, "one output leg");
        assertEq(paid[0], collateralIn, "solver delivered the collateral");

        // Maker position: +1 aWETH collateral, +1500 USDC debt (leverage opened).
        assertApproxEqAbs(IERC20(aWETH).balanceOf(maker) - makerAWethBefore, collateralIn, 2, "maker aWETH up");
        assertApproxEqAbs(IERC20(usdcDebtToken).balanceOf(maker) - makerDebtBefore, borrowOut, 2, "maker debt up");

        // Maker spent exactly the DAI equity (the swap-to-deposit contribution).
        assertEq(IERC20(DAI).balanceOf(maker), 0, "maker DAI equity spent");
        // Wallets pass-through: neither the delivered WETH nor the borrowed USDC lingers.
        assertEq(IERC20(WETH).balanceOf(maker), 0, "maker WETH forwarded into deposit");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "maker USDC forwarded out via borrow");

        // Solver: fronted 1 WETH, received both inputs (borrow proceeds + equity).
        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver WETH spent");
        assertEq(IERC20(USDC).balanceOf(solver), borrowOut, "solver received borrow USDC");
        assertEq(IERC20(DAI).balanceOf(solver), equityIn, "solver received DAI equity");

        // Nothing stranded in Settlement or modules.
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(DAI).balanceOf(address(settlement)), 0, "settlement DAI drained");
        assertEq(IERC20(WETH).balanceOf(address(depositModule)), 0, "deposit module drained");
        assertEq(IERC20(USDC).balanceOf(address(borrowModule)), 0, "borrow module drained");
    }
}
