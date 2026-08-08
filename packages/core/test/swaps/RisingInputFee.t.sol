// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "../shared/PackedEncode.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, LegIn, LegOut, OrderSide} from "@core/settlement/Settlement.sol";
import {SettlementLens} from "@core/periphery/SettlementLens.sol";
import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @dev Rising-input auction: a SELL input leg with `startAmountIn < endAmountIn`
/// is charged at the shared auction tick — the relayer-fee auction for orders
/// whose economics have no conversion leg to price a filler's compensation into
/// (pure deposits). Flag-free and uniform: `start == end` legs stay fixed,
/// `start != end` legs auction on the order's shared decay clock.
///
///   tokenIn  = USDC   (maker gives — rising F0 → FMAX)
///   tokenOut = WETH   (solver gives — fixed), or EMPTY (pure-fee shape)
contract RisingInputFeeTest is CoreSettlementBase {
    uint256 constant F0 = 2_000e6; //    input floor (auction start, best for maker)
    uint256 constant FMAX = 2_200e6; //  input ceiling (auction end, worst for maker)
    uint256 constant WETH_OUT = 1 ether;
    uint32 constant DURATION = 1000;

    /// @dev SELL order with a rising USDC input leg (F0 → FMAX over DURATION)
    ///      against a fixed WETH output.
    function _risingOrder(uint256 nonce) internal view returns (Order memory o) {
        o = _order(maker, nonce, USDC, WETH, F0, WETH_OUT, new Item[](0));
        o.legsIn = PackedEncode.setLegInEnd(o.legsIn, 0, FMAX); // rising input (start F0 → end FMAX)
        o.timing = _packTiming(uint32(block.timestamp), DURATION, 0);
    }

    function _fund() internal {
        deal(USDC, maker, FMAX);
        deal(WETH, solver, WETH_OUT);
        _approveMakerToSettlement(USDC, FMAX);
        _approveSolverSide(WETH_OUT, WETH);
    }

    // ── A fixed leg (start == end) stays fixed even mid-decay ──
    function test_fixedLeg_unaffectedByDecay() public {
        _fund();
        Order memory o = _risingOrder(0);
        o.legsIn = PackedEncode.setLegInEnd(o.legsIn, 0, 0); // fixed again (end == 0 sentinel)
        bytes memory sig = _sign(o);

        vm.warp(block.timestamp + DURATION / 2); // mid-decay — must not matter
        vm.prank(solver);
        settlement.fill(o, sig, F0);

        assertEq(IERC20(USDC).balanceOf(solver), F0, "fixed leg charges startAmountIn");
    }

    // ── A rising leg is charged at the shared auction tick ──
    function test_risingLeg_chargesAuctionTick() public {
        _fund();
        Order memory o = _risingOrder(1);
        bytes memory sig = _sign(o);

        vm.warp(block.timestamp + DURATION / 2); // bump = 5000
        uint256 expected = F0 + (FMAX - F0) / 2; // 2100e6

        vm.prank(solver);
        settlement.fill(o, sig, F0);

        assertEq(IERC20(USDC).balanceOf(solver), expected, "solver received the risen tick");
        assertEq(IERC20(USDC).balanceOf(maker), FMAX - expected, "maker paid the risen tick");
        assertEq(IERC20(WETH).balanceOf(maker), WETH_OUT, "output leg untouched");
    }

    // ── At the floor (t = start) the rising leg charges exactly F0 ──
    function test_risingLeg_atStart_chargesFloor() public {
        _fund();
        Order memory o = _risingOrder(2);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fill(o, sig, F0);

        assertEq(IERC20(USDC).balanceOf(solver), F0, "floor tick at decay start");
    }

    // ── At/after the ceiling (t >= start+duration) the rising leg charges exactly
    //    FMAX and is clamped there — never exceeds endAmountIn on any fill. ──
    function test_risingLeg_atCeiling_chargesFMaxAndClamps() public {
        _fund();
        Order memory o = _risingOrder(13);
        bytes memory sig = _sign(o);

        // Warp well past the duration — bump saturates to 10000, tick = FMAX.
        vm.warp(block.timestamp + DURATION * 3);
        vm.prank(solver);
        settlement.fill(o, sig, F0);

        assertEq(IERC20(USDC).balanceOf(solver), FMAX, "ceiling tick charges exactly endAmountIn");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "maker paid the whole ceiling, nothing left");
    }

    // ── Gas bump widens the fee leg with basefee (no time decay) ──
    function test_risingLeg_gasBump_widensFee() public {
        _fund();
        Order memory o = _risingOrder(3);
        _setDecayDuration(o, 0); //      no time decay — gas bump only
        o.gasBumpBps = 2_000; //         max +20% of the leg span
        o.gasPriceRef = 10 gwei; //      reference basefee for the full bump

        bytes memory sig = _sign(o);

        vm.fee(5 gwei); // half the reference → gasAdd = 2000 * 5/10 = 1000 bps
        uint256 expected = F0 + ((FMAX - F0) * 1_000) / 10_000; // 2020e6

        vm.prank(solver);
        settlement.fill(o, sig, F0);

        assertEq(IERC20(USDC).balanceOf(solver), expected, "fee widened by the gas bump");
    }

    // ── Pure-fee shape: EMPTY tokenOut, the rising leg is the whole economics ──
    function test_risingLeg_emptyTokenOut() public {
        deal(USDC, maker, FMAX);
        _approveMakerToSettlement(USDC, FMAX);

        Order memory o = _risingOrder(4);
        o.legsOut = PackedEncode.legsOut(new LegOut[](0));
        bytes memory sig = _sign(o);

        vm.warp(block.timestamp + DURATION / 2);
        uint256 expected = F0 + (FMAX - F0) / 2;

        vm.prank(solver);
        uint256[] memory outs = settlement.fill(o, sig, F0);

        assertEq(outs.length, 0, "no output legs");
        assertEq(IERC20(USDC).balanceOf(solver), expected, "solver received only the rising fee");
        assertEq(IERC20(USDC).balanceOf(maker), FMAX - expected, "maker paid only the rising fee");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement drained");
    }

    // ── Partial fills price each slice at its own tick ──
    function test_risingLeg_partialFills_perTick() public {
        _fund();
        Order memory o = _risingOrder(5);
        bytes memory sig = _sign(o);

        // First half at the floor (bump = 0).
        vm.prank(solver);
        settlement.fill(o, sig, F0 / 2);
        uint256 firstOwed = (F0 / 2) * F0 / F0; // 1000e6
        assertEq(IERC20(USDC).balanceOf(solver), firstOwed, "first slice at floor tick");

        // Second half mid-decay (bump = 5000).
        vm.warp(block.timestamp + DURATION / 2);
        vm.prank(solver);
        settlement.fill(o, sig, F0 - F0 / 2);
        uint256 secondOwed = ((F0 - F0 / 2) * (F0 + (FMAX - F0) / 2)) / F0; // 1050e6
        assertEq(IERC20(USDC).balanceOf(solver), firstOwed + secondOwed, "second slice at the risen tick");
        assertEq(IERC20(WETH).balanceOf(maker), WETH_OUT, "full output delivered across fills");
    }

    // ── Rising input composes with a fee OUTPUT leg to the originator ──
    function test_risingLeg_combinesWithFeeOutputLeg() public {
        _fund();
        address feeRecipient = address(0xF00DFEE);
        uint256 skim = WETH_OUT / 100; // 1% of the delivery, as its own leg

        Order memory o = _risingOrder(6);
        LegOut[] memory _tmplegsOut = new LegOut[](2);
        _tmplegsOut[0] = LegOut(WETH, WETH_OUT - skim, 0, address(0)); // maker
        _tmplegsOut[1] = LegOut(WETH, skim, 0, feeRecipient); //          originator fee
        o.legsOut = PackedEncode.legsOut(_tmplegsOut);
        bytes memory sig = _sign(o);

        vm.warp(block.timestamp + DURATION / 2);
        uint256 expectedIn = F0 + (FMAX - F0) / 2;

        vm.prank(solver);
        settlement.fill(o, sig, F0);

        assertEq(IERC20(USDC).balanceOf(solver), expectedIn, "rising input charged");
        assertEq(IERC20(WETH).balanceOf(maker), WETH_OUT - skim, "maker nets output minus fee leg");
        assertEq(IERC20(WETH).balanceOf(feeRecipient), skim, "originator fee leg delivered");
    }

    // ── Soft exclusivity discounts the rising leg like any auction input ──
    function test_risingLeg_softExclusivity_discountsRisingLeg() public {
        _fund();
        // Solver must also over-deliver the output by the override.
        uint256 overrideBps = 100;
        deal(WETH, solver, WETH_OUT + WETH_OUT * overrideBps / 10_000);
        _approveSolverSide(WETH_OUT + WETH_OUT * overrideBps / 10_000, WETH);

        Order memory o = _risingOrder(7);
        o.exclusiveFiller = address(0xE0E0);
        _setExclusivityEnd(o, uint32(block.timestamp + DURATION));
        o.exclusivityOverrideBps = overrideBps;
        bytes memory sig = _sign(o);

        vm.warp(block.timestamp + DURATION / 2);
        uint256 tick = F0 + (FMAX - F0) / 2;
        uint256 expectedIn = (tick * (10_000 - overrideBps)) / 10_000; // maker charged LESS

        vm.prank(solver); // NOT the exclusive filler → override applies
        settlement.fill(o, sig, F0);

        assertEq(IERC20(USDC).balanceOf(solver), expectedIn, "rising leg discounted by override");
    }

    // ── A falling input leg (end < start) reverts InvalidAuctionParams ──
    function test_fallingInputLeg_reverts() public {
        _fund();
        Order memory o = _risingOrder(8);
        o.legsIn = PackedEncode.setLegInStart(o.legsIn, 0, FMAX);
        o.legsIn = PackedEncode.setLegInEnd(o.legsIn, 0, F0); // falling — inputs may only rise
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(); // DutchAuction.InvalidAuctionParams
        settlement.fill(o, sig, FMAX);
    }

    // ──────────────────── Lens ────────────────────

    function test_lens_validateOrder_inputLegRules() public view {
        // Rising leg → well-formed, no flag needed.
        Order memory o = _risingOrder(9);
        (bool ok, string memory reason) = lens.validateOrder(o);
        assertTrue(ok, string.concat("rising leg valid: ", reason));

        // Falling leg → malformed.
        o.legsIn = PackedEncode.setLegInStart(o.legsIn, 0, FMAX);
        o.legsIn = PackedEncode.setLegInEnd(o.legsIn, 0, F0);
        (ok, reason) = lens.validateOrder(o);
        assertFalse(ok, "falling input leg rejected");
        assertEq(reason, "input end < start (must rise)");
    }

    function test_lens_validateOrder_emptyTokenOutShapes() public view {
        // Pure-fee shape with items → well-formed.
        Order memory o = _risingOrder(10);
        o.legsOut = PackedEncode.legsOut(new LegOut[](0));
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.MAKE, module: address(0xD0D0), amount: 1 ether, recipient: address(0), data: ""});
        o.items = PackedEncode.items(items);
        (bool ok, string memory reason) = lens.validateOrder(o);
        assertTrue(ok, string.concat("deposit shape valid: ", reason));

        // Empty tokenOut with NO items → giveaway.
        o.items = PackedEncode.noItems();
        (ok, reason) = lens.validateOrder(o);
        assertFalse(ok, "no outputs and no items rejected");
        assertEq(reason, "no tokenOut and no items (giveaway)");

        // BUY can never omit tokenOut (it anchors there).
        o = _risingOrder(10);
        o.timing |= uint256(1) << 101; // BUY (timing bit 101)
        o.legsOut = PackedEncode.legsOut(new LegOut[](0));
        (ok, reason) = lens.validateOrder(o);
        assertFalse(ok, "buy without tokenOut rejected");
        assertEq(reason, "buy requires tokenOut");
    }

    function test_lens_relevantState_capsAtWorstCaseCeiling() public {
        // Item-free rising order: the maker-capacity cap must use the auction
        // CEILING (endAmountIn), a conservative lower bound.
        deal(USDC, maker, FMAX);
        _approveMakerToSettlement(USDC, F0); // allowance = only the floor

        Order memory o = _risingOrder(11);
        bytes memory sig = _sign(o);

        (SettlementLens.OrderStatus status, uint256 fillable,,) = lens.getOrderRelevantState(o, sig, solver, "");
        assertEq(uint8(status), uint8(SettlementLens.OrderStatus.Fillable));
        assertEq(fillable, (F0 * F0) / FMAX, "capped by allowance at the ceiling tick");
    }

    // ── Gap u: one SELL order with a FIXED input leg + a RISING input leg.
    //    The per-leg branch must charge the fixed leg its exact amount and the
    //    rising leg the auction tick, in the same fill. ──
    function test_mixedFixedAndRisingInputLegs() public {
        address DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        uint256 usdcFixed = 2_000e6; //   fixed anchor input
        uint256 wethFloor = 0.001 ether; // rising fee leg floor
        uint256 wethCeil = 0.003 ether; //  rising fee leg ceiling
        uint256 daiOut = 500e18; //         solver delivers to maker

        deal(USDC, maker, usdcFixed);
        deal(WETH, maker, wethCeil);
        deal(DAI, solver, daiOut);
        vm.startPrank(maker);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDC, uint160(usdcFixed), 0);
        permit3.approveToken(address(settlement), WETH, uint160(wethCeil), 0);
        vm.stopPrank();
        vm.startPrank(solver);
        IERC20(DAI).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), DAI, uint160(daiOut), 0);
        vm.stopPrank();

        Order memory o = _order(maker, 20, USDC, DAI, usdcFixed, daiOut, new Item[](0));
        LegIn[] memory _tmplegsIn = new LegIn[](2);
        _tmplegsIn[0] = LegIn(USDC, usdcFixed, 0); //          end == 0 ⇒ fixed anchor
        _tmplegsIn[1] = LegIn(WETH, wethFloor, wethCeil); //   start != end ⇒ rising fee leg
        o.legsIn = PackedEncode.legsIn(_tmplegsIn);
        o.timing = _packTiming(uint32(block.timestamp), DURATION, 0);
        bytes memory sig = _sign(o);

        vm.warp(block.timestamp + DURATION / 2); // bump = 5000
        uint256 expectedWeth = wethFloor + (wethCeil - wethFloor) / 2; // 0.002 WETH

        vm.prank(solver);
        settlement.fill(o, sig, usdcFixed);

        assertEq(IERC20(USDC).balanceOf(solver), usdcFixed, "fixed leg charged exactly startAmountIn");
        assertEq(IERC20(WETH).balanceOf(solver), expectedWeth, "rising leg charged the auction tick");
        assertEq(IERC20(DAI).balanceOf(maker), daiOut, "maker received the output");
        // No dust stranded in settlement across either input token.
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
    }

    function test_lens_relevantState_emptyTokenOut_isFillable() public view {
        Order memory o = _risingOrder(12);
        o.legsOut = PackedEncode.legsOut(new LegOut[](0));
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.MAKE, module: address(0xD0D0), amount: 1 ether, recipient: address(0), data: ""});
        o.items = PackedEncode.items(items);

        (SettlementLens.OrderStatus status, uint256 fillable,,) = lens.getOrderRelevantState(o, "", solver, "");
        assertEq(uint8(status), uint8(SettlementLens.OrderStatus.Fillable), "deposit shape not Invalid");
        assertEq(fillable, F0, "full anchor fillable (item orders skip the cap)");
    }
}
