// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order, Item, ItemOp, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {PackedArrays} from "@core/settlement/PackedArrays.sol";

import {SliceRecorderModule} from "../shared/MockModules.sol";
import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";
import {PackedEncode} from "../shared/PackedEncode.sol";

/// @title ItemOpRange
/// @notice An item's `op` is a RAW BYTE in the signed blob, not an enum.
///
///  {PackedArrays.itemAt} returns it as a `uint256` and deliberately does not
///  narrow it, so the `ItemOp` enum exists only on the Solidity side of the wire.
///  Before the range check, {Base._runItem} dispatched MAKE, else TAKE, else
///  SETTLE — which meant every `op >= 2` ran the SETTLE branch, and
///  {Batch._assertMatchShape}'s `op == SETTLE` prohibition could be walked past by
///  signing `op = 3`. The netted path would then execute the one item kind it
///  declares it cannot account for (SETTLE routes the maker's asset to the filler,
///  not to the pool).
///
///  Not a theft path — the byte is inside the maker's own signature, and every
///  shipped SETTLE module moves only the maker's assets — but it turned a named,
///  deliberate path restriction into an advisory one. Both halves are asserted
///  here: the dispatcher rejects the record, and the batch guard asks `>=`.
///
///  Cross-reference: `docs/reference-audits.md` §C3/§C6, finding F2.
contract ItemOpRangeTest is CoreSettlementBase {
    SliceRecorderModule recorder;

    uint256 constant PRICE = 1_000e6; // USDC out to the maker == the BUY anchor
    uint256 constant QTY = 100; //      the item's signed quantity

    function setUp() public override {
        super.setUp();
        recorder = new SliceRecorderModule(address(settlement));
    }

    /// @dev BUY shape (fixed USDC output is the denominator, no input legs) with a
    ///      single item whose `op` byte is written verbatim — so the caller may pass
    ///      an op the enum cannot hold.
    function _orderWithRawOp(uint256 nonce, uint8 op) internal view returns (Order memory o) {
        o = _sellOrder(nonce, maker, address(0), USDC, 0, PRICE, new Item[](0));
        o.items = PackedEncode.itemRawOp(op, address(recorder), QTY, address(0), abi.encode(address(0xBEEF), uint256(5)));
        o.timing |= uint256(1) << 101; // BUY
    }

    function _fundSolver() internal {
        deal(USDC, solver, PRICE);
        _approveSolverSide(PRICE, USDC);
    }

    // ──────────────── single-order path: the dispatcher ────────────────

    /// The control: `op = 2` IS SettLE and still dispatches, so the range check
    /// narrowed nothing that was previously reachable and meaningful.
    function test_settleOp_stillDispatches() public {
        _fundSolver();
        Order memory o = _orderWithRawOp(1, uint8(ItemOp.SETTLE));
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fill(o, sig, PRICE);

        assertEq(recorder.callCount(), 1, "a well-formed SETTLE item still runs");
        assertEq(recorder.callAt(0).slice, QTY, "and carries its full signed amount");
    }

    /// An op past the enum is a malformed record, not a third settle flavour.
    function test_opAboveSettle_reverts() public {
        _fundSolver();
        Order memory o = _orderWithRawOp(2, 3);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(PackedArrays.MalformedPackedArray.selector);
        settlement.fill(o, sig, PRICE);

        assertEq(recorder.callCount(), 0, "nothing was dispatched");
    }

    /// The top of the byte range behaves the same as the bottom of the invalid one
    /// — there is no wrap-around or mask that would rehabilitate a large op.
    function test_maxOpByte_reverts() public {
        _fundSolver();
        Order memory o = _orderWithRawOp(3, type(uint8).max);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(PackedArrays.MalformedPackedArray.selector);
        settlement.fill(o, sig, PRICE);
    }

    function testFuzz_anyOpAboveSettle_reverts(uint8 op) public {
        op = uint8(bound(uint256(op), uint256(ItemOp.SETTLE) + 1, type(uint8).max));
        _fundSolver();
        Order memory o = _orderWithRawOp(4, op);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(PackedArrays.MalformedPackedArray.selector);
        settlement.fill(o, sig, PRICE);
    }

    // ──────────────── netted path: the shape guard ────────────────

    /// `matchSettle` refuses a SETTLE item. The guard must key on the DISPATCHER's
    /// behaviour (`>=`), not on the enum value (`==`) — otherwise `op = 3` reaches
    /// the SETTLE branch with the prohibition never having fired.
    function test_matchSettle_rejectsOpAboveSettle_atTheShapeGuard() public {
        Order memory o = _orderWithRawOp(5, 3);
        _expectMatchSettleRejection(o);
    }

    function test_matchSettle_rejectsSettleOp() public {
        Order memory o = _orderWithRawOp(6, uint8(ItemOp.SETTLE));
        _expectMatchSettleRejection(o);
    }

    /// @dev Both cases must fail at `_assertMatchShape` — i.e. in PHASE 1, before
    ///      any schedule step runs — so the plan carries no steps at all. A guard
    ///      that fired later would already have moved funds.
    function _expectMatchSettleRejection(Order memory o) internal {
        Order[] memory orders = new Order[](1);
        orders[0] = o;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(o);
        uint256[] memory fills = new uint256[](1);
        fills[0] = PRICE;

        vm.prank(solver);
        vm.expectRevert(Base.MatchSettleItemUnsupported.selector);
        settlement.matchSettle(
            MatchPlan({
                orders: orders,
                sigs: sigs,
                fillAmounts: fills,
                takerDatas: new bytes[](0),
                schedule: new uint256[](0),
                callTargets: new address[](0),
                callDatas: new bytes[](0),
                profitRecipient: address(0)
            })
        );
    }
}
