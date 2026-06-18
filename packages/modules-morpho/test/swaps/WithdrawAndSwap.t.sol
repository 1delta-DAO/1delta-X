// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {LimitOrder, Item, ItemOp} from "@core/settlement/LimitOrderSettlement.sol";

import {MorphoModulesBase} from "../shared/MorphoModulesBase.t.sol";

/// @dev Withdraw collateral + swap: maker already has a wstETH collateral position
/// on Morpho, unwinds it and sells the wstETH for USDC.
///
///   tokenIn  = wstETH   (maker gives — sourced from the withdraw item)
///   tokenOut = USDC     (solver gives, maker receives)
///
/// One TAKE item: MorphoBlueWithdrawCollateralModule, routed via `permit3.take` so
/// the taker allowance gate enforces the exact (user, module, ref) amount. Unlike
/// Aave there is NO receipt token to pull — Morpho authorisation + the taker gate
/// is the whole authorization story, and `withdrawCollateral` sends straight to
/// Settlement.
contract WithdrawAndSwapTest is MorphoModulesBase {
    // ──────────────────── Direct fill ────────────────────

    function test_withdraw_collateral_and_swap_morpho() public {
        uint256 wstethIn = 1 ether;
        uint256 usdcOut = 2_000e6;

        _seedCollateral(wstethIn); //          collateral is exact — no cushion needed
        deal(USDC, solver, usdcOut);

        bytes memory takerData = _marketData();
        bytes32 ref = keccak256(takerData);

        _approveMakerWithdrawSide(wstethIn, ref);
        _approveSolverSide(usdcOut, USDC);

        LimitOrder memory order = _buildWithdrawOrder(wstethIn, usdcOut);
        bytes memory sig = _sign(order);

        uint256 makerCollatBefore = _collateral(maker);
        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, wstethIn);

        assertEq(paid, usdcOut, "solver paid exactly usdcOut");
        assertEq(IERC20(USDC).balanceOf(maker) - makerUsdcBefore, usdcOut, "maker received USDC");
        assertEq(makerCollatBefore - _collateral(maker), wstethIn, "maker collateral withdrawn exactly");
        assertEq(IERC20(WSTETH).balanceOf(solver), wstethIn, "solver received wstETH");

        assertEq(IERC20(WSTETH).balanceOf(address(settlement)), 0, "settlement wstETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(WSTETH).balanceOf(address(withdrawModule)), 0, "module wstETH drained");

        (uint160 remaining,,) = permit3.takerAllowance(maker, address(withdrawModule), ref);
        assertEq(remaining, 0, "taker allowance spent");
    }

    // ──────────────────── Single-signature permit fill ────────────────────

    function test_permit_withdraw_collateral_and_swap() public {
        uint256 wstethIn = 1 ether;
        uint256 usdcOut = 2_000e6;

        _seedCollateral(wstethIn);
        deal(USDC, solver, usdcOut);

        // Morpho-native authorisation: not part of the signed batch.
        vm.prank(maker);
        MORPHO.setAuthorization(address(withdrawModule), true);

        bytes memory takerData = _marketData();

        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE,
            module: address(withdrawModule),
            amount: wstethIn,
            recipient: address(0),
            data: takerData
        });

        LimitOrder memory order = _order(maker, 1, WSTETH, USDC, wstethIn, usdcOut, items);

        // Only one token permit needed (the tokenIn shortfall fallback); the
        // withdraw needs no token allowance at all — just the taker permit.
        IPermit3.TokenPermit[] memory tp = new IPermit3.TokenPermit[](1);
        tp[0] = IPermit3.TokenPermit(address(settlement), WSTETH, uint160(wstethIn), uint48(order.deadline));

        IPermit3.PermitBatch memory batch =
            _buildBatch(tp, _takerPermits1(address(settlement), keccak256(takerData), wstethIn), 0, order.deadline);

        bytes memory sig = _signPermitWitness(batch, _hashOrder(order));

        vm.prank(solver);
        settlement.fillWithPermit(order, batch, sig, wstethIn);

        assertEq(IERC20(WSTETH).balanceOf(solver), wstethIn, "solver received wstETH");
        assertEq(IERC20(USDC).balanceOf(maker), usdcOut, "maker received USDC");
    }
}
