// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UniversalSettlement, Order, Validator, OrderSide, CurvePoint} from "@core/settlement/UniversalSettlement.sol";
import {DutchAuction} from "@core/settlement/DutchAuction.sol";

import {MockSettlementBase} from "../shared/MockSettlementBase.t.sol";

/// @title AuctionAndExclusivity
/// @notice Coverage for soft-exclusivity override, the piecewise-linear auction
///         curve, and the basefee gas bump — on both SELL and BUY sides.
contract AuctionAndExclusivityTest is MockSettlementBase {
    uint256 constant SELL_IN = 1_000e18; // tA the maker sells (anchor)
    uint256 constant SELL_OUT = 2e18; // tB fixed-price output
    uint256 constant BUY_OUT = 1e18; // tB the maker buys (anchor)
    uint256 constant BUY_IN = 1_500e18; // tA fixed-price input

    address constant EX = address(0xE); // a nominated exclusive filler (not our solver)

    function _fundSell(uint256 outAmount) internal {
        tA.mint(maker, SELL_IN);
        _makerApprove(address(settlement), address(tA), SELL_IN);
        tB.mint(solver, outAmount);
        _solverApprove(address(settlement), address(tB), outAmount);
    }

    function _fundBuy(uint256 inMax) internal {
        tA.mint(maker, inMax);
        _makerApprove(address(settlement), address(tA), inMax);
        tB.mint(solver, BUY_OUT);
        _solverApprove(address(settlement), address(tB), BUY_OUT);
    }

    // ════════════════════ soft exclusivity override ════════════════════

    function test_override_sell_nonExclusiveMustDeliverMore() public {
        uint256 bumped = (SELL_OUT * 10_100) / 10_000; // +100 bps
        _fundSell(bumped);

        Order memory order = _plainOrder(1, address(tA), address(tB), SELL_IN, SELL_OUT);
        order.exclusiveFiller = EX;
        order.exclusivityEndTime = uint32(block.timestamp + 100);
        order.exclusivityOverrideBps = 100;
        bytes memory sig = _sign(order);

        // Non-exclusive `solver` fills in-window → must deliver 1% more output.
        vm.prank(solver);
        uint256[] memory outs = settlement.fill(order, sig, SELL_IN);
        assertEq(outs[0], bumped, "delivered output bumped by override");
        assertEq(tB.balanceOf(maker), bumped, "maker got the improved output");
    }

    function test_override_buy_nonExclusiveChargesLess() public {
        _fundBuy(BUY_IN);

        Order memory order = _buyOrder(1, address(tA), address(tB), BUY_IN, BUY_IN, BUY_OUT);
        order.exclusiveFiller = EX;
        order.exclusivityEndTime = uint32(block.timestamp + 100);
        order.exclusivityOverrideBps = 100; // maker pays 1% less
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, BUY_OUT);

        uint256 discounted = (BUY_IN * 9_900) / 10_000;
        assertEq(tB.balanceOf(maker), BUY_OUT, "maker got exact output");
        assertEq(tA.balanceOf(solver), discounted, "solver charged the maker 1% less");
    }

    function test_override_exclusiveFiller_noBump() public {
        _fundSell(SELL_OUT);
        Order memory order = _plainOrder(1, address(tA), address(tB), SELL_IN, SELL_OUT);
        order.exclusiveFiller = solver; // the exclusive filler IS our solver
        order.exclusivityEndTime = uint32(block.timestamp + 100);
        order.exclusivityOverrideBps = 100;
        bytes memory sig = _sign(order);

        // Exclusive filler pays the base price — no override.
        vm.prank(solver);
        uint256[] memory outs = settlement.fill(order, sig, SELL_IN);
        assertEq(outs[0], SELL_OUT, "exclusive filler delivers base output");
    }

    function test_hardExclusivity_zeroBps_stillReverts() public {
        _fundSell(SELL_OUT);
        Order memory order = _plainOrder(1, address(tA), address(tB), SELL_IN, SELL_OUT);
        order.exclusiveFiller = EX;
        order.exclusivityEndTime = uint32(block.timestamp + 100);
        order.exclusivityOverrideBps = 0; // hard
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(UniversalSettlement.NotExclusiveFiller.selector);
        settlement.fill(order, sig, SELL_IN);
    }

    // ════════════════════ piecewise auction curve ════════════════════

    function _curve3() internal pure returns (CurvePoint[] memory c) {
        c = new CurvePoint[](3);
        c[0] = CurvePoint({timeDelta: 0, bumpBps: 0});
        c[1] = CurvePoint({timeDelta: 100, bumpBps: 5_000});
        c[2] = CurvePoint({timeDelta: 200, bumpBps: 10_000});
    }

    function test_curve_sell_interpolatesBetweenPoints() public {
        _fundSell(SELL_OUT);
        uint256 start = SELL_OUT;
        uint256 end = 1e18;

        Order memory order = _plainOrder(1, address(tA), address(tB), SELL_IN, start);
        order.endAmountOut = _u1(end);
        order.decayStartTime = uint32(block.timestamp);
        order.curve = _curve3();
        bytes memory sig = _sign(order);

        // t=50 → halfway into [0,100] → bump 2500 → out = start - (start-end)*2500/10000.
        vm.warp(block.timestamp + 50);
        uint256 exp1 = start - ((start - end) * 2_500) / 10_000;
        assertEq(settlement.previewAmountOut(order)[0], exp1, "interp in first segment");

        // t=150 → halfway into [100,200] → bump 7500.
        vm.warp(block.timestamp + 100);
        uint256 exp2 = start - ((start - end) * 7_500) / 10_000;
        assertEq(settlement.previewAmountOut(order)[0], exp2, "interp in second segment");

        vm.prank(solver);
        uint256[] memory outs = settlement.fill(order, sig, SELL_IN);
        assertEq(outs[0], exp2, "fill uses the curve price");
    }

    function test_curve_clampsAfterLastPoint() public {
        Order memory order = _plainOrder(1, address(tA), address(tB), SELL_IN, SELL_OUT);
        order.endAmountOut = _u1(1e18);
        order.decayStartTime = uint32(block.timestamp);
        order.curve = _curve3();

        vm.warp(block.timestamp + 10_000); // well past the last point
        assertEq(settlement.previewAmountOut(order)[0], 1e18, "clamped to end (bump 10000)");
    }

    function test_curve_revertsBeforeStart() public {
        Order memory order = _plainOrder(1, address(tA), address(tB), SELL_IN, SELL_OUT);
        order.endAmountOut = _u1(1e18);
        order.decayStartTime = uint32(block.timestamp + 100); // future
        order.curve = _curve3();

        vm.expectRevert(DutchAuction.AuctionNotStarted.selector);
        settlement.previewAmountOut(order);
    }

    function test_curve_buy_risesWithBump() public {
        _fundBuy(2_000e18);
        uint256 startIn = 1_000e18;
        uint256 endIn = 2_000e18;

        Order memory order = _buyOrder(1, address(tA), address(tB), startIn, endIn, BUY_OUT);
        order.decayStartTime = uint32(block.timestamp);
        order.curve = _curve3();
        bytes memory sig = _sign(order);

        vm.warp(block.timestamp + 50); // bump 2500
        uint256 expIn = startIn + ((endIn - startIn) * 2_500) / 10_000;
        assertEq(settlement.previewAmountIn(order)[0], expIn, "input rises along the curve");

        vm.prank(solver);
        settlement.fill(order, sig, BUY_OUT);
        assertEq(tA.balanceOf(solver), expIn, "maker paid the curve input");
    }

    // ════════════════════ gas bump ════════════════════

    function test_gasBump_sell_reducesOutputWithBasefee() public {
        _fundSell(SELL_OUT);
        uint256 start = SELL_OUT;
        uint256 end = 1e18;
        uint64 ref = 30 gwei;

        // No time decay (duration 0, no curve) → the ONLY bump is the gas bump.
        Order memory order = _plainOrder(1, address(tA), address(tB), SELL_IN, start);
        order.endAmountOut = _u1(end);
        order.gasBumpBps = 1_000;
        order.gasPriceRef = ref;
        bytes memory sig = _sign(order);

        vm.fee(ref); // basefee == ref → full 1000 bps of gas bump
        uint256 exp = start - ((start - end) * 1_000) / 10_000;
        assertEq(settlement.previewAmountOut(order)[0], exp, "gas bump at ref basefee");

        vm.prank(solver);
        uint256[] memory outs = settlement.fill(order, sig, SELL_IN);
        assertEq(outs[0], exp, "fill applies gas bump");
    }

    function test_gasBump_cappedAtGasBumpBps() public {
        Order memory order = _plainOrder(1, address(tA), address(tB), SELL_IN, SELL_OUT);
        order.endAmountOut = _u1(1e18);
        order.gasBumpBps = 1_000;
        order.gasPriceRef = 30 gwei;

        vm.fee(90 gwei); // 3× ref → gas add would be 3000, capped to 1000
        uint256 exp = SELL_OUT - ((SELL_OUT - 1e18) * 1_000) / 10_000;
        assertEq(settlement.previewAmountOut(order)[0], exp, "gas bump capped");
    }

    function test_gasBump_belowRef_partial() public {
        Order memory order = _plainOrder(1, address(tA), address(tB), SELL_IN, SELL_OUT);
        order.endAmountOut = _u1(1e18);
        order.gasBumpBps = 1_000;
        order.gasPriceRef = 30 gwei;

        vm.fee(15 gwei); // half of ref → 500 bps
        uint256 exp = SELL_OUT - ((SELL_OUT - 1e18) * 500) / 10_000;
        assertEq(settlement.previewAmountOut(order)[0], exp, "gas bump scales below ref");
    }

    function test_gasBump_buy_raisesInput() public {
        _fundBuy(BUY_IN * 2);
        uint256 startIn = 1_000e18;
        uint256 endIn = 2_000e18;
        uint64 ref = 30 gwei;

        Order memory order = _buyOrder(1, address(tA), address(tB), startIn, endIn, BUY_OUT);
        order.gasBumpBps = 1_000;
        order.gasPriceRef = ref;
        bytes memory sig = _sign(order);

        vm.fee(ref); // full 1000 bps
        uint256 expIn = startIn + ((endIn - startIn) * 1_000) / 10_000;
        assertEq(settlement.previewAmountIn(order)[0], expIn, "gas bump raises buy input");

        vm.prank(solver);
        settlement.fill(order, sig, BUY_OUT);
        assertEq(tA.balanceOf(solver), expIn, "maker paid the gas-bumped input");
    }

    // ════════════════════ validateOrder ════════════════════

    function test_validateOrder_newFields() public view {
        // Well-formed with all three features.
        Order memory ok = _plainOrder(1, address(tA), address(tB), SELL_IN, SELL_OUT);
        ok.endAmountOut = _u1(1e18);
        ok.exclusiveFiller = EX;
        ok.exclusivityEndTime = uint32(block.timestamp + 100);
        ok.exclusivityOverrideBps = 50;
        ok.decayStartTime = uint32(block.timestamp);
        ok.curve = _curve3();
        ok.gasBumpBps = 500;
        ok.gasPriceRef = 30 gwei;
        (bool good,) = settlement.validateOrder(ok);
        assertTrue(good, "well-formed advanced order validates");

        // override without exclusiveFiller
        Order memory o1 = _plainOrder(2, address(tA), address(tB), SELL_IN, SELL_OUT);
        o1.exclusivityOverrideBps = 50;
        (bool b1, string memory r1) = settlement.validateOrder(o1);
        assertFalse(b1, "override needs exclusiveFiller");
        assertEq(r1, "override without exclusiveFiller");

        // non-increasing curve timeDelta
        Order memory o2 = _plainOrder(3, address(tA), address(tB), SELL_IN, SELL_OUT);
        o2.decayStartTime = uint32(block.timestamp);
        CurvePoint[] memory bad = new CurvePoint[](2);
        bad[0] = CurvePoint({timeDelta: 100, bumpBps: 0});
        bad[1] = CurvePoint({timeDelta: 100, bumpBps: 5_000}); // not strictly increasing
        o2.curve = bad;
        (bool b2, string memory r2) = settlement.validateOrder(o2);
        assertFalse(b2, "curve time must increase");
        assertEq(r2, "curve timeDelta not increasing");

        // gas bump without reference price
        Order memory o3 = _plainOrder(4, address(tA), address(tB), SELL_IN, SELL_OUT);
        o3.gasBumpBps = 500;
        (bool b3, string memory r3) = settlement.validateOrder(o3);
        assertFalse(b3, "gas bump needs gasPriceRef");
        assertEq(r3, "gasBump without gasPriceRef");
    }
}
