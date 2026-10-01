// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {IProceedsAsset} from "@core/interfaces/IProceedsAsset.sol";
import {IPositionSource} from "@core/interfaces/IPositionSource.sol";
import {DustHandler} from "@lib/DustHandler.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";

import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";
import {Chains, Lenders} from "@coretest/data/LenderRegistry.sol";

import {AaveV2WithdrawModule, AaveV2RepayModule, AaveV2BorrowModule} from "../src/AaveV2Modules.sol";
import {IAaveV2Pool, IAaveV2CreditDelegation} from "../src/interfaces/IAaveV2.sol";

/// @title Audit20260930AaveV2ForkTest
/// @notice 2026-09-30 audit (group B-lend1) against the LIVE Aave v2 LendingPool:
///   • L-AAVE-1 — Aave v2 rounds aToken transfers HALF-UP; an `Exact` withdraw of an
///     amount in the rounding window (pull `amount`, withdraw `amount`) reverted
///     `VL_NOT_ENOUGH_AVAILABLE_USER_BALANCE` deterministically. Fails before the fix.
///   • L-AAVE-5 — the v2 withdraw and repay modules had never run against a real
///     pool (only mocks): Exact + `Full` withdraw, repay Sweep + Recycle, and the new
///     `IProceedsAsset` / `IPositionSource` views.
contract Audit20260930AaveV2ForkTest is CoreSettlementBase {
    uint256 constant RAY = 1e27;

    AaveV2WithdrawModule withdrawModule;
    AaveV2RepayModule repayModule;
    AaveV2BorrowModule borrowModule;

    address POOL;
    address aWETH;
    address usdcVariableDebt;

    function setUp() public override {
        super.setUp();
        POOL = lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2];
        aWETH = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][WETH].collateral;
        usdcVariableDebt = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][USDC].debt;
        withdrawModule = new AaveV2WithdrawModule(address(permit3));
        repayModule = new AaveV2RepayModule(address(permit3), address(settlement));
        borrowModule = new AaveV2BorrowModule(address(permit3));
        vm.label(POOL, "aaveV2Pool");
        vm.label(aWETH, "aWETH_v2");
    }

    // ── helpers ──

    function _rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b + RAY / 2) / RAY;
    }

    function _rayDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * RAY + b / 2) / b;
    }

    function _badAmount(uint256 index, uint256 from) internal pure returns (uint256 a) {
        for (a = from; a < from + 100_000; ++a) {
            if (_rayMul(_rayDiv(a, index), index) < a) return a;
        }
        revert("no rounding-window amount found");
    }

    function _seedAWeth(uint256 amount) internal {
        deal(WETH, maker, amount);
        vm.startPrank(maker);
        IERC20(WETH).approve(POOL, amount);
        IAaveV2Pool(POOL).deposit(WETH, amount, maker, 0);
        vm.stopPrank();
    }

    function _withdrawOrder(uint256 nonce, bytes memory data, uint256 wethIn, uint256 usdcOut)
        internal
        returns (Order memory order, bytes memory sig)
    {
        vm.startPrank(maker);
        IERC20(aWETH).approve(address(withdrawModule), type(uint256).max);
        permit3.approveTaker(address(settlement), address(withdrawModule), keccak256(data), uint160(wethIn), 0);
        vm.stopPrank();
        deal(USDC, solver, usdcOut);
        _approveSolverSide(usdcOut, USDC);
        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE, address(withdrawModule), wethIn, address(0), data);
        order = _order(maker, nonce, WETH, USDC, wethIn, usdcOut, items);
        sig = _sign(order);
    }

    // ── L-AAVE-1 ──

    function test_audit_L_AAVE_1_exactWithdraw_roundingWindowAmount_fills() public {
        _seedAWeth(5 ether);
        uint256 index = IAaveV2Pool(POOL).getReserveNormalizedIncome(WETH);
        uint256 wethIn = _badAmount(index, 1 ether);
        assertEq(_rayMul(_rayDiv(wethIn, index), index), wethIn - 1, "half-up round trip loses one wei");

        bytes memory data = abi.encode(POOL, WETH, aWETH);
        (Order memory order, bytes memory sig) = _withdrawOrder(1, data, wethIn, 1_500e6);
        uint256 aBefore = IERC20(aWETH).balanceOf(maker);

        vm.prank(solver);
        settlement.fill(order, sig, wethIn);

        assertEq(IERC20(WETH).balanceOf(solver), wethIn, "solver received exactly the signed WETH");
        assertApproxEqAbs(aBefore - IERC20(aWETH).balanceOf(maker), wethIn, 2, "position down by the amount");
        assertEq(IERC20(aWETH).balanceOf(address(withdrawModule)), 0, "top-up surplus returned");
        assertEq(IERC20(WETH).balanceOf(address(withdrawModule)), 0, "module holds no underlying");
    }

    // ── L-AAVE-5: real-pool coverage ──

    function test_audit_L_AAVE_5_exactWithdraw_live() public {
        _seedAWeth(5 ether);
        bytes memory data = abi.encode(POOL, WETH, aWETH);
        (Order memory order, bytes memory sig) = _withdrawOrder(2, data, 2 ether, 3_000e6);
        vm.prank(solver);
        settlement.fill(order, sig, 1 ether);
        vm.prank(solver);
        settlement.fill(order, sig, 1 ether);
        assertEq(IERC20(WETH).balanceOf(solver), 2 ether, "two Exact slices");
        assertEq(IERC20(aWETH).balanceOf(address(withdrawModule)), 0, "module empty");
    }

    function test_audit_L_AAVE_5_fullWithdraw_live() public {
        _seedAWeth(5 ether);
        uint256 sell = 4 ether;
        bytes memory data = abi.encode(POOL, WETH, aWETH, DustHandler.encodeMode(DustHandler.BalanceMode.Full), sell);
        (Order memory order, bytes memory sig) = _withdrawOrder(3, data, sell, 6_000e6);
        uint256 position = IERC20(aWETH).balanceOf(maker);

        vm.prank(solver);
        settlement.fill(order, sig, sell);

        assertEq(IERC20(aWETH).balanceOf(maker), 0, "position closed");
        assertEq(IERC20(WETH).balanceOf(solver), sell, "solver got the signed amount");
        assertApproxEqAbs(IERC20(WETH).balanceOf(maker), position - sell, 2, "remainder to the maker");
        assertEq(IERC20(WETH).balanceOf(address(withdrawModule)), 0, "module empty");
    }

    function test_audit_L_AAVE_5_fullWithdraw_shortPosition_reverts() public {
        _seedAWeth(2 ether);
        uint256 sell = 4 ether;
        bytes memory data = abi.encode(POOL, WETH, aWETH, DustHandler.encodeMode(DustHandler.BalanceMode.Full), sell);
        (Order memory order, bytes memory sig) = _withdrawOrder(4, data, sell, 6_000e6);
        deal(WETH, maker, sell);
        vm.prank(maker);
        permit3.approveToken(address(settlement), WETH, type(uint160).max, 0);

        vm.prank(solver);
        vm.expectPartialRevert(FullFillGuard.ShortWithdraw.selector);
        settlement.fill(order, sig, sell);
        assertEq(IERC20(WETH).balanceOf(maker), sell, "wallet untouched");
    }

    /// Opens 10 WETH / `debt` USDC on v2 directly, dumps the USDC.
    function _openDebt(uint256 debt) internal {
        _seedAWeth(10 ether);
        vm.startPrank(maker);
        IAaveV2Pool(POOL).borrow(USDC, debt, 2, 0, maker);
        IERC20(USDC).transfer(address(0xdead), debt);
        vm.stopPrank();
    }

    function _repayFill(uint256 nonce, uint256 buffered, uint256 action) internal {
        deal(WETH, maker, 1 ether);
        deal(USDC, solver, buffered);
        _approveSolverSide(buffered, USDC);
        vm.startPrank(maker);
        permit3.approveToken(address(settlement), WETH, 1 ether, 0);
        permit3.approveToken(address(repayModule), USDC, uint160(buffered), 0);
        vm.stopPrank();
        Item[] memory items = new Item[](1);
        items[0] = Item(
            ItemOp.MAKE, address(repayModule), buffered, address(0), abi.encode(POOL, USDC, uint256(2), usdcVariableDebt, action)
        );
        Order memory order = _order(maker, nonce, WETH, USDC, 1 ether, buffered, items);
        bytes memory sig = _sign(order);
        vm.prank(solver);
        settlement.fill(order, sig, 1 ether);
    }

    function test_audit_L_AAVE_5_repaySweep_live() public {
        uint256 debt = 1_000e6;
        _openDebt(debt);
        uint256 buffered = debt + 50e6;
        uint256 debtBefore = IERC20(usdcVariableDebt).balanceOf(maker);
        _repayFill(5, buffered, uint256(DustHandler.DustAction.SweepToUser));
        assertEq(IERC20(usdcVariableDebt).balanceOf(maker), 0, "debt closed");
        assertEq(IERC20(USDC).balanceOf(maker), buffered - debtBefore, "unused buffer refunded");
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "module empty");
    }

    function test_audit_L_AAVE_5_repayRecycle_live() public {
        uint256 debt = 1_000e6;
        _openDebt(debt);
        uint256 buffered = debt + 50e6;
        address aUSDC = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][USDC].collateral;
        uint256 debtBefore = IERC20(usdcVariableDebt).balanceOf(maker);
        _repayFill(6, buffered, uint256(DustHandler.DustAction.Recycle));
        assertEq(IERC20(usdcVariableDebt).balanceOf(maker), 0, "debt closed");
        assertApproxEqAbs(IERC20(aUSDC).balanceOf(maker), buffered - debtBefore, 2, "surplus re-deposited");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "nothing swept to the wallet");
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "module empty");
    }

    // ── L-AAVE-5 (5): lens / PositionFillModule views ──

    /// Raw staticcalls so this compiles — and FAILS — against the pre-fix modules,
    /// which implemented neither view (the lens reported "unknown" and a
    /// PositionFillModule could not size a v2 exit).
    function test_audit_L_AAVE_5_views_proceedsAndPosition() public {
        _seedAWeth(3 ether);
        bytes memory wData = abi.encode(POOL, WETH, aWETH);
        (bool ok, bytes memory ret) =
            address(withdrawModule).staticcall(abi.encodeCall(IProceedsAsset.proceedsAsset, (wData)));
        assertTrue(ok && ret.length == 32, "withdraw answers proceedsAsset");
        assertEq(abi.decode(ret, (address)), WETH);

        (ok, ret) = address(withdrawModule).staticcall(abi.encodeCall(IPositionSource.positionOf, (maker, wData)));
        assertTrue(ok && ret.length == 64, "withdraw answers positionOf");
        (address asset, uint256 amount) = abi.decode(ret, (address, uint256));
        assertEq(asset, WETH);
        assertEq(amount, IERC20(aWETH).balanceOf(maker), "raw aToken position");

        (ok, ret) = address(borrowModule).staticcall(
            abi.encodeCall(IProceedsAsset.proceedsAsset, (abi.encode(POOL, USDC, uint256(2))))
        );
        assertTrue(ok && ret.length == 32, "borrow answers proceedsAsset");
        assertEq(abi.decode(ret, (address)), USDC);
    }
}
