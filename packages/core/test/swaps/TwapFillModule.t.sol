// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {UniversalSettlement, CallbackMode, Order, Item, OrderSide, Validator} from "@core/settlement/UniversalSettlement.sol";
import {TwapFillModule} from "@core/modules/TwapFillModule.sol";
import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @dev A mock DEX for the PostInputs callback: pulls the solver's just-received
///      `tokenIn` and hands back `tokenOut` from its own stock — models the solver
///      converting the input it was paid into the output it must deliver, with no
///      inventory and no flash.
contract TwapSwapHelper {
    function swap(address who, address tokenIn, uint256 amtIn, address tokenOut, uint256 amtOut) external {
        IERC20(tokenIn).transferFrom(who, address(this), amtIn);
        IERC20(tokenOut).transfer(who, amtOut);
    }
}

/// @dev TWAP as a fill module: one signed order (sell 1000 USDC into WETH),
/// released in 10 equal 100-USDC parts over a 1000s window (one part / 100s).
/// The module gates each fill to the parts whose window has opened — no fill
/// runs ahead of schedule, one part per window is steady state, a skipped-window
/// solver can catch up, and the core caps total at fillTotal. Fixed price per
/// part (0.05 WETH / 100 USDC); pricing is orthogonal to the schedule.
contract TwapFillModuleTest is CoreSettlementBase {
    TwapFillModule twap;

    uint256 constant TOTAL = 1_000e6; //   sell 1000 USDC
    uint256 constant PART = 100e6; //      per part (⇒ 10 parts)
    uint256 constant WETH_TOTAL = 0.5 ether; // total WETH received (rate 2000)
    uint256 constant WETH_PART = WETH_TOTAL * PART / TOTAL; // 0.05 WETH / part
    uint32 constant DURATION = 1000; //    ⇒ partDuration = 100

    function setUp() public override {
        super.setUp();
        twap = new TwapFillModule();
        vm.label(address(twap), "twapFillModule");
    }

    function _twapOrder(uint256 nonce, uint32 startTime, uint256 total, uint256 part)
        internal
        view
        returns (Order memory o)
    {
        o = _order(maker, nonce, USDC, WETH, total, WETH_TOTAL, new Item[](0));
        o.startAmountOut = _u1(total * WETH_TOTAL / TOTAL); // scale WETH to `total`
        o.endAmountOut = o.startAmountOut;
        o.fillModule = address(twap);
        o.fillTotal = total; //         the TWAP total (denominator)
        o.minFillAnchor = part; //      part size ⇒ parts = total/part
        o.decayStartTime = startTime; //TWAP start
        o.decayDuration = DURATION; //  total window
    }

    function _fund() internal {
        deal(USDC, maker, TOTAL);
        deal(WETH, solver, WETH_TOTAL);
        _approveMakerToSettlement(USDC, TOTAL);
        _approveSolverSide(WETH_TOTAL, WETH);
    }

    // ── The full schedule: one part per window, ahead-of-schedule reverts,
    //    catch-up, completion, and the post-completion revert. ──
    function test_twap_schedule() public {
        _fund();
        uint32 t0 = uint32(block.timestamp);
        Order memory o = _twapOrder(1, t0, TOTAL, PART);
        bytes memory sig = _sign(o);

        // Part 1 opens at t0.
        vm.prank(solver);
        settlement.fill(o, sig, PART);
        assertEq(IERC20(WETH).balanceOf(maker), WETH_PART, "part 1: maker got 0.05 WETH");
        assertEq(IERC20(USDC).balanceOf(solver), PART, "part 1: solver got 100 USDC");

        // Second fill in the SAME window → nothing new unlocked → revert.
        vm.prank(solver);
        vm.expectRevert(TwapFillModule.TwapPartUnavailable.selector);
        settlement.fill(o, sig, PART);

        // Part 2 window.
        vm.warp(t0 + 100);
        vm.prank(solver);
        settlement.fill(o, sig, PART);
        assertEq(IERC20(WETH).balanceOf(maker), 2 * WETH_PART, "part 2 filled");

        // Skip to window 5 → catch up parts 3,4,5 in one fill (large fillAmount).
        vm.warp(t0 + 400);
        vm.prank(solver);
        settlement.fill(o, sig, TOTAL);
        assertEq(IERC20(WETH).balanceOf(maker), 5 * WETH_PART, "caught up to 5 parts");
        assertEq(IERC20(USDC).balanceOf(solver), 5 * PART, "solver has 500 USDC");

        // Final window → the remaining 5 parts complete the order.
        vm.warp(t0 + 900);
        vm.prank(solver);
        settlement.fill(o, sig, TOTAL);
        assertEq(IERC20(WETH).balanceOf(maker), WETH_TOTAL, "TWAP complete: 0.5 WETH");
        assertEq(IERC20(USDC).balanceOf(solver), TOTAL, "solver has all 1000 USDC");

        // Order fully filled → any further fill reverts (nothing left to unlock).
        vm.warp(t0 + 2000);
        vm.prank(solver);
        vm.expectRevert(TwapFillModule.TwapPartUnavailable.selector);
        settlement.fill(o, sig, PART);
    }

    // ── No fill before the schedule starts. ──
    function test_twap_beforeStart_reverts() public {
        _fund();
        uint32 t0 = uint32(block.timestamp);
        Order memory o = _twapOrder(2, t0 + 500, TOTAL, PART); // starts in the future
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(TwapFillModule.TwapPartUnavailable.selector);
        settlement.fill(o, sig, PART);
    }

    // ── A solver may take FEWER whole parts than are open (one part's liquidity
    //    at a time), rounded to a part boundary. ──
    function test_twap_respectsFillAmount() public {
        _fund();
        uint32 t0 = uint32(block.timestamp);
        Order memory o = _twapOrder(3, t0, TOTAL, PART);
        bytes memory sig = _sign(o);

        // 5 parts are open, but the solver fills just one.
        vm.warp(t0 + 400);
        vm.prank(solver);
        settlement.fill(o, sig, PART); // requests one part
        assertEq(IERC20(WETH).balanceOf(maker), WETH_PART, "only one part filled despite 5 open");
        assertEq(IERC20(USDC).balanceOf(solver), PART, "solver took one part");
    }

    // ── Misconfigured schedule (total not a whole number of parts) reverts. ──
    function test_twap_misconfigured_reverts() public {
        deal(USDC, maker, 1_050e6);
        deal(WETH, solver, WETH_TOTAL);
        _approveMakerToSettlement(USDC, 1_050e6);
        _approveSolverSide(WETH_TOTAL, WETH);

        uint32 t0 = uint32(block.timestamp);
        Order memory o = _twapOrder(4, t0, 1_050e6, PART); // 1050 % 100 != 0
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(TwapFillModule.TwapNotConfigured.selector);
        settlement.fill(o, sig, PART);
    }

    // ── The Lens accepts a well-formed TWAP order (fill-module denominated). ──
    function test_twap_lens_accepts() public view {
        Order memory o = _twapOrder(5, uint32(block.timestamp), TOTAL, PART);
        (bool ok, string memory reason) = lens.validateOrder(o);
        assertTrue(ok, string.concat("TWAP order should validate: ", reason));
    }

    // ── TWAP needs NO solver inventory. A part is item-free, so PostInputs pays
    //    the solver the maker's USDC FIRST; it swaps that into WETH in the
    //    callback and delivers — zero inventory, zero flash, per part. ──
    function test_twap_zeroInventoryFill_postInputs() public {
        TwapSwapHelper swapHelper = new TwapSwapHelper();
        deal(WETH, address(swapHelper), 100 ether); // the DEX has the output stock

        deal(USDC, maker, TOTAL);
        _approveMakerToSettlement(USDC, TOTAL);
        // Solver holds NOTHING; it only approves the helper to pull the USDC it is
        // about to be paid. (Its standing Permit3 WETH allowance to Settlement — set
        // in the base setUp — lets Settlement pull the WETH it just swapped for.)
        vm.prank(solver);
        IERC20(USDC).approve(address(swapHelper), type(uint256).max);
        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver has no WETH");
        assertEq(IERC20(USDC).balanceOf(solver), 0, "solver has no USDC");

        uint32 t0 = uint32(block.timestamp);
        Order memory o = _twapOrder(6, t0, TOTAL, PART);
        bytes memory sig = _sign(o);

        // Part 1, PostInputs: paid PART USDC → swap → deliver WETH_PART.
        bytes memory cb = abi.encodeCall(TwapSwapHelper.swap, (solver, USDC, PART, WETH, WETH_PART));
        vm.prank(solver);
        settlement.fillWithCallback(o, sig, PART, address(swapHelper), cb, CallbackMode.PostInputs);

        assertEq(IERC20(WETH).balanceOf(maker), WETH_PART, "maker received the part's WETH");
        assertEq(IERC20(USDC).balanceOf(maker), TOTAL - PART, "maker spent one part of USDC");
        // Pure pass-through: the solver ends with exactly what it started — nothing.
        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver delivered all it swapped");
        assertEq(IERC20(USDC).balanceOf(solver), 0, "solver consumed the input it was paid");
    }
}
