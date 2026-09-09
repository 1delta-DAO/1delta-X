// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {PositionFillModule} from "@lib/PositionFillModule.sol";

import {IComet} from "../../src/interfaces/ICompoundV3.sol";
import {CompoundV3ModulesBase} from "../shared/CompoundV3ModulesBase.t.sol";

/// @dev FULL CLOSE OF A WETH/USDC COMET LOOP, position-sized.
///
///   1. repay ALL the USDC base debt         ← first: Comet blocks a collateral
///                                             withdraw that leaves you unhealthy
///   2. withdraw ALL WETH collateral         ← {PositionFillModule} sizes the fill
///   3. the solver takes the WETH and pays USDC — the legs ARE the swap
///
/// Comet earns its own close test because its `positionOf` has to pick a ledger:
/// the collateral read here is `collateralBalanceOf`, while a base-asset exit would
/// be `balanceOf`. Sizing a close off the wrong one resolves to zero and the fill
/// pays nothing — the failure the R2-L3 fix and its unit test exist for, here in a
/// real close.
///
/// On Comet a "repay" IS `supplyTo` of the base asset, so the repay item is a MAKE
/// on the same Comet the withdraw uses — the two items address one venue and only
/// the withdraw reports a position, which is what keeps the scan unambiguous.
contract PositionSizedLoopCloseTest is CompoundV3ModulesBase {
    PositionFillModule internal fillModule;

    uint256 internal constant COLLATERAL = 8 ether; //   WETH collateral held
    uint256 internal constant CAP = 8.4 ether; //        signed ceiling (+5% margin)
    uint256 internal constant DEBT = 8_000e6; //         USDC borrowed against it
    uint256 internal constant USDC_LEG = 11_000e6; //    USDC the solver pays at the cap
    uint256 internal constant REPAY_CEILING = 11_000e6; // module caps at live debt

    function setUp() public override {
        super.setUp();
        fillModule = new PositionFillModule();
        vm.label(address(fillModule), "positionFillModule");
    }

    /// @dev Supply WETH collateral, draw USDC against it (a base withdraw past the
    /// supply IS the borrow on Comet), and dump the proceeds so the wallet starts
    /// clean — the close must be funded by the solver.
    function _openLoop() internal {
        deal(WETH, maker, COLLATERAL);
        vm.startPrank(maker);
        IERC20(WETH).approve(COMET, COLLATERAL);
        IComet(COMET).supply(WETH, COLLATERAL);
        IComet(COMET).withdraw(USDC, DEBT);
        IERC20(USDC).transfer(address(0xdead), DEBT);
        vm.stopPrank();
    }

    function _closeOrder(uint256 nonce) internal view returns (Order memory order) {
        // ⚠ REPAY BEFORE WITHDRAW — the position item is index 1, not 0.
        Item[] memory items = new Item[](2);
        items[0] = Item(ItemOp.MAKE, address(repayModule), REPAY_CEILING, address(0), abi.encode(COMET, USDC));
        items[1] = Item(ItemOp.TAKE, address(takerModule), CAP, address(0), _withdrawData(COMET, WETH));
        order = _order(maker, nonce, WETH, USDC, CAP, USDC_LEG, items);
        order.fillModule = address(fillModule);
        order.fillTotal = CAP;
    }

    function _approveAll() internal {
        vm.startPrank(maker);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), WETH, uint160(CAP), 0);
        permit3.approveTaker(
            address(settlement), address(takerModule), keccak256(_withdrawData(COMET, WETH)), uint160(CAP), 0
        );
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(repayModule), USDC, uint160(REPAY_CEILING), 0);
        vm.stopPrank();
    }

    function test_close_wethUsdcCometLoop_positionSized() public {
        _openLoop();
        vm.warp(block.timestamp + 90 days); // let the debt actually accrue
        _approveAll();
        deal(USDC, solver, USDC_LEG);
        _approveSolverSide(USDC_LEG, USDC);

        Order memory order = _closeOrder(1);
        bytes memory sig = _sign(order);

        (uint256 delta,,) = lens.previewFill(order, order.fillTotal, solver, "");
        uint256 live = _wethCollateral(maker);
        assertEq(delta, live, "fill sized from the LIVE Comet collateral ledger");
        assertLt(delta, CAP, "below the cap, so this is a partial fill");

        uint256 debtBefore = _usdcDebt(maker);
        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);

        vm.prank(solver);
        uint256 g0 = gasleft();
        settlement.fill(order, sig, delta);
        uint256 closeGas = g0 - gasleft();

        assertEq(_wethCollateral(maker), 0, "collateral fully exited");
        assertEq(IERC20(WETH).balanceOf(maker), 0, "no unconverted WETH in the wallet");
        assertEq(IERC20(WETH).balanceOf(solver), live, "solver bought the whole position");
        assertEq(_usdcDebt(maker), 0, "USDC debt fully repaid");
        assertGt(debtBefore, DEBT, "and it had accrued past the borrowed amount");
        assertGt(IERC20(USDC).balanceOf(maker), makerUsdcBefore, "maker kept the surplus USDC");

        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(WETH).balanceOf(address(takerModule)), 0, "taker module drained");
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "repay module drained");

        console2.log("=== comet WETH/USDC loop close, position-sized ===");
        console2.log("  collateral withdrawn (wei) :", live);
        console2.log("  USDC debt repaid           :", debtBefore);
        console2.log("  gas, whole close           :", closeGas);
    }

    /// @dev The same close signed withdraw-first, which is what an index-0 rule
    /// would have forced: Comet refuses to release collateral against open debt.
    function test_positionItemIsNotIndexZero() public {
        _openLoop();
        _approveAll();
        deal(USDC, solver, USDC_LEG);
        _approveSolverSide(USDC_LEG, USDC);

        Order memory order = _closeOrder(2);
        Item[] memory items = new Item[](2);
        items[0] = Item(ItemOp.TAKE, address(takerModule), CAP, address(0), _withdrawData(COMET, WETH));
        items[1] = Item(ItemOp.MAKE, address(repayModule), REPAY_CEILING, address(0), abi.encode(COMET, USDC));
        order.items = PackedEncode.items(items);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(); // Comet: not collateralized
        settlement.fill(order, sig, CAP);
    }
}
