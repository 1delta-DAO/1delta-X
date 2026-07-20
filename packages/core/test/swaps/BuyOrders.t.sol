// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SettlementBase} from "@core/settlement/SettlementBase.sol";
import {UniversalSettlement, CallbackMode, Order, Item, Validator, OrderSide} from "@core/settlement/UniversalSettlement.sol";
import {SettlementLens} from "@core/periphery/SettlementLens.sol";
import {DutchAuction} from "@core/settlement/DutchAuction.sol";

import {MockSettlementBase, MockERC20} from "../shared/MockSettlementBase.t.sol";

/// @dev Callback target that hands the solver output inventory just-in-time.
contract BuySupplier {
    function supply(address to, address token, uint256 amount) external {
        MockERC20(token).transfer(to, amount);
    }
}

/// @dev Callback DEX for PostInputs: pulls the just-received input from the solver
///      and returns the fixed output it must deliver.
contract BuySwapHelper {
    function swap(address who, address tokenIn, uint256 amtIn, address tokenOut, uint256 amtOut) external {
        MockERC20(tokenIn).transferFrom(who, address(this), amtIn);
        MockERC20(tokenOut).transfer(who, amtOut);
    }
}

/// @title BuyOrders
/// @notice Exact-output (BUY) order coverage: fixed output basket, rising input
///         auction. Mirrors the SELL suite from the other side — fills are
///         denominated in tokenOut[0] units, the maker receives exactly the
///         signed output and pays at most `endAmountIn`.
contract BuyOrdersTest is MockSettlementBase {
    uint256 constant OUT = 1e18; // exact tB the maker buys (anchor)
    uint256 constant PRICE = 1_500e18; // fixed tA price
    uint256 constant START_IN = 1_000e18; // auction: cheap for maker
    uint256 constant END_IN = 2_000e18; // auction: ceiling ("pay up to")

    BuySupplier supplier;
    BuySwapHelper swapHelper;

    function setUp() public override {
        super.setUp();
        supplier = new BuySupplier();
        swapHelper = new BuySwapHelper();
    }

    // ── funding: maker pays input (tA), solver delivers fixed output (tB) ──

    function _fundMakerInput(uint256 maxIn) internal {
        tA.mint(maker, maxIn);
        _makerApprove(address(settlement), address(tA), maxIn);
    }

    function _fundSolverOutput(uint256 out) internal {
        tB.mint(solver, out);
        _solverApprove(address(settlement), address(tB), out);
    }

    // ════════════════════ fixed-price BUY ════════════════════

    function test_buy_fullFill_fixedPrice() public {
        _fundMakerInput(PRICE);
        _fundSolverOutput(OUT);

        Order memory order = _buyOrder(1, address(tA), address(tB), PRICE, PRICE, OUT);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256[] memory outs = settlement.fill(order, sig, OUT); // fillAmount in tokenOut units

        assertEq(outs[0], OUT, "delivered exact output");
        assertEq(tB.balanceOf(maker), OUT, "maker received exact output");
        assertEq(tA.balanceOf(maker), 0, "maker paid the price");
        assertEq(tA.balanceOf(solver), PRICE, "solver received the input");
        assertEq(lens.remaining(order), 0, "fully filled");
    }

    function test_buy_partialFill_exactOutputConserved() public {
        _fundMakerInput(PRICE);
        _fundSolverOutput(OUT);

        Order memory order = _buyOrder(1, address(tA), address(tB), PRICE, PRICE, OUT);
        bytes memory sig = _sign(order);

        // Two partials of OUT/2 each → maker ends with exactly OUT, pays exactly PRICE.
        vm.prank(solver);
        settlement.fill(order, sig, OUT / 2);
        assertEq(lens.remaining(order), OUT / 2, "half remaining");

        vm.prank(solver);
        settlement.fill(order, sig, OUT / 2);

        assertEq(tB.balanceOf(maker), OUT, "output conserved across partials");
        assertEq(tA.balanceOf(solver), PRICE, "input summed to price");
        assertEq(lens.remaining(order), 0, "filled");
    }

    function test_buy_overFill_reverts() public {
        _fundMakerInput(PRICE);
        _fundSolverOutput(OUT);
        Order memory order = _buyOrder(1, address(tA), address(tB), PRICE, PRICE, OUT);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, OUT);

        vm.prank(solver);
        vm.expectRevert(SettlementBase.OverFill.selector);
        settlement.fill(order, sig, 1);
    }

    // ════════════════════ rising input auction ════════════════════

    function test_buy_inputAuction_midpointPrice() public {
        _fundMakerInput(END_IN);
        _fundSolverOutput(OUT);

        Order memory order = _buyOrder(1, address(tA), address(tB), START_IN, END_IN, OUT);
        order.decayStartTime = uint32(block.timestamp);
        order.decayDuration = 100;
        bytes memory sig = _sign(order);

        vm.warp(block.timestamp + 50); // halfway → price halfway between start and end
        uint256 mid = (START_IN + END_IN) / 2;
        assertEq(lens.previewAmountIn(order)[0], mid, "preview midpoint input");

        vm.prank(solver);
        settlement.fill(order, sig, OUT);

        assertEq(tB.balanceOf(maker), OUT, "maker got exact output");
        assertEq(tA.balanceOf(solver), mid, "solver charged the midpoint input");
    }

    function test_buy_payAtMost_endAmountIn() public {
        _fundMakerInput(END_IN);
        _fundSolverOutput(OUT);

        Order memory order = _buyOrder(1, address(tA), address(tB), START_IN, END_IN, OUT);
        order.decayStartTime = uint32(block.timestamp);
        order.decayDuration = 100;
        bytes memory sig = _sign(order);

        vm.warp(block.timestamp + 500); // well past duration → ceiling price
        assertEq(lens.previewAmountIn(order)[0], END_IN, "preview at ceiling");

        vm.prank(solver);
        settlement.fill(order, sig, OUT);
        assertEq(tA.balanceOf(solver), END_IN, "maker paid at most endAmountIn");
    }

    function test_buy_auctionNotStarted_reverts() public {
        _fundMakerInput(END_IN);
        _fundSolverOutput(OUT);
        Order memory order = _buyOrder(1, address(tA), address(tB), START_IN, END_IN, OUT);
        order.decayStartTime = uint32(block.timestamp + 100); // future start
        order.decayDuration = 100;
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(DutchAuction.AuctionNotStarted.selector);
        settlement.fill(order, sig, OUT);
    }

    // ════════════════════ callback modes ════════════════════

    /// @dev Zero-inventory solver sources the fixed output in a PreDelivery callback.
    function test_buy_fillWithCallback_preDelivery_sourcesOutput() public {
        _fundMakerInput(PRICE);
        // solver has an allowance for tB but NO balance — the callback supplies it.
        _solverApprove(address(settlement), address(tB), OUT);
        tB.mint(address(supplier), OUT);

        Order memory order = _buyOrder(1, address(tA), address(tB), PRICE, PRICE, OUT);
        bytes memory sig = _sign(order);
        bytes memory cb = abi.encodeCall(BuySupplier.supply, (solver, address(tB), OUT));

        assertEq(tB.balanceOf(solver), 0, "solver starts with no output");
        vm.prank(solver);
        settlement.fillWithCallback(order, sig, OUT, address(supplier), cb, CallbackMode.PreDelivery);

        assertEq(tB.balanceOf(maker), OUT, "maker got exact output");
        assertEq(tA.balanceOf(solver), PRICE, "solver paid the input");
    }

    /// @dev Zero-inventory, zero-flash BUY: PostInputs pays the solver the maker's
    ///      input first, it swaps that into the fixed output, then delivers.
    function test_buy_fillWithCallback_postInputs_zeroInventory() public {
        _fundMakerInput(PRICE);
        _solverApprove(address(settlement), address(tB), OUT);
        // The DEX holds output stock and will pull the solver's received input.
        tB.mint(address(swapHelper), OUT);
        vm.prank(solver);
        tA.approve(address(swapHelper), type(uint256).max);

        Order memory order = _buyOrder(1, address(tA), address(tB), PRICE, PRICE, OUT);
        bytes memory sig = _sign(order);
        bytes memory cb = abi.encodeCall(BuySwapHelper.swap, (solver, address(tA), PRICE, address(tB), OUT));

        assertEq(tB.balanceOf(solver), 0, "no output inventory");
        vm.prank(solver);
        settlement.fillWithCallback(order, sig, OUT, address(swapHelper), cb, CallbackMode.PostInputs);

        assertEq(tB.balanceOf(maker), OUT, "maker got exact output");
        assertEq(tA.balanceOf(maker), 0, "maker paid the input");
        assertEq(tB.balanceOf(solver), 0, "solver delivered all it sourced");
    }

    // ════════════════════ preflight + validation ════════════════════

    function test_buy_preflight_cappedByMakerInputAtCeiling() public {
        // Maker can only fund half the ceiling cost → fillable is capped to OUT/2.
        _fundMakerInput(END_IN / 2);
        _fundSolverOutput(OUT);

        Order memory order = _buyOrder(1, address(tA), address(tB), START_IN, END_IN, OUT);
        bytes memory sig = _sign(order);

        (SettlementLens.OrderStatus status, uint256 fillable, bool sigValid,) =
            lens.getOrderRelevantState(order, sig, solver, "");

        assertEq(uint256(status), uint256(SettlementLens.OrderStatus.Fillable), "fillable");
        assertTrue(sigValid, "sig valid");
        // capacity (END_IN/2) buys floor(capacity * OUT / END_IN) = OUT/2 output units.
        assertEq(fillable, OUT / 2, "capped by maker input at the ceiling tick");
    }

    function test_buy_validateOrder_acceptsAndRejects() public view {
        Order memory ok = _buyOrder(1, address(tA), address(tB), START_IN, END_IN, OUT);
        (bool good,) = lens.validateOrder(ok);
        assertTrue(good, "well-formed buy validates");

        // Non-fixed output → rejected.
        Order memory badOut = _buyOrder(2, address(tA), address(tB), START_IN, END_IN, OUT);
        badOut.endAmountOut[0] = OUT - 1;
        (bool ok2, string memory r2) = lens.validateOrder(badOut);
        assertFalse(ok2, "non-fixed output rejected");
        assertEq(r2, "buy output must be fixed");

        // Falling input (end < start) → rejected.
        Order memory badIn = _buyOrder(3, address(tA), address(tB), END_IN, START_IN, OUT);
        (bool ok3, string memory r3) = lens.validateOrder(badIn);
        assertFalse(ok3, "falling input rejected");
        assertEq(r3, "endAmountIn < startAmountIn");
    }

    // ════════════════════ fuzz: exact-output conservation ════════════════════

    function testFuzz_buy_partials_conserveOutput(uint256 out, uint256 firstFill) public {
        out = bound(out, 2, 1_000_000e18);
        firstFill = bound(firstFill, 1, out - 1);

        _fundMakerInput(PRICE);
        _fundSolverOutput(out);

        Order memory order = _buyOrder(1, address(tA), address(tB), PRICE, PRICE, out);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, firstFill);
        vm.prank(solver);
        settlement.fill(order, sig, out - firstFill);

        // Fixed output is conserved exactly; total input never exceeds PRICE.
        assertEq(tB.balanceOf(maker), out, "output conserved");
        assertLe(tA.balanceOf(solver), PRICE, "input within the ceiling");
    }
}
