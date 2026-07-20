// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OrderState} from "@core/settlement/OrderState.sol";
import {Base} from "@core/settlement/Base.sol";
import {Settlement, Order, Item, Validator} from "@core/settlement/Settlement.sol";
import {NonceManager} from "@core/settlement/NonceManager.sol";
import {MockSettlementBase} from "../shared/MockSettlementBase.t.sol";

/// @dev Port of 0x's cancellation coverage (single / batch / pair-rollback /
/// idempotent / only-maker) against our nonce-bitmap + rollback floor. Covers
/// single-nonce cancel, 256-at-once word invalidation, the `minValidNonce`
/// rollback primitive (0x `minValidSalt` analogue), monotonicity, idempotence,
/// per-maker isolation, and that each cancellation actually blocks a fill.
contract NonceCancellationTest is MockSettlementBase {
    uint256 constant AMOUNT_IN = 100e18;
    uint256 constant AMOUNT_OUT = 300e18;

    function setUp() public override {
        super.setUp();
        tA.mint(maker, 10_000e18);
        tB.mint(solver, 10_000e18);
        _makerApprove(address(settlement), address(tA), type(uint160).max);
        _solverApprove(address(settlement), address(tB), type(uint160).max);
    }

    function _order(uint256 nonce) internal view returns (Order memory) {
        return _plainOrder(nonce, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
    }

    function _cancel(uint256 nonce) internal {
        uint256[] memory nonces = new uint256[](1);
        nonces[0] = nonce;
        vm.prank(maker);
        settlement.cancelOrders(nonces);
    }

    function _fill(Order memory o) internal {
        bytes memory sig = _sign(o); // sign FIRST — inlining it consumes the prank
        vm.prank(solver);
        settlement.fill(o, sig, AMOUNT_IN);
    }

    // ──────────────────── Single-nonce cancel ────────────────────

    function test_cancel_blocksFill() public {
        Order memory o = _order(7);
        bytes memory sig = _sign(o);
        _cancel(7);
        vm.prank(solver);
        vm.expectRevert(OrderState.NonceCancelled.selector);
        settlement.fill(o, sig, AMOUNT_IN);
    }

    function test_cancel_idempotent() public {
        _cancel(7);
        _cancel(7); // no revert
        assertTrue(settlement.isNonceCancelled(maker, 7), "still cancelled");
    }

    function test_cancel_isPerMaker() public {
        // solver cancels nonce 7 in ITS namespace; maker's order nonce 7 unaffected.
        uint256[] memory nonces = new uint256[](1);
        nonces[0] = 7;
        vm.prank(solver);
        settlement.cancelOrders(nonces);

        Order memory o = _order(7);
        _fill(o); // still fillable
        assertEq(tA.balanceOf(solver), AMOUNT_IN, "maker's order unaffected by solver's cancel");
    }

    // ──────────────────── Word invalidation (256 at once) ────────────────────

    function test_invalidateNonceWord_cancels256() public {
        vm.prank(maker);
        settlement.invalidateNonceWord(0); // nonces 0..255

        Order memory low = _order(5); // word 0 → cancelled
        bytes memory lowSig = _sign(low);
        vm.prank(solver);
        vm.expectRevert(OrderState.NonceCancelled.selector);
        settlement.fill(low, lowSig, AMOUNT_IN);

        Order memory high = _order(300); // word 1 → untouched
        _fill(high);
        assertEq(tA.balanceOf(solver), AMOUNT_IN, "nonce in another word still fills");
    }

    // ──────────────────── Rollback floor (minValidSalt analogue) ────────────────────

    function test_rollback_cancelsBelowFloor() public {
        vm.prank(maker);
        settlement.rollbackNonces(100);

        Order memory below = _order(50);
        bytes memory belowSig = _sign(below);
        vm.prank(solver);
        vm.expectRevert(OrderState.NonceCancelled.selector);
        settlement.fill(below, belowSig, AMOUNT_IN);
    }

    function test_rollback_atOrAboveFloor_stillFills() public {
        vm.prank(maker);
        settlement.rollbackNonces(100);
        Order memory atFloor = _order(100); // 100 is NOT < 100 → still valid
        _fill(atFloor);
        assertEq(tA.balanceOf(solver), AMOUNT_IN, "nonce == floor fills");
    }

    function test_rollback_monotonic_revertsOnDecrease() public {
        vm.startPrank(maker);
        settlement.rollbackNonces(100);
        vm.expectRevert(NonceManager.RollbackTooLow.selector);
        settlement.rollbackNonces(99);
        vm.stopPrank();
    }

    // ──────────────────── Cancel after a partial fill ────────────────────

    function test_cancel_afterPartialFill_blocksRemainder() public {
        Order memory o = _order(7);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        settlement.fill(o, sig, AMOUNT_IN / 2); // partial

        _cancel(7);
        vm.prank(solver);
        vm.expectRevert(OrderState.NonceCancelled.selector);
        settlement.fill(o, sig, AMOUNT_IN / 2); // remainder blocked
    }
}
