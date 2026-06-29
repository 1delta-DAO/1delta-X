// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {LimitOrder, Item, ItemOp} from "@core/settlement/LimitOrderSettlement.sol";

import {IComet} from "../../src/interfaces/ICompoundV3.sol";
import {CompoundV3ModulesBase} from "../shared/CompoundV3ModulesBase.t.sol";

/// @dev Deposit X + borrow Y in one order: maker deposits 1 WETH as collateral
/// on the USDC Comet and borrows USDC against it. The solver funds the WETH
/// collateral and receives the borrow proceeds in exchange. (No swap of the
/// borrowed asset back into collateral — this is deposit+borrow, not a levered
/// position; see FlashLoanLeverage for the levered variant.)
///
///   tokenIn  = USDC   (maker gives — sourced from the borrow item)
///   tokenOut = WETH   (solver gives → forwarded into the deposit item)
///
/// Items:
///   [0] MAKE  CometDepositModule   supply WETH collateral
///   [1] TAKE  CometTakerModule(Borrow)  borrow USDC (base withdraw past supply)
contract DepositBorrowTest is CompoundV3ModulesBase {
    // borrowOut sits comfortably under the USDC-Comet WETH collateral factor for
    // 1 WETH at the pinned block, leaving headroom for ETH price.
    uint256 constant BORROW_OUT = 1_000e6;

    // ──────────────────── Direct fill ────────────────────

    function test_depositX_borrowY_cometV3() public {
        uint256 collateralIn = 1 ether; //    maker receives + deposits
        uint256 borrowOut = BORROW_OUT; //     maker borrows → solver receives

        deal(WETH, solver, collateralIn);

        _approveMakerDepositBorrowSide(collateralIn, borrowOut);
        _approveSolverSide(collateralIn, WETH);

        LimitOrder memory order = _buildDepositBorrowOrder(collateralIn, borrowOut);
        bytes memory sig = _sign(order);

        uint256 makerCollatBefore = _wethCollateral(maker);
        uint256 makerDebtBefore = _usdcDebt(maker);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, borrowOut);

        assertEq(paid, collateralIn, "solver paid 1 WETH of collateral");

        // Maker: has a fresh ~1 WETH collateral position and ~borrowOut USDC of debt.
        assertApproxEqAbs(_wethCollateral(maker) - makerCollatBefore, collateralIn, 2, "maker collateral up");
        assertApproxEqAbs(_usdcDebt(maker) - makerDebtBefore, borrowOut, 2, "maker debt up");

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
        assertEq(IERC20(USDC).balanceOf(address(takerModule)), 0, "taker module USDC drained");
    }

    // ──────────────────── Single-signature permit fill ────────────────────

    function test_permit_deposit_and_borrow() public {
        uint256 collateralIn = 1 ether;
        uint256 borrowOut = BORROW_OUT;

        deal(WETH, solver, collateralIn);

        // Comet account-manager flag: Comet-native, separate from Permit3.
        vm.prank(maker);
        IComet(COMET).allow(address(takerModule), true);

        bytes memory borrowData = _borrowData(COMET, USDC);

        Item[] memory items = new Item[](2);
        items[0] = Item(ItemOp.MAKE, address(depositModule), collateralIn, address(0), abi.encode(COMET, WETH));
        items[1] = Item(ItemOp.TAKE, address(takerModule), borrowOut, address(0), borrowData);

        LimitOrder memory order = _order(maker, 2, USDC, WETH, borrowOut, collateralIn, items);

        IPermit3.TokenPermit[] memory tp = new IPermit3.TokenPermit[](2);
        tp[0] = IPermit3.TokenPermit(address(settlement), USDC, uint160(borrowOut), uint48(order.deadline));
        tp[1] = IPermit3.TokenPermit(address(depositModule), WETH, uint160(collateralIn), uint48(order.deadline));

        IPermit3.PermitBatch memory batch =
            _buildBatch(tp, _takerPermits1(address(settlement), keccak256(borrowData), borrowOut), 1, order.deadline);

        bytes memory sig = _signPermitWitness(batch, _hashOrder(order));

        vm.prank(solver);
        settlement.fillWithPermit(order, batch, sig, borrowOut);

        assertApproxEqAbs(_wethCollateral(maker), collateralIn, 2, "maker collateral up");
        assertApproxEqAbs(_usdcDebt(maker), borrowOut, 2, "maker debt up");
        assertEq(IERC20(USDC).balanceOf(solver), borrowOut, "solver received borrow proceeds");
    }
}
