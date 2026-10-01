// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {DustHandler} from "@lib/DustHandler.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";

import {CompoundV2WithdrawModule} from "../../src/CompoundV2Modules.sol";
import {CompoundV2ModulesBase} from "../shared/CompoundV2ModulesBase.t.sol";

/// @title Audit20260930CompoundV2WithdrawForkTest
/// @notice 2026-09-30 audit (group B-lend1), against the LIVE Compound v2 cUSDC market:
///   • L-CV2-7 — the ERC-20 `CompoundV2WithdrawModule` `Full` branch had no test (only
///     the native one did); its `requireDelivered` was guarded only syntactically.
///   • L-CV2-4 — a `data` blob naming the wrong underlying for a real cToken is
///     rejected instead of stranding the redeemed USDC and billing the wallet.
contract Audit20260930CompoundV2WithdrawForkTest is CompoundV2ModulesBase {
    /// @dev `CompoundV2WithdrawModule.UnderlyingMismatch(address,address)`, spelled out
    ///      so this file also compiles against the pre-fix module (fails-before proof).
    bytes4 constant UNDERLYING_MISMATCH = bytes4(keccak256("UnderlyingMismatch(address,address)"));

    function _grantWithdraw(bytes memory data, uint256 cap) internal {
        vm.startPrank(maker);
        IERC20(address(CUSDC)).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(withdrawModule), address(CUSDC), type(uint160).max, 0);
        permit3.approveTaker(address(settlement), address(withdrawModule), keccak256(data), uint160(cap), 0);
        vm.stopPrank();
    }

    /// `Full` closes the whole cUSDC position: the signed amount to the solver, the
    /// accrued remainder back to the maker, nothing left on the module.
    function test_audit_L_CV2_7_erc20FullWithdraw_closesPosition() public {
        uint256 seed = 2_000e6;
        uint256 sell = 1_500e6;
        _seedUsdcCollateral(seed);

        bytes memory data = abi.encode(
            address(CUSDC), USDC, DustHandler.encodeMode(DustHandler.BalanceMode.Full), sell
        );
        _grantWithdraw(data, sell);
        deal(DAI, solver, 1_400e18);
        _approveSolverSide(1_400e18, DAI);

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE, address(withdrawModule), sell, address(0), data);
        Order memory order = _order(maker, 1, USDC, DAI, sell, 1_400e18, items);
        bytes memory sig = _sign(order);

        uint256 collBefore = _usdcCollateral(maker);
        vm.prank(solver);
        settlement.fill(order, sig, sell);

        assertEq(IERC20(address(CUSDC)).balanceOf(maker), 0, "position fully redeemed");
        assertEq(IERC20(USDC).balanceOf(solver), sell, "solver got the signed amount");
        assertApproxEqAbs(IERC20(USDC).balanceOf(maker), collBefore - sell, 2, "remainder swept to maker");
        assertEq(IERC20(USDC).balanceOf(address(withdrawModule)), 0, "module holds no USDC");
        assertEq(IERC20(address(CUSDC)).balanceOf(address(withdrawModule)), 0, "module holds no cUSDC");
    }

    /// `Full` refuses a position worth less than the signed amount (I-8) instead of
    /// letting the core bill the gap to the maker's wallet.
    function test_audit_L_CV2_7_erc20FullWithdraw_shortPosition_reverts() public {
        uint256 seed = 1_000e6;
        uint256 sell = 1_500e6; // more than the position
        _seedUsdcCollateral(seed);

        bytes memory data = abi.encode(
            address(CUSDC), USDC, DustHandler.encodeMode(DustHandler.BalanceMode.Full), sell
        );
        _grantWithdraw(data, sell);
        deal(USDC, maker, sell); // wallet funds + standing allowance the gap could be billed to
        vm.prank(maker);
        permit3.approveToken(address(settlement), USDC, type(uint160).max, 0);
        deal(DAI, solver, 1_400e18);
        _approveSolverSide(1_400e18, DAI);

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE, address(withdrawModule), sell, address(0), data);
        Order memory order = _order(maker, 2, USDC, DAI, sell, 1_400e18, items);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectPartialRevert(FullFillGuard.ShortWithdraw.selector);
        settlement.fill(order, sig, sell);
        assertEq(IERC20(USDC).balanceOf(maker), sell, "wallet untouched");
    }

    /// L-CV2-4 on the live market: cUSDC named with DAI as its underlying. Before
    /// the binding the module measured a zero DAI delta, forwarded nothing, left the
    /// redeemed USDC stranded on the singleton, and the core pulled the whole DAI
    /// input leg from the maker's wallet.
    function test_audit_L_CV2_4_realCToken_wrongUnderlying_reverts() public {
        _seedUsdcCollateral(2_000e6);
        uint256 sell = 500e18;
        bytes memory data = abi.encode(address(CUSDC), DAI); // encoder bug

        _grantWithdraw(data, sell);
        deal(DAI, maker, sell);
        vm.startPrank(maker);
        IERC20(DAI).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), DAI, type(uint160).max, 0);
        vm.stopPrank();
        deal(USDC, solver, 400e6);
        _approveSolverSide(400e6, USDC);

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE, address(withdrawModule), sell, address(0), data);
        Order memory order = _order(maker, 3, DAI, USDC, sell, 400e6, items);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(UNDERLYING_MISMATCH, DAI, USDC));
        settlement.fill(order, sig, sell);

        assertEq(IERC20(DAI).balanceOf(maker), sell, "wallet not billed");
        assertEq(IERC20(USDC).balanceOf(address(withdrawModule)), 0, "nothing stranded");
    }
}
