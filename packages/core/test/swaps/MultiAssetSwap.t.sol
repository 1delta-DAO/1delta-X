// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, Validator} from "@core/settlement/UniversalSettlement.sol";

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
            nonce: nonce,
            deadline: block.timestamp + 1 hours,
            tokenIn: tokenIn,
            amountIn: amountIn,
            decayStartTime: 0,
            decayDuration: 0,
            tokenOut: tokenOut,
            startAmountOut: amountOut,
            endAmountOut: amountOut,
            exclusiveFiller: address(0),
            exclusivityEndTime: 0,
            minFillAmountIn: 0,
            items: new Item[](0),
            validators: new Validator[](0),
            invariants: new Validator[](0)
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
        assertEq(settlement.remaining(order), usdcIn / 2, "half remaining");

        // Second fill: the rest. Legs accumulate exactly to the signed totals.
        vm.prank(solver);
        uint256[] memory p2 = settlement.fill(order, sig, usdcIn - usdcIn / 2);
        assertEq(p1[0] + p2[0], wethOut, "WETH legs sum to total");
        assertEq(p1[1] + p2[1], daiOut, "DAI legs sum to total");
        assertEq(settlement.remaining(order), 0, "fully filled");

        assertEq(IERC20(WETH).balanceOf(maker), wethOut, "maker got full WETH");
        assertEq(IERC20(DAI).balanceOf(maker), daiOut, "maker got full DAI");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver got full USDC");
    }

    // ──────────────────── validateOrder guards ────────────────────

    function test_validate_rejectsLengthMismatch() public view {
        Order memory order =
            _multiOrder(3, _a1(USDC), _u1(1e6), _addr2(WETH, DAI), _u1(1 ether)); // 2 tokenOut, 1 amount
        (bool ok, string memory reason) = settlement.validateOrder(order);
        assertFalse(ok, "length mismatch rejected");
        assertEq(reason, "tokenOut/amountOut length mismatch");
    }

    function test_validate_rejectsInOutOverlap() public view {
        // WETH appears in both the input and output baskets.
        Order memory order =
            _multiOrder(4, _addr2(WETH, USDC), _uint2(1 ether, 1e6), _a1(WETH), _u1(1 ether));
        (bool ok, string memory reason) = settlement.validateOrder(order);
        assertFalse(ok, "in/out overlap rejected");
        assertEq(reason, "tokenIn == tokenOut");
    }

    function test_validate_rejectsDuplicateTokenIn() public view {
        Order memory order =
            _multiOrder(5, _addr2(USDC, USDC), _uint2(1e6, 2e6), _a1(WETH), _u1(1 ether));
        (bool ok, string memory reason) = settlement.validateOrder(order);
        assertFalse(ok, "duplicate tokenIn rejected");
        assertEq(reason, "duplicate tokenIn");
    }
}
