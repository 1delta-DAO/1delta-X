// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "../../../src/interfaces/IPermit3.sol";
import {LimitOrder, Item, ItemOp} from "../../../src/settlement/LimitOrderSettlement.sol";

import {LimitOrderSettlementBase} from "../shared/LimitOrderSettlementBase.t.sol";

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
contract WithdrawAndSwapTest is LimitOrderSettlementBase {
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

        LimitOrder memory order = _buildWithdrawOrder(wethIn, usdcOut, takerData);
        bytes memory sig = _sign(order);

        uint256 makerAWethBefore = IERC20(aWETH).balanceOf(maker);
        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, wethIn);

        assertEq(paid, usdcOut, "solver paid exactly usdcOut");
        assertEq(IERC20(USDC).balanceOf(maker) - makerUsdcBefore, usdcOut, "maker received USDC");
        assertApproxEqAbs(makerAWethBefore - IERC20(aWETH).balanceOf(maker), wethIn, 2, "maker aWETH burned");
        assertEq(IERC20(WETH).balanceOf(solver), wethIn, "solver received WETH");

        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(aWETH).balanceOf(address(withdrawModule)), 0, "module aWETH drained");

        (uint160 remaining,,) = permit3.takerAllowance(maker, address(withdrawModule), ref);
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
            op: ItemOp.TAKE,
            module: address(withdrawModule),
            amount: wethIn,
            recipient: address(0),
            data: takerData
        });

        LimitOrder memory order = _order(maker, 1, WETH, USDC, wethIn, usdcOut, items);

        IPermit3.PermitBatch memory batch = _buildBatch(
            _tokenPermitsWithTaker(address(settlement), WETH, wethIn, address(withdrawModule), aWETH, wethIn),
            _takerPermits1(address(withdrawModule), keccak256(takerData), wethIn),
            0,
            order.deadline
        );

        bytes memory sig = _signPermitWitness(batch, _hashOrder(order));

        vm.prank(solver);
        settlement.fillWithPermit(order, batch, sig, wethIn);

        assertEq(IERC20(WETH).balanceOf(solver), wethIn, "solver received WETH");
        assertEq(IERC20(USDC).balanceOf(maker), usdcOut, "maker received USDC");
    }
}
