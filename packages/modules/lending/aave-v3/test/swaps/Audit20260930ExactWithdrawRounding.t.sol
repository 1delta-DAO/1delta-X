// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order} from "@core/settlement/Settlement.sol";

import {IAaveV3Pool} from "../../src/interfaces/IAaveV3.sol";
import {AaveModulesBase} from "../shared/AaveModulesBase.t.sol";

/// @title Audit20260930ExactWithdrawRoundingTest
/// @notice 2026-09-30 audit, L-AAVE-1 / G-VENUE_B-3 — against the LIVE Aave v3
///         mainnet pool at the harness's pinned block (22,000,000), which still runs
///         PRE-v3.5 math: an aToken transfer moves `rayDiv(amount, index)` scaled
///         units rounded HALF-UP and `withdraw` checks `amount <=
///         rayMul(scaled, index)`. For ~(1 - RAY/index)/2 of all amounts that round
///         trip is `amount - 1`, and the `Exact` withdraw — pull exactly `amount`,
///         withdraw exactly `amount` — reverted `NOT_ENOUGH_AVAILABLE_USER_BALANCE`
///         every time. Spark and other v3 forks on pre-3.5 code share the shape.
///
///         The test derives a failing amount from the LIVE index with the venue's
///         own half-up formulas, then fills an Exact withdraw of it.
contract Audit20260930ExactWithdrawRoundingTest is AaveModulesBase {
    uint256 constant RAY = 1e27;

    function _rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b + RAY / 2) / RAY;
    }

    function _rayDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * RAY + b / 2) / b;
    }

    /// First amount at or above `from` whose half-up round trip loses a wei.
    function _badAmount(uint256 index, uint256 from) internal pure returns (uint256 a) {
        for (a = from; a < from + 100_000; ++a) {
            if (_rayMul(_rayDiv(a, index), index) < a) return a;
        }
        revert("no rounding-window amount found");
    }

    function test_audit_L_AAVE_1_exactWithdraw_roundingWindowAmount_fills() public {
        _seedAWethPosition(5 ether);
        uint256 index = IAaveV3Pool(AAVE_POOL).getReserveNormalizedIncome(WETH);
        assertGt(index, RAY, "index above RAY");
        uint256 wethIn = _badAmount(index, 1 ether);
        // Sanity: this IS the venue-rejected amount under the pre-fix pull.
        assertEq(_rayMul(_rayDiv(wethIn, index), index), wethIn - 1, "half-up round trip loses one wei");

        uint256 usdcOut = 1_500e6;
        bytes memory data = abi.encode(AAVE_POOL, WETH, aWETH);
        _approveMakerWithdrawSide(wethIn, keccak256(data), data);
        deal(USDC, solver, usdcOut);
        _approveSolverSide(usdcOut, USDC);

        Order memory order = _buildWithdrawOrder(wethIn, usdcOut, data);
        bytes memory sig = _sign(order);
        uint256 aBefore = IERC20(aWETH).balanceOf(maker);

        vm.prank(solver);
        settlement.fill(order, sig, wethIn);

        assertEq(IERC20(WETH).balanceOf(solver), wethIn, "solver received exactly the signed WETH");
        assertEq(IERC20(USDC).balanceOf(maker), usdcOut, "maker paid at the signed price");
        // The position paid `wethIn` (+ at most the top-up's sub-scaled-unit dust).
        assertApproxEqAbs(aBefore - IERC20(aWETH).balanceOf(maker), wethIn, 2, "position down by the amount");
        assertEq(IERC20(aWETH).balanceOf(address(withdrawModule)), 0, "module returns the top-up surplus");
        assertEq(IERC20(WETH).balanceOf(address(withdrawModule)), 0, "module holds no underlying");
    }

    /// A batch of consecutive window amounts, as distinct partial slices of one
    /// order — each slice is an independent Exact pull, so each must clear.
    function test_audit_L_AAVE_1_exactWithdraw_windowSlices_allFill() public {
        _seedAWethPosition(5 ether);
        uint256 index = IAaveV3Pool(AAVE_POOL).getReserveNormalizedIncome(WETH);
        uint256 s1 = _badAmount(index, 0.4 ether);
        uint256 s2 = _badAmount(index, 0.9 ether);
        uint256 total = s1 + s2;

        bytes memory data = abi.encode(AAVE_POOL, WETH, aWETH);
        _approveMakerWithdrawSide(total, keccak256(data), data);
        deal(USDC, solver, 10_000e6);
        _approveSolverSide(10_000e6, USDC);

        Order memory order = _buildWithdrawOrder(total, 3_000e6, data);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, s1);
        vm.prank(solver);
        settlement.fill(order, sig, s2);

        assertEq(IERC20(WETH).balanceOf(solver), total, "both window slices filled");
        assertEq(IERC20(aWETH).balanceOf(address(withdrawModule)), 0, "module ends empty");
    }
}
