// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order} from "@core/settlement/UniversalSettlement.sol";
import {FeeConfig} from "@core/utils/FeeConfig.sol";

import {AaveModulesBase} from "../shared/AaveModulesBase.t.sol";

/// @dev Withdraw + sourcing fee: the "integrator exit fee" flow. The maker
/// unwinds an aWETH position; the originator's charge (e.g. an off-chain
/// computed interest margin, converted to bps at order creation) is signed into
/// `feeConfig` and skimmed from the maker's USDC payout. The TAKE withdraw item
/// runs untouched — only the conversion delivery is split maker/sourcer.
///
///   tokenIn  = WETH   (maker gives — sourced from the withdraw item)
///   tokenOut = USDC   (solver gives gross → split maker/sourcer)
contract WithdrawWithFeeTest is AaveModulesBase {
    address feeRecipient = address(0x50FCE);

    function test_withdraw_withSourcingFee_aaveV3() public {
        uint256 wethIn = 1 ether;
        uint256 usdcOut = 2_000e6; //          solver delivers this gross
        uint256 feeBps = 250; //               2.5% — stands in for the exit margin
        uint256 fee = usdcOut * feeBps / 10_000; // 50 USDC to the sourcer
        uint256 makerNet = usdcOut - fee;

        _seedAWethPosition(wethIn + 1e15); // +0.001 WETH cushion for scaled rounding
        deal(USDC, solver, usdcOut);

        bytes memory takerData = abi.encode(AAVE_POOL, WETH, aWETH);
        bytes32 ref = keccak256(takerData);

        _approveMakerWithdrawSide(wethIn, ref, takerData);
        _approveSolverSide(usdcOut, USDC);

        Order memory order = _buildWithdrawOrder(wethIn, usdcOut, takerData);
        order.feeConfig = FeeConfig.pack(feeRecipient, feeBps);
        bytes memory sig = _sign(order);

        uint256 makerAWethBefore = IERC20(aWETH).balanceOf(maker);
        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, wethIn)[0];

        // Solver still pays the full gross output; only the split changed.
        assertEq(paid, usdcOut, "solver paid full gross usdcOut");
        assertEq(IERC20(USDC).balanceOf(maker) - makerUsdcBefore, makerNet, "maker received net of fee");
        assertEq(IERC20(USDC).balanceOf(feeRecipient), fee, "sourcer received the fee");

        // Withdraw leg untouched by the fee: full position slice unwound.
        assertApproxEqAbs(makerAWethBefore - IERC20(aWETH).balanceOf(maker), wethIn, 2, "maker aWETH burned");
        assertEq(IERC20(WETH).balanceOf(solver), wethIn, "solver received WETH");

        // Nothing stranded: settlement/module empty, taker allowance spent.
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(aWETH).balanceOf(address(withdrawModule)), 0, "module aWETH drained");

        (uint160 remaining,,) = permit3.takerAllowance(maker, address(withdrawModule), ref);
        assertEq(remaining, 0, "taker allowance spent");
    }

    /// @dev Two half fills: the withdraw item slices and the fee skim must scale
    /// by the same fill fraction, so the sourcer accumulates exactly the full-fill
    /// fee once the order completes.
    function test_withdraw_withSourcingFee_partialFills_aaveV3() public {
        uint256 wethIn = 1 ether;
        uint256 usdcOut = 2_000e6;
        uint256 feeBps = 250;
        uint256 fee = usdcOut * feeBps / 10_000;

        _seedAWethPosition(wethIn + 1e15);
        deal(USDC, solver, usdcOut);

        bytes memory takerData = abi.encode(AAVE_POOL, WETH, aWETH);
        bytes32 ref = keccak256(takerData);

        _approveMakerWithdrawSide(wethIn, ref, takerData);
        _approveSolverSide(usdcOut, USDC);

        Order memory order = _buildWithdrawOrder(wethIn, usdcOut, takerData);
        order.feeConfig = FeeConfig.pack(feeRecipient, feeBps);
        bytes memory sig = _sign(order);

        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);

        // First half: fee skims pro-rata on the delivered slice.
        vm.prank(solver);
        settlement.fill(order, sig, wethIn / 2);
        assertEq(IERC20(USDC).balanceOf(feeRecipient), fee / 2, "half fee after half fill");
        assertEq(IERC20(USDC).balanceOf(maker) - makerUsdcBefore, (usdcOut - fee) / 2, "maker net half");

        // Second half completes the order: totals match the full-fill split exactly.
        vm.prank(solver);
        settlement.fill(order, sig, wethIn / 2);
        assertEq(IERC20(USDC).balanceOf(feeRecipient), fee, "full fee accumulated");
        assertEq(IERC20(USDC).balanceOf(maker) - makerUsdcBefore, usdcOut - fee, "maker net full");
        assertEq(IERC20(WETH).balanceOf(solver), wethIn, "solver received all WETH");

        (uint160 remaining,,) = permit3.takerAllowance(maker, address(withdrawModule), ref);
        assertEq(remaining, 0, "taker allowance fully spent");

        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
    }
}
