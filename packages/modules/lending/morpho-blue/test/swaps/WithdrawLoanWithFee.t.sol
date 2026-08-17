// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {MorphoModulesBase} from "../shared/MorphoModulesBase.t.sol";

/// @dev Loan-deposit exit + sourcing fee: the "integrator earn product" flow.
/// The maker has USDC supplied as LOAN asset (earning interest); on exit the
/// originator's charge (an off-chain computed interest margin, converted to bps
/// at order creation) is signed in as a fee OUTPUT LEG split off the maker's
/// payout. Same-asset pass-through — no conversion, the solver's compensation is
/// the in/out spread:
///
///   tokenIn  = USDC   (maker gives — sourced from the loan-withdraw item)
///   tokenOut = USDC   (solver gives gross → split maker/sourcer)
///
/// One TAKE item: MorphoBlueTakerModule (op=Withdraw, the loan leg), routed via
/// `permit3.take`. Morpho authorisation + the taker gate is the whole story —
/// the supply position is not tokenised.
contract WithdrawLoanWithFeeTest is MorphoModulesBase {
    address feeRecipient = address(0x50FCE);

    function _buildLoanWithdrawOrder(uint256 usdcIn, uint256 usdcOut) internal view returns (Order memory order) {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE,
            module: address(takerModule),
            amount: usdcIn,
            recipient: address(0),
            data: _loanWithdrawData()
        });
        order = _order(maker, 1, USDC, USDC, usdcIn, usdcOut, items);
    }

    function _approveMakerLoanWithdrawSide(uint256 usdcIn, bytes32 ref) internal {
        vm.startPrank(maker);
        // Fallback for the tokenIn shortfall — never triggers in this flow.
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDC, uint160(usdcIn), 0);
        // Morpho-native authorisation for the combined taker module; the taker
        // allowance is the only per-fill cap (no receipt token to pull).
        MORPHO.setAuthorization(address(takerModule), true);
        permit3.approveTaker(address(settlement), address(takerModule), ref, uint160(usdcIn), 0);
        vm.stopPrank();
    }

    function test_withdrawLoan_withSourcingFee_morpho() public {
        uint256 usdcIn = 2_000e6; //           unwound from the supply position
        uint256 usdcOut = 1_990e6; //          solver delivers gross (10 USDC spread)
        uint256 feeBps = 250; //               2.5% — stands in for the exit margin
        uint256 fee = usdcOut * feeBps / 10_000; // 49.75 USDC to the sourcer
        uint256 makerNet = usdcOut - fee;

        _seedLoanSupply(usdcIn + 1e6); //      +1 USDC cushion for share rounding
        deal(USDC, solver, usdcOut);

        bytes32 ref = keccak256(_loanWithdrawData());
        _approveMakerLoanWithdrawSide(usdcIn, ref);
        _approveSolverSide(usdcOut, USDC);

        Order memory order = _buildLoanWithdrawOrder(usdcIn, usdcOut);
        _splitFeeLeg(order, feeRecipient, fee); // fee as its own output leg
        bytes memory sig = _sign(order);

        uint256 makerSupplyBefore = _supplyAssets(maker);
        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);

        vm.prank(solver);
        uint256[] memory outs = settlement.fill(order, sig, usdcIn);

        // Solver still pays the full gross output; only the split changed.
        assertEq(outs[0] + outs[1], usdcOut, "solver paid full gross usdcOut");
        assertEq(IERC20(USDC).balanceOf(maker) - makerUsdcBefore, makerNet, "maker received net of fee");
        assertEq(IERC20(USDC).balanceOf(feeRecipient), fee, "sourcer received the fee");

        // Withdraw leg untouched by the fee: supply position down by the order slice.
        assertApproxEqAbs(makerSupplyBefore - _supplyAssets(maker), usdcIn, 2, "maker supply unwound");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver received the withdrawn USDC");

        // Nothing stranded: settlement/module empty, taker allowance spent.
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(USDC).balanceOf(address(takerModule)), 0, "module USDC drained");

        (uint160 remaining,) = permit3.takerAllowance(maker, address(settlement), address(takerModule), ref);
        assertEq(remaining, 0, "taker allowance spent");
    }

    /// @dev Two half fills: the loan-withdraw item slices and the fee skim must
    /// scale by the same fill fraction, so the sourcer accumulates exactly the
    /// full-fill fee once the order completes.
    function test_withdrawLoan_withSourcingFee_partialFills_morpho() public {
        uint256 usdcIn = 2_000e6;
        uint256 usdcOut = 1_990e6;
        uint256 feeBps = 250;
        uint256 fee = usdcOut * feeBps / 10_000;

        _seedLoanSupply(usdcIn + 1e6);
        deal(USDC, solver, usdcOut);

        bytes32 ref = keccak256(_loanWithdrawData());
        _approveMakerLoanWithdrawSide(usdcIn, ref);
        _approveSolverSide(usdcOut, USDC);

        Order memory order = _buildLoanWithdrawOrder(usdcIn, usdcOut);
        _splitFeeLeg(order, feeRecipient, fee); // fee as its own output leg
        bytes memory sig = _sign(order);

        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);

        // First half: fee skims pro-rata on the delivered slice.
        vm.prank(solver);
        settlement.fill(order, sig, usdcIn / 2);
        assertEq(IERC20(USDC).balanceOf(feeRecipient), fee / 2, "half fee after half fill");
        assertEq(IERC20(USDC).balanceOf(maker) - makerUsdcBefore, (usdcOut - fee) / 2, "maker net half");

        // Second half completes the order: totals match the full-fill split exactly.
        vm.prank(solver);
        settlement.fill(order, sig, usdcIn / 2);
        assertEq(IERC20(USDC).balanceOf(feeRecipient), fee, "full fee accumulated");
        assertEq(IERC20(USDC).balanceOf(maker) - makerUsdcBefore, usdcOut - fee, "maker net full");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver received all withdrawn USDC");

        (uint160 remaining,) = permit3.takerAllowance(maker, address(settlement), address(takerModule), ref);
        assertEq(remaining, 0, "taker allowance fully spent");

        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
    }
}
