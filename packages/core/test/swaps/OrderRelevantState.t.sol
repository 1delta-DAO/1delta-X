// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UniversalSettlement, Order, Item, Validator, OrderSide} from "@core/settlement/UniversalSettlement.sol";
import {SettlementLens} from "@core/periphery/SettlementLens.sol";
import {MockSettlementBase} from "../shared/MockSettlementBase.t.sol";

/// @dev Port of 0x's `getLimitOrderRelevantState` / `batchGet...RelevantStates`
/// coverage against our `getOrderRelevantState`: the status matrix, the
/// live-fillable amount capped by the maker's Permit3 allowance + balance
/// ("under-funded"), signature validity independent of status, and the batch
/// getter degrading bad orders to Invalid instead of reverting.
contract OrderRelevantStateTest is MockSettlementBase {
    uint256 constant AMOUNT_IN = 100e18; // tA maker gives
    uint256 constant AMOUNT_OUT = 300e18; // tB maker gets

    function setUp() public override {
        super.setUp();
        tA.mint(maker, 1_000e18);
        tB.mint(solver, 1_000e18);
        _makerApprove(address(settlement), address(tA), type(uint160).max);
        _solverApprove(address(settlement), address(tB), type(uint160).max);
    }

    function _order(uint256 nonce) internal view returns (Order memory) {
        return _plainOrder(nonce, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
    }

    function _state(Order memory o, bytes memory sig)
        internal
        view
        returns (SettlementLens.OrderStatus status, uint256 fillable, bool sigValid)
    {
        return lens.getOrderRelevantState(o, sig);
    }

    // ──────────────────── Status matrix ────────────────────

    function test_state_fillable_fresh() public view {
        Order memory o = _order(1);
        (SettlementLens.OrderStatus status, uint256 fillable, bool sigValid) = _state(o, _sign(o));
        assertEq(uint8(status), uint8(SettlementLens.OrderStatus.Fillable), "fillable");
        assertEq(fillable, AMOUNT_IN, "full amount fillable");
        assertTrue(sigValid, "sig valid");
    }

    function test_state_filled_afterFullFill() public {
        Order memory o = _order(1);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        settlement.fill(o, sig, AMOUNT_IN);

        (SettlementLens.OrderStatus status, uint256 fillable,) = _state(o, sig);
        assertEq(uint8(status), uint8(SettlementLens.OrderStatus.Filled), "filled");
        assertEq(fillable, 0, "nothing left");
    }

    function test_state_partiallyFilled_remaining() public {
        Order memory o = _order(1);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        settlement.fill(o, sig, AMOUNT_IN / 4);

        (SettlementLens.OrderStatus status, uint256 fillable,) = _state(o, sig);
        assertEq(uint8(status), uint8(SettlementLens.OrderStatus.Fillable), "still fillable");
        assertEq(fillable, AMOUNT_IN - AMOUNT_IN / 4, "remaining fillable");
    }

    function test_state_expired() public {
        Order memory o = _order(1);
        bytes memory sig = _sign(o);
        vm.warp(o.deadline + 1);
        (SettlementLens.OrderStatus status, uint256 fillable,) = _state(o, sig);
        assertEq(uint8(status), uint8(SettlementLens.OrderStatus.Expired), "expired");
        assertEq(fillable, 0, "nothing fillable");
    }

    function test_state_cancelled_byNonce() public {
        Order memory o = _order(1);
        bytes memory sig = _sign(o);
        uint256[] memory nonces = new uint256[](1);
        nonces[0] = 1;
        vm.prank(maker);
        settlement.cancelOrders(nonces);

        (SettlementLens.OrderStatus status,,) = _state(o, sig);
        assertEq(uint8(status), uint8(SettlementLens.OrderStatus.Cancelled), "cancelled");
    }

    function test_state_cancelled_byRollback() public {
        Order memory o = _order(5);
        bytes memory sig = _sign(o);
        vm.prank(maker);
        settlement.rollbackNonces(10); // floor above nonce 5

        (SettlementLens.OrderStatus status,,) = _state(o, sig);
        assertEq(uint8(status), uint8(SettlementLens.OrderStatus.Cancelled), "rolled back");
    }

    function test_state_invalid_malformed() public view {
        Order memory o = _order(1);
        o.tokenIn = new address[](0); // malformed shape
        o.startAmountIn = new uint256[](0);
        (SettlementLens.OrderStatus status,,) = _state(o, _sign(_order(1)));
        assertEq(uint8(status), uint8(SettlementLens.OrderStatus.Invalid), "invalid");
    }

    // ──────────────────── Under-funded cap (0x "actualFillable") ────────────────────

    function test_state_underfunded_byAllowance() public {
        // Maker only allows Settlement to pull 40 of the 100 tokenIn.
        _makerApprove(address(settlement), address(tA), 40e18);
        Order memory o = _order(1);
        (, uint256 fillable,) = _state(o, _sign(o));
        assertEq(fillable, 40e18, "fillable capped by allowance");
    }

    function test_state_underfunded_byBalance() public {
        // Fresh maker with only 25 tA in the wallet, unlimited allowance.
        address poorMaker = vm.addr(0xBEEF11);
        vm.startPrank(poorMaker);
        tA.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(tA), type(uint160).max, 0);
        vm.stopPrank();
        tA.mint(poorMaker, 25e18);

        Order memory o = _order(1);
        o.maker = poorMaker;
        // (signature validity is irrelevant to the fillable-amount computation)
        (, uint256 fillable,) = _state(o, _sign(_order(1)));
        assertEq(fillable, 25e18, "fillable capped by balance");
    }

    // ──────────────────── Signature validity ────────────────────

    function test_state_badSignature_stillFillableButInvalidSig() public view {
        Order memory o = _order(1);
        bytes memory badSig = _signWith(o, solverPk); // wrong signer
        (SettlementLens.OrderStatus status,, bool sigValid) = _state(o, badSig);
        assertEq(uint8(status), uint8(SettlementLens.OrderStatus.Fillable), "status independent of sig");
        assertFalse(sigValid, "signature invalid");
    }

    // ──────────────────── Batch getter degrades bad orders ────────────────────

    function test_batchState_mixedIncludingMalformed() public {
        Order memory good = _order(1);
        Order memory filled = _order(2);
        bytes memory goodSig = _sign(good);
        bytes memory filledSig = _sign(filled);

        vm.prank(solver);
        settlement.fill(filled, filledSig, AMOUNT_IN); // → Filled

        Order memory malformed = _order(3);
        malformed.tokenOut = new address[](0); // → Invalid

        Order[] memory orders = new Order[](3);
        bytes[] memory sigs = new bytes[](3);
        orders[0] = good;
        orders[1] = filled;
        orders[2] = malformed;
        sigs[0] = goodSig;
        sigs[1] = filledSig;
        sigs[2] = _sign(_order(3));

        (SettlementLens.OrderStatus[] memory statuses, uint256[] memory fillable,) =
            lens.getOrderRelevantStates(orders, sigs);

        assertEq(uint8(statuses[0]), uint8(SettlementLens.OrderStatus.Fillable), "0 fillable");
        assertEq(fillable[0], AMOUNT_IN, "0 full");
        assertEq(uint8(statuses[1]), uint8(SettlementLens.OrderStatus.Filled), "1 filled");
        assertEq(uint8(statuses[2]), uint8(SettlementLens.OrderStatus.Invalid), "2 invalid, no revert");
    }
}
