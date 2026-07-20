// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "@core/settlement/Base.sol";
import {stdError} from "forge-std/StdError.sol";

import {Settlement, CallbackMode, Order, Item, Validator, OrderSide, CurvePoint} from "@core/settlement/Settlement.sol";
import {DutchAuction} from "@core/settlement/DutchAuction.sol";

import {MockSettlementBase, MockERC20} from "../shared/MockSettlementBase.t.sol";

/// @dev Hands the solver output inventory just-in-time (PreDelivery callback).
contract Supplier {
    function supply(address to, address token, uint256 amount) external {
        MockERC20(token).transfer(to, amount);
    }
}

/// @dev Pulls the solver's just-received input and returns the fixed output
///      (PostInputs callback).
contract SwapHelper {
    function swap(address who, address tokenIn, uint256 amtIn, address tokenOut, uint256 amtOut) external {
        MockERC20(tokenIn).transferFrom(who, address(this), amtIn);
        MockERC20(tokenOut).transfer(who, amtOut);
    }
}

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
        vm.expectRevert(Base.NotExclusiveFiller.selector);
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
        assertEq(lens.previewAmountOut(order)[0], exp1, "interp in first segment");

        // t=150 → halfway into [100,200] → bump 7500.
        vm.warp(block.timestamp + 100);
        uint256 exp2 = start - ((start - end) * 7_500) / 10_000;
        assertEq(lens.previewAmountOut(order)[0], exp2, "interp in second segment");

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
        assertEq(lens.previewAmountOut(order)[0], 1e18, "clamped to end (bump 10000)");
    }

    function test_curve_revertsBeforeStart() public {
        Order memory order = _plainOrder(1, address(tA), address(tB), SELL_IN, SELL_OUT);
        order.endAmountOut = _u1(1e18);
        order.decayStartTime = uint32(block.timestamp + 100); // future
        order.curve = _curve3();

        vm.expectRevert(DutchAuction.AuctionNotStarted.selector);
        lens.previewAmountOut(order);
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
        assertEq(lens.previewAmountIn(order)[0], expIn, "input rises along the curve");

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
        assertEq(lens.previewAmountOut(order)[0], exp, "gas bump at ref basefee");

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
        assertEq(lens.previewAmountOut(order)[0], exp, "gas bump capped");
    }

    function test_gasBump_belowRef_partial() public {
        Order memory order = _plainOrder(1, address(tA), address(tB), SELL_IN, SELL_OUT);
        order.endAmountOut = _u1(1e18);
        order.gasBumpBps = 1_000;
        order.gasPriceRef = 30 gwei;

        vm.fee(15 gwei); // half of ref → 500 bps
        uint256 exp = SELL_OUT - ((SELL_OUT - 1e18) * 500) / 10_000;
        assertEq(lens.previewAmountOut(order)[0], exp, "gas bump scales below ref");
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
        assertEq(lens.previewAmountIn(order)[0], expIn, "gas bump raises buy input");

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
        (bool good,) = lens.validateOrder(ok);
        assertTrue(good, "well-formed advanced order validates");

        // override without exclusiveFiller
        Order memory o1 = _plainOrder(2, address(tA), address(tB), SELL_IN, SELL_OUT);
        o1.exclusivityOverrideBps = 50;
        (bool b1, string memory r1) = lens.validateOrder(o1);
        assertFalse(b1, "override needs exclusiveFiller");
        assertEq(r1, "override without exclusiveFiller");

        // non-increasing curve timeDelta
        Order memory o2 = _plainOrder(3, address(tA), address(tB), SELL_IN, SELL_OUT);
        o2.decayStartTime = uint32(block.timestamp);
        CurvePoint[] memory bad = new CurvePoint[](2);
        bad[0] = CurvePoint({timeDelta: 100, bumpBps: 0});
        bad[1] = CurvePoint({timeDelta: 100, bumpBps: 5_000}); // not strictly increasing
        o2.curve = bad;
        (bool b2, string memory r2) = lens.validateOrder(o2);
        assertFalse(b2, "curve time must increase");
        assertEq(r2, "curve timeDelta not increasing");

        // gas bump without reference price
        Order memory o3 = _plainOrder(4, address(tA), address(tB), SELL_IN, SELL_OUT);
        o3.gasBumpBps = 500;
        (bool b3, string memory r3) = lens.validateOrder(o3);
        assertFalse(b3, "gas bump needs gasPriceRef");
        assertEq(r3, "gasBump without gasPriceRef");
    }

    function test_validateOrder_moreRejects() public view {
        // exclusivityOverrideBps > 10000
        Order memory o1 = _plainOrder(1, address(tA), address(tB), SELL_IN, SELL_OUT);
        o1.exclusiveFiller = EX;
        o1.exclusivityOverrideBps = 10_001;
        (bool b1, string memory r1) = lens.validateOrder(o1);
        assertFalse(b1);
        assertEq(r1, "exclusivityOverrideBps > 10000");

        // curve bumpBps > 10000
        Order memory o2 = _plainOrder(2, address(tA), address(tB), SELL_IN, SELL_OUT);
        o2.decayStartTime = uint32(block.timestamp);
        CurvePoint[] memory c2 = new CurvePoint[](1);
        c2[0] = CurvePoint({timeDelta: 0, bumpBps: 10_001});
        o2.curve = c2;
        (bool b2, string memory r2) = lens.validateOrder(o2);
        assertFalse(b2);
        assertEq(r2, "curve bumpBps > 10000");

        // curve set without decayStartTime
        Order memory o3 = _plainOrder(3, address(tA), address(tB), SELL_IN, SELL_OUT);
        CurvePoint[] memory c3 = new CurvePoint[](1);
        c3[0] = CurvePoint({timeDelta: 0, bumpBps: 5_000});
        o3.curve = c3; // decayStartTime left 0
        (bool b3, string memory r3) = lens.validateOrder(o3);
        assertFalse(b3);
        assertEq(r3, "curve set without decayStartTime");

        // gasBumpBps > 10000
        Order memory o4 = _plainOrder(4, address(tA), address(tB), SELL_IN, SELL_OUT);
        o4.gasBumpBps = 10_001;
        o4.gasPriceRef = 30 gwei;
        (bool b4, string memory r4) = lens.validateOrder(o4);
        assertFalse(b4);
        assertEq(r4, "gasBumpBps > 10000");
    }

    // ════════════════════ gas bump composed with a decaying auction ════════════════════

    function test_gasBump_plusTimeDecay_sumsAndFills() public {
        uint256 start = SELL_OUT; // 2e18
        uint256 end = 1e18;
        uint64 ref = 30 gwei;

        Order memory order = _plainOrder(1, address(tA), address(tB), SELL_IN, start);
        order.endAmountOut = _u1(end);
        order.decayStartTime = uint32(block.timestamp);
        order.decayDuration = 100;
        order.gasBumpBps = 1_000;
        order.gasPriceRef = ref;
        bytes memory sig = _sign(order);

        // t+50 → auction bump 5000; basefee = half ref → gas add 500; total 5500.
        uint256 exp = start - ((start - end) * 5_500) / 10_000; // 1.45e18
        _fundSell(exp);

        vm.warp(block.timestamp + 50);
        vm.fee(ref / 2);
        assertEq(lens.previewAmountOut(order)[0], exp, "auction + gas bump compose");

        vm.prank(solver);
        assertEq(settlement.fill(order, sig, SELL_IN)[0], exp, "fill uses the composed price");
    }

    function test_gasBump_plusTimeDecay_saturatesToEnd() public {
        Order memory order = _plainOrder(1, address(tA), address(tB), SELL_IN, SELL_OUT);
        order.endAmountOut = _u1(1e18);
        order.decayStartTime = uint32(block.timestamp);
        order.decayDuration = 100;
        order.gasBumpBps = 3_000;
        order.gasPriceRef = 30 gwei;

        // t+80 (auction 8000) + full gas 3000 = 11000 → clamped to 10000 → end price.
        vm.warp(block.timestamp + 80);
        vm.fee(30 gwei);
        assertEq(lens.previewAmountOut(order)[0], 1e18, "bump clamps at 10000 -> end");
    }

    // ════════════════════ non-monotonic / plateau / edge curves ════════════════════

    function test_curve_decreasingAndPlateauSegments() public {
        // Dips 8000→2000, plateaus at 2000, then rises 2000→6000.
        CurvePoint[] memory c = new CurvePoint[](4);
        c[0] = CurvePoint({timeDelta: 0, bumpBps: 8_000});
        c[1] = CurvePoint({timeDelta: 100, bumpBps: 2_000});
        c[2] = CurvePoint({timeDelta: 200, bumpBps: 2_000});
        c[3] = CurvePoint({timeDelta: 300, bumpBps: 6_000});

        uint256 start = SELL_OUT;
        uint256 end = 1e18;
        Order memory order = _plainOrder(1, address(tA), address(tB), SELL_IN, start);
        order.endAmountOut = _u1(end);
        order.decayStartTime = uint32(block.timestamp);
        order.curve = c;

        uint256 t0 = block.timestamp;
        vm.warp(t0 + 50); // decreasing: 8000 - 6000*50/100 = 5000
        assertEq(lens.previewAmountOut(order)[0], start - ((start - end) * 5_000) / 10_000, "decreasing segment");
        vm.warp(t0 + 150); // plateau: 2000
        assertEq(lens.previewAmountOut(order)[0], start - ((start - end) * 2_000) / 10_000, "plateau segment");
        vm.warp(t0 + 250); // rising: 2000 + 4000*50/100 = 4000
        assertEq(lens.previewAmountOut(order)[0], start - ((start - end) * 4_000) / 10_000, "rising segment");
    }

    function test_curve_firstPointNonZeroTime_clampsToFirstBump() public {
        CurvePoint[] memory c = new CurvePoint[](2);
        c[0] = CurvePoint({timeDelta: 50, bumpBps: 2_000});
        c[1] = CurvePoint({timeDelta: 150, bumpBps: 8_000});
        Order memory order = _plainOrder(1, address(tA), address(tB), SELL_IN, SELL_OUT);
        order.endAmountOut = _u1(1e18);
        order.decayStartTime = uint32(block.timestamp);
        order.curve = c;

        vm.warp(block.timestamp + 20); // before first point → clamp to 2000
        assertEq(
            lens.previewAmountOut(order)[0], SELL_OUT - ((SELL_OUT - 1e18) * 2_000) / 10_000, "clamp to first bump"
        );
    }

    function test_curve_singlePoint() public {
        CurvePoint[] memory c = new CurvePoint[](1);
        c[0] = CurvePoint({timeDelta: 0, bumpBps: 4_000});
        Order memory order = _plainOrder(1, address(tA), address(tB), SELL_IN, SELL_OUT);
        order.endAmountOut = _u1(1e18);
        order.decayStartTime = uint32(block.timestamp);
        order.curve = c;

        vm.warp(block.timestamp + 50);
        assertEq(
            lens.previewAmountOut(order)[0], SELL_OUT - ((SELL_OUT - 1e18) * 4_000) / 10_000, "single-point curve"
        );
    }

    function test_curve_fillRevertsBeforeStart() public {
        _fundSell(SELL_OUT);
        Order memory order = _plainOrder(1, address(tA), address(tB), SELL_IN, SELL_OUT);
        order.endAmountOut = _u1(1e18);
        order.decayStartTime = uint32(block.timestamp + 100);
        order.curve = _curve3();
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(DutchAuction.AuctionNotStarted.selector);
        settlement.fill(order, sig, SELL_IN);
    }

    // ════════════════════ partial fills + multi-leg under a curve ════════════════════

    function test_curve_partialFills_perTickPricing() public {
        uint256 start = SELL_OUT;
        uint256 end = 1e18;
        Order memory order = _plainOrder(1, address(tA), address(tB), SELL_IN, start);
        order.endAmountOut = _u1(end);
        order.decayStartTime = uint32(block.timestamp);
        order.curve = _curve3(); // [(0,0),(100,5000),(200,10000)]
        bytes memory sig = _sign(order);

        uint256 t0 = block.timestamp;
        uint256 price1 = start - ((start - end) * 2_500) / 10_000; // bump 2500 at t+50
        uint256 out1 = ((SELL_IN / 2) * price1) / SELL_IN;
        uint256 price2 = start - ((start - end) * 7_500) / 10_000; // bump 7500 at t+150
        uint256 out2 = ((SELL_IN / 2) * price2) / SELL_IN;
        _fundSell(out1 + out2);

        vm.warp(t0 + 50);
        vm.prank(solver);
        assertEq(settlement.fill(order, sig, SELL_IN / 2)[0], out1, "first partial priced at its tick");

        vm.warp(t0 + 150);
        vm.prank(solver);
        assertEq(settlement.fill(order, sig, SELL_IN / 2)[0], out2, "second partial priced at its later tick");
        assertEq(tB.balanceOf(maker), out1 + out2, "maker received both partials");
    }

    function test_curve_multiOutput_sharedBump() public {
        address[] memory tokenOut = new address[](2);
        tokenOut[0] = address(tB);
        tokenOut[1] = address(tC);
        uint256[] memory startO = new uint256[](2);
        startO[0] = 2e18;
        startO[1] = 4e18;
        uint256[] memory endO = new uint256[](2);
        endO[0] = 1e18;
        endO[1] = 2e18;

        Order memory order = _plainOrderMultiOut(1, address(tA), SELL_IN, tokenOut, startO);
        order.endAmountOut = endO;
        order.decayStartTime = uint32(block.timestamp);
        order.curve = _curve3();
        bytes memory sig = _sign(order);

        uint256 outB = 2e18 - (1e18 * 2_500) / 10_000; // shared bump 2500
        uint256 outC = 4e18 - (2e18 * 2_500) / 10_000;
        tA.mint(maker, SELL_IN);
        _makerApprove(address(settlement), address(tA), SELL_IN);
        tB.mint(solver, outB);
        tC.mint(solver, outC);
        _solverApprove(address(settlement), address(tB), outB);
        _solverApprove(address(settlement), address(tC), outC);

        vm.warp(block.timestamp + 50);
        vm.prank(solver);
        uint256[] memory outs = settlement.fill(order, sig, SELL_IN);
        assertEq(outs[0], outB, "leg B shares the bump");
        assertEq(outs[1], outC, "leg C shares the bump");
    }

    // ════════════════════ override composed with auction / callbacks / batch ════════════════════

    function test_override_onDecayedPrice() public {
        uint256 priced = SELL_OUT - ((SELL_OUT - 1e18) * 5_000) / 10_000; // midpoint 1.5e18
        uint256 bumped = (priced * 10_100) / 10_000;
        _fundSell(bumped);

        Order memory order = _plainOrder(1, address(tA), address(tB), SELL_IN, SELL_OUT);
        order.endAmountOut = _u1(1e18);
        order.decayStartTime = uint32(block.timestamp);
        order.decayDuration = 100;
        order.exclusiveFiller = EX;
        order.exclusivityEndTime = uint32(block.timestamp + 1_000);
        order.exclusivityOverrideBps = 100;
        bytes memory sig = _sign(order);

        vm.warp(block.timestamp + 50);
        vm.prank(solver);
        assertEq(settlement.fill(order, sig, SELL_IN)[0], bumped, "override applied on top of the auction price");
    }

    function test_override_fillWithCallback_preDelivery() public {
        uint256 bumped = (SELL_OUT * 10_100) / 10_000;
        Supplier supplier = new Supplier();
        tA.mint(maker, SELL_IN);
        _makerApprove(address(settlement), address(tA), SELL_IN);
        _solverApprove(address(settlement), address(tB), bumped);
        tB.mint(address(supplier), bumped);

        Order memory order = _plainOrder(1, address(tA), address(tB), SELL_IN, SELL_OUT);
        order.exclusiveFiller = EX;
        order.exclusivityEndTime = uint32(block.timestamp + 100);
        order.exclusivityOverrideBps = 100;
        bytes memory sig = _sign(order);
        bytes memory cb = abi.encodeCall(Supplier.supply, (solver, address(tB), bumped));

        vm.prank(solver);
        settlement.fillWithCallback(
            order, sig, SELL_IN, address(supplier), cb, CallbackMode.PreDelivery
        );
        assertEq(tB.balanceOf(maker), bumped, "override honored in PreDelivery callback");
    }

    function test_override_fillWithCallback_postInputs_buy() public {
        uint256 discounted = (BUY_IN * 9_900) / 10_000;
        SwapHelper helper = new SwapHelper();
        tA.mint(maker, BUY_IN);
        _makerApprove(address(settlement), address(tA), BUY_IN);
        _solverApprove(address(settlement), address(tB), BUY_OUT);
        tB.mint(address(helper), BUY_OUT);
        vm.prank(solver);
        tA.approve(address(helper), type(uint256).max);

        Order memory order = _buyOrder(1, address(tA), address(tB), BUY_IN, BUY_IN, BUY_OUT);
        order.exclusiveFiller = EX;
        order.exclusivityEndTime = uint32(block.timestamp + 100);
        order.exclusivityOverrideBps = 100;
        bytes memory sig = _sign(order);
        bytes memory cb = abi.encodeCall(SwapHelper.swap, (solver, address(tA), discounted, address(tB), BUY_OUT));

        vm.prank(solver);
        settlement.fillWithCallback(
            order, sig, BUY_OUT, address(helper), cb, CallbackMode.PostInputs
        );
        assertEq(tB.balanceOf(maker), BUY_OUT, "maker got exact output");
        assertEq(tA.balanceOf(maker), BUY_IN - discounted, "maker paid only the discounted input");
    }

    function test_override_batchFill_threadsFillerAndOverride() public {
        uint256 bumped = (SELL_OUT * 10_100) / 10_000;
        tA.mint(maker, 2 * SELL_IN);
        _makerApprove(address(settlement), address(tA), 2 * SELL_IN);
        tB.mint(solver, bumped);
        _solverApprove(address(settlement), address(tB), bumped);

        Order memory soft = _plainOrder(1, address(tA), address(tB), SELL_IN, SELL_OUT);
        soft.exclusiveFiller = EX;
        soft.exclusivityEndTime = uint32(block.timestamp + 100);
        soft.exclusivityOverrideBps = 100;

        Order memory hard = _plainOrder(2, address(tA), address(tB), SELL_IN, SELL_OUT);
        hard.exclusiveFiller = EX;
        hard.exclusivityEndTime = uint32(block.timestamp + 100);
        hard.exclusivityOverrideBps = 0; // hard → skipped

        Order[] memory orders = new Order[](2);
        orders[0] = soft;
        orders[1] = hard;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(soft);
        sigs[1] = _sign(hard);
        uint256[] memory amts = new uint256[](2);
        amts[0] = SELL_IN;
        amts[1] = SELL_IN;

        vm.prank(solver);
        (, bool[] memory success) = settlement.batchFill(orders, sigs, amts, false);
        assertTrue(success[0], "soft-exclusivity order filled with override");
        assertFalse(success[1], "hard-exclusivity order skipped");
        assertEq(tB.balanceOf(maker), bumped, "override delivered via batchFill");
    }

    function test_override_buy_over10000_reverts() public {
        _fundBuy(BUY_IN);
        Order memory order = _buyOrder(1, address(tA), address(tB), BUY_IN, BUY_IN, BUY_OUT);
        order.exclusiveFiller = EX;
        order.exclusivityEndTime = uint32(block.timestamp + 100);
        order.exclusivityOverrideBps = 10_001; // malformed; validateOrder would reject it
        bytes memory sig = _sign(order);

        // A non-exclusive filler triggers the override; (10000 - 10001) underflows.
        vm.prank(solver);
        vm.expectRevert(stdError.arithmeticError);
        settlement.fill(order, sig, BUY_OUT);
    }

    // ════════════════════ fuzz ════════════════════

    function testFuzz_gasBump_withinBounds(uint256 basefee) public {
        basefee = bound(basefee, 0, 1_000 gwei);
        Order memory order = _plainOrder(1, address(tA), address(tB), SELL_IN, SELL_OUT);
        order.endAmountOut = _u1(1e18);
        order.gasBumpBps = 2_000;
        order.gasPriceRef = 30 gwei;

        vm.fee(basefee);
        uint256 out = lens.previewAmountOut(order)[0];
        // The gas bump only decays the maker's output toward `end`, never past it.
        assertLe(out, SELL_OUT, "never above start");
        assertGe(out, 1e18, "never below end");
    }
}
