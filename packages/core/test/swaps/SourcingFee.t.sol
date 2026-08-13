// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "../shared/PackedEncode.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, LegIn, LegOut, OrderSide, Validator} from "@core/settlement/Settlement.sol";
import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @dev Originator/sourcing fee as an OUTPUT LEG: every output leg names its own
/// `recipient` (0 = maker), so the party that sourced the order is paid by
/// simply adding one more signed leg. A bps-of-tick fee is a leg whose
/// start/end decay in proportion to the main leg; an absolute fee is a fixed
/// leg. No fee subsystem, no admin — the fee is ordinary delivery.
///
///   tokenIn  = USDC   (maker gives, solver receives)
///   tokenOut = WETH   [leg 0 → maker, leg 1 → feeRecipient]
contract SourcingFeeTest is CoreSettlementBase {
    address feeRecipient = address(0xF00DFEE);

    /// @dev Two-leg output: `wethOut - fee` to the maker, `fee` to the sourcer.
    ///      Both fixed (SELL with no decay) unless the test mutates them.
    function _feeLegOrder(uint256 nonce, uint256 usdcIn, uint256 wethOut, uint256 fee)
        internal
        view
        returns (Order memory order)
    {
        order = _order(maker, nonce, USDC, WETH, usdcIn, wethOut, new Item[](0));
        LegOut[] memory _tmplegsOut = new LegOut[](2);
        _tmplegsOut[0] = LegOut(WETH, wethOut - fee, 0, address(0)); // maker
        _tmplegsOut[1] = LegOut(WETH, fee, 0, feeRecipient); //         sourcer
        order.legsOut = PackedEncode.legsOut(_tmplegsOut);
    }

    function _fund(uint256 usdcIn, uint256 wethOut) internal {
        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);
        vm.prank(maker);
        permit3.approveToken(address(settlement), USDC, uint160(usdcIn), 0);
        _approveSolverSide(wethOut, WETH);
    }

    // ── Fee leg delivered to the sourcer; solver's total delivery = gross ──
    function test_feeLeg_paysRecipient() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        uint256 fee = wethOut / 100; // 1%
        _fund(usdcIn, wethOut);

        Order memory order = _feeLegOrder(0, usdcIn, wethOut, fee);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256[] memory outs = settlement.fill(order, sig, usdcIn);

        assertEq(outs[0], wethOut - fee, "maker leg");
        assertEq(outs[1], fee, "fee leg");
        assertEq(IERC20(WETH).balanceOf(maker), wethOut - fee, "maker nets output minus fee");
        assertEq(IERC20(WETH).balanceOf(feeRecipient), fee, "sourcer received the fee leg");
        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver delivered the full gross amount");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver received full input unchanged");
    }

    // ── No fee leg behaves exactly like before ──
    function test_noFeeLeg_isNoop() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        _fund(usdcIn, wethOut);

        Order memory order = _order(maker, 1, USDC, WETH, usdcIn, wethOut, new Item[](0));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, usdcIn);

        assertEq(IERC20(WETH).balanceOf(maker), wethOut, "maker got full output");
        assertEq(IERC20(WETH).balanceOf(feeRecipient), 0, "no fee paid");
    }

    // ── Fee leg scales pro-rata across partial fills ──
    function test_feeLeg_partialFills_proRata() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        uint256 fee = wethOut * 25 / 1000; // 2.5%
        _fund(usdcIn, wethOut);

        Order memory order = _feeLegOrder(2, usdcIn, wethOut, fee);
        bytes memory sig = _sign(order);

        // Half fill → half of each leg (ceil slicing, exact here).
        vm.prank(solver);
        settlement.fill(order, sig, usdcIn / 2);
        assertEq(IERC20(WETH).balanceOf(feeRecipient), fee / 2, "fee accrues on first partial");
        assertEq(IERC20(WETH).balanceOf(maker), (wethOut - fee) / 2, "maker nets first partial");

        // Remainder completes both legs exactly.
        vm.prank(solver);
        settlement.fill(order, sig, usdcIn - usdcIn / 2);
        assertEq(IERC20(WETH).balanceOf(feeRecipient), fee, "fee accrues across fills");
        assertEq(IERC20(WETH).balanceOf(maker), wethOut - fee, "maker nets total minus fee");
    }

    // ── bps-of-tick fee: fee leg decays in PROPORTION to the main leg ──
    function test_feeLeg_proportionalDecay_matchesBps() public {
        uint256 usdcIn = 2_000e6;
        uint256 startOut = 1 ether;
        uint256 endOut = 0.9 ether;
        uint256 feeBps = 100; // 1% of the realized tick
        _fund(usdcIn, startOut); // solver funded for the worst (start) case

        Order memory order = _order(maker, 3, USDC, WETH, usdcIn, startOut, new Item[](0));
        order.timing = _packTiming(uint32(block.timestamp), 1000, 0);
        LegOut[] memory outs2 = new LegOut[](2);
        outs2[0] = LegOut(WETH, startOut * (10_000 - feeBps) / 10_000, endOut * (10_000 - feeBps) / 10_000, address(0));
        outs2[1] = LegOut(WETH, startOut * feeBps / 10_000, endOut * feeBps / 10_000, feeRecipient);
        order.legsOut = PackedEncode.legsOut(outs2);
        bytes memory sig = _sign(order);

        vm.warp(block.timestamp + 500); // bump = 5000 → tick = 0.95 ether
        uint256 tick = (startOut + endOut) / 2;

        vm.prank(solver);
        settlement.fill(order, sig, usdcIn);

        // Both legs decayed by the same bump ⇒ the fee is exactly bps of the tick.
        assertEq(IERC20(WETH).balanceOf(feeRecipient), tick * feeBps / 10_000, "fee = bps of realized tick");
        assertEq(IERC20(WETH).balanceOf(maker), tick * (10_000 - feeBps) / 10_000, "maker = rest of tick");
    }

    // ── Multiple fee recipients: one leg each (originator + partner tiers) ──
    function test_feeLeg_multipleRecipients() public {
        address partner = address(0xBEEF2);
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        uint256 fee1 = wethOut / 100; //  1% originator
        uint256 fee2 = wethOut / 200; //  0.5% partner
        _fund(usdcIn, wethOut);

        Order memory order = _order(maker, 4, USDC, WETH, usdcIn, wethOut, new Item[](0));
        LegOut[] memory _tmplegsOut = new LegOut[](3);
        _tmplegsOut[0] = LegOut(WETH, wethOut - fee1 - fee2, 0, address(0));
        _tmplegsOut[1] = LegOut(WETH, fee1, 0, feeRecipient);
        _tmplegsOut[2] = LegOut(WETH, fee2, 0, partner);
        order.legsOut = PackedEncode.legsOut(_tmplegsOut);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, usdcIn);

        assertEq(IERC20(WETH).balanceOf(maker), wethOut - fee1 - fee2, "maker net");
        assertEq(IERC20(WETH).balanceOf(feeRecipient), fee1, "originator tier");
        assertEq(IERC20(WETH).balanceOf(partner), fee2, "partner tier");
    }

    // ── Explicit recipient == maker behaves identically to address(0) ──
    function test_feeLeg_explicitMakerRecipient() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        _fund(usdcIn, wethOut);

        Order memory order = _order(maker, 5, USDC, WETH, usdcIn, wethOut, new Item[](0));
        order.legsOut = PackedEncode.setLegOutRecipient(order.legsOut, 0, maker); // explicit instead of the 0-default
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, usdcIn);

        assertEq(IERC20(WETH).balanceOf(maker), wethOut, "maker got full output");
    }

    // ── Lens: duplicate (token, recipient) pair flagged; distinct recipients fine ──
    function test_feeLeg_validateOrder() public view {
        Order memory good = _feeLegOrder(6, 2_000e6, 1 ether, 0.01 ether);
        (bool ok, string memory reason) = lens.validateOrder(good);
        assertTrue(ok, string.concat("fee-leg order valid: ", reason));

        // Same token to the SAME recipient twice → double-delivery footgun.
        Order memory dup = _feeLegOrder(7, 2_000e6, 1 ether, 0.01 ether);
        dup.legsOut = PackedEncode.setLegOutRecipient(dup.legsOut, 1, address(0)); // both legs now → maker
        (bool ok2, string memory reason2) = lens.validateOrder(dup);
        assertFalse(ok2, "duplicate (token, recipient) rejected");
        assertEq(reason2, "duplicate output token+recipient");
    }

    // ── Lens: a leg addressed to the settlement contract (self-burn) is flagged ──
    function test_feeLeg_recipientSettlement_lensRejects() public view {
        Order memory o = _feeLegOrder(9, 2_000e6, 1 ether, 0.01 ether);
        o.legsOut = PackedEncode.setLegOutRecipient(o.legsOut, 1, address(settlement)); // burn the fee leg
        (bool ok, string memory reason) = lens.validateOrder(o);
        assertFalse(ok, "settlement recipient rejected");
        assertEq(reason, "recipient is settlement (burn)");
    }

    // ── Soft-exclusivity override bumps ONLY the maker's leg, never the fee leg ──
    //    (Regression guard for the fix: an "absolute" fee stays absolute; the
    //    maker's exclusivity compensation does not leak to the originator.) ──
    function test_feeLeg_softExclusivity_notAppliedToFeeLeg() public {
        uint256 usdcIn = 2_000e6;
        uint256 makerLeg = 0.9 ether; // fixed maker output
        uint256 fee = 0.05 ether; //    fixed absolute fee to the originator
        uint256 overrideBps = 100; //   1% soft-exclusivity improvement

        // Solver must cover the bumped maker leg + the (un-bumped) fee leg.
        uint256 bumpedMaker = makerLeg * (10_000 + overrideBps) / 10_000; // ceil in-contract
        deal(USDC, maker, usdcIn);
        deal(WETH, solver, bumpedMaker + fee + 1);
        vm.prank(maker);
        permit3.approveToken(address(settlement), USDC, uint160(usdcIn), 0);
        _approveSolverSide(bumpedMaker + fee + 1, WETH);

        Order memory order = _order(maker, 11, USDC, WETH, usdcIn, makerLeg, new Item[](0));
        // Two fixed output legs: maker + originator fee.
        LegOut[] memory _tmplegsOut = new LegOut[](2);
        _tmplegsOut[0] = LegOut(WETH, makerLeg, 0, address(0));
        _tmplegsOut[1] = LegOut(WETH, fee, 0, feeRecipient);
        order.legsOut = PackedEncode.legsOut(_tmplegsOut);
        // Soft exclusivity: a nominated filler, but the solver is NOT it → override.
        order.exclusiveFiller = address(0xE0E0);
        _setExclusivityEnd(order, uint32(block.timestamp + 1 hours));
        order.params = (order.params & ~uint256(0xffff)) | uint256(overrideBps);
        bytes memory sig = _sign(order);

        vm.prank(solver); // non-exclusive in-window filler
        uint256[] memory outs = settlement.fill(order, sig, usdcIn);

        // Maker leg bumped up; fee leg delivered at its EXACT signed amount.
        uint256 expectedMaker = (makerLeg * (10_000 + overrideBps) + 9_999) / 10_000; // ceilDiv
        assertEq(outs[0], expectedMaker, "maker leg bumped by override");
        assertEq(outs[1], fee, "fee leg NOT bumped (absolute stays absolute)");
        assertEq(IERC20(WETH).balanceOf(maker), expectedMaker, "maker received bumped amount");
        assertEq(IERC20(WETH).balanceOf(feeRecipient), fee, "originator received exactly the signed fee");
    }

    // ── Gap f: fee leg on a BUY order (fixed outputs, one to a recipient) ──
    function test_feeLeg_onBuyOrder() public {
        address originator = feeRecipient;
        uint256 usdcIn = 2_000e6; //     fixed-price BUY input
        uint256 makerOut = 0.95 ether; //  anchor (legsOut[0])
        uint256 fee = 0.05 ether; //       fee leg (fixed)

        deal(USDC, maker, usdcIn);
        deal(WETH, solver, makerOut + fee);
        vm.prank(maker);
        permit3.approveToken(address(settlement), USDC, uint160(usdcIn), 0);
        _approveSolverSide(makerOut + fee, WETH);

        LegOut[] memory legsOut = new LegOut[](2);
        legsOut[0] = LegOut(WETH, makerOut, 0, address(0)); // anchor → maker
        legsOut[1] = LegOut(WETH, fee, 0, originator); //      fee → originator

        Order memory order = Order({
            params: 0,
            pricingModule: address(0),
            maker: maker,
            nonce: 12,
            deadline: block.timestamp + 1 hours,
            legsIn: _legsIn1(USDC, usdcIn), // fixed-price input (end == 0)
            legsOut: PackedEncode.legsOut(legsOut),
            timing: uint256(1) << 101, // BUY (timing bit 101)
            exclusiveFiller: address(0),
            minFillAnchor: 0,
            curve: PackedEncode.noCurve(),
            items: PackedEncode.noItems(),
            validators: PackedEncode.noValidators(),
            invariants: PackedEncode.noValidators(),
            fillModule: address(0),
            fillTotal: 0
        });
        bytes memory sig = _sign(order);

        // Full fill (denominated in legsOut[0] units = the maker anchor).
        vm.prank(solver);
        settlement.fill(order, sig, makerOut);

        assertEq(IERC20(WETH).balanceOf(maker), makerOut, "maker got exact fixed output");
        assertEq(IERC20(WETH).balanceOf(originator), fee, "originator got exact fee leg");
        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver delivered both legs");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver received the fixed input");
    }

    // ── Gap f (cont.): fee leg on a BUY order slices correctly across a partial fill ──
    function test_feeLeg_onBuyOrder_partialFill() public {
        uint256 usdcIn = 2_000e6;
        uint256 makerOut = 0.95 ether;
        uint256 fee = 0.05 ether;

        deal(USDC, maker, usdcIn);
        deal(WETH, solver, makerOut + fee);
        vm.prank(maker);
        permit3.approveToken(address(settlement), USDC, uint160(usdcIn), 0);
        _approveSolverSide(makerOut + fee, WETH);

        LegOut[] memory legsOut = new LegOut[](2);
        legsOut[0] = LegOut(WETH, makerOut, 0, address(0));
        legsOut[1] = LegOut(WETH, fee, 0, feeRecipient);

        Order memory order = Order({
            params: 0,
            pricingModule: address(0),
            maker: maker,
            nonce: 13,
            deadline: block.timestamp + 1 hours,
            legsIn: _legsIn1(USDC, usdcIn),
            legsOut: PackedEncode.legsOut(legsOut),
            timing: uint256(1) << 101, // BUY (timing bit 101)
            exclusiveFiller: address(0),
            minFillAnchor: 0,
            curve: PackedEncode.noCurve(),
            items: PackedEncode.noItems(),
            validators: PackedEncode.noValidators(),
            invariants: PackedEncode.noValidators(),
            fillModule: address(0),
            fillTotal: 0
        });
        bytes memory sig = _sign(order);

        // Two halves; each leg is an independent cumulative ceil-slice, summing exact.
        vm.prank(solver);
        settlement.fill(order, sig, makerOut / 2);
        vm.prank(solver);
        settlement.fill(order, sig, makerOut - makerOut / 2);

        assertEq(IERC20(WETH).balanceOf(maker), makerOut, "maker leg sums to exact fixed output");
        assertEq(IERC20(WETH).balanceOf(feeRecipient), fee, "fee leg sums to exact fixed fee");
    }
}
