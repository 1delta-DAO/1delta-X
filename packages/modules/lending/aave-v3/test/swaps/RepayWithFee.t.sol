// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, OrderSide, Validator, LegIn, LegOut} from "@core/settlement/Settlement.sol";

import {AaveModulesBase} from "../shared/AaveModulesBase.t.sol";

/// @dev Gasless self-repay + relayer fee — the MAKE-action mirror of the deposit
/// flow. The maker closes their own USDC debt using their own USDC (the repay
/// module pulls it), with no conversion; there's no output to price a filler's
/// compensation into, so the order carries a rising `tokenIn` fee leg
/// (`startAmountIn < endAmountIn`) that auction-discovers the relayer's
/// gas + margin. Structurally identical to {DepositWithFeeTest}, with a repay
/// MAKE item instead of a deposit.
///
///   items    = [ MAKE AaveV3RepayModule: repay the debt ]
///   tokenIn  = USDC, F0 → FMAX rising    (the relayer fee, maker pays)
///   tokenOut = —                          (empty; nothing delivered back)
contract RepayWithFeeTest is AaveModulesBase {
    uint256 constant DEBT = 3_000e6; //     the maker's USDC debt to close
    uint256 constant BUFFER = 50e6; //      over-repay buffer for accrual
    uint256 constant F0 = 1e6; //           fee floor (auction start)
    uint256 constant FMAX = 5e6; //         fee ceiling (auction end)
    uint32 constant DURATION = 1000;

    function _buildRepayFeeOrder(uint256 nonce) internal view returns (Order memory order) {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(repayModule),
            amount: DEBT + BUFFER, //  ceiling; SweepToUser pulls only min(amount, live debt)
            recipient: address(0),
            data: abi.encode(AAVE_POOL, USDC, uint256(2), usdcDebtToken)
        });
        order = Order({
            params: 0,
            pricingModule: address(0),
            maker: maker,
            nonce: nonce,
            deadline: block.timestamp + 1 hours,
            legsIn: _legsIn1Rising(USDC, F0, FMAX),
            legsOut: PackedEncode.legsOut(new LegOut[](0)),
            timing: _packTiming(uint32(block.timestamp), uint32(DURATION), 0),
            exclusiveFiller: address(0),
            minFillAnchor: F0, //      full-fill only (repay is not partial-friendly here)
            curve: _noCurve(),
            items: PackedEncode.items(items),
            validators: PackedEncode.noValidators(),
            invariants: PackedEncode.noValidators(),
            fillModule: address(0),
            fillTotal: 0
        });
    }

    function _approveMakerRepayFeeSide() internal {
        vm.startPrank(maker);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        // Repay module pulls the maker's USDC to close the debt.
        permit3.approveToken(address(repayModule), USDC, uint160(DEBT + BUFFER), 0);
        // Settlement pulls the rising fee leg — cap at the auction ceiling.
        permit3.approveToken(address(settlement), USDC, uint160(FMAX), 0);
        vm.stopPrank();
    }

    function test_repay_withRisingFee_aaveV3() public {
        _openUsdcDebt(DEBT); //           maker owes DEBT USDC, wallet dumped to 0
        deal(USDC, maker, DEBT + BUFFER + FMAX); // fund the repay + the fee
        _approveMakerRepayFeeSide();

        uint256 debtBefore = IERC20(usdcDebtToken).balanceOf(maker);
        assertGt(debtBefore, 0, "maker has debt pre-fill");
        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);

        Order memory order = _buildRepayFeeOrder(1);
        bytes memory sig = _sign(order);

        vm.warp(block.timestamp + DURATION / 2); // bump = 5000
        uint256 fee = F0 + (FMAX - F0) / 2; //      3e6

        vm.prank(solver);
        settlement.fill(order, sig, F0);

        // Debt closed; the relayer earned exactly the risen tick.
        assertEq(IERC20(usdcDebtToken).balanceOf(maker), 0, "debt zeroed");
        assertEq(IERC20(USDC).balanceOf(solver), fee, "relayer earned the auction-tick fee");
        // Maker spent: the repaid debt (+ tiny accrual) + the fee; dust refunded.
        uint256 spent = makerUsdcBefore - IERC20(USDC).balanceOf(maker);
        assertApproxEqAbs(spent, debtBefore + fee, 1e6, "maker spent debt + fee (dust refunded)");

        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "repay module drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement drained");
    }
}
