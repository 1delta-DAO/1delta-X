// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "../shared/PackedEncode.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, Validator, LegIn, LegOut, OrderSide} from "@core/settlement/Settlement.sol";

import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @dev Multi-asset conversion leg: the maker gives a basket
///      (`tokenIn[]`/`amountIn[]`) and/or receives a basket
///      (`tokenOut[]`/`startAmountOut[]`/`endAmountOut[]`). Partial fills are
///      driven by the single fraction `fillAmountIn / amountIn[0]`, so every
///      input and output leg scales together. No lending items — this is the
///      purest exercise of the new multi-asset swap mechanics.
contract MultiAssetSwapTest is CoreSettlementBase {
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    function setUp() public override {
        super.setUp();
        vm.label(DAI, "DAI");
        // Maker + solver bare-approve DAI to Permit3 (base only wires WETH/USDC).
        vm.prank(maker);
        IERC20(DAI).approve(address(permit3), type(uint256).max);
        vm.prank(solver);
        IERC20(DAI).approve(address(permit3), type(uint256).max);
    }

    /// @dev Build a fixed-price multi-asset order (start == end on every output).
    function _multiOrder(
        uint256 nonce,
        address[] memory tokenIn,
        uint256[] memory amountIn,
        address[] memory tokenOut,
        uint256[] memory amountOut
    ) internal view returns (Order memory) {
        LegIn[] memory legsIn = new LegIn[](tokenIn.length);
        for (uint256 i; i < tokenIn.length; i++) {
            legsIn[i] = LegIn(tokenIn[i], amountIn[i], 0); // fixed input (end == 0)
        }
        LegOut[] memory legsOut = new LegOut[](tokenOut.length);
        for (uint256 j; j < tokenOut.length; j++) {
            legsOut[j] = LegOut(tokenOut[j], amountOut[j], 0, address(0)); // fixed output (end == 0)
        }
        return Order({
            params: 0,
            pricingModule: address(0),
            maker: maker,
            nonce: nonce,
            legsIn: PackedEncode.legsIn(legsIn),
            legsOut: PackedEncode.legsOut(legsOut),
            timing: _expiryBits(block.timestamp + 1 hours),
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

    function _addr2(address a, address b) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _uint2(uint256 a, uint256 b) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](2);
        arr[0] = a;
        arr[1] = b;
    }

    // ──────────────────── Multi-OUT: one asset in, basket out ────────────────────

    function test_multiOut_full() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        uint256 daiOut = 1_000e18;

        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);
        deal(DAI, solver, daiOut);

        _approveMakerToSettlement(USDC, usdcIn);
        _approveSolverSide(wethOut, WETH);
        _approveSolverSide(daiOut, DAI);

        Order memory order = _multiOrder(0, _a1(USDC), _u1(usdcIn), _addr2(WETH, DAI), _uint2(wethOut, daiOut));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256[] memory paid = settlement.fill(order, sig, usdcIn);

        assertEq(paid.length, 2, "two output legs");
        assertEq(paid[0], wethOut, "WETH leg paid");
        assertEq(paid[1], daiOut, "DAI leg paid");

        // Maker gave USDC, received the WETH + DAI basket straight to wallet.
        assertEq(IERC20(USDC).balanceOf(maker), 0, "maker USDC spent");
        assertEq(IERC20(WETH).balanceOf(maker), wethOut, "maker received WETH");
        assertEq(IERC20(DAI).balanceOf(maker), daiOut, "maker received DAI");

        // Solver gave the basket, received USDC.
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver received USDC");
        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver WETH spent");
        assertEq(IERC20(DAI).balanceOf(solver), 0, "solver DAI spent");

        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement drained");
    }

    // ──────────────────── Multi-IN: basket in, one asset out ────────────────────

    function test_multiIn_full() public {
        uint256 wethIn = 1 ether; //   amountIn[0] — the fill denominator
        uint256 usdcIn = 500e6;
        uint256 daiOut = 1_500e18;

        deal(WETH, maker, wethIn);
        deal(USDC, maker, usdcIn);
        deal(DAI, solver, daiOut);

        _approveMakerToSettlement(WETH, wethIn);
        _approveMakerToSettlement(USDC, usdcIn);
        _approveSolverSide(daiOut, DAI);

        Order memory order = _multiOrder(1, _addr2(WETH, USDC), _uint2(wethIn, usdcIn), _a1(DAI), _u1(daiOut));
        bytes memory sig = _sign(order);

        // fillAmountIn is in tokenIn[0] (WETH) units; full fill == amountIn[0].
        vm.prank(solver);
        uint256[] memory paid = settlement.fill(order, sig, wethIn);

        assertEq(paid[0], daiOut, "DAI leg paid");

        // Solver received the full WETH + USDC basket.
        assertEq(IERC20(WETH).balanceOf(solver), wethIn, "solver received WETH");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver received USDC");
        // Maker received DAI.
        assertEq(IERC20(DAI).balanceOf(maker), daiOut, "maker received DAI");
        assertEq(IERC20(WETH).balanceOf(maker), 0, "maker WETH spent");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "maker USDC spent");

        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
    }

    // ──────────────────── Partial fill scales the whole basket ────────────────────

    function test_multiOut_partialFill_scalesBasket() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        uint256 daiOut = 1_000e18;

        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);
        deal(DAI, solver, daiOut);

        _approveMakerToSettlement(USDC, usdcIn);
        _approveSolverSide(wethOut, WETH);
        _approveSolverSide(daiOut, DAI);

        Order memory order = _multiOrder(2, _a1(USDC), _u1(usdcIn), _addr2(WETH, DAI), _uint2(wethOut, daiOut));
        bytes memory sig = _sign(order);

        // First fill: half → every output leg halves.
        vm.prank(solver);
        uint256[] memory p1 = settlement.fill(order, sig, usdcIn / 2);
        assertEq(p1[0], wethOut / 2, "WETH half");
        assertEq(p1[1], daiOut / 2, "DAI half");
        assertEq(lens.remaining(order), usdcIn / 2, "half remaining");

        // Second fill: the rest. Legs accumulate exactly to the signed totals.
        vm.prank(solver);
        uint256[] memory p2 = settlement.fill(order, sig, usdcIn - usdcIn / 2);
        assertEq(p1[0] + p2[0], wethOut, "WETH legs sum to total");
        assertEq(p1[1] + p2[1], daiOut, "DAI legs sum to total");
        assertEq(lens.remaining(order), 0, "fully filled");

        assertEq(IERC20(WETH).balanceOf(maker), wethOut, "maker got full WETH");
        assertEq(IERC20(DAI).balanceOf(maker), daiOut, "maker got full DAI");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver got full USDC");
    }

    // ──────────────────── Multi-out dutch auction + partial fill ────────────────────

    /// @dev Every output leg auctions simultaneously on ONE shared clock, each
    ///      decaying between its own start/end bounds — and a partial fill still
    ///      slices the whole basket by fillAmountIn / amountIn[0].
    /// @dev Two output legs on one shared decay clock (100s from now).
    function _twoCurveOrder(uint256 usdcIn, uint256 wethStart, uint256 wethEnd, uint256 daiStart, uint256 daiEnd)
        internal
        view
        returns (Order memory order)
    {
        LegOut[] memory legsOut = new LegOut[](2);
        legsOut[0] = LegOut(WETH, wethStart, wethEnd, address(0));
        legsOut[1] = LegOut(DAI, daiStart, daiEnd, address(0));
        order = Order({
            params: 0,
            pricingModule: address(0),
            maker: maker,
            nonce: 6,
            legsIn: _legsIn1(USDC, usdcIn),
            legsOut: PackedEncode.legsOut(legsOut),
            timing: _packTiming(uint32(block.timestamp), 100, 0) | _expiryBits(block.timestamp + 1 hours),
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

    function test_multiOut_dutchDecay_partialFill() public {
        uint256 usdcIn = 2_000e6;
        // Two DIFFERENT decay curves, one clock.
        uint256 wethStart = 1 ether;
        uint256 wethEnd = 0.8 ether;
        uint256 daiStart = 1_000e18;
        uint256 daiEnd = 900e18;

        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethStart);
        deal(DAI, solver, daiStart);

        _approveMakerToSettlement(USDC, usdcIn);
        _approveSolverSide(wethStart, WETH);
        _approveSolverSide(daiStart, DAI);

        Order memory order = _twoCurveOrder(usdcIn, wethStart, wethEnd, daiStart, daiEnd);
        bytes memory sig = _sign(order);

        // Warp to the auction midpoint → each leg decays halfway.
        vm.warp(block.timestamp + 50);
        uint256 wethMid = wethStart - (wethStart - wethEnd) / 2; // 0.9 ether
        uint256 daiMid = daiStart - (daiStart - daiEnd) / 2; //    950e18

        uint256[] memory preview = lens.previewAmountOut(order);
        assertEq(preview[0], wethMid, "WETH midpoint price");
        assertEq(preview[1], daiMid, "DAI midpoint price");

        // Partial fill: half the order at the midpoint tick → half of each leg.
        vm.prank(solver);
        uint256[] memory paid = settlement.fill(order, sig, usdcIn / 2);
        assertEq(paid[0], wethMid / 2, "WETH leg = half of midpoint");
        assertEq(paid[1], daiMid / 2, "DAI leg = half of midpoint");
        assertEq(lens.remaining(order), usdcIn / 2, "half remaining");

        assertEq(IERC20(WETH).balanceOf(maker), wethMid / 2, "maker got half WETH");
        assertEq(IERC20(DAI).balanceOf(maker), daiMid / 2, "maker got half DAI");
    }

    // ──────────────────── validateOrder guards ────────────────────

    // NB: `tokenIn/amountIn` (and `tokenOut/amountOut`) length-mismatch cases are
    // gone — each leg now bundles its token with its amounts in one LegIn/LegOut
    // struct, so a parallel-array mismatch is structurally impossible to express.

    function test_validate_rejectsInOutOverlap() public view {
        // WETH appears in both the input and output baskets.
        Order memory order = _multiOrder(4, _addr2(WETH, USDC), _uint2(1 ether, 1e6), _a1(WETH), _u1(1 ether));
        (bool ok, string memory reason) = lens.validateOrder(order);
        assertFalse(ok, "in/out overlap rejected");
        assertEq(reason, "input token == output token");
    }

    function test_validate_rejectsDuplicateTokenIn() public view {
        Order memory order = _multiOrder(5, _addr2(USDC, USDC), _uint2(1e6, 2e6), _a1(WETH), _u1(1 ether));
        (bool ok, string memory reason) = lens.validateOrder(order);
        assertFalse(ok, "duplicate tokenIn rejected");
        assertEq(reason, "duplicate input token");
    }

    // ──────────────────── On-chain safe-fail of malformed orders ────────────────────
    //
    // `validateOrder` is view-only and NOT called during `fill`. These lock in the
    // trust-model claim: a malformed order that slips past off-chain validation can
    // only ever harm its own maker — protocol funds and the solver stay safe, and
    // shape mismatches revert rather than misbehave.

    /// @dev A duplicate `tokenIn` entry is a maker footgun, not a protocol bug: the
    ///      order simply sells the SUM of the two duplicate legs. Every move is still
    ///      gated by the maker's own Permit3 allowance, Settlement is never drained,
    ///      and the solver receives exactly what it paid for.
    function test_fill_duplicateTokenIn_onlyChargesMaker() public {
        uint256 a = 500e6;
        uint256 b = 300e6;
        uint256 wethOut = 1 ether;

        deal(USDC, maker, a + b);
        deal(WETH, solver, wethOut);

        _approveMakerToSettlement(USDC, a + b);
        _approveSolverSide(wethOut, WETH);

        // Duplicate USDC leg — rejected off-chain, but nothing stops an on-chain fill.
        Order memory order = _multiOrder(10, _addr2(USDC, USDC), _uint2(a, b), _a1(WETH), _u1(wethOut));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256[] memory paid = settlement.fill(order, sig, a); // fillAmountIn == amountIn[0]

        assertEq(paid[0], wethOut, "maker paid the full output leg");
        // Maker is charged the SUM of both duplicate legs — the footgun, self-inflicted.
        assertEq(IERC20(USDC).balanceOf(maker), 0, "maker debited a + b");
        assertEq(IERC20(USDC).balanceOf(solver), a + b, "solver received exactly a + b");
        // Protocol invariant: Settlement never accumulates or leaks value.
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement drained");
        assertEq(IERC20(WETH).balanceOf(maker), wethOut, "maker received the output");
    }

    // NB: the former `test_fill_{output,input}LengthMismatch_reverts` cases are
    // obsolete — bundling token+amounts per leg removes the parallel-array shape
    // that could desynchronize, so there is no longer an on-chain OOB to guard.
}
