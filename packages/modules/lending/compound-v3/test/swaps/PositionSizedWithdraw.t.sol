// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {PositionFillModule} from "@lib/PositionFillModule.sol";

import {IComet} from "../../src/interfaces/ICompoundV3.sol";
import {CompoundV3ModulesBase} from "../shared/CompoundV3ModulesBase.t.sol";

/// @dev POSITION-SIZED EXIT on Comet — the fill delta is resolved from the
/// maker's live position, so everything they hold under the signed cap is SOLD
/// rather than partly returned as unconverted dust.
///
/// Comet is the venue where this can go wrong quietly: the base asset's supply
/// lives in `balanceOf` while `collateralBalanceOf` returns ZERO for it, so a
/// reader that consults one ledger for both sizes a base exit at 0. Both branches
/// are pinned below, seeded to DIFFERENT amounts so a module reading the wrong
/// ledger cannot accidentally pass.
contract PositionSizedWithdrawTest is CompoundV3ModulesBase {
    PositionFillModule internal fillModule;

    uint256 internal constant WETH_CAP = 1.5 ether;
    uint256 internal constant WETH_QUOTE = 3_000e6;

    function setUp() public override {
        super.setUp();
        fillModule = new PositionFillModule();
        vm.label(address(fillModule), "positionFillModule");
    }

    function _positionOrder(uint256 nonce, address assetIn, uint256 cap, address assetOut, uint256 quote)
        internal
        view
        returns (Order memory order)
    {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE,
            module: address(takerModule),
            amount: cap, //                     must equal fillTotal and legsIn[0].start
            recipient: address(0),
            data: _withdrawData(COMET, assetIn) // no BalanceMode word: `Exact`
        });
        order = _order(maker, nonce, assetIn, assetOut, cap, quote, items);
        order.fillModule = address(fillModule);
        order.fillTotal = cap;
    }

    // ──────────────────── Collateral ledger ────────────────────

    /// @dev The property, on the collateral side: a position below the cap is sold
    /// in full and paid pro rata.
    function test_collateral_positionSized_sellsTheWholePosition() public {
        uint256 position = 1.3 ether;
        _seedWethCollateral(position);
        deal(USDC, solver, WETH_QUOTE);

        bytes memory takerData = _withdrawData(COMET, WETH);
        _approveMakerWithdrawSide(WETH_CAP, keccak256(takerData), takerData);
        _approveSolverSide(WETH_QUOTE, USDC);

        uint256 live = _wethCollateral(maker);
        uint256 expectedQuote = (live * WETH_QUOTE + WETH_CAP - 1) / WETH_CAP; // ceilDiv, as Pricing does

        Order memory order = _positionOrder(1, WETH, WETH_CAP, USDC, WETH_QUOTE);
        bytes memory sig = _sign(order);
        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, WETH_CAP)[0];

        assertEq(paid, expectedQuote, "maker paid pro rata for the LIVE position");
        assertEq(IERC20(USDC).balanceOf(maker) - makerUsdcBefore, expectedQuote, "maker received it");
        assertEq(IERC20(WETH).balanceOf(solver), live, "solver bought the whole live position");
        assertEq(IERC20(WETH).balanceOf(maker), 0, "no unconverted dust in the wallet");
        assertLe(_wethCollateral(maker), 1, "collateral fully exited");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement drained");
    }

    // ──────────────────── Base ledger ────────────────────

    /// @dev The same property on the BASE asset, which is the branch that reads
    /// `balanceOf` instead of `collateralBalanceOf`. Seeded alongside a DIFFERENT
    /// collateral amount so a reader that consulted the collateral ledger would
    /// resolve to the wrong number rather than coincidentally the right one — and
    /// since `collateralBalanceOf(maker, USDC)` is 0 on the real Comet, it would
    /// resolve to zero and revert `ZeroFill`.
    function test_base_positionSized_readsTheBaseLedger() public {
        uint256 baseSupply = 900e6;
        uint256 cap = 1_200e6;
        uint256 quote = 0.4 ether; // paid in WETH so tokenIn/tokenOut stay distinct

        _seedWethCollateral(2 ether); // a DIFFERENT, non-zero collateral position
        _seedBaseSupply(baseSupply);
        deal(WETH, solver, quote);

        bytes memory takerData = _withdrawData(COMET, USDC);
        vm.startPrank(maker);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDC, uint160(cap), 0);
        permit3.approveTaker(address(settlement), address(takerModule), keccak256(takerData), uint160(cap), 0);
        vm.stopPrank();
        _approveSolverSide(quote, WETH);

        assertEq(IComet(COMET).collateralBalanceOf(maker, USDC), 0, "base has no collateral ledger");

        uint256 live = _baseSupply(maker);
        uint256 expectedQuote = (live * quote + cap - 1) / cap;

        Order memory order = _positionOrder(2, USDC, cap, WETH, quote);
        bytes memory sig = _sign(order);
        uint256 makerWethBefore = IERC20(WETH).balanceOf(maker);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, cap)[0];

        assertEq(paid, expectedQuote, "maker paid pro rata for the LIVE base supply");
        assertEq(IERC20(WETH).balanceOf(maker) - makerWethBefore, expectedQuote, "maker received it");
        assertEq(IERC20(USDC).balanceOf(solver), live, "solver bought the whole base supply");
        assertLe(_baseSupply(maker), 1, "base supply fully exited");
        assertApproxEqAbs(_wethCollateral(maker), 2 ether, 2, "collateral position untouched");
    }

    // ──────────────────── Guards ────────────────────

    /// @dev The borrow op shares the module and the byte map; sizing a borrow leg
    /// from a supply position would price the fill off an unrelated number, so
    /// `positionOf` refuses it.
    ///
    /// It surfaces as `NoPositionItem`, not the module's own `BadOp`: the fill module
    /// SCANS items for one that reports a position (a close is signed
    /// `[repay, withdraw]`, so the position item is not index 0), and a `try`/`catch`
    /// is what lets a non-reporting item be skipped. The cost is diagnostic — a
    /// refusing module's revert reason is swallowed — and "no item in this order
    /// reports a position" is the accurate thing to say about the result.
    function test_borrowOp_reverts() public {
        _seedWethCollateral(1 ether);
        deal(USDC, solver, WETH_QUOTE);
        _approveSolverSide(WETH_QUOTE, USDC);

        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE,
            module: address(takerModule),
            amount: WETH_CAP,
            recipient: address(0),
            data: _borrowData(COMET, USDC) //   op 0, not 1
        });
        Order memory order = _order(maker, 3, WETH, USDC, WETH_CAP, WETH_QUOTE, items);
        order.fillModule = address(fillModule);
        order.fillTotal = WETH_CAP;
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(PositionFillModule.NoPositionItem.selector);
        settlement.fill(order, sig, WETH_CAP);
    }
}
