// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {IComet} from "../../src/interfaces/ICompoundV3.sol";
import {CompoundV3ModulesBase} from "../shared/CompoundV3ModulesBase.t.sol";

/// @dev Base-deposit exit + sourcing fee: the "integrator earn product" flow.
/// The maker has USDC supplied as BASE asset (earning interest); on exit the
/// originator's charge (an off-chain computed interest margin, converted to bps
/// at order creation) is signed in as a fee OUTPUT LEG split off the maker's
/// payout. Same-asset pass-through — no conversion, the solver's compensation is
/// the in/out spread:
///
///   tokenIn  = USDC   (maker gives — sourced from the base-withdraw item)
///   tokenOut = USDC   (solver gives gross → split maker/sourcer)
///
/// One TAKE item: CometTakerModule (op=Withdraw, asset = the base token) —
/// `withdrawFrom` on a positive base balance IS the deposit withdrawal; the
/// no-debt assertion pins that it never tips over into a borrow.
contract WithdrawWithFeeTest is CompoundV3ModulesBase {
    address feeRecipient = address(0x50FCE);

    function _buildBaseWithdrawOrder(uint256 usdcIn, uint256 usdcOut, bytes memory takerData)
        internal
        view
        returns (Order memory order)
    {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE, module: address(takerModule), amount: usdcIn, recipient: address(0), data: takerData
        });
        order = _order(maker, 1, USDC, USDC, usdcIn, usdcOut, items);
    }

    function _approveMakerBaseWithdrawSide(uint256 usdcIn, bytes32 ref) internal {
        vm.startPrank(maker);
        // Fallback for the tokenIn shortfall — never triggers in this flow.
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDC, uint160(usdcIn), 0);
        // `comet.allow(takerModule)` (set in setUp) is the protocol-native gate;
        // the Permit3 taker allowance caps the fill on the exact position.
        permit3.approveTaker(address(settlement), ref, uint160(usdcIn), 0);
        vm.stopPrank();
    }

    function test_withdrawBase_withSourcingFee_cometV3() public {
        uint256 usdcIn = 2_000e6; //           unwound from the base position
        uint256 usdcOut = 1_990e6; //          solver delivers gross (10 USDC spread)
        uint256 feeBps = 250; //               2.5% — stands in for the exit margin
        uint256 fee = usdcOut * feeBps / 10_000; // 49.75 USDC to the sourcer
        uint256 makerNet = usdcOut - fee;

        _seedBaseSupply(usdcIn + 1e6); //      +1 USDC cushion for principal rounding
        deal(USDC, solver, usdcOut);

        bytes memory takerData = _withdrawData(COMET, USDC);
        bytes32 ref = keccak256(takerData);

        _approveMakerBaseWithdrawSide(usdcIn, ref);
        _approveSolverSide(usdcOut, USDC);

        Order memory order = _buildBaseWithdrawOrder(usdcIn, usdcOut, takerData);
        _splitFeeLeg(order, feeRecipient, fee); // fee as its own output leg
        bytes memory sig = _sign(order);

        // Same-asset overlap (tokenIn == tokenOut == USDC) with items is a valid
        // shape — pinned here against the lens (it used to false-negative it).
        // Block-scoped: keeps the locals off the stack for the fill below.
        {
            (bool okLens, string memory lensReason) = lens.validateOrder(order);
            assertTrue(okLens, string.concat("same-asset exit validates: ", lensReason));
        }

        uint256 makerSupplyBefore = _baseSupply(maker);
        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);

        vm.prank(solver);
        uint256[] memory outs = settlement.fill(order, sig, usdcIn);

        // Solver still pays the full gross output; only the split changed.
        assertEq(outs[0] + outs[1], usdcOut, "solver paid full gross usdcOut");
        assertEq(IERC20(USDC).balanceOf(maker) - makerUsdcBefore, makerNet, "maker received net of fee");
        assertEq(IERC20(USDC).balanceOf(feeRecipient), fee, "sourcer received the fee");

        // Withdraw leg untouched by the fee: base position down by the order
        // slice, and it stayed a withdrawal — never flipped into a borrow.
        assertApproxEqAbs(makerSupplyBefore - _baseSupply(maker), usdcIn, 2, "maker base supply unwound");
        assertEq(IComet(COMET).borrowBalanceOf(maker), 0, "no debt opened");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver received the withdrawn USDC");

        // Nothing stranded: settlement/module empty, taker allowance spent.
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(USDC).balanceOf(address(takerModule)), 0, "module USDC drained");

        (uint160 remaining,,) = permit3.takerAllowance(maker, address(takerModule), ref);
        assertEq(remaining, 0, "taker allowance spent");
    }

    /// @dev Two half fills: the base-withdraw item slices and the fee skim must
    /// scale by the same fill fraction, so the sourcer accumulates exactly the
    /// full-fill fee once the order completes.
    function test_withdrawBase_withSourcingFee_partialFills_cometV3() public {
        uint256 usdcIn = 2_000e6;
        uint256 usdcOut = 1_990e6;
        uint256 feeBps = 250;
        uint256 fee = usdcOut * feeBps / 10_000;

        _seedBaseSupply(usdcIn + 1e6);
        deal(USDC, solver, usdcOut);

        bytes memory takerData = _withdrawData(COMET, USDC);
        bytes32 ref = keccak256(takerData);

        _approveMakerBaseWithdrawSide(usdcIn, ref);
        _approveSolverSide(usdcOut, USDC);

        Order memory order = _buildBaseWithdrawOrder(usdcIn, usdcOut, takerData);
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
        assertEq(IComet(COMET).borrowBalanceOf(maker), 0, "no debt opened");

        (uint160 remaining,,) = permit3.takerAllowance(maker, address(takerModule), ref);
        assertEq(remaining, 0, "taker allowance fully spent");

        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
    }
}
