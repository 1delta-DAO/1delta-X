// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Order, Item, ItemOp, LegIn, LegOut, OrderSide} from "@core/settlement/Settlement.sol";
import {Signatures} from "@core/settlement/Signatures.sol";
import {OrderState} from "@core/settlement/OrderState.sol";

import {BridgedOrderInbox} from "../src/BridgedOrderInbox.sol";
import {BridgeTestBase} from "./shared/BridgeTestBase.t.sol";

/// @title InboxAccountingTest
/// @notice The escrow's security properties, independent of any particular
///         bridge. The load-bearing one is {test_cannotDrainAnotherCommitsFunds}:
///         the inbox is a POOLED maker with a standing Permit3 allowance over its
///         whole balance, so isolation cannot come from bookkeeping — it comes
///         from refusing to approve an order until the bridge has delivered its
///         full input leg.
contract InboxAccountingTest is BridgeTestBase {
    uint256 constant BRIDGED = 100e18; // tA arriving from the source chain
    uint256 constant DELIVERED = 300e18; // tB the solver owes the end user

    // ──────────────────── Happy path ────────────────────

    function test_credit_activate_fill_deliversToEndUser() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        bytes32 h = _hashOrder(o);

        _acrossDeliver(BRIDGED, _commitmentFor(h));
        (,, uint256 credited,,,,,) = inbox.commits(h);
        assertEq(credited, BRIDGED, "credited");

        inbox.activate(o);
        assertTrue(settlement.orderApproved(address(inbox), h), "approved on-chain");

        _fundSolverOut(DELIVERED);
        vm.prank(solver);
        settlement.fill(o, "", BRIDGED); // empty sig — the on-chain approval authorizes

        assertEq(tB.balanceOf(endUser), DELIVERED, "end user received output");
        assertEq(tA.balanceOf(solver), BRIDGED, "solver received the bridged input");
        assertEq(tA.balanceOf(address(inbox)), 0, "inbox emptied");
    }

    /// @dev The end user needed no allowance, no balance, and no prior interaction
    ///      with this chain — the whole point of making the inbox the maker.
    function test_endUserNeverTouchedThisChain() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        _acrossDeliver(BRIDGED, _commitmentFor(_hashOrder(o)));
        inbox.activate(o);
        _fundSolverOut(DELIVERED);

        (uint160 allowed,) = permit3.tokenAllowance(endUser, address(settlement), address(tB));
        assertEq(allowed, 0, "no allowance");
        assertEq(endUser.balance, 0, "no gas");

        vm.prank(solver);
        settlement.fill(o, "", BRIDGED);
        assertEq(tB.balanceOf(endUser), DELIVERED, "still received");
    }

    // ──────────────────── The funding invariant ────────────────────

    function test_activate_underfunded_reverts() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        _acrossDeliver(BRIDGED - 1, _commitmentFor(_hashOrder(o)));

        vm.expectRevert(BridgedOrderInbox.Underfunded.selector);
        inbox.activate(o);
    }

    function test_activate_neverCredited_reverts() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        vm.expectRevert(BridgedOrderInbox.BadCommitment.selector);
        inbox.activate(o);
    }

    /// @dev A partially-filled source order bridges in slices; they accumulate
    ///      against one destination hash until the anchor is covered.
    function test_activate_accumulatesAcrossDeliveries() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        bytes32 h = _hashOrder(o);

        _acrossDeliver(BRIDGED / 2, _commitmentFor(h));
        vm.expectRevert(BridgedOrderInbox.Underfunded.selector);
        inbox.activate(o);

        _acrossDeliver(BRIDGED / 2, _commitmentFor(h));
        inbox.activate(o);
        assertTrue(settlement.orderApproved(address(inbox), h), "approved once fully funded");
    }

    /// @dev THE isolation property. A victim's funds sit in the shared escrow. An
    ///      attacker bridges dust naming their own order — one that would pull the
    ///      victim's balance — and cannot get it approved. Without the
    ///      full-funding rule the settlement's Permit3 pull would happily drain the
    ///      pool, because nothing at pull time consults this contract.
    function test_cannotDrainAnotherCommitsFunds() public {
        Order memory victim = _dstOrder(1, BRIDGED, DELIVERED);
        _acrossDeliver(BRIDGED, _commitmentFor(_hashOrder(victim)));
        inbox.activate(victim);

        // Attacker's order: same size, but every output goes to the attacker.
        Order memory attack = _dstOrder(2, BRIDGED, 1);
        attack.legsOut = PackedEncode.oneLegOut(address(tB), 1, 0, solver);
        bytes32 ah = _hashOrder(attack);

        _acrossDeliver(1, _commitmentFor(ah)); // one wei of "funding"

        vm.expectRevert(BridgedOrderInbox.Underfunded.selector);
        inbox.activate(attack);

        // And without an approval there is no authorization at all.
        _fundSolverOut(DELIVERED);
        vm.prank(solver);
        vm.expectRevert(Signatures.OrderNotApproved.selector);
        settlement.fill(attack, "", BRIDGED);

        assertEq(tA.balanceOf(address(inbox)), BRIDGED + 1, "victim's funds untouched");
    }

    /// @dev SECURITY REGRESSION — the SECOND way to drain another commit's funds,
    ///      and the one the full-funding rule above does NOT catch.
    ///
    ///      {test_cannotDrainAnotherCommitsFunds} relies on `credited >= anchor`
    ///      bounding the pull. That step assumes the amount PULLED equals the
    ///      amount COUNTED — true only for a FIXED input leg. A RISING leg
    ///      (`legsIn[0].end != 0`, the relayer-fee auction) is priced by
    ///      {Pricing.inputOwed} at the decayed tick and reaches `end`, while
    ///      `filled` only ever reaches the anchor, `start`.
    ///
    ///      So the attacker funds their commitment HONESTLY — `credited == anchor`,
    ///      no `Underfunded` — and still walks off with `end`. Here that is 100×
    ///      the funding, taken straight out of the victim's balance, with `sync`
    ///      recording a spend of `start` and leaving `liability` overstated forever.
    ///      Rejected at the shape gate; nothing downstream could catch it.
    function test_shape_rejectsRisingInputLeg() public {
        Order memory victim = _dstOrder(1, BRIDGED, DELIVERED);
        _acrossDeliver(BRIDGED, _commitmentFor(_hashOrder(victim)));
        inbox.activate(victim);

        // start == 1e18 (fully funded), end == 100e18 (what a decayed fill pulls).
        Order memory attack = _dstOrder(2, 1e18, 1);
        attack.legsIn = PackedEncode.oneLegIn(address(tA), 1e18, BRIDGED);
        attack.legsOut = PackedEncode.oneLegOut(address(tB), 1, 0, solver);
        // {DutchAuction} timing layout: decayStartTime [0:32), decayDuration [32:64).
        attack.timing = uint256(uint32(block.timestamp)) | (uint256(1 hours) << 32);

        _acrossDeliver(1e18, _commitmentFor(_hashOrder(attack))); // the FULL anchor

        vm.expectRevert(BridgedOrderInbox.UnsupportedOrderShape.selector);
        inbox.activate(attack);

        // No approval ⇒ no authorization, so the pull never happens.
        _fundSolverOut(DELIVERED);
        vm.warp(block.timestamp + 1 hours); // auction fully decayed
        vm.prank(solver);
        vm.expectRevert(Signatures.OrderNotApproved.selector);
        settlement.fill(attack, "", 1e18);

        assertEq(tA.balanceOf(address(inbox)), BRIDGED + 1e18, "victim's funds untouched");
    }

    /// @dev The counterpart: a FIXED input leg (`end == 0`) is the supported shape
    ///      and still activates. Guards against the check above being widened into
    ///      "reject any leg whose end field is set", which would break every order.
    function test_shape_acceptsFixedInputLeg() public {
        Order memory o = _dstOrder(3, BRIDGED, DELIVERED);
        _acrossDeliver(BRIDGED, _commitmentFor(_hashOrder(o)));
        inbox.activate(o);
        assertTrue(settlement.orderApproved(address(inbox), _hashOrder(o)), "fixed leg activates");
    }

    // ──────────────────── Settlement / refunds ────────────────────

    function test_settle_refundsUnfilledToBeneficiary() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        _acrossDeliver(BRIDGED, _commitmentFor(_hashOrder(o)));
        inbox.activate(o);

        vm.warp(_deadline(o) + 1);
        inbox.settle(_hashOrder(o));

        assertEq(tA.balanceOf(beneficiary), BRIDGED, "full refund");
        assertEq(inbox.liability(address(tA)), 0, "liability cleared");
    }

    function test_settle_afterPartialFill_refundsRemainder() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        _acrossDeliver(BRIDGED, _commitmentFor(_hashOrder(o)));
        inbox.activate(o);

        _fundSolverOut(DELIVERED);
        vm.prank(solver);
        settlement.fill(o, "", BRIDGED / 4);

        vm.warp(_deadline(o) + 1);
        inbox.settle(_hashOrder(o));

        assertEq(tB.balanceOf(endUser), DELIVERED / 4, "user got the filled quarter");
        assertEq(tA.balanceOf(beneficiary), (BRIDGED * 3) / 4, "rest refunded");
        assertEq(tA.balanceOf(address(inbox)), 0, "inbox emptied");
    }

    function test_settle_beforeDeadline_reverts() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        _acrossDeliver(BRIDGED, _commitmentFor(_hashOrder(o)));
        inbox.activate(o);

        vm.expectRevert(BridgedOrderInbox.NotYetRefundable.selector);
        inbox.settle(_hashOrder(o));
    }

    /// @dev A commitment nobody ever activated still refunds — that is what the
    ///      commitment's own `expiry` is for, since there is no order deadline.
    function test_settle_neverActivated_usesCommitmentExpiry() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        bytes32 h = _hashOrder(o);
        _acrossDeliver(BRIDGED, _commitmentFor(h));

        vm.expectRevert(BridgedOrderInbox.NotYetRefundable.selector);
        inbox.settle(h);

        vm.warp(block.timestamp + COMMITMENT_EXPIRY_OFFSET + 1);
        inbox.settle(h);
        assertEq(tA.balanceOf(beneficiary), BRIDGED, "refunded on expiry");
    }

    function test_settle_twice_reverts() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        bytes32 h = _hashOrder(o);
        _acrossDeliver(BRIDGED, _commitmentFor(h));
        inbox.activate(o);

        vm.warp(_deadline(o) + 1);
        inbox.settle(h);
        vm.expectRevert(BridgedOrderInbox.AlreadySettled.selector);
        inbox.settle(h);
    }

    /// @dev Settling revokes the on-chain approval, so a re-credited hash can
    ///      never ride a stale authorization.
    function test_settle_revokesApproval() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        bytes32 h = _hashOrder(o);
        _acrossDeliver(BRIDGED, _commitmentFor(h));
        inbox.activate(o);

        vm.warp(_deadline(o) + 1);
        inbox.settle(h);
        assertFalse(settlement.orderApproved(address(inbox), h), "approval withdrawn");
    }

    function test_credit_afterSettle_reverts() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        bytes32 h = _hashOrder(o);
        _acrossDeliver(BRIDGED, _commitmentFor(h));
        vm.warp(block.timestamp + COMMITMENT_EXPIRY_OFFSET + 1);
        inbox.settle(h);

        tA.mint(address(inbox), BRIDGED);
        vm.prank(address(spokePool));
        vm.expectRevert(BridgedOrderInbox.AlreadySettled.selector);
        inbox.handleV3AcrossMessage(address(tA), BRIDGED, address(spokePool), _commitmentFor(h));
    }

    // ──────────────────── Rescue ────────────────────

    function test_rescue_onlyUnattributedBalance() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        _acrossDeliver(BRIDGED, _commitmentFor(_hashOrder(o)));

        tA.mint(address(inbox), 7e18); // a stray delivery with no commitment
        assertEq(inbox.rescuable(address(tA)), 7e18, "only the stray amount");

        vm.prank(inboxOwner);
        uint256 got = inbox.rescue(address(tA), inboxOwner);
        assertEq(got, 7e18, "rescued the stray");
        assertEq(tA.balanceOf(address(inbox)), BRIDGED, "commitment untouched");
    }

    function test_rescue_nothingLoose_reverts() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        _acrossDeliver(BRIDGED, _commitmentFor(_hashOrder(o)));

        vm.prank(inboxOwner);
        vm.expectRevert(BridgedOrderInbox.NothingToRescue.selector);
        inbox.rescue(address(tA), inboxOwner);
    }

    function test_rescue_onlyOwner() public {
        tA.mint(address(inbox), 1e18);
        vm.prank(solver);
        vm.expectRevert(BridgedOrderInbox.NotOwner.selector);
        inbox.rescue(address(tA), solver);
    }

    // ──────────────────── sync: keeping the escape hatch usable ────────────────────

    /// @dev Settlement pulls an order's inputs through Permit3 without calling the
    ///      inbox, so nothing observes a fill. Until {sync} reconciles, `liability`
    ///      still counts funds that already left — which pins {rescuable} at zero.
    ///      With any filled-but-unsettled commit around (i.e. normal traffic) that
    ///      would keep the escape hatch shut exactly when it is needed.
    function test_sync_unblocksRescueAfterAFill() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        bytes32 h = _hashOrder(o);
        _acrossDeliver(BRIDGED, _commitmentFor(h));
        inbox.activate(o);
        _fundSolverOut(DELIVERED);
        vm.prank(solver);
        settlement.fill(o, "", BRIDGED);

        tA.mint(address(inbox), 7e18); // an orphaned delivery needing recovery
        assertEq(inbox.rescuable(address(tA)), 0, "understated while the fill is unreconciled");

        inbox.sync(h);
        assertEq(inbox.liability(address(tA)), 0, "spent funds no longer counted as owed");
        assertEq(inbox.rescuable(address(tA)), 7e18, "orphan now recoverable");

        vm.prank(inboxOwner);
        assertEq(inbox.rescue(address(tA), inboxOwner), 7e18, "rescued");
    }

    /// @dev sync + settle must release exactly `credited` in total, never twice.
    function test_sync_thenSettle_accountsExactlyOnce() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        bytes32 h = _hashOrder(o);
        _acrossDeliver(BRIDGED, _commitmentFor(h));
        inbox.activate(o);
        _fundSolverOut(DELIVERED);
        vm.prank(solver);
        settlement.fill(o, "", BRIDGED / 4);

        inbox.sync(h);
        inbox.sync(h); // idempotent
        assertEq(inbox.liability(address(tA)), (BRIDGED * 3) / 4, "only the unspent part is owed");

        vm.warp(_deadline(o) + 1);
        inbox.settle(h);
        assertEq(inbox.liability(address(tA)), 0, "cleared exactly once");
        assertEq(tA.balanceOf(beneficiary), (BRIDGED * 3) / 4, "remainder refunded");
        assertEq(tA.balanceOf(address(inbox)), 0, "inbox emptied");
    }

    function test_sync_beforeActivation_isNoop() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        bytes32 h = _hashOrder(o);
        _acrossDeliver(BRIDGED, _commitmentFor(h));
        inbox.sync(h);
        assertEq(inbox.liability(address(tA)), BRIDGED, "nothing pulled yet");
    }

    // ──────────────────── Ownership ────────────────────

    /// @dev Two-step, because the owner is the only route to {rescue}: a one-step
    ///      transfer to a mistyped address would strand orphaned deliveries forever.
    function test_ownership_isTwoStep() public {
        vm.prank(inboxOwner);
        inbox.transferOwnership(solver);
        assertEq(inbox.owner(), inboxOwner, "unchanged until accepted");
        assertEq(inbox.pendingOwner(), solver, "nominated");

        vm.prank(solver);
        inbox.acceptOwnership();
        assertEq(inbox.owner(), solver, "handover complete");
        assertEq(inbox.pendingOwner(), address(0), "nomination cleared");
    }

    function test_ownership_onlyNomineeCanAccept() public {
        vm.prank(inboxOwner);
        inbox.transferOwnership(solver);

        vm.prank(maker);
        vm.expectRevert(BridgedOrderInbox.NotPendingOwner.selector);
        inbox.acceptOwnership();
    }

    function test_ownership_onlyOwnerCanNominate() public {
        vm.prank(solver);
        vm.expectRevert(BridgedOrderInbox.NotOwner.selector);
        inbox.transferOwnership(solver);
    }

    // ──────────────────── Across-hook guards ────────────────────

    function test_handleAcross_onlySpokePool() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        vm.prank(solver);
        vm.expectRevert(BridgedOrderInbox.NotSpokePool.selector);
        inbox.handleV3AcrossMessage(address(tA), BRIDGED, solver, _commitmentFor(_hashOrder(o)));
    }

    /// @dev The chain-id bound in the commitment. The raw order hash is NOT
    ///      chain-bound (only the EIP-712 digest is, and the signature-less path
    ///      never computes one), so a replayed message would otherwise credit the
    ///      same order on a chain it was never meant for.
    function test_handleAcross_wrongChain_reverts() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        tA.mint(address(inbox), BRIDGED);
        vm.prank(address(spokePool));
        vm.expectRevert(BridgedOrderInbox.WrongChain.selector);
        inbox.handleV3AcrossMessage(
            address(tA), BRIDGED, address(spokePool), _commitmentFor(_hashOrder(o), uint64(block.chainid) + 1)
        );
    }

    function test_handleAcross_malformedMessage_reverts() public {
        tA.mint(address(inbox), BRIDGED);
        vm.prank(address(spokePool));
        vm.expectRevert(BridgedOrderInbox.BadCommitment.selector);
        inbox.handleV3AcrossMessage(address(tA), BRIDGED, address(spokePool), hex"dead");
    }

    function test_handleAcross_disabledToken_reverts() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        vm.prank(address(spokePool));
        vm.expectRevert(BridgedOrderInbox.TokenNotEnabled.selector);
        inbox.handleV3AcrossMessage(address(tC), BRIDGED, address(spokePool), _commitmentFor(_hashOrder(o)));
    }

    function test_credit_tokenMismatch_reverts() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        bytes32 h = _hashOrder(o);
        _acrossDeliver(BRIDGED, _commitmentFor(h));

        vm.prank(inboxOwner);
        inbox.enableToken(address(tC));
        vm.prank(address(spokePool));
        vm.expectRevert(BridgedOrderInbox.TokenMismatch.selector);
        inbox.handleV3AcrossMessage(address(tC), 1, address(spokePool), _commitmentFor(h));
    }

    // ──────────────────── Order-shape guards ────────────────────

    function _credited(Order memory o) internal returns (bytes32 h) {
        h = _hashOrder(o);
        _acrossDeliver(BRIDGED, _commitmentFor(h));
    }

    function test_shape_rejectsForeignMaker() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        o.maker = maker;
        _credited(o);
        vm.expectRevert(OrderState.NotOrderMaker.selector);
        inbox.activate(o);
    }

    function test_shape_rejectsItems() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        Item[] memory _tmpitems = new Item[](1);
        _tmpitems[0] = Item({op: ItemOp.MAKE, module: address(0xBAD), amount: 1, recipient: address(0), data: ""});
        o.items = PackedEncode.items(_tmpitems);
        _credited(o);
        vm.expectRevert(BridgedOrderInbox.UnsupportedOrderShape.selector);
        inbox.activate(o);
    }

    /// @dev SECURITY REGRESSION — a FILL-ONCE order ({DutchAuction.useNonceInvalidator},
    ///      `timing` bit 100) records its progress by consuming the maker's NONCE
    ///      rather than writing `filled[orderHash]`, which then stays 0 forever. This
    ///      inbox derives refunds from exactly that counter (`sync`: "`filled` ... IS
    ///      the amount of `token` pulled from here"), so such an order would be FILLED
    ///      and then REFUNDED IN FULL — a double payout whose excess is drawn from
    ///      other commitments' pooled balance, defeating the isolation that
    ///      {test_cannotDrainAnotherCommitsFunds} exists to guarantee.
    ///
    ///      Rejected at the shape gate. `sync` cannot be taught to read the nonce
    ///      bitmap instead: it is not amount-denominated (it can only say
    ///      filled/not-filled) and `credited` may legitimately exceed the anchor.
    function test_shape_rejectsFillOnceOrder() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        o.timing |= uint256(1) << 100; // the fill-once opt-in
        _credited(o);
        vm.expectRevert(BridgedOrderInbox.UnsupportedOrderShape.selector);
        inbox.activate(o);
    }

    /// @dev `recipient == address(0)` means "the maker", which here is the escrow —
    ///      the user's proceeds would land back inside it, reachable only by rescue.
    function test_shape_rejectsOutputToMaker() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        o.legsOut = PackedEncode.setLegOutRecipient(o.legsOut, 0, address(0));
        _credited(o);
        vm.expectRevert(BridgedOrderInbox.UnsupportedOrderShape.selector);
        inbox.activate(o);
    }

    function test_shape_rejectsOutputToInbox() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        o.legsOut = PackedEncode.setLegOutRecipient(o.legsOut, 0, address(inbox));
        _credited(o);
        vm.expectRevert(BridgedOrderInbox.UnsupportedOrderShape.selector);
        inbox.activate(o);
    }

    function test_shape_rejectsBuySide() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        o.timing |= uint256(1) << 101; // BUY (timing bit 101)
        _credited(o);
        vm.expectRevert(BridgedOrderInbox.UnsupportedOrderShape.selector);
        inbox.activate(o);
    }

    /// @dev A fill module decouples the fill delta from the leg anchor, which
    ///      would break the denomination both the funding invariant and {settle}'s
    ///      accounting depend on.
    function test_shape_rejectsFillModule() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        o.fillModule = address(0xF11);
        _credited(o);
        vm.expectRevert(BridgedOrderInbox.UnsupportedOrderShape.selector);
        inbox.activate(o);
    }

    function test_shape_rejectsMultipleInputLegs() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        LegIn[] memory _tmplegsIn = new LegIn[](2);
        _tmplegsIn[0] = LegIn(address(tA), BRIDGED, 0);
        _tmplegsIn[1] = LegIn(address(tC), 1, 0);
        o.legsIn = PackedEncode.legsIn(_tmplegsIn);
        _credited(o);
        vm.expectRevert(BridgedOrderInbox.UnsupportedOrderShape.selector);
        inbox.activate(o);
    }

    function test_shape_rejectsNoOutputs() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        o.legsOut = PackedEncode.legsOut(new LegOut[](0));
        _credited(o);
        vm.expectRevert(BridgedOrderInbox.UnsupportedOrderShape.selector);
        inbox.activate(o);
    }

    function test_shape_rejectsExpiredDeadline() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        _credited(o);
        vm.warp(_deadline(o) + 1);
        vm.expectRevert(BridgedOrderInbox.UnsupportedOrderShape.selector);
        inbox.activate(o);
    }

    /// @dev Activating a DIFFERENT order than the one committed cannot work: the
    ///      inbox looks the commitment up by the hash of what it was handed.
    function test_activate_wrongOrder_findsNoCommitment() public {
        Order memory committed = _dstOrder(1, BRIDGED, DELIVERED);
        _credited(committed);

        Order memory substitute = _dstOrder(2, BRIDGED, 1); // cheaper output, same funding
        vm.expectRevert(BridgedOrderInbox.BadCommitment.selector);
        inbox.activate(substitute);
    }

    // ──────────────────── Lens ────────────────────

    /// @dev The lens must attest a sigless order from the settler's own approval
    ///      record. Before this, `isSignatureValid` was unconditionally false for
    ///      the empty-sig path and the orderbook had to take the client's word for it.
    function test_lens_attestsSiglessOrder() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        _acrossDeliver(BRIDGED, _commitmentFor(_hashOrder(o)));
        _fundSolverOut(DELIVERED);

        (,, bool sigValidBefore,) = lens.getOrderRelevantState(o, "", solver, "");
        assertFalse(sigValidBefore, "unapproved sigless order is not authorized");

        inbox.activate(o);
        (, uint256 fillable, bool sigValid,) = lens.getOrderRelevantState(o, "", solver, "");
        assertTrue(sigValid, "approved sigless order attests");
        assertEq(fillable, BRIDGED, "fillable reflects the escrowed balance");
    }

    /// @dev While the bridge is still in flight the order reads as unfillable, so
    ///      a book that gates on `fillableAmount > 0` naturally holds it back
    ///      instead of needing an arrival race.
    function test_lens_reportsZeroFillableBeforeArrival() public view {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        (, uint256 fillable,,) = lens.getOrderRelevantState(o, "", solver, "");
        assertEq(fillable, 0, "nothing to fill until funds land");
        assertEq(inbox.missingFunding(_hashOrder(o), BRIDGED), BRIDGED, "full amount outstanding");
    }
}
