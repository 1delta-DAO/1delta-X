// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order, Item, ItemOp, Validator} from "@core/settlement/Structs.sol";
import {OrderGates} from "@core/settlement/OrderGates.sol";
import {IOrderValidator} from "@core/interfaces/IOrderValidator.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";

import {MockSettlementBase} from "@coretest/shared/MockSettlementBase.t.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

/// @dev A third-party end-state invariant that is already true.
contract AlwaysTrueInvariant20260930 is IOrderValidator {
    function validate(Order calldata, address, bytes calldata, bytes calldata) external pure returns (bool) {
        return true;
    }
}

/// @dev A MAKE module that does nothing — a "position item" that delivers nothing.
contract NoopMaker20260930 is IMakerModule {
    function makeOnBehalf(address, uint256, bytes calldata) external override {}
}

/// @title Audit 2026-09-30 VAL-1 — the lens mirrors the core's invariant-receipt rule
/// @notice {Base._runInvariants} now refuses any filler but the named
///         `exclusiveFiller` on an order with invariants and no output leg — position
///         items or not. The lens must agree on both of its surfaces: the shape check
///         ({SettlementLens.validateOrder}) and the amount preview ({previewFill}).
contract Audit20260930InvariantReceiptLensTest is MockSettlementBase {
    uint256 constant PAY = 1_000e18;
    address named = makeAddr("named");

    function _receiptOrder(uint256 nonce, bool positionItem, address exclusive)
        internal
        returns (Order memory o)
    {
        o = _blank(nonce);
        o.legsIn = _legsIn1(address(tA), PAY);
        Validator[] memory vs = new Validator[](1);
        vs[0] = Validator({target: address(new AlwaysTrueInvariant20260930()), data: ""});
        o.invariants = PackedEncode.validators(vs);
        if (positionItem) {
            Item[] memory its = new Item[](1);
            its[0] = Item({
                op: ItemOp.MAKE, module: address(new NoopMaker20260930()), amount: PAY, recipient: address(0), data: ""
            });
            o.items = PackedEncode.items(its);
        }
        o.exclusiveFiller = exclusive;
    }

    /// @dev Before: a MAKE/TAKE item counted as consideration, so the lens read this
    ///      order valid while the settler (since VAL-1) refuses every open filler.
    function test_audit_VAL_1_lens_positionItemDoesNotLiftReceiptRule() public {
        Order memory o = _receiptOrder(1, true, address(0));
        (bool ok, string memory why) = lens.validateOrder(o);
        assertFalse(ok, "lens flags the open invariant-receipt order");
        assertEq(why, "invariant-only consideration needs a single hard exclusiveFiller for the order's life");

        // The settler's verdict on the same order.
        tA.mint(maker, PAY);
        _makerApprove(address(settlement), address(tA), PAY);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(OrderGates.NotExclusiveFiller.selector);
        settlement.fill(o, sig, PAY);
    }

    /// @dev `previewFill` refuses the outside filler exactly as the fill does, and
    ///      quotes the named one.
    function test_audit_VAL_1_lens_previewRefusesUnnamedFiller() public {
        Order memory o = _receiptOrder(2, false, named);
        vm.expectRevert(OrderGates.NotExclusiveFiller.selector);
        lens.previewFill(o, PAY, solver, "");

        (uint256 delta, uint256[] memory received,) = lens.previewFill(o, PAY, named, "");
        assertEq(delta, PAY);
        assertEq(received[0], PAY);
    }

    /// @dev Control: an output leg is the receipt, so an open filler previews fine.
    function test_audit_VAL_1_lens_outputLegOrder_unaffected() public {
        Order memory o = _receiptOrder(3, false, address(0));
        o.legsOut = _legsOut1(address(tB), 1e18);
        (uint256 delta,,) = lens.previewFill(o, PAY, solver, "");
        assertEq(delta, PAY);
    }
}
