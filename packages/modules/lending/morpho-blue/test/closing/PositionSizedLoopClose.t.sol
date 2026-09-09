// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {PositionFillModule} from "@lib/PositionFillModule.sol";

import {MorphoModulesBase} from "../shared/MorphoModulesBase.t.sol";

/// @dev FULL CLOSE OF A wstETH/USDC MORPHO LOOP, position-sized.
///
///   1. repay ALL the USDC debt              ← must come first: Morpho refuses to
///                                             move collateral out while unhealthy
///   2. withdraw ALL wstETH collateral       ← {PositionFillModule} sizes the fill
///   3. the solver takes the wstETH and pays USDC — the legs ARE the swap
///
/// The point of running this on Morpho as well as Aave is that the position lives
/// in Morpho's own storage rather than in a transferable receipt token, so
/// `positionOf` reads `position(id, user).collateral` off a market decoded from the
/// item blob. If that decode or the market id were wrong, the fill would size
/// against someone else's position — or nothing.
///
/// It is also the venue that proves the item SCAN: the position-bearing item is
/// index 1 here, behind the repay.
contract PositionSizedLoopCloseTest is MorphoModulesBase {
    PositionFillModule internal fillModule;

    uint256 internal constant COLLATERAL = 10 ether; //  wstETH held
    uint256 internal constant CAP = 10.5 ether; //       signed ceiling (+5% margin)
    uint256 internal constant DEBT = 10_000e6; //        USDC borrowed
    uint256 internal constant USDC_LEG = 13_000e6; //    USDC the solver pays at the cap
    uint256 internal constant REPAY_CEILING = 13_000e6; // module caps at live debt

    function setUp() public override {
        super.setUp();
        fillModule = new PositionFillModule();
        vm.label(address(fillModule), "positionFillModule");
    }

    function _closeOrder(uint256 nonce) internal view returns (Order memory order) {
        // ⚠ REPAY BEFORE WITHDRAW. Pulling collateral out while the debt is open
        // leaves the position unhealthy and Morpho reverts, so the position item is
        // NOT index 0 — which is exactly why the fill module scans for it.
        Item[] memory items = new Item[](2);
        items[0] = Item(ItemOp.MAKE, address(repayModule), REPAY_CEILING, address(0), _marketData());
        items[1] = Item(ItemOp.TAKE, address(takerModule), CAP, address(0), _withdrawData());
        order = _order(maker, nonce, WSTETH, USDC, CAP, USDC_LEG, items);
        order.fillModule = address(fillModule);
        order.fillTotal = CAP;
    }

    function _approveAll() internal {
        vm.startPrank(maker);
        IERC20(WSTETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), WSTETH, uint160(CAP), 0);
        MORPHO.setAuthorization(address(takerModule), true);
        permit3.approveTaker(address(settlement), address(takerModule), keccak256(_withdrawData()), uint160(CAP), 0);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(repayModule), USDC, uint160(REPAY_CEILING), 0);
        vm.stopPrank();
    }

    function test_close_wstethUsdcLoop_positionSized() public {
        _openPosition(COLLATERAL, DEBT);
        vm.warp(block.timestamp + 90 days); // let both sides actually accrue
        _approveAll();
        deal(USDC, solver, USDC_LEG);
        _approveSolverSide(USDC_LEG, USDC);

        Order memory order = _closeOrder(1);
        bytes memory sig = _sign(order);

        (uint256 delta,,) = lens.previewFill(order, order.fillTotal, solver, "");
        uint256 live = MORPHO.position(_marketId(), maker).collateral;
        assertEq(delta, live, "fill sized from the LIVE morpho collateral");
        assertLt(delta, CAP, "below the cap, so this is a partial fill");

        uint256 debtBefore = _borrowAssets(maker);
        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);

        vm.prank(solver);
        uint256 g0 = gasleft();
        settlement.fill(order, sig, delta);
        uint256 closeGas = g0 - gasleft();

        assertEq(MORPHO.position(_marketId(), maker).collateral, 0, "collateral fully exited");
        assertEq(IERC20(WSTETH).balanceOf(maker), 0, "no unconverted wstETH in the wallet");
        assertEq(IERC20(WSTETH).balanceOf(solver), live, "solver bought the whole position");
        assertEq(_borrowAssets(maker), 0, "USDC debt fully repaid");
        assertGt(debtBefore, DEBT, "and it had accrued past the borrowed amount");
        assertGt(IERC20(USDC).balanceOf(maker), makerUsdcBefore, "maker kept the surplus USDC");

        assertEq(IERC20(WSTETH).balanceOf(address(settlement)), 0, "settlement wstETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(WSTETH).balanceOf(address(takerModule)), 0, "taker module drained");
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "repay module drained");

        console2.log("=== morpho wstETH/USDC loop close, position-sized ===");
        console2.log("  collateral withdrawn (wei) :", live);
        console2.log("  USDC debt repaid           :", debtBefore);
        console2.log("  gas, whole close           :", closeGas);
    }

    /// @dev The position item is index 1, so a fill module that assumed index 0
    /// could not size this order at all. Pinned by construction: swap the items and
    /// the venue itself rejects the shape.
    function test_positionItemIsNotIndexZero() public {
        _openPosition(COLLATERAL, DEBT);
        _approveAll();
        deal(USDC, solver, USDC_LEG);
        _approveSolverSide(USDC_LEG, USDC);

        Order memory order = _closeOrder(2);
        // Withdraw first, repay second — the order a naive index-0 rule would force.
        Item[] memory items = new Item[](2);
        items[0] = Item(ItemOp.TAKE, address(takerModule), CAP, address(0), _withdrawData());
        items[1] = Item(ItemOp.MAKE, address(repayModule), REPAY_CEILING, address(0), _marketData());
        order.items = PackedEncode.items(items);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(); // Morpho: position unhealthy with the debt still open
        settlement.fill(order, sig, CAP);
    }
}
