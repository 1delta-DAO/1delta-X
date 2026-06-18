// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {LimitOrder, Item, ItemOp} from "@core/settlement/LimitOrderSettlement.sol";

import {CompoundV3ModulesBase} from "../shared/CompoundV3ModulesBase.t.sol";

/// @dev Withdraw + swap: maker already has a WETH collateral position on the
/// USDC Comet, unwinds WETH and sells it for USDC.
///
///   tokenIn  = WETH   (maker gives — sourced from the withdraw item)
///   tokenOut = USDC   (solver gives, maker receives)
///
/// One TAKE item: CometWithdrawModule, routed via `permit3.take` so the taker
/// allowance gate enforces the exact (user, module, ref) amount. There is no
/// receipt token: `comet.allow(withdrawModule)` (set in setUp) lets the module
/// call `withdrawFrom`, which burns the maker's collateral and sends WETH
/// straight to Settlement.
contract WithdrawAndSwapTest is CompoundV3ModulesBase {
    // ──────────────────── Direct fill ────────────────────

    function test_withdraw_and_swap_cometV3() public {
        uint256 wethIn = 1 ether;
        uint256 usdcOut = 2_000e6;

        _seedWethCollateral(wethIn + 1e15); // small cushion
        deal(USDC, solver, usdcOut);

        bytes memory takerData = abi.encode(COMET, WETH);
        bytes32 ref = keccak256(takerData);

        _approveMakerWithdrawSide(wethIn, ref, takerData);
        _approveSolverSide(usdcOut, USDC);

        LimitOrder memory order = _buildWithdrawOrder(wethIn, usdcOut, takerData);
        bytes memory sig = _sign(order);

        uint256 makerCollatBefore = _wethCollateral(maker);
        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, wethIn);

        assertEq(paid, usdcOut, "solver paid exactly usdcOut");
        assertEq(IERC20(USDC).balanceOf(maker) - makerUsdcBefore, usdcOut, "maker received USDC");
        assertApproxEqAbs(makerCollatBefore - _wethCollateral(maker), wethIn, 2, "maker collateral burned");
        assertEq(IERC20(WETH).balanceOf(solver), wethIn, "solver received WETH");

        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(WETH).balanceOf(address(withdrawModule)), 0, "module WETH drained");

        (uint160 remaining,,) = permit3.takerAllowance(maker, address(withdrawModule), ref);
        assertEq(remaining, 0, "taker allowance spent");
    }

    // ──────────────────── Single-signature permit fill ────────────────────

    function test_permit_withdraw_and_swap() public {
        uint256 wethIn = 1 ether;
        uint256 usdcOut = 2_000e6;

        _seedWethCollateral(wethIn + 1e15);
        deal(USDC, solver, usdcOut);

        bytes memory takerData = abi.encode(COMET, WETH);

        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE,
            module: address(withdrawModule),
            amount: wethIn,
            recipient: address(0),
            data: takerData
        });

        LimitOrder memory order = _order(maker, 1, WETH, USDC, wethIn, usdcOut, items);

        // Only the WETH tokenIn-shortfall fallback + the taker allowance are
        // needed — Comet's `allow` (set in setUp) covers the protocol side, so
        // there is no receipt-token permit like Aave's aToken pull.
        IPermit3.TokenPermit[] memory tp = new IPermit3.TokenPermit[](1);
        tp[0] = IPermit3.TokenPermit(address(settlement), WETH, uint160(wethIn), uint48(order.deadline));

        IPermit3.PermitBatch memory batch =
            _buildBatch(tp, _takerPermits1(address(settlement), keccak256(takerData), wethIn), 0, order.deadline);

        bytes memory sig = _signPermitWitness(batch, _hashOrder(order));

        vm.prank(solver);
        settlement.fillWithPermit(order, batch, sig, wethIn);

        assertEq(IERC20(WETH).balanceOf(solver), wethIn, "solver received WETH");
        assertEq(IERC20(USDC).balanceOf(maker), usdcOut, "maker received USDC");
    }
}
