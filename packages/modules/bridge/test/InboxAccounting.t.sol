// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Order, Item, ItemOp, LegIn, LegOut, OrderSide} from "@core/settlement/Settlement.sol";
import {Signatures} from "@core/settlement/Signatures.sol";
import {OrderState} from "@core/settlement/OrderState.sol";

import {BridgedOrderInbox} from "../src/BridgedOrderInbox.sol";
import {CommitmentCodec} from "../src/CommitmentCodec.sol";
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
        uint256 credited = _credited(h);
        assertEq(credited, BRIDGED, "credited");

        inbox.activate(o, beneficiary);
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
        inbox.activate(o, beneficiary);
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
        inbox.activate(o, beneficiary);
    }

    function test_activate_neverCredited_reverts() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        vm.expectRevert(BridgedOrderInbox.BadCommitment.selector);
        inbox.activate(o, beneficiary);
    }

    /// @dev A partially-filled source order bridges in slices; they accumulate
    ///      against one destination hash until the anchor is covered.
    function test_activate_accumulatesAcrossDeliveries() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        bytes32 h = _hashOrder(o);

        _acrossDeliver(BRIDGED / 2, _commitmentFor(h));
        vm.expectRevert(BridgedOrderInbox.Underfunded.selector);
        inbox.activate(o, beneficiary);

        _acrossDeliver(BRIDGED / 2, _commitmentFor(h));
        inbox.activate(o, beneficiary);
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
        inbox.activate(victim, beneficiary);

        // Attacker's order: same size, but every output goes to the attacker.
        Order memory attack = _dstOrder(2, BRIDGED, 1);
        attack.legsOut = PackedEncode.oneLegOut(address(tB), 1, 0, solver);
        bytes32 ah = _hashOrder(attack);

        _acrossDeliver(1, _commitmentFor(ah)); // one wei of "funding"

        vm.expectRevert(BridgedOrderInbox.Underfunded.selector);
        inbox.activate(attack, beneficiary);

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
        inbox.activate(victim, beneficiary);

        // start == 1e18 (fully funded), end == 100e18 (what a decayed fill pulls).
        Order memory attack = _dstOrder(2, 1e18, 1);
        attack.legsIn = PackedEncode.oneLegIn(address(tA), 1e18, BRIDGED);
        attack.legsOut = PackedEncode.oneLegOut(address(tB), 1, 0, solver);
        // {DutchAuction} timing layout: decayStartTime [0:32), decayDuration [32:64).
        attack.timing = uint256(uint32(block.timestamp)) | (uint256(1 hours) << 32);

        _acrossDeliver(1e18, _commitmentFor(_hashOrder(attack))); // the FULL anchor

        vm.expectRevert(BridgedOrderInbox.UnsupportedOrderShape.selector);
        inbox.activate(attack, beneficiary);

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
        inbox.activate(o, beneficiary);
        assertTrue(settlement.orderApproved(address(inbox), _hashOrder(o)), "fixed leg activates");
    }

    // ──────────────────── Settlement / refunds ────────────────────

    function test_settle_refundsUnfilledToBeneficiary() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        _acrossDeliver(BRIDGED, _commitmentFor(_hashOrder(o)));
        inbox.activate(o, beneficiary);

        vm.warp(_expiry(o) + 1);
        _settle(_hashOrder(o));

        assertEq(tA.balanceOf(beneficiary), BRIDGED, "full refund");
        assertEq(inbox.liability(address(tA)), 0, "liability cleared");
    }

    function test_settle_afterPartialFill_refundsRemainder() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        _acrossDeliver(BRIDGED, _commitmentFor(_hashOrder(o)));
        inbox.activate(o, beneficiary);

        _fundSolverOut(DELIVERED);
        vm.prank(solver);
        settlement.fill(o, "", BRIDGED / 4);

        vm.warp(_expiry(o) + 1);
        _settle(_hashOrder(o));

        assertEq(tB.balanceOf(endUser), DELIVERED / 4, "user got the filled quarter");
        assertEq(tA.balanceOf(beneficiary), (BRIDGED * 3) / 4, "rest refunded");
        assertEq(tA.balanceOf(address(inbox)), 0, "inbox emptied");
    }

    function test_settle_beforeDeadline_reverts() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        _acrossDeliver(BRIDGED, _commitmentFor(_hashOrder(o)));
        inbox.activate(o, beneficiary);

        vm.expectRevert(BridgedOrderInbox.NotYetRefundable.selector);
        _settle(_hashOrder(o));
    }

    /// @dev A commitment nobody ever activated still refunds — that is what the
    ///      commitment's own `expiry` is for, since there is no order deadline.
    function test_settle_neverActivated_usesCommitmentExpiry() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        bytes32 h = _hashOrder(o);
        _acrossDeliver(BRIDGED, _commitmentFor(h));

        vm.expectRevert(BridgedOrderInbox.NotYetRefundable.selector);
        _settle(h);

        vm.warp(block.timestamp + COMMITMENT_EXPIRY_OFFSET + 1);
        _settle(h);
        assertEq(tA.balanceOf(beneficiary), BRIDGED, "refunded on expiry");
    }

    /// @dev Settle is idempotent, not terminal: a second call refunds nothing and
    ///      changes nothing. (The one-shot `settled` flag is what let a dust credit
    ///      plus one `settle` retire a victim's hash — F29 finding 4.)
    function test_settle_twice_isIdempotent() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        bytes32 h = _hashOrder(o);
        _acrossDeliver(BRIDGED, _commitmentFor(h));
        inbox.activate(o, beneficiary);

        vm.warp(_expiry(o) + 1);
        assertEq(_settle(h), BRIDGED, "first settle refunds everything");
        assertEq(_settle(h), 0, "second settle refunds nothing");
        assertEq(inbox.liability(address(tA)), 0, "liability cleared once");
    }

    /// @dev Settling revokes the on-chain approval, so a re-credited hash can
    ///      never ride a stale authorization.
    function test_settle_revokesApproval() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        bytes32 h = _hashOrder(o);
        _acrossDeliver(BRIDGED, _commitmentFor(h));
        inbox.activate(o, beneficiary);

        vm.warp(_expiry(o) + 1);
        _settle(h);
        assertFalse(settlement.orderApproved(address(inbox), h), "approval withdrawn");
    }

    /// @dev A late delivery after a settle credits the row again and is refundable
    ///      again — nothing a stranger can do closes a row for its beneficiary.
    function test_credit_afterSettle_reopensTheRow() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        bytes32 h = _hashOrder(o);
        _acrossDeliver(BRIDGED, _commitmentFor(h));
        vm.warp(block.timestamp + COMMITMENT_EXPIRY_OFFSET + 1);
        assertEq(_settle(h), BRIDGED);

        _acrossDeliver(BRIDGED, _commitmentFor(h)); // late slice, fresh expiry
        assertEq(inbox.liability(address(tA)), BRIDGED, "the late slice is owed again");
        vm.expectRevert(BridgedOrderInbox.NotYetRefundable.selector);
        _settle(h);
        vm.warp(block.timestamp + COMMITMENT_EXPIRY_OFFSET + 1);
        assertEq(_settle(h), BRIDGED, "and refundable again");
        assertEq(tA.balanceOf(beneficiary), 2 * BRIDGED);
    }

    // ──────────────────── Rescue ────────────────────

    /// @dev CHANGED by audit 2026-09-30 (BRIDGE-A-1): a stray transfer no event
    ///      announced is no longer instantly rescuable — it could be an in-flight
    ///      LayerZero delivery whose compose has not run. It goes through the
    ///      delayed stray path, still bounded by `balance - liability`.
    function test_rescue_onlyUnattributedBalance() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        _acrossDeliver(BRIDGED, _commitmentFor(_hashOrder(o)));

        tA.mint(address(inbox), 7e18); // a stray delivery with no commitment
        assertEq(inbox.rescuable(address(tA)), 0, "nothing announced, nothing instantly rescuable");
        assertEq(inbox.strayBalance(address(tA)), 7e18, "only the stray amount");

        vm.prank(inboxOwner);
        inbox.queueStrayRescue(address(tA), inboxOwner, type(uint256).max);
        vm.warp(block.timestamp + inbox.COMPOSE_SOURCE_DELAY());
        vm.prank(inboxOwner);
        uint256 got = inbox.executeStrayRescue(address(tA));
        assertEq(got, 7e18, "rescued the stray");
        assertEq(tA.balanceOf(address(inbox)), BRIDGED, "commitment untouched");
    }

    function test_rescue_nothingLoose_reverts() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        _acrossDeliver(BRIDGED, _commitmentFor(_hashOrder(o)));

        vm.prank(inboxOwner);
        vm.expectRevert(BridgedOrderInbox.NothingToRescue.selector);
        inbox.rescue(address(tA), inboxOwner, type(uint256).max);
    }

    function test_rescue_onlyOwner() public {
        tA.mint(address(inbox), 1e18);
        vm.prank(solver);
        vm.expectRevert(BridgedOrderInbox.NotOwner.selector);
        inbox.rescue(address(tA), solver, type(uint256).max);
        vm.prank(solver);
        vm.expectRevert(BridgedOrderInbox.NotOwner.selector);
        inbox.queueStrayRescue(address(tA), solver, 1e18);
        vm.prank(solver);
        vm.expectRevert(BridgedOrderInbox.NotOwner.selector);
        inbox.executeStrayRescue(address(tA));
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
        inbox.activate(o, beneficiary);
        _fundSolverOut(DELIVERED);
        vm.prank(solver);
        settlement.fill(o, "", BRIDGED);

        tA.mint(address(inbox), 7e18); // a stray delivery needing recovery
        assertEq(inbox.strayBalance(address(tA)), 0, "understated while the fill is unreconciled");

        inbox.sync(h);
        assertEq(inbox.liability(address(tA)), 0, "spent funds no longer counted as owed");
        assertEq(inbox.strayBalance(address(tA)), 7e18, "stray now recoverable");

        vm.prank(inboxOwner);
        inbox.queueStrayRescue(address(tA), inboxOwner, type(uint256).max);
        vm.warp(block.timestamp + inbox.COMPOSE_SOURCE_DELAY());
        vm.prank(inboxOwner);
        assertEq(inbox.executeStrayRescue(address(tA)), 7e18, "rescued");
    }

    /// @dev sync + settle must release exactly `credited` in total, never twice.
    function test_sync_thenSettle_accountsExactlyOnce() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        bytes32 h = _hashOrder(o);
        _acrossDeliver(BRIDGED, _commitmentFor(h));
        inbox.activate(o, beneficiary);
        _fundSolverOut(DELIVERED);
        vm.prank(solver);
        settlement.fill(o, "", BRIDGED / 4);

        inbox.sync(h);
        inbox.sync(h); // idempotent
        assertEq(inbox.liability(address(tA)), (BRIDGED * 3) / 4, "only the unspent part is owed");

        vm.warp(_expiry(o) + 1);
        _settle(h);
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

    /// @dev A delivery in another enabled token for the same hash lands in ITS OWN
    ///      row (the token is part of the key); it neither blocks the real row nor
    ///      can it fund the order, whose input leg names `tA`.
    function test_credit_otherToken_isItsOwnRow() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        bytes32 h = _hashOrder(o);
        _acrossDeliver(BRIDGED, _commitmentFor(h));

        vm.prank(inboxOwner);
        inbox.enableToken(address(tC));
        tC.mint(address(inbox), 1);
        vm.prank(address(spokePool));
        inbox.handleV3AcrossMessage(address(tC), 1, address(spokePool), _commitmentFor(h));

        assertEq(_credited(h), BRIDGED, "the tA row is untouched");
        (,, uint256 cCredited,,,,,) = inbox.commits(inbox.commitKey(h, beneficiary, address(tC)));
        assertEq(cCredited, 1, "the tC row holds the stray wei");
        inbox.activate(o, beneficiary); // funded from the tA row
        assertTrue(settlement.orderApproved(address(inbox), h));
    }

    // ──────────────────── Order-shape guards ────────────────────

    function _creditedOrder(Order memory o) internal returns (bytes32 h) {
        h = _hashOrder(o);
        _acrossDeliver(BRIDGED, _commitmentFor(h));
    }

    function test_shape_rejectsForeignMaker() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        o.maker = maker;
        _creditedOrder(o);
        // Now refused by the inbox's own shape check (audit 2026-09-30: the maker
        // is part of `_staticShapeOk`, which `settleExpired` also consults) before
        // Settlement's `NotOrderMaker` is ever reached.
        vm.expectRevert(BridgedOrderInbox.UnsupportedOrderShape.selector);
        inbox.activate(o, beneficiary);
    }

    function test_shape_rejectsItems() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        Item[] memory _tmpitems = new Item[](1);
        _tmpitems[0] = Item({op: ItemOp.MAKE, module: address(0xBAD), amount: 1, recipient: address(0), data: ""});
        o.items = PackedEncode.items(_tmpitems);
        _creditedOrder(o);
        vm.expectRevert(BridgedOrderInbox.UnsupportedOrderShape.selector);
        inbox.activate(o, beneficiary);
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
        _creditedOrder(o);
        vm.expectRevert(BridgedOrderInbox.UnsupportedOrderShape.selector);
        inbox.activate(o, beneficiary);
    }

    /// @dev `recipient == address(0)` means "the maker", which here is the escrow —
    ///      the user's proceeds would land back inside it, reachable only by rescue.
    function test_shape_rejectsOutputToMaker() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        o.legsOut = PackedEncode.setLegOutRecipient(o.legsOut, 0, address(0));
        _creditedOrder(o);
        vm.expectRevert(BridgedOrderInbox.UnsupportedOrderShape.selector);
        inbox.activate(o, beneficiary);
    }

    function test_shape_rejectsOutputToInbox() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        o.legsOut = PackedEncode.setLegOutRecipient(o.legsOut, 0, address(inbox));
        _creditedOrder(o);
        vm.expectRevert(BridgedOrderInbox.UnsupportedOrderShape.selector);
        inbox.activate(o, beneficiary);
    }

    function test_shape_rejectsBuySide() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        o.timing |= uint256(1) << 101; // BUY (timing bit 101)
        _creditedOrder(o);
        vm.expectRevert(BridgedOrderInbox.UnsupportedOrderShape.selector);
        inbox.activate(o, beneficiary);
    }

    /// @dev A fill module decouples the fill delta from the leg anchor, which
    ///      would break the denomination both the funding invariant and {settle}'s
    ///      accounting depend on.
    function test_shape_rejectsFillModule() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        o.fillModule = address(0xF11);
        _creditedOrder(o);
        vm.expectRevert(BridgedOrderInbox.UnsupportedOrderShape.selector);
        inbox.activate(o, beneficiary);
    }

    function test_shape_rejectsMultipleInputLegs() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        LegIn[] memory _tmplegsIn = new LegIn[](2);
        _tmplegsIn[0] = LegIn(address(tA), BRIDGED, 0);
        _tmplegsIn[1] = LegIn(address(tC), 1, 0);
        o.legsIn = PackedEncode.legsIn(_tmplegsIn);
        _creditedOrder(o);
        vm.expectRevert(BridgedOrderInbox.UnsupportedOrderShape.selector);
        inbox.activate(o, beneficiary);
    }

    function test_shape_rejectsNoOutputs() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        o.legsOut = PackedEncode.legsOut(new LegOut[](0));
        _creditedOrder(o);
        vm.expectRevert(BridgedOrderInbox.UnsupportedOrderShape.selector);
        inbox.activate(o, beneficiary);
    }

    function test_shape_rejectsExpiredDeadline() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        _creditedOrder(o);
        vm.warp(_expiry(o) + 1);
        vm.expectRevert(BridgedOrderInbox.UnsupportedOrderShape.selector);
        inbox.activate(o, beneficiary);
    }

    /// @dev Activating a DIFFERENT order than the one committed cannot work: the
    ///      inbox looks the commitment up by the hash of what it was handed.
    function test_activate_wrongOrder_findsNoCommitment() public {
        Order memory committed = _dstOrder(1, BRIDGED, DELIVERED);
        _creditedOrder(committed);

        Order memory substitute = _dstOrder(2, BRIDGED, 1); // cheaper output, same funding
        vm.expectRevert(BridgedOrderInbox.BadCommitment.selector);
        inbox.activate(substitute, beneficiary);
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

        inbox.activate(o, beneficiary);
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
        assertEq(_missing(_hashOrder(o), BRIDGED), BRIDGED, "full amount outstanding");
    }

    // ──────────────────── Row isolation (F28 finding 1 → F29 finding 4) ────────────────────

    function _commitmentAs(bytes32 orderHash, address who, uint32 expiry) internal pure returns (bytes memory) {
        return CommitmentCodec.encode(
            CommitmentCodec.Commitment({orderHash: orderHash, beneficiary: who, dstChainId: DST_CHAIN, expiry: expiry})
        );
    }

    /// @dev F28: a 1-wei front-credit naming the victim's hash with the ATTACKER
    ///      as beneficiary. Now it lands in the attacker's own row: the victim's
    ///      delivery is unaffected, the victim's row activates, and the attacker's
    ///      wei refunds to the attacker alone.
    function test_frontCredit_landsInItsOwnRow() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        bytes32 h = _hashOrder(o);
        address attacker = address(0xA77);

        _acrossDeliver(1, _commitmentAs(h, attacker, uint32(block.timestamp) + 3 days));
        _acrossDeliver(BRIDGED, _commitmentFor(h));

        assertEq(_credited(h), BRIDGED, "victim row holds only the victim's principal");
        inbox.activate(o, beneficiary);

        vm.warp(_expiry(o) + 1);
        assertEq(_settle(h), BRIDGED, "victim refunded to the victim");
        vm.warp(block.timestamp + 3 days); // the attacker's own fallback
        assertEq(inbox.settle(h, attacker, address(tA)), 1, "attacker refunded their own wei");
        assertEq(tA.balanceOf(beneficiary), BRIDGED);
        assertEq(tA.balanceOf(attacker), 1);
    }

    /// @dev F29 vector A: front-credit with `expiry = 0`, then `settle` at once, then
    ///      the victim's delivery. Before: the hash was terminal and the victim's
    ///      relay unwound. Now: the attacker settles their own empty-ish row; the
    ///      victim's row is untouched and activates.
    function test_frontCreditThenSettle_cannotRetireTheHash() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        bytes32 h = _hashOrder(o);
        address attacker = address(0xA77);

        _acrossDeliver(1, _commitmentAs(h, attacker, 0));
        assertEq(inbox.settle(h, attacker, address(tA)), 1, "attacker settles their own row");

        _acrossDeliver(BRIDGED, _commitmentFor(h));
        inbox.activate(o, beneficiary);
        assertTrue(settlement.orderApproved(address(inbox), h), "victim's order activates regardless");
    }

    /// @dev F29 vector C: a copycat credit carrying the victim's beneficiary AND
    ///      token is a gift to the victim's row. Its `expiry` can only RAISE the
    ///      fallback (max), and the order-deadline path refunds the row anyway.
    function test_copycatCredit_isAGift_andCannotLockTheRow() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        bytes32 h = _hashOrder(o);
        uint32 honest = uint32(block.timestamp) + 3 days;

        _acrossDeliver(BRIDGED, _commitmentAs(h, beneficiary, honest));
        _acrossDeliver(1, _commitmentAs(h, beneficiary, type(uint32).max)); // "lock until 2106"
        assertEq(inbox.refundAfter(h, beneficiary, address(tA)), type(uint32).max, "fallback raised by the copycat");

        // ...but the ORDER's deadline is signed and public: once it passes, anyone
        // refunds the row by presenting the order.
        vm.warp(honest + 1);
        vm.expectRevert(BridgedOrderInbox.NotYetRefundable.selector);
        _settle(h);
        vm.warp(_expiry(o) + 1);
        assertEq(
            inbox.settleExpired(o, beneficiary, address(tA)), BRIDGED + 1, "refunded on the order's deadline, gift included"
        );
    }

    /// @dev An early copycat `expiry` cannot force an early refund either: max, not min.
    function test_copycatCredit_cannotShortenTheFallback() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        bytes32 h = _hashOrder(o);
        uint32 honest = uint32(block.timestamp) + 3 days;
        _acrossDeliver(BRIDGED, _commitmentAs(h, beneficiary, honest));
        _acrossDeliver(1, _commitmentAs(h, beneficiary, 0));
        assertEq(inbox.refundAfter(h, beneficiary, address(tA)), honest, "fallback not lowered");
        vm.expectRevert(BridgedOrderInbox.NotYetRefundable.selector);
        _settle(h);
    }

    /// @dev Only ONE row may fund a hash at a time: a second row (another
    ///      beneficiary, fully funded) cannot activate over the active one, and
    ///      refunds to its own beneficiary.
    function test_secondRow_cannotActivateOverTheActiveOne() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        bytes32 h = _hashOrder(o);
        address other = address(0x07E5);
        _acrossDeliver(BRIDGED, _commitmentFor(h));
        _acrossDeliver(BRIDGED, _commitmentAs(h, other, uint32(block.timestamp) + 3 days));

        inbox.activate(o, beneficiary);
        vm.expectRevert(BridgedOrderInbox.RowActive.selector);
        inbox.activate(o, other);

        vm.warp(_expiry(o) + 1);
        assertEq(_settle(h), BRIDGED, "the active row refunds itself");
        vm.warp(block.timestamp + 3 days); // the other row never activated: its own fallback
        assertEq(inbox.settle(h, other, address(tA)), BRIDGED, "and so does the other");
    }

    /// @dev Same-beneficiary top-ups still accumulate (the partial-fill path).
    function test_sameBeneficiaryCreditsAccumulate() public {
        Order memory o = _dstOrder(1, BRIDGED, DELIVERED);
        bytes32 h = _hashOrder(o);
        _acrossDeliver(BRIDGED / 2, _commitmentFor(h));
        _acrossDeliver(BRIDGED / 2, _commitmentFor(h));
        assertEq(_credited(h), BRIDGED, "accumulated");
    }
}
