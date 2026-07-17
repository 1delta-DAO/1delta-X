// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/UniversalSettlement.sol";
import {AaveModulesBase} from "../shared/AaveModulesBase.t.sol";

/// @dev Lending-action compatibility for the sourcing fee LEG: the fee is an
/// extra output leg addressed to the sourcer — the MAKE deposit and TAKE borrow
/// items run untouched. Here the collateral leg (`tokenOut = WETH`) funds a
/// deposit, so the deposit item is sized to the MAKER leg's amount (the net of
/// the fee split); the borrow (TAKE) is entirely independent of the fee.
///
///   tokenIn  = USDC   (maker gives — sourced from the borrow item)
///   tokenOut = WETH   [net → maker → deposited, fee → sourcer]
contract DepositBorrowWithFeeTest is AaveModulesBase {
    address feeRecipient = address(0x50FCE);

    function test_depositBorrow_withSourcingFee_aaveV3() public {
        uint256 collateralIn = 1 ether; //     solver delivers this gross
        uint256 borrowOut = 1_500e6;
        uint256 feeBps = 100; //               1%
        uint256 fee = collateralIn * feeBps / 10_000; // 0.01 WETH to sourcer
        uint256 netDeposit = collateralIn - fee; //      maker deposits the rest

        deal(WETH, solver, collateralIn);
        _approveMakerDepositBorrowSide(collateralIn, borrowOut);
        _approveSolverSide(collateralIn, WETH);

        // Deposit sized to the net (post-fee) collateral; borrow unchanged.
        Item[] memory items = new Item[](2);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(depositModule),
            amount: netDeposit,
            recipient: address(0),
            data: abi.encode(AAVE_POOL, WETH)
        });
        items[1] = Item({
            op: ItemOp.TAKE,
            module: address(borrowModule),
            amount: borrowOut,
            recipient: address(0),
            data: abi.encode(AAVE_POOL, USDC, uint256(2))
        });
        Order memory order = _order(maker, 2, USDC, WETH, borrowOut, collateralIn, items);
        _splitFeeLeg(order, feeRecipient, fee); // fee as its own output leg
        bytes memory sig = _sign(order);

        uint256 makerAWethBefore = IERC20(aWETH).balanceOf(maker);
        uint256 makerDebtBefore = IERC20(usdcDebtToken).balanceOf(maker);

        vm.prank(solver);
        uint256[] memory outs = settlement.fill(order, sig, borrowOut);

        // Solver still pays the full gross collateral; only the split changed.
        assertEq(outs[0] + outs[1], collateralIn, "solver paid full gross collateral");
        assertEq(IERC20(WETH).balanceOf(feeRecipient), fee, "sourcer received the fee");

        // Lending legs executed on the net amounts — deposit and borrow both live.
        assertApproxEqAbs(IERC20(aWETH).balanceOf(maker) - makerAWethBefore, netDeposit, 2, "maker aWETH up by net");
        assertApproxEqAbs(IERC20(usdcDebtToken).balanceOf(maker) - makerDebtBefore, borrowOut, 2, "maker debt up");

        // Solver received the borrow proceeds (TAKE leg untouched by the fee).
        assertEq(IERC20(USDC).balanceOf(solver), borrowOut, "solver received USDC");
        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver WETH fully spent");

        // Nothing stranded: maker wallet drained, settlement/modules empty.
        assertEq(IERC20(WETH).balanceOf(maker), 0, "maker WETH forwarded into deposit");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
    }
}
