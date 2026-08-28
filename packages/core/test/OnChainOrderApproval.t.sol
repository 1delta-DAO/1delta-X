// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Signatures} from "@core/settlement/Signatures.sol";
import {OrderState} from "@core/settlement/OrderState.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {Base} from "@core/settlement/Base.sol";
import {Settlement, Order} from "@core/settlement/Settlement.sol";

import {MockSettlementBase} from "./shared/MockSettlementBase.t.sol";

/// @dev A "dumb" contract maker. Like any multisig it can execute arbitrary calls
///      (`exec`), but it implements NO signature scheme — no EIP-1271
///      `isValidSignature`, no fallback returning the magic value. So NEITHER the
///      ECDSA nor the 1271 branch of {SignatureVerification} can ever authorize it:
///      its only way to place an order is the on-chain {approveOrder} fallback.
contract SignatureLessMaker {
    function exec(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        require(ok, "exec failed");
        return ret;
    }
}

/// @title OnChainOrderApprovalTest
/// @notice Coverage for the signature-less order path: a maker that cannot sign
///         (a non-EIP-1271 multisig, modelled by {SignatureLessMaker}) authorizes
///         an order on-chain via {approveOrder}, and a filler settles it with an
///         EMPTY `sig`. Verifies the happy path, the no-approval / wrong-maker /
///         revoked / nonce-cancelled rejections, that approval authorizes partial
///         fills (not a single use), and that it works through `batchFill`.
contract OnChainOrderApprovalTest is MockSettlementBase {
    uint256 constant AMOUNT_IN = 100e18; // tA maker gives
    uint256 constant AMOUNT_OUT = 300e18; // tB maker gets

    SignatureLessMaker cm; // the signature-less contract maker

    function setUp() public override {
        super.setUp();
        cm = new SignatureLessMaker();
        vm.label(address(cm), "sigless-maker");

        // Fund the contract maker with tokenIn and wire its Permit3 allowances —
        // all via ordinary on-chain calls it executes itself. NO signatures anywhere.
        tA.mint(address(cm), 1_000e18);
        cm.exec(address(tA), abi.encodeWithSignature("approve(address,uint256)", address(permit3), type(uint256).max));
        cm.exec(
            address(permit3),
            abi.encodeCall(IPermit3.approveToken, (address(settlement), address(tA), type(uint160).max, uint48(0)))
        );

        // Solver can deliver tokenOut.
        tB.mint(solver, 1_000e18);
        vm.startPrank(solver);
        tB.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(tB), type(uint160).max, 0);
        vm.stopPrank();
    }

    /// @dev A plain SELL order whose maker is the signature-less contract.
    function _order(uint256 nonce) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        o.maker = address(cm);
    }

    /// @dev The maker authorizes `o` on-chain (returns the order hash it recorded).
    function _approve(Order memory o) internal returns (bytes32) {
        bytes memory ret = cm.exec(address(settlement), abi.encodeCall(OrderState.approveOrder, (o)));
        return abi.decode(ret, (bytes32));
    }

    // ──────────────────── Happy path ────────────────────

    function test_approve_thenFill_emptySig() public {
        Order memory o = _order(1);
        bytes32 hash = _approve(o);

        assertTrue(settlement.orderApproved(address(cm), hash), "approval recorded");

        // Empty sig → the on-chain approval authorizes the fill.
        vm.prank(solver);
        settlement.fill(o, "", AMOUNT_IN);

        assertEq(tB.balanceOf(address(cm)), AMOUNT_OUT, "sigless maker got output");
        assertEq(tA.balanceOf(solver), AMOUNT_IN, "solver got input");
    }

    // ──────────────────── Rejections ────────────────────

    function test_fill_emptySig_withoutApproval_reverts() public {
        Order memory o = _order(1); // never approved
        vm.prank(solver);
        vm.expectRevert(Signatures.OrderNotApproved.selector);
        settlement.fill(o, "", AMOUNT_IN);
    }

    /// @dev A stranger cannot approve an order whose `maker` is someone else — the
    ///      `order.maker == msg.sender` guard rejects it, and even without the guard
    ///      the mapping is keyed by msg.sender so it would never be consulted.
    function test_approveOrder_wrongMaker_reverts() public {
        Order memory o = _order(1); // maker == cm
        vm.prank(solver);
        vm.expectRevert(OrderState.NotOrderMaker.selector);
        settlement.approveOrder(o);
    }

    function test_revokeOrderApproval_blocksFill() public {
        Order memory o = _order(1);
        bytes32 hash = _approve(o);

        cm.exec(address(settlement), abi.encodeCall(OrderState.revokeOrderApproval, (hash)));
        assertFalse(settlement.orderApproved(address(cm), hash), "approval cleared");

        vm.prank(solver);
        vm.expectRevert(Signatures.OrderNotApproved.selector);
        settlement.fill(o, "", AMOUNT_IN);
    }

    /// @dev REGRESSION: revocation must bind on the REMAINDER of an already
    ///      partially-filled order too. `_verifySignature` short-circuits on a
    ///      non-zero `filled[orderHash]` to skip re-running `ecrecover` on later
    ///      fills — but that skip must not swallow the on-chain-approval check, which
    ///      unlike a signature is revocable. The earlier test only revokes before any
    ///      fill, so it passes either way; this one is the case that distinguishes them.
    function test_revokeOrderApproval_blocksRemainderAfterPartialFill() public {
        Order memory o = _order(1);
        bytes32 hash = _approve(o);

        vm.prank(solver);
        settlement.fill(o, "", AMOUNT_IN / 10); // partial → filled[hash] != 0
        assertGt(settlement.filled(hash), 0, "counter advanced");

        cm.exec(address(settlement), abi.encodeCall(OrderState.revokeOrderApproval, (hash)));

        // {OrderCancelled}, not {OrderNotApproved}: revoking a TOUCHED order parks
        // the cancel sentinel, because clearing the flag alone was bypassable by any
        // non-empty `sig` (see {OrderState.revokeOrderApproval} and
        // `test_revoke_blocksRemainder_evenWithNonEmptySig`). The remainder is still
        // blocked — it is blocked harder, and by a gate that does not depend on which
        // branch of {Signatures._verifySignature} the filler steers into.
        vm.prank(solver);
        vm.expectRevert(OrderState.OrderCancelled.selector);
        settlement.fill(o, "", AMOUNT_IN - AMOUNT_IN / 10);
    }

    /// @dev Cancelling the order's nonce blocks an on-chain-approved order exactly
    ///      as it blocks a signed one — the nonce gate runs regardless of how the
    ///      order was authorized.
    function test_cancelNonce_blocksApprovedOrder() public {
        Order memory o = _order(1);
        _approve(o);

        uint256[] memory nonces = new uint256[](1);
        nonces[0] = 1;
        cm.exec(address(settlement), abi.encodeWithSignature("cancelOrders(uint256[])", nonces));

        vm.prank(solver);
        vm.expectRevert(OrderState.NonceCancelled.selector);
        settlement.fill(o, "", AMOUNT_IN);
    }

    // ──────────────────── Partial fills ────────────────────

    /// @dev One approval authorizes the order for partial fills up to its size, just
    ///      like a signature — it is not consumed per fill.
    function test_approval_authorizesPartialFills() public {
        Order memory o = _order(1);
        _approve(o);

        vm.prank(solver);
        settlement.fill(o, "", AMOUNT_IN / 4);
        vm.prank(solver);
        settlement.fill(o, "", (AMOUNT_IN * 3) / 4);

        assertEq(tB.balanceOf(address(cm)), AMOUNT_OUT, "both partials delivered full output");
        assertEq(tA.balanceOf(solver), AMOUNT_IN, "solver paid the full input");
    }

    // ──────────────────── approveOrders (batch) ────────────────────

    /// @dev The batch is exactly N sequential {approveOrder}s: one multisig action
    ///      authorizes a whole ladder, each order individually fillable after.
    function test_approveOrders_batchAuthorizesAll() public {
        Order[] memory orders = new Order[](3);
        orders[0] = _order(1);
        orders[1] = _order(2);
        orders[2] = _order(3);

        bytes memory ret =
            cm.exec(address(settlement), abi.encodeCall(OrderState.approveOrders, (orders)));
        bytes32[] memory hashes = abi.decode(ret, (bytes32[]));

        assertEq(hashes.length, 3, "one hash per order");
        for (uint256 i; i < 3; ++i) {
            assertTrue(settlement.orderApproved(address(cm), hashes[i]), "each order recorded");
        }

        // Any of them fills with an empty sig, independently of the others.
        vm.prank(solver);
        settlement.fill(orders[1], "", AMOUNT_IN);
        assertEq(tB.balanceOf(address(cm)), AMOUNT_OUT, "batch-approved order settled");
    }

    /// @dev All-or-nothing on the maker guard: one foreign order poisons the whole
    ///      batch, so a multisig can never half-approve its ladder.
    function test_approveOrders_wrongMakerAnywhere_revertsWhole() public {
        Order[] memory orders = new Order[](2);
        orders[0] = _order(1);
        orders[1] = _order(2);
        orders[1].maker = address(0xBEEF); // not the caller

        vm.prank(address(cm));
        vm.expectRevert(OrderState.NotOrderMaker.selector);
        settlement.approveOrders(orders);

        // Nothing from the failed batch is approved — including the valid one.
        vm.prank(solver);
        vm.expectRevert(Signatures.OrderNotApproved.selector);
        settlement.fill(_order(1), "", AMOUNT_IN);
    }

    // ──────────────────── batchFill ────────────────────

    function test_batchFill_approvedOrder_emptySig() public {
        Order memory o = _order(1);
        _approve(o);

        Order[] memory orders = new Order[](1);
        orders[0] = o;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = ""; // empty → approval path
        uint256[] memory amts = new uint256[](1);
        amts[0] = AMOUNT_IN;

        vm.prank(solver);
        (, bool[] memory ok) = settlement.batchFill(orders, sigs, amts, true);
        assertTrue(ok[0], "approved order settled in batch with empty sig");
        assertEq(tB.balanceOf(address(cm)), AMOUNT_OUT, "batch delivered output");
    }

    // ─────────── revocation binds whatever the filler passes ───────────

    /// @dev REGRESSION (audit finding). {Signatures._verifySignature} skips
    ///      re-verification once `filled != 0`, and that skip is reached by ANY
    ///      non-empty `sig`. It cannot tell that the earlier fill was authorised by
    ///      the {approveOrder} record rather than by a signature. So clearing the
    ///      flag alone was bypassable: after one approval-authorised partial fill, a
    ///      filler passing 65 arbitrary bytes took the signature branch, hit the
    ///      skip, and settled the remainder of a REVOKED order.
    ///
    ///      `cm` implements no EIP-1271 at all, so the signature below can never be
    ///      valid for it — which is what makes this a pure authorisation bypass
    ///      rather than a signature-forgery question.
    function test_revoke_blocksRemainder_evenWithNonEmptySig() public {
        Order memory o = _order(20);
        bytes32 hash = _approve(o);

        vm.prank(solver);
        settlement.fill(o, "", AMOUNT_IN / 10); // approval-authorised partial
        assertGt(settlement.filled(hash), 0, "counter advanced");

        cm.exec(address(settlement), abi.encodeCall(OrderState.revokeOrderApproval, (hash)));

        bytes memory garbage = new bytes(65);
        garbage[64] = bytes1(uint8(27));
        vm.prank(solver);
        vm.expectRevert(OrderState.OrderCancelled.selector);
        settlement.fill(o, garbage, AMOUNT_IN / 10);
    }

    /// @dev The empty-sig path must keep its original, more precise error.
    function test_revoke_emptySigStillReportsNotApproved_whenUntouched() public {
        Order memory o = _order(21);
        bytes32 hash = _approve(o);
        cm.exec(address(settlement), abi.encodeCall(OrderState.revokeOrderApproval, (hash)));
        vm.prank(solver);
        vm.expectRevert(Signatures.OrderNotApproved.selector);
        settlement.fill(o, "", AMOUNT_IN / 10);
    }

    /// @dev An UNTOUCHED order is not escalated to a cancel, so approve → revoke →
    ///      re-approve still round-trips. Only a partially filled order is one-way.
    function test_revoke_untouchedOrder_canBeReApproved() public {
        Order memory o = _order(22);
        bytes32 hash = _approve(o);
        cm.exec(address(settlement), abi.encodeCall(OrderState.revokeOrderApproval, (hash)));
        assertEq(settlement.filled(hash), 0, "never filled, so never cancelled");

        _approve(o); // revive
        vm.prank(solver);
        settlement.fill(o, "", AMOUNT_IN / 10);
        assertGt(settlement.filled(hash), 0, "re-approved order fills again");
    }

    /// @dev The `wasApproved` guard is load-bearing: {OrderState.revokeOrderApproval}
    ///      takes a BARE HASH, so without it any caller could park the cancel
    ///      sentinel on any partially filled order and cancel a stranger's order.
    function test_revoke_byNonMaker_cannotCancelSomeoneElsesOrder() public {
        Order memory o = _order(23);
        bytes32 hash = _approve(o);
        vm.prank(solver);
        settlement.fill(o, "", AMOUNT_IN / 10);
        uint256 filledBefore = settlement.filled(hash);

        vm.prank(solver); // not the maker, never approved this hash
        settlement.revokeOrderApproval(hash);

        assertEq(settlement.filled(hash), filledBefore, "stranger must not cancel the order");
        vm.prank(solver);
        settlement.fill(o, "", AMOUNT_IN / 10); // maker's approval still stands
        assertGt(settlement.filled(hash), filledBefore, "order still fillable");
    }

    /// @dev REGRESSION: the `order.maker == msg.sender` guard on {OrderState.approveOrder}
    ///      is LOAD-BEARING, and not for the reason it looks. The approval mapping is
    ///      keyed by `msg.sender` on write and by `order.maker` on read, so a stranger's
    ///      row is genuinely never consulted on the fill path — which makes the guard
    ///      look redundant, and is exactly why it must not be deleted.
    ///
    ///      {OrderState.revokeOrderApproval} takes a BARE HASH and uses a set approval
    ///      flag as PROOF OF MAKERSHIP before parking the cancel sentinel in the
    ///      globally-keyed `filled` mapping. The guard is what makes that proof sound.
    ///      Remove it and a stranger owns a two-transaction griefing attack on every
    ///      partially-filled order in the book, whose struct is public by construction:
    ///
    ///        1. `approveOrder(victimOrder)` → sets `orderApproved[attacker][victimHash]`
    ///        2. `revokeOrderApproval(victimHash)` → flag is set, so
    ///           `filled[victimHash] = type(uint256).max` — the victim's order is
    ///           permanently cancelled.
    ///
    ///      Both write doors are checked, {approveOrder} and the {approveOrders} batch,
    ///      because deleting the guard from either one alone opens the same attack.
    ///      {test_revoke_byNonMaker_cannotCancelSomeoneElsesOrder} pins the second step
    ///      in isolation; this pins the chain, so the guard cannot be dropped as dead
    ///      weight without a red test.
    function test_approveThenRevoke_byStranger_cannotCancelSomeoneElsesOrder() public {
        address attacker = makeAddr("approval-griefer");

        Order memory o = _order(24);
        bytes32 hash = _approve(o);
        vm.prank(solver);
        settlement.fill(o, "", AMOUNT_IN / 10); // partial → filled != 0, the sentinel's precondition
        uint256 filledBefore = settlement.filled(hash);

        // Step 1, single — denied. The attacker holds the victim's full order struct.
        vm.prank(attacker);
        vm.expectRevert(OrderState.NotOrderMaker.selector);
        settlement.approveOrder(o);

        // Step 1, batch — the second write site, denied on the same guard.
        Order[] memory batch = new Order[](1);
        batch[0] = o;
        vm.prank(attacker);
        vm.expectRevert(OrderState.NotOrderMaker.selector);
        settlement.approveOrders(batch);

        assertFalse(settlement.orderApproved(attacker, hash), "attacker row must never be set");

        // Step 2 — inert without step 1, because `wasApproved` reads the attacker's row.
        vm.prank(attacker);
        settlement.revokeOrderApproval(hash);

        assertEq(settlement.filled(hash), filledBefore, "victim's order must not be cancelled");
        assertTrue(settlement.orderApproved(address(cm), hash), "maker's own approval untouched");

        // And the victim's order is not merely un-cancelled, it is still fillable.
        vm.prank(solver);
        settlement.fill(o, "", AMOUNT_IN / 10);
        assertGt(settlement.filled(hash), filledBefore, "order still fills for its maker");
    }
}
