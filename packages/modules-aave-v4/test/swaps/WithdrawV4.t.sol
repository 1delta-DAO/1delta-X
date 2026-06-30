// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order} from "@core/settlement/UniversalSettlement.sol";

import {ISpokeV4} from "../../src/interfaces/IAaveV4.sol";
import {AaveV4ModulesBase} from "../shared/AaveV4ModulesBase.t.sol";

/// @dev Aave v4 withdraw + swap: maker already has a WETH collateral position,
/// unwinds WETH and sells it for USDC.
///
///   tokenIn  = WETH   (maker gives — sourced from the withdraw item)
///   tokenOut = USDC   (solver gives, maker receives)
///
/// One TAKE item: AaveV4WithdrawModule, routed via `permit3.take` so the taker
/// allowance gate enforces the exact (user, module, ref) amount. The
/// TakerPositionManager has no receiver, so the withdrawn WETH lands in the
/// module and is forwarded to Settlement.
contract WithdrawV4Test is AaveV4ModulesBase {
    function test_withdraw_and_swap_aaveV4() public {
        uint256 wethIn = 1 ether;
        uint256 usdcOut = 2_000e6;

        _seedV4WethPosition(wethIn + 1e15); // +0.001 WETH cushion for scaled rounding
        deal(USDC, solver, usdcOut);

        bytes memory takerData = abi.encode(MAIN_SPOKE, TAKER_PM, wethReserveId, WETH);
        bytes32 ref = keccak256(takerData);

        _approveMakerWithdrawSide(wethIn, ref);
        _approveSolverSide(usdcOut, USDC);

        Order memory order = _buildV4WithdrawOrder(wethIn, usdcOut, takerData);
        bytes memory sig = _sign(order);

        uint256 suppliedBefore = ISpokeV4(MAIN_SPOKE).getUserSuppliedAssets(wethReserveId, maker);
        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, wethIn);

        assertEq(paid, usdcOut, "solver paid exactly usdcOut");
        assertEq(IERC20(USDC).balanceOf(maker) - makerUsdcBefore, usdcOut, "maker received USDC");
        assertApproxEqAbs(
            suppliedBefore - ISpokeV4(MAIN_SPOKE).getUserSuppliedAssets(wethReserveId, maker),
            wethIn,
            2,
            "maker collateral withdrawn"
        );
        assertEq(IERC20(WETH).balanceOf(solver), wethIn, "solver received WETH");

        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(WETH).balanceOf(address(withdrawModule)), 0, "module WETH drained");

        (uint160 remaining,,) = permit3.takerAllowance(maker, address(withdrawModule), ref);
        assertEq(remaining, 0, "taker allowance spent");
    }
}
