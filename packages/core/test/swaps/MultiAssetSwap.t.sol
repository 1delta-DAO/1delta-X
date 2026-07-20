// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {stdError} from "forge-std/StdError.sol";

import {Order, Item, Validator, OrderSide} from "@core/settlement/Settlement.sol";

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
        return Order({
            maker: maker,
            side: OrderSide.SELL,
            nonce: nonce,
            deadline: block.timestamp + 1 hours,
            tokenIn: tokenIn,
            startAmountIn: amountIn,
            endAmountIn: amountIn,
            decayStartTime: 0,
            decayDuration: 0,
            tokenOut: tokenOut,
            startAmountOut: amountOut,
            endAmountOut: amountOut,
            recipientOut: new address[](tokenOut.length),
            exclusiveFiller: address(0),
            exclusivityEndTime: 0,
            minFillAnchor: 0,
            exclusivityOverrideBps: 0,
            curve: _noCurve(),
            gasBumpBps: 0,
            gasPriceRef: 0,
            items: new Item[](0),
            validators: new Validator[](0),
            invariants: new Validator[](0),
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

        Order memory order =
            _multiOrder(0, _a1(USDC), _u1(usdcIn), _addr2(WETH, DAI), _uint2(wethOut, daiOut));
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

        Order memory order =
            _multiOrder(1, _addr2(WETH, USDC), _uint2(wethIn, usdcIn), _a1(DAI), _u1(daiOut));
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

        Order memory order =
            _multiOrder(2, _a1(USDC), _u1(usdcIn), _addr2(WETH, DAI), _uint2(wethOut, daiOut));
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

        Order memory order = Order({
            maker: maker,
            side: OrderSide.SELL,
            nonce: 6,
            deadline: block.timestamp + 1 hours,
            tokenIn: _a1(USDC),
            startAmountIn: _u1(usdcIn),
            endAmountIn: _u1(usdcIn),
            decayStartTime: uint32(block.timestamp),
            decayDuration: 100,
            tokenOut: _addr2(WETH, DAI),
            startAmountOut: _uint2(wethStart, daiStart),
            endAmountOut: _uint2(wethEnd, daiEnd),
            recipientOut: new address[](2),
            exclusiveFiller: address(0),
            exclusivityEndTime: 0,
            minFillAnchor: 0,
            exclusivityOverrideBps: 0,
            curve: _noCurve(),
            gasBumpBps: 0,
            gasPriceRef: 0,
            items: new Item[](0),
            validators: new Validator[](0),
            invariants: new Validator[](0),
            fillModule: address(0),
            fillTotal: 0
        });
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

    function test_validate_rejectsLengthMismatch() public view {
        Order memory order =
            _multiOrder(3, _a1(USDC), _u1(1e6), _addr2(WETH, DAI), _u1(1 ether)); // 2 tokenOut, 1 amount
        (bool ok, string memory reason) = lens.validateOrder(order);
        assertFalse(ok, "length mismatch rejected");
        assertEq(reason, "tokenOut/amountOut length mismatch");
    }

    function test_validate_rejectsInOutOverlap() public view {
        // WETH appears in both the input and output baskets.
        Order memory order =
            _multiOrder(4, _addr2(WETH, USDC), _uint2(1 ether, 1e6), _a1(WETH), _u1(1 ether));
        (bool ok, string memory reason) = lens.validateOrder(order);
        assertFalse(ok, "in/out overlap rejected");
        assertEq(reason, "tokenIn == tokenOut");
    }

    function test_validate_rejectsDuplicateTokenIn() public view {
        Order memory order =
            _multiOrder(5, _addr2(USDC, USDC), _uint2(1e6, 2e6), _a1(WETH), _u1(1 ether));
        (bool ok, string memory reason) = lens.validateOrder(order);
        assertFalse(ok, "duplicate tokenIn rejected");
        assertEq(reason, "duplicate tokenIn");
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
        Order memory order =
            _multiOrder(10, _addr2(USDC, USDC), _uint2(a, b), _a1(WETH), _u1(wethOut));
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

    /// @dev A tokenOut/amountOut length mismatch safe-fails: `_deliverOutputs`
    ///      indexes the shorter price array and reverts (array OOB) instead of
    ///      silently mispricing.
    function test_fill_outputLengthMismatch_reverts() public {
        deal(USDC, maker, 1_000e6);
        deal(WETH, solver, 1 ether); //   fund leg 0 so we reach the OOB on leg 1
        _approveMakerToSettlement(USDC, 1_000e6);
        _approveSolverSide(1 ether, WETH);

        // 2 tokenOut, 1 price entry — leg 0 (WETH) delivers, leg 1 indexes startAmountOut[1].
        Order memory order = _multiOrder(11, _a1(USDC), _u1(1_000e6), _addr2(WETH, DAI), _u1(1 ether));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(stdError.indexOOBError);
        settlement.fill(order, sig, 1_000e6);
    }

    /// @dev A tokenIn/amountIn length mismatch safe-fails: `_payInputsToSolver`
    ///      indexes the shorter amount array and reverts (array OOB).
    function test_fill_inputLengthMismatch_reverts() public {
        deal(USDC, maker, 1_000e6);
        deal(WETH, solver, 1 ether);
        _approveMakerToSettlement(USDC, 1_000e6);
        _approveSolverSide(1 ether, WETH);

        // 2 tokenIn, 1 amount entry.
        Order memory order = _multiOrder(12, _addr2(USDC, DAI), _u1(1_000e6), _a1(WETH), _u1(1 ether));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(stdError.indexOOBError);
        settlement.fill(order, sig, 1_000e6);
    }
}
