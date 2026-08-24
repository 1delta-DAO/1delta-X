// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";

import {SliceRecorderModule} from "../shared/MockModules.sol";
import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @title SettleSlice
/// @notice The core's SETTLE **slice arithmetic**, asserted directly.
///
///  A SETTLE item's signed `amount` is the quantity for a FULLY filled order; each
///  fill dispatches its pro-rata share. Every other suite watches that indirectly,
///  through a token balance a module happened to move — which measures the core and
///  the module at once, and cannot see a slice the module rounded on its own.
///  {SliceRecorderModule} transfers nothing and records what it was handed, so the
///  numbers below are the core's own.
///
///  This is the coverage that used to ride on the shipped `Erc1155SettlementModule`
///  before the modules moved to `packages/modules` — strictly stronger, since the
///  exact per-fill slice is now an assertion rather than an inference.
contract SettleSliceTest is CoreSettlementBase {
    SliceRecorderModule recorder;

    uint256 constant PRICE = 1_000e6; // USDC out to the maker == the anchor
    uint256 constant QTY = 100; //       the item's signed quantity

    function setUp() public override {
        super.setUp();
        recorder = new SliceRecorderModule(address(settlement));
    }

    /// @dev BUY shape: fixed USDC output is the denominator, no input legs, one
    ///      SETTLE item carrying the quantity. Partial-fillable.
    function _order(uint256 nonce, uint256 qty) internal view returns (Order memory o) {
        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.SETTLE, address(recorder), qty, address(0), abi.encode(address(0xBEEF), uint256(5)));
        o = _sellOrder(nonce, maker, address(0), USDC, 0, PRICE, items);
        o.timing |= uint256(1) << 101; // BUY: the fixed USDC output is the anchor
    }

    function _fundSolver(uint256 usdc) internal {
        deal(USDC, solver, usdc);
        _approveSolverSide(usdc, USDC);
    }

    // ── the slice the core computes, read back verbatim ──

    function test_slice_fullFill_isTheSignedAmount() public {
        _fundSolver(PRICE);
        Order memory o = _order(1, QTY);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fill(o, sig, PRICE);

        assertEq(recorder.callCount(), 1, "one dispatch");
        SliceRecorderModule.Call memory c = recorder.callAt(0);
        assertEq(c.slice, QTY, "a full fill dispatches the whole signed amount");
        assertEq(c.maker, maker, "maker threaded through");
        assertEq(c.filler, solver, "SETTLE is filler-aware");
        assertEq(c.data, abi.encode(address(0xBEEF), uint256(5)), "item data untouched");
    }

    function test_slice_partialFills_areProRata_andAccumulate() public {
        _fundSolver(PRICE);
        Order memory o = _order(2, QTY);
        bytes memory sig = _sign(o);

        vm.startPrank(solver);
        settlement.fill(o, sig, (PRICE * 30) / 100); // 30%
        assertEq(recorder.callAt(0).slice, 30, "first slice is 30% of the quantity");

        settlement.fill(o, sig, (PRICE * 45) / 100); // 45%
        assertEq(recorder.callAt(1).slice, 45, "second slice is 45%");

        settlement.fill(o, sig, PRICE - (PRICE * 75) / 100); // the remainder
        vm.stopPrank();

        assertEq(recorder.callCount(), 3, "one dispatch per fill");
        assertEq(recorder.totalSlice(), QTY, "slices accumulate to exactly the signed amount");
    }

    /// @dev Slices FLOOR, so they can undershoot mid-way — but the core must never
    ///      let the total exceed what the maker signed. Three fills of a third of a
    ///      quantity that does not divide by three: 33 + 33 + 34, never 100 + dust.
    function test_slice_roundingNeverOverdispatches() public {
        _fundSolver(PRICE);
        Order memory o = _order(3, 100);
        bytes memory sig = _sign(o);

        uint256 third = PRICE / 3;
        vm.startPrank(solver);
        settlement.fill(o, sig, third);
        settlement.fill(o, sig, third);
        settlement.fill(o, sig, PRICE - 2 * third);
        vm.stopPrank();

        assertEq(recorder.totalSlice(), 100, "no over-dispatch across a rounding schedule");
        assertLe(recorder.callAt(0).slice, 34, "an individual slice floors rather than rounds up");
    }

    /// @dev A fill so small its slice floors to zero is REJECTED, not silently
    ///      skipped — a filler must never pay and have the item do nothing.
    function test_slice_flooringToZero_reverts() public {
        _fundSolver(PRICE);
        Order memory o = _order(4, 1); // quantity 1 over the whole order
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(Base.SettleSliceZero.selector);
        settlement.fill(o, sig, PRICE / 10); // 10% of a quantity of 1 ⇒ 0
    }

    /// @dev The module gate every settle module must carry: the maker's order
    ///      signature is the authority, so a direct call has none.
    function test_slice_directCall_reverts() public {
        vm.expectRevert(SliceRecorderModule.OnlySettlement.selector);
        recorder.settle(maker, solver, 1, "");
    }
}
