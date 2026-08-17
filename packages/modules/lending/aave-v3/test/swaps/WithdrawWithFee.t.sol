// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, OrderSide, Validator, LegIn, LegOut} from "@core/settlement/Settlement.sol";
import {AaveModulesBase} from "../shared/AaveModulesBase.t.sol";

/// @dev Withdraw + sourcing fee: the "integrator exit fee" flow. The maker
/// unwinds an aWETH position; the originator's charge (e.g. an off-chain
/// computed interest margin, priced at order creation) is signed in as a fee
/// OUTPUT LEG addressed to the sourcer. The TAKE withdraw item runs untouched —
/// only the conversion delivery is split maker/sourcer.
///
///   tokenIn  = WETH   (maker gives — sourced from the withdraw item)
///   tokenOut = USDC   [net → maker, fee → sourcer]
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
        _splitFeeLeg(order, feeRecipient, fee); // fee as its own output leg
        bytes memory sig = _sign(order);

        uint256 makerAWethBefore = IERC20(aWETH).balanceOf(maker);
        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);

        vm.prank(solver);
        uint256[] memory outs = settlement.fill(order, sig, wethIn);

        // Solver still pays the full gross output; only the split changed.
        assertEq(outs[0] + outs[1], usdcOut, "solver paid full gross usdcOut");
        assertEq(IERC20(USDC).balanceOf(maker) - makerUsdcBefore, makerNet, "maker received net of fee");
        assertEq(IERC20(USDC).balanceOf(feeRecipient), fee, "sourcer received the fee");

        // Withdraw leg untouched by the fee: full position slice unwound.
        assertApproxEqAbs(makerAWethBefore - IERC20(aWETH).balanceOf(maker), wethIn, 2, "maker aWETH burned");
        assertEq(IERC20(WETH).balanceOf(solver), wethIn, "solver received WETH");

        // Nothing stranded: settlement/module empty, taker allowance spent.
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(aWETH).balanceOf(address(withdrawModule)), 0, "module aWETH drained");

        (uint160 remaining,) = permit3.takerAllowance(maker, address(settlement), address(withdrawModule), ref);
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
        _splitFeeLeg(order, feeRecipient, fee); // fee as its own output leg
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

        (uint160 remaining,) = permit3.takerAllowance(maker, address(settlement), address(withdrawModule), ref);
        assertEq(remaining, 0, "taker allowance fully spent");

        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
    }

    /// @dev Zero-capital exit: the non-conversion withdrawal. The TAKE item routes
    /// the withdrawn WETH STRAIGHT to the maker's wallet (`recipient = maker`) and
    /// the relayer's compensation is a rising same-asset fee leg — no `tokenOut`,
    /// so the relayer fronts NOTHING (no inventory, no flash) and just collects
    /// the auction-tick fee. Ordering makes the fee self-funding: items execute
    /// before `_payInputsToSolver`, so the withdrawal lands in the maker's wallet
    /// first and the fee is pulled out of it.
    function test_withdrawToWallet_withRisingFee_aaveV3() public {
        uint256 wethOut = 1 ether; //  withdrawn straight to the maker
        uint256 feeFloor = 1e15; //    0.001 WETH — auction start
        uint256 feeCeil = 3e15; //     auction end (worst for maker)
        uint32 duration = 1000;

        _seedAWethPosition(wethOut + 1e15);
        // Maker starts with an EMPTY WETH wallet — the fee can only come from
        // the withdrawal itself.
        assertEq(IERC20(WETH).balanceOf(maker), 0, "maker wallet empty pre-fill");

        bytes memory takerData = abi.encode(AAVE_POOL, WETH, aWETH);
        bytes32 ref = keccak256(takerData);
        _approveMakerWithdrawSide(wethOut, ref, takerData); // includes settlement WETH allowance ≥ ceil

        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE,
            module: address(withdrawModule),
            amount: wethOut,
            recipient: maker, //        straight to the wallet — never touches settlement
            data: takerData
        });
        Order memory order = Order({
            params: 0,
            pricingModule: address(0),
            maker: maker,
            nonce: 31,
            deadline: block.timestamp + 1 hours,
            legsIn: _legsIn1Rising(WETH, feeFloor, feeCeil),
            legsOut: PackedEncode.legsOut(new LegOut[](0)),
            timing: _packTiming(uint32(block.timestamp), uint32(duration), 0),
            exclusiveFiller: address(0),
            minFillAnchor: 0,
            curve: _noCurve(),
            items: PackedEncode.items(items),
            validators: PackedEncode.noValidators(),
            invariants: PackedEncode.noValidators(),
            fillModule: address(0),
            fillTotal: 0
        });
        bytes memory sig = _sign(order);

        vm.warp(block.timestamp + duration / 2); // bump = 5000
        uint256 fee = feeFloor + (feeCeil - feeFloor) / 2; // 2e15

        vm.prank(solver);
        settlement.fill(order, sig, feeFloor);

        // Maker holds the withdrawal minus the fee; the relayer fronted nothing.
        assertEq(IERC20(WETH).balanceOf(maker), wethOut - fee, "maker nets withdrawal minus fee");
        assertEq(IERC20(WETH).balanceOf(solver), fee, "relayer earned the auction-tick fee");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement never held the withdrawal");

        (uint160 remaining,) = permit3.takerAllowance(maker, address(settlement), address(withdrawModule), ref);
        assertEq(remaining, 0, "taker allowance spent");
    }
}
