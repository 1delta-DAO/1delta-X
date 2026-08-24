// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {DustHandler} from "@lib/DustHandler.sol";

import {AaveModulesBase} from "../shared/AaveModulesBase.t.sol";

/// @dev Withdraw + swap: maker already has an aWETH position, unwinds WETH and
/// sells it for USDC.
///
///   tokenIn  = WETH   (maker gives — sourced from the withdraw item)
///   tokenOut = USDC   (solver gives, maker receives)
///
/// One TAKE item: AaveV3WithdrawModule, routed via `permit3.take` so the taker
/// allowance gate enforces the exact (user, module, ref) amount. aWETH proceeds
/// flow: user aWETH → module (via token allowance) → pool.withdraw burns + sends
/// WETH → settlement.
contract WithdrawAndSwapTest is AaveModulesBase {
    // ──────────────────── Direct fill ────────────────────

    function test_withdraw_and_swap_aaveV3() public {
        uint256 wethIn = 1 ether;
        uint256 usdcOut = 2_000e6;

        _seedAWethPosition(wethIn + 1e15); // +0.001 WETH cushion for scaled rounding
        deal(USDC, solver, usdcOut);

        bytes memory takerData = abi.encode(AAVE_POOL, WETH, aWETH);
        bytes32 ref = keccak256(takerData);

        _approveMakerWithdrawSide(wethIn, ref, takerData);
        _approveSolverSide(usdcOut, USDC);

        Order memory order = _buildWithdrawOrder(wethIn, usdcOut, takerData);
        bytes memory sig = _sign(order);

        uint256 makerAWethBefore = IERC20(aWETH).balanceOf(maker);
        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, wethIn)[0];

        assertEq(paid, usdcOut, "solver paid exactly usdcOut");
        assertEq(IERC20(USDC).balanceOf(maker) - makerUsdcBefore, usdcOut, "maker received USDC");
        assertApproxEqAbs(makerAWethBefore - IERC20(aWETH).balanceOf(maker), wethIn, 2, "maker aWETH burned");
        assertEq(IERC20(WETH).balanceOf(solver), wethIn, "solver received WETH");

        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(aWETH).balanceOf(address(withdrawModule)), 0, "module aWETH drained");

        (uint160 remaining,) = permit3.takerAllowance(maker, address(settlement), address(withdrawModule), ref);
        assertEq(remaining, 0, "taker allowance spent");
    }

    // ──────────────────── Single-signature permit fill ────────────────────

    function test_permit_withdraw_and_swap() public {
        uint256 wethIn = 1 ether;
        uint256 usdcOut = 2_000e6;

        _seedAWethPosition(wethIn + 1e15);
        deal(USDC, solver, usdcOut);

        bytes memory takerData = abi.encode(AAVE_POOL, WETH, aWETH);

        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE, module: address(withdrawModule), amount: wethIn, recipient: address(0), data: takerData
        });

        Order memory order = _order(maker, 1, WETH, USDC, wethIn, usdcOut, items);

        IPermit3.PermitBatch memory batch = _buildBatch(
            _tokenPermitsWithTaker(address(settlement), WETH, wethIn, address(withdrawModule), aWETH, wethIn),
            _takerPermits1(address(settlement), address(withdrawModule), keccak256(takerData), wethIn),
            0,
            _expiry(order)
        );

        bytes memory sig = _signPermitWitness(batch, _hashOrder(order));

        vm.prank(solver);
        settlement.fillWithPermit(order, batch, sig, wethIn);

        assertEq(IERC20(WETH).balanceOf(solver), wethIn, "solver received WETH");
        assertEq(IERC20(USDC).balanceOf(maker), usdcOut, "maker received USDC");
    }

    // ──────────────────── Full-balance withdrawal ────────────────────

    /// @dev `BalanceMode.Full`: the maker holds an aWETH position LARGER than the
    /// order amount (the surplus stands in for accrued interest). The withdraw
    /// module pulls the entire rebasing balance, forwards the signed `wethIn` to
    /// the solver, and sweeps the accrued excess back to the maker in-kind — the
    /// TAKE-side mirror of the over-repay refund. The position is fully exited.
    function test_withdraw_full_balance_sweeps_excess_aaveV3() public {
        uint256 wethIn = 1 ether; //          amount that flows to the solver
        uint256 excess = 0.3 ether; //        surplus beyond the order amount
        uint256 usdcOut = 2_000e6;

        _seedAWethPosition(wethIn + excess);
        deal(USDC, solver, usdcOut);

        // Full-balance flag appended → distinct taker-allowance ref.
        // `Full` is full-fill only: the trailing word is the maker-signed item total.
        bytes memory takerData = abi.encode(AAVE_POOL, WETH, aWETH, uint8(DustHandler.BalanceMode.Full), wethIn);
        bytes32 ref = keccak256(takerData);

        vm.startPrank(maker);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), WETH, uint160(wethIn), 0);
        // Full-balance pull needs an uncapped aWETH token allowance to the module.
        IERC20(aWETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(withdrawModule), aWETH, type(uint160).max, 0);
        // Taker gate still bounds the order slice that reaches the solver.
        permit3.approveTaker(address(settlement), address(withdrawModule), ref, uint160(wethIn), 0);
        vm.stopPrank();
        _approveSolverSide(usdcOut, USDC);

        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE, module: address(withdrawModule), amount: wethIn, recipient: address(0), data: takerData
        });
        Order memory order = _order(maker, 1, WETH, USDC, wethIn, usdcOut, items);
        bytes memory sig = _sign(order);

        uint256 makerWethBefore = IERC20(WETH).balanceOf(maker); // 0 — all supplied

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, wethIn)[0];

        assertEq(paid, usdcOut, "solver paid usdcOut");
        // Position fully exited (≤1 wei rebasing rounding).
        assertApproxEqAbs(IERC20(aWETH).balanceOf(maker), 0, 2, "aWETH position fully closed");
        // Solver got exactly the signed order slice.
        assertEq(IERC20(WETH).balanceOf(solver), wethIn, "solver received exactly wethIn");
        // Maker got the swap output AND the accrued excess swept back in-kind.
        assertEq(IERC20(USDC).balanceOf(maker), usdcOut, "maker received USDC");
        assertApproxEqAbs(IERC20(WETH).balanceOf(maker) - makerWethBefore, excess, 1e12, "excess WETH swept to maker");
        // Nothing stranded anywhere.
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(WETH).balanceOf(address(withdrawModule)), 0, "module WETH drained");
        assertEq(IERC20(aWETH).balanceOf(address(withdrawModule)), 0, "module aWETH drained");
    }
}
