// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "../shared/PackedEncode.sol";

import {OrderState} from "@core/settlement/OrderState.sol";
import {Base} from "@core/settlement/Base.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, Validator, LegIn, LegOut, OrderSide} from "@core/settlement/Settlement.sol";
import {Settlement} from "@core/settlement/Settlement.sol";
import {DutchAuction} from "@core/settlement/DutchAuction.sol";

import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @dev Partial-fill math and dutch-auction edges for the multi-asset
///      conversion leg. Everything here is a pure swap (no items), so it
///      isolates the single-fraction scaling `f = fillAmountIn / amountIn[0]`
///      and the per-leg auction pricing.
contract MultiAssetPartialsTest is CoreSettlementBase {
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    function setUp() public override {
        super.setUp();
        vm.label(DAI, "DAI");
        vm.label(WBTC, "WBTC");
        vm.startPrank(maker);
        IERC20(DAI).approve(address(permit3), type(uint256).max);
        IERC20(WBTC).approve(address(permit3), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(solver);
        IERC20(DAI).approve(address(permit3), type(uint256).max);
        IERC20(WBTC).approve(address(permit3), type(uint256).max);
        vm.stopPrank();
    }

    // ──────────────────── builders ────────────────────

    function _order(
        uint256 nonce,
        address[] memory tokenIn,
        uint256[] memory amountIn,
        address[] memory tokenOut,
        uint256[] memory startOut,
        uint256[] memory endOut,
        uint32 decayStart,
        uint32 decayDur
    ) internal view returns (Order memory) {
        LegIn[] memory legsIn = new LegIn[](tokenIn.length);
        for (uint256 i; i < tokenIn.length; i++) {
            legsIn[i] = LegIn(tokenIn[i], amountIn[i], 0); // fixed input (end == 0)
        }
        LegOut[] memory legsOut = new LegOut[](tokenOut.length);
        for (uint256 j; j < tokenOut.length; j++) {
            legsOut[j] = LegOut(tokenOut[j], startOut[j], endOut[j], address(0));
        }
        return Order({
            params: 0,
            pricingModule: address(0),
            maker: maker,
            nonce: nonce,
            legsIn: PackedEncode.legsIn(legsIn),
            legsOut: PackedEncode.legsOut(legsOut),
            timing: _packTiming(decayStart, decayDur, 0) | _expiryBits(block.timestamp + 1 hours),
            exclusiveFiller: address(0),
            minFillAnchor: 0,
            curve: PackedEncode.noCurve(),
            items: PackedEncode.noItems(),
            validators: PackedEncode.noValidators(),
            invariants: PackedEncode.noValidators(),
            fillModule: address(0),
            fillTotal: 0
        });
    }

    function _fixed(
        uint256 nonce,
        address[] memory tokenIn,
        uint256[] memory amountIn,
        address[] memory tokenOut,
        uint256[] memory amountOut
    ) internal view returns (Order memory) {
        return _order(nonce, tokenIn, amountIn, tokenOut, amountOut, amountOut, 0, 0);
    }

    function _a2(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        r[0] = a;
        r[1] = b;
    }

    function _u2(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }

    // ──────────────────── multi-IN partial ────────────────────

    /// @dev Basket in, one out; a half fill halves BOTH inputs and the output.
    function test_multiIn_partialFill_scalesBasket() public {
        uint256 wethIn = 1 ether; // amountIn[0] (fill denominator)
        uint256 usdcIn = 500e6;
        uint256 daiOut = 1_500e18;

        deal(WETH, maker, wethIn);
        deal(USDC, maker, usdcIn);
        deal(DAI, solver, daiOut);
        _approveMakerToSettlement(WETH, wethIn);
        _approveMakerToSettlement(USDC, usdcIn);
        _approveSolverSide(daiOut, DAI);

        Order memory order = _fixed(0, _a2(WETH, USDC), _u2(wethIn, usdcIn), _a1(DAI), _u1(daiOut));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256[] memory p1 = settlement.fill(order, sig, wethIn / 2);
        assertEq(p1[0], daiOut / 2, "DAI half");
        assertEq(IERC20(WETH).balanceOf(solver), wethIn / 2, "solver got half WETH");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn / 2, "solver got half USDC");
        assertEq(lens.remaining(order), wethIn / 2, "half remaining");

        vm.prank(solver);
        settlement.fill(order, sig, wethIn - wethIn / 2);
        assertEq(IERC20(WETH).balanceOf(solver), wethIn, "solver got all WETH");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver got all USDC");
        assertEq(IERC20(DAI).balanceOf(maker), daiOut, "maker got all DAI");
    }

    // ──────────────────── 2-in × 2-out ────────────────────

    /// @dev Four distinct tokens: maker gives {WETH, USDC}, receives {DAI, WBTC}.
    ///      An uneven partial then the remainder; every leg scales by the same
    ///      fraction and accumulates to its signed total.
    function test_2in2out_partial_thenFull() public {
        uint256 wethIn = 1 ether; // amountIn[0]
        uint256 usdcIn = 2_000e6;
        uint256 daiOut = 1_500e18;
        uint256 wbtcOut = 0.05e8; // WBTC, 8 decimals

        deal(WETH, maker, wethIn);
        deal(USDC, maker, usdcIn);
        deal(DAI, solver, daiOut);
        deal(WBTC, solver, wbtcOut);
        _approveMakerToSettlement(WETH, wethIn);
        _approveMakerToSettlement(USDC, usdcIn);
        _approveSolverSide(daiOut, DAI);
        _approveSolverSide(wbtcOut, WBTC);

        Order memory order = _fixed(1, _a2(WETH, USDC), _u2(wethIn, usdcIn), _a2(DAI, WBTC), _u2(daiOut, wbtcOut));
        bytes memory sig = _sign(order);

        // 30% then 70%.
        vm.prank(solver);
        uint256[] memory p1 = settlement.fill(order, sig, 0.3 ether);
        assertEq(p1[0], daiOut * 3 / 10, "DAI 30%");
        assertEq(p1[1], wbtcOut * 3 / 10, "WBTC 30%");
        assertEq(IERC20(WETH).balanceOf(solver), 0.3 ether, "WETH 30%");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn * 3 / 10, "USDC 30%");

        vm.prank(solver);
        settlement.fill(order, sig, 0.7 ether);
        assertEq(lens.remaining(order), 0, "filled");
        // All four legs accumulate exactly to their signed totals.
        assertEq(IERC20(WETH).balanceOf(solver), wethIn, "WETH exact");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "USDC exact");
        assertEq(IERC20(DAI).balanceOf(maker), daiOut, "DAI exact");
        assertEq(IERC20(WBTC).balanceOf(maker), wbtcOut, "WBTC exact");
    }

    // ──────────────────── rounding: inputs sum exactly, outputs ceil ────────────────────

    /// @dev Uneven thirds. Cumulative pro-rata makes every INPUT leg sum to its
    ///      exact total; per-fill ceil on the OUTPUT means the maker is never
    ///      underpaid (sum ≥ nominal, by at most (#fills-1) wei).
    function test_thirds_inputsExact_outputCeil() public {
        uint256 usdcIn = 3_000e6; // amountIn[0]
        uint256 daiIn = 900e18; //   amountIn[1]
        uint256 wethOut = 1 ether; // not divisible by 3 → exercises ceil

        deal(USDC, maker, usdcIn);
        deal(DAI, maker, daiIn);
        deal(WETH, solver, wethOut + 10); // headroom for ceil dust
        _approveMakerToSettlement(USDC, usdcIn);
        _approveMakerToSettlement(DAI, daiIn);
        _approveSolverSide(wethOut + 10, WETH);

        Order memory order = _fixed(2, _a2(USDC, DAI), _u2(usdcIn, daiIn), _a1(WETH), _u1(wethOut));
        bytes memory sig = _sign(order);

        uint256 got;
        vm.prank(solver);
        got += settlement.fill(order, sig, 1_000e6)[0];
        vm.prank(solver);
        got += settlement.fill(order, sig, 1_000e6)[0];
        vm.prank(solver);
        got += settlement.fill(order, sig, 1_000e6)[0];

        assertEq(lens.remaining(order), 0, "fully filled");
        // Inputs: exact cumulative totals.
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "USDC exact");
        assertEq(IERC20(DAI).balanceOf(solver), daiIn, "DAI exact");
        // Output: maker never underpaid; ceil dust is tiny.
        assertGe(got, wethOut, "maker got at least nominal");
        assertLe(got - wethOut, 2, "ceil dust <= (#fills - 1) wei");
        assertEq(IERC20(WETH).balanceOf(maker), got, "maker WETH == sum of legs");
    }

    // ──────────────────── multi-IN dutch decay ────────────────────

    function test_multiIn_dutchDecay_midpoint() public {
        uint256 wethIn = 1 ether;
        uint256 usdcIn = 500e6;
        uint256 daiStart = 1_600e18;
        uint256 daiEnd = 1_400e18;

        deal(WETH, maker, wethIn);
        deal(USDC, maker, usdcIn);
        deal(DAI, solver, daiStart);
        _approveMakerToSettlement(WETH, wethIn);
        _approveMakerToSettlement(USDC, usdcIn);
        _approveSolverSide(daiStart, DAI);

        Order memory order = _order(
            3, _a2(WETH, USDC), _u2(wethIn, usdcIn), _a1(DAI), _u1(daiStart), _u1(daiEnd), uint32(block.timestamp), 100
        );
        bytes memory sig = _sign(order);

        vm.warp(block.timestamp + 50);
        uint256 mid = daiStart - (daiStart - daiEnd) / 2; // 1500e18
        assertEq(lens.previewAmountOut(order)[0], mid, "midpoint price");

        vm.prank(solver);
        uint256[] memory paid = settlement.fill(order, sig, wethIn);
        assertEq(paid[0], mid, "full fill at midpoint tick");
        assertEq(IERC20(DAI).balanceOf(maker), mid, "maker got midpoint DAI");
    }

    // ──────────────────── auction edges ────────────────────

    function test_auctionNotStarted_reverts() public {
        Order memory order = _order(
            4, _a1(USDC), _u1(1_000e6), _a1(WETH), _u1(1 ether), _u1(0.9 ether), uint32(block.timestamp + 1000), 100
        );
        deal(USDC, maker, 1_000e6);
        deal(WETH, solver, 1 ether);
        _approveMakerToSettlement(USDC, 1_000e6);
        _approveSolverSide(1 ether, WETH);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(DutchAuction.AuctionNotStarted.selector);
        settlement.fill(order, sig, 1_000e6);
    }

    function test_auctionElapsed_floorPrice() public {
        uint256 start = 1 ether;
        uint256 end = 0.9 ether;
        Order memory order =
            _order(5, _a1(USDC), _u1(1_000e6), _a1(WETH), _u1(start), _u1(end), uint32(block.timestamp), 100);
        deal(USDC, maker, 1_000e6);
        deal(WETH, solver, start);
        _approveMakerToSettlement(USDC, 1_000e6);
        _approveSolverSide(start, WETH);
        bytes memory sig = _sign(order);

        vm.warp(block.timestamp + 500); // well past duration
        vm.prank(solver);
        uint256[] memory paid = settlement.fill(order, sig, 1_000e6);
        assertEq(paid[0], end, "price pinned at floor after duration");
    }

    function test_startBelowEnd_revertsAtFill() public {
        // start < end on the (only) output leg → InvalidAuctionParams in pricing.
        Order memory order =
            _order(6, _a1(USDC), _u1(1_000e6), _a1(WETH), _u1(0.8 ether), _u1(1 ether), uint32(block.timestamp), 100);
        deal(USDC, maker, 1_000e6);
        deal(WETH, solver, 1 ether);
        _approveMakerToSettlement(USDC, 1_000e6);
        _approveSolverSide(1 ether, WETH);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(DutchAuction.InvalidAuctionParams.selector);
        settlement.fill(order, sig, 1_000e6);
    }

    // ──────────────────── fill-count guards ────────────────────

    function test_overFill_reverts() public {
        Order memory order = _fixed(7, _a1(USDC), _u1(1_000e6), _a1(WETH), _u1(1 ether));
        deal(USDC, maker, 1_000e6);
        deal(WETH, solver, 1 ether);
        _approveMakerToSettlement(USDC, 1_000e6);
        _approveSolverSide(1 ether, WETH);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, 1_000e6); // full
        vm.prank(solver);
        vm.expectRevert(OrderState.OverFill.selector);
        settlement.fill(order, sig, 1);
    }

    function test_zeroFill_reverts() public {
        Order memory order = _fixed(8, _a1(USDC), _u1(1_000e6), _a1(WETH), _u1(1 ether));
        bytes memory sig = _sign(order);
        vm.prank(solver);
        vm.expectRevert(OrderState.ZeroFill.selector);
        settlement.fill(order, sig, 0);
    }
}
