// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item} from "@core/settlement/UniversalSettlement.sol";
import {UniversalSettlement} from "@core/settlement/UniversalSettlement.sol";
import {FeeConfig} from "@core/utils/FeeConfig.sol";
import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @dev Optional order-sourcing fee (`Order.feeConfig`): a signed, per-order fee
/// skimmed from the maker's `tokenOut` delivery to a recipient — the party that
/// sourced the order. No admin, no global switch. The solver's total delivery is
/// unchanged; the maker forgoes the fee it signed.
///
///   tokenIn  = USDC   (maker gives, solver receives)
///   tokenOut = WETH   (solver gives, split maker / feeRecipient)
contract SourcingFeeTest is CoreSettlementBase {
    address feeRecipient = address(0xF00DFEE);

    function _feeOrder(uint256 nonce, uint256 usdcIn, uint256 wethOut, uint256 feeBps)
        internal
        view
        returns (Order memory order)
    {
        order = _order(maker, nonce, USDC, WETH, usdcIn, wethOut, new Item[](0));
        order.feeConfig = FeeConfig.pack(feeRecipient, feeBps);
    }

    function _fund(uint256 usdcIn, uint256 wethOut) internal {
        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);
        vm.prank(maker);
        permit3.approveToken(address(settlement), USDC, uint160(usdcIn), 0);
        _approveSolverSide(wethOut, WETH);
    }

    // ── Fee skimmed to the sourcer; solver delivers the same total ──
    function test_fee_skimmedToRecipient() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        uint256 feeBps = 100; // 1%
        _fund(usdcIn, wethOut);

        Order memory order = _feeOrder(0, usdcIn, wethOut, feeBps);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256[] memory outs = settlement.fill(order, sig, usdcIn);

        uint256 fee = wethOut * feeBps / 10_000; // 0.01 WETH
        assertEq(outs[0], wethOut, "outs records GROSS delivery");
        assertEq(IERC20(WETH).balanceOf(maker), wethOut - fee, "maker nets output minus fee");
        assertEq(IERC20(WETH).balanceOf(feeRecipient), fee, "sourcer received the fee");
        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver delivered the full gross amount");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver received full input unchanged");
    }

    // ── Zero feeConfig behaves exactly like no fee ──
    function test_fee_zero_isNoop() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        _fund(usdcIn, wethOut);

        Order memory order = _order(maker, 1, USDC, WETH, usdcIn, wethOut, new Item[](0));
        assertEq(order.feeConfig, bytes32(0), "no fee by default");
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, usdcIn);

        assertEq(IERC20(WETH).balanceOf(maker), wethOut, "maker got full output");
        assertEq(IERC20(WETH).balanceOf(feeRecipient), 0, "no fee paid");
    }

    // ── Fee scales pro-rata across partial fills ──
    function test_fee_partialFills_proRata() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        uint256 feeBps = 250; // 2.5%
        _fund(usdcIn, wethOut);

        Order memory order = _feeOrder(2, usdcIn, wethOut, feeBps);
        bytes memory sig = _sign(order);

        // Half fill → half the output, half the fee.
        vm.prank(solver);
        uint256 half = settlement.fill(order, sig, usdcIn / 2)[0];
        uint256 feeHalf = half * feeBps / 10_000;
        assertEq(IERC20(WETH).balanceOf(feeRecipient), feeHalf, "fee accrues on first partial");
        assertEq(IERC20(WETH).balanceOf(maker), half - feeHalf, "maker nets first partial minus fee");

        // Remainder.
        vm.prank(solver);
        uint256 rest = settlement.fill(order, sig, usdcIn - usdcIn / 2)[0];
        uint256 feeRest = rest * feeBps / 10_000;
        assertEq(IERC20(WETH).balanceOf(feeRecipient), feeHalf + feeRest, "fee accrues across fills");
        assertEq(IERC20(WETH).balanceOf(maker), (half + rest) - (feeHalf + feeRest), "maker nets total minus fees");
    }

    // ── Valid fee exactly at the cap fills and pays the sourcer ──
    function test_fee_atCap_fills() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        uint256 feeBps = FeeConfig.MAX_FEE_BPS; // 10%
        _fund(usdcIn, wethOut);

        Order memory order = _feeOrder(3, usdcIn, wethOut, feeBps);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, usdcIn);

        uint256 fee = wethOut * feeBps / 10_000; // 0.1 WETH
        assertEq(IERC20(WETH).balanceOf(feeRecipient), fee, "sourcer paid at the cap");
        assertEq(IERC20(WETH).balanceOf(maker), wethOut - fee, "maker nets the rest");
    }

    // ── Various valid bps all skim exactly and leave the solver cost unchanged ──
    function test_fee_variousValidBps() public {
        uint16[4] memory bpsCases = [uint16(1), 50, 333, 999];
        for (uint256 i; i < bpsCases.length; i++) {
            uint256 feeBps = bpsCases[i];
            uint256 usdcIn = 2_000e6;
            uint256 wethOut = 1 ether;

            address freshMaker = maker; // reuse maker; new nonce each iteration
            deal(USDC, freshMaker, usdcIn);
            deal(WETH, solver, wethOut);
            vm.prank(freshMaker);
            permit3.approveToken(address(settlement), USDC, uint160(usdcIn), 0);
            _approveSolverSide(wethOut, WETH);

            uint256 recipBefore = IERC20(WETH).balanceOf(feeRecipient);
            uint256 makerBefore = IERC20(WETH).balanceOf(freshMaker);

            Order memory order = _feeOrder(100 + i, usdcIn, wethOut, feeBps);
            bytes memory sig = _sign(order);
            vm.prank(solver);
            settlement.fill(order, sig, usdcIn);

            uint256 fee = wethOut * feeBps / 10_000;
            assertEq(IERC20(WETH).balanceOf(feeRecipient) - recipBefore, fee, "sourcer skim exact");
            assertEq(IERC20(WETH).balanceOf(freshMaker) - makerBefore, wethOut - fee, "maker net exact");
            assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver input unchanged");
            // reset solver USDC for the next iteration's assertion baseline
            deal(USDC, solver, 0);
        }
    }

    // ── Tiny fee that floors to zero: maker keeps everything, sourcer gets 0 ──
    function test_fee_roundsDownToZero() public {
        // amount * bps < 10_000 → fee floors to 0.
        uint256 usdcIn = 1; //     anchor of 1 unit
        uint256 wethOut = 5; //    5 wei out, 1 bps → 5*1/10000 = 0
        uint256 feeBps = 1;
        _fund(usdcIn, wethOut);

        Order memory order = _feeOrder(4, usdcIn, wethOut, feeBps);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, usdcIn);

        assertEq(IERC20(WETH).balanceOf(feeRecipient), 0, "fee floored to zero");
        assertEq(IERC20(WETH).balanceOf(maker), wethOut, "maker keeps full output");
    }

    // ── Fee above MAX_FEE_BPS reverts at fill ──
    function test_fee_aboveMax_reverts() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        _fund(usdcIn, wethOut);

        Order memory order = _feeOrder(5, usdcIn, wethOut, FeeConfig.MAX_FEE_BPS + 1);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(UniversalSettlement.InvalidFee.selector);
        settlement.fill(order, sig, usdcIn);
    }

    // ── Non-zero fee with a zero-address recipient reverts (never burns) ──
    function test_fee_zeroRecipient_reverts() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        _fund(usdcIn, wethOut);

        Order memory order = _order(maker, 6, USDC, WETH, usdcIn, wethOut, new Item[](0));
        order.feeConfig = FeeConfig.pack(address(0), 100); // 1% but no recipient
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(UniversalSettlement.InvalidFee.selector);
        settlement.fill(order, sig, usdcIn);
    }

    // ── A huge packed fee value (high bits) is caught by the cap, not silently used ──
    function test_fee_hugePackedValue_reverts() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        _fund(usdcIn, wethOut);

        Order memory order = _order(maker, 7, USDC, WETH, usdcIn, wethOut, new Item[](0));
        // Max out the high 96 bits → an absurd feeBps, must revert.
        order.feeConfig = FeeConfig.pack(feeRecipient, type(uint96).max);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(UniversalSettlement.InvalidFee.selector);
        settlement.fill(order, sig, usdcIn);
    }

    // ── validateOrder flags an over-cap fee and a recipient-less fee ──
    function test_fee_validateOrder() public view {
        Order memory good = _feeOrder(4, 2_000e6, 1 ether, FeeConfig.MAX_FEE_BPS);
        (bool ok,) = lens.validateOrder(good);
        assertTrue(ok, "fee at the cap is valid");

        Order memory tooHigh = _feeOrder(5, 2_000e6, 1 ether, FeeConfig.MAX_FEE_BPS + 1);
        (bool ok2, string memory reason2) = lens.validateOrder(tooHigh);
        assertFalse(ok2, "over-cap fee rejected");
        assertEq(reason2, "feeBps > MAX_FEE_BPS");

        Order memory noRecipient = _order(maker, 6, USDC, WETH, 2_000e6, 1 ether, new Item[](0));
        noRecipient.feeConfig = FeeConfig.pack(address(0), 100); // bps set, recipient zero
        (bool ok3, string memory reason3) = lens.validateOrder(noRecipient);
        assertFalse(ok3, "fee without recipient rejected");
        assertEq(reason3, "fee set without recipient");
    }
}
