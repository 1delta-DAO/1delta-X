// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {Order, Item, ItemOp} from "@core/settlement/UniversalSettlement.sol";

import {MorphoModulesBase} from "../shared/MorphoModulesBase.t.sol";

/// @dev Supply collateral X + borrow Y in one order: maker supplies 1 wstETH as
/// collateral and borrows USDC against it on a Morpho market. The solver funds the
/// wstETH collateral and receives the borrow proceeds in exchange.
///
///   tokenIn  = USDC     (maker gives — sourced from the borrow item)
///   tokenOut = wstETH   (solver gives → forwarded into the supply item)
///
/// Items:
///   [0] MAKE  MorphoBlueSupplyCollateralModule   supply wstETH
///   [1] TAKE  MorphoBlueTakerModule (op=Borrow)   borrow USDC
contract SupplyBorrowTest is MorphoModulesBase {
    // ──────────────────── Direct fill ────────────────────

    function test_supplyX_borrowY_morpho() public {
        uint256 collateralIn = 1 ether; //    maker receives + supplies
        uint256 borrowOut = 1_500e6; //        maker borrows → solver receives

        deal(WSTETH, solver, collateralIn);

        _approveMakerSupplyBorrowSide(collateralIn, borrowOut);
        _approveSolverSide(collateralIn, WSTETH);

        Order memory order = _buildSupplyBorrowOrder(collateralIn, borrowOut);
        bytes memory sig = _sign(order);

        uint256 makerCollatBefore = _collateral(maker);
        uint256 makerDebtBefore = _borrowAssets(maker);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, borrowOut)[0];

        assertEq(paid, collateralIn, "solver paid 1 wstETH of collateral");

        // Maker: has a fresh ~1 wstETH collateral position and ~1500 USDC of debt.
        assertEq(_collateral(maker) - makerCollatBefore, collateralIn, "maker collateral up exactly");
        assertApproxEqAbs(_borrowAssets(maker) - makerDebtBefore, borrowOut, 2, "maker debt up");

        // Solver: spent wstETH, received USDC.
        assertEq(IERC20(WSTETH).balanceOf(solver), 0, "solver wstETH spent");
        assertEq(IERC20(USDC).balanceOf(solver), borrowOut, "solver received USDC");

        // Wallet balances unchanged — neither leg's asset sat in the maker's EOA.
        assertEq(IERC20(WSTETH).balanceOf(maker), 0, "maker wstETH forwarded into supply");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "maker USDC forwarded out via borrow");

        // Settlement & modules end empty.
        assertEq(IERC20(WSTETH).balanceOf(address(settlement)), 0, "settlement wstETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(WSTETH).balanceOf(address(supplyModule)), 0, "supply module wstETH drained");
        assertEq(IERC20(USDC).balanceOf(address(takerModule)), 0, "taker module USDC drained");
    }

    // ──────────────────── Single-signature permit fill ────────────────────

    function test_permit_supply_and_borrow() public {
        uint256 collateralIn = 1 ether;
        uint256 borrowOut = 1_500e6;

        deal(WSTETH, solver, collateralIn);
        // wstETH is tokenOut here — unlike WETH it isn't pre-approved for the solver
        // in the base harness, so approve it for the Settlement payout leg.
        _approveSolverSide(collateralIn, WSTETH);

        // Morpho-native authorisation: separate from Permit3, like Aave's credit
        // delegation — not part of the signed batch.
        vm.prank(maker);
        MORPHO.setAuthorization(address(takerModule), true);

        // Supply MAKE uses bare market data; the borrow TAKE uses op-prefixed data.
        bytes memory marketData = _marketData();
        bytes memory borrowData = _borrowData();

        Item[] memory items = new Item[](2);
        items[0] = Item(ItemOp.MAKE, address(supplyModule), collateralIn, address(0), marketData);
        items[1] = Item(ItemOp.TAKE, address(takerModule), borrowOut, address(0), borrowData);

        Order memory order = _order(maker, 2, USDC, WSTETH, borrowOut, collateralIn, items);

        IPermit3.TokenPermit[] memory tp = new IPermit3.TokenPermit[](2);
        tp[0] = IPermit3.TokenPermit(address(settlement), USDC, uint160(borrowOut), uint48(order.deadline));
        tp[1] = IPermit3.TokenPermit(address(supplyModule), WSTETH, uint160(collateralIn), uint48(order.deadline));

        IPermit3.PermitBatch memory batch =
            _buildBatch(tp, _takerPermits1(address(settlement), keccak256(borrowData), borrowOut), 1, order.deadline);

        bytes memory sig = _signPermitWitness(batch, _hashOrder(order));

        vm.prank(solver);
        settlement.fillWithPermit(order, batch, sig, borrowOut);

        assertEq(_collateral(maker), collateralIn, "maker collateral up");
        assertApproxEqAbs(_borrowAssets(maker), borrowOut, 2, "maker debt up");
        assertEq(IERC20(USDC).balanceOf(solver), borrowOut, "solver received borrow proceeds");
    }
}
