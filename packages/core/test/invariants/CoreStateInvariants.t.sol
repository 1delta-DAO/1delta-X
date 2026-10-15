// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MockSettlementBase} from "../shared/MockSettlementBase.t.sol";
import {StateHandler} from "./StateHandler.sol";

/// @title CoreStateInvariants
/// @notice STATEFUL invariant coverage for the four pieces of mutable state the
///         settler owns, back at the roots:
///
///           1. FILL state        — `filled[orderHash]` and the cancellation sentinel
///           2. CANCELLATION state— `nonceBitmap` + `minValidNonce`
///           3. APPROVAL state    — `orderApproved[maker][orderHash]`
///           4. DELEGATION state  — `orderSignerExpiry[maker][signer]`
///
///         Those four mappings (plus Permit3's own books) are the ENTIRE mutable
///         surface of the settler — {OrderState} pins the slot layout for exactly that
///         reason — so a property that holds over all four holds over the protocol's
///         authority model as a whole.
///
///  ── HOW THIS DIFFERS FROM THE UNIT SUITES ────────────────────────────────────
///  The `swaps/` and `items/` suites prove POSITIVE facts about scenarios someone
///  thought of: this cancel works, that delegate is rejected. This suite proves a
///  NEGATIVE fact over a scenario space nobody enumerated: across a random walk of
///  the lifecycle entry points (every cancel / approval / delegation write, and the
///  fill entries `fill`, `fillUpTo`, `fillWithCallback`, `batchFill` and
///  `matchSettle` — `fillWithPermit` / `fillWithPermitTake` are unit-tested only;
///  corrected in audit 2026-09-30 CORE-FILL-2), called by every actor (three makers, two fillers and
///  an unrelated attacker) in every order, *no write ever lands in a cell its caller
///  had no authority over*. {StateHandler} snapshots all 89 watched cells before each
///  action and diffs them after, so griefing, front-running and outright theft — all
///  of which reduce, on-chain, to a write in somebody else's cell — surface as an
///  unallowed diff rather than as an absent test.
///
///  On top of that the walk enforces the IRREVERSIBILITY laws that make the lifecycle
///  safe to build an orderbook on: `filled` never rewinds, a cancellation sentinel is
///  never cleared, a cancelled nonce never comes back to life, the rollback floor
///  never retreats — and each settled fill conserves value to the wei.
///
///  The NETTED path is walked the same way ({StateHandler.doMatchSettle}): two or
///  three orders under a solver-fuzzed schedule — shuffled, a `PULL` duplicated, a
///  step dropped, a `PRESEND` inserted, an ITEM or DELIVER re-run — and every
///  settlement that survives is held to the same wei-exact ledger over makers,
///  solver and lender. That is the `Batch.matchSettle` claim "any schedule yields a
///  correct settlement or a revert" as a checked property: the credit ledger's
///  `PULL` netting, `_creditItemProceeds`' excess-to-maker attribution, and
///  `_sweepSurplus`' wholeness floor are what make it hold.
///
///  Since task 31 the netted path also admits DELIVERY-FUNDED items, so the book
///  carries two pre-funded MAKE orders (9, 10: different makers, one SHARED module
///  holding residue). Every settled fill or match of them must leave the maker's
///  wallet tB untouched, raise `supplied[maker]` by exactly the delivered slice and
///  leave the module at its floor; and no schedule that hoists a pre-funded item
///  ahead of its own DELIVER may settle — the delivery ledger {Batch._stepDeliver}
///  writes is what refuses it ({Base._forSlice} `ForLegInvalid`).
///
///  ⚠ `fail_on_revert = false` (see `[profile.core.invariant]`): a fuzzer allowed to
///  call anything as anyone reverts constantly and that is the intended behaviour. It
///  also means an assertion that REVERTED inside the handler would be swallowed, so
///  the handler RECORDS findings into one string per family and the four
///  `invariant_*` functions below are what actually fail the run.
contract CoreStateInvariants is MockSettlementBase {
    StateHandler internal handler;

    uint256 internal constant CANCELLED = type(uint256).max;

    function setUp() public override {
        super.setUp();
        handler = new StateHandler();
        handler.init(permit3, settlement, tA, tB);

        bytes4[] memory sel = new bytes4[](18);
        sel[0] = StateHandler.doFill.selector;
        sel[1] = StateHandler.doFillSigless.selector;
        sel[2] = StateHandler.doFillAsDelegate.selector;
        sel[3] = StateHandler.doFillBadSig.selector;
        sel[4] = StateHandler.doCancelOrder.selector;
        sel[5] = StateHandler.doCancelNonces.selector;
        sel[6] = StateHandler.doRollback.selector;
        sel[7] = StateHandler.doInvalidateWord.selector;
        sel[8] = StateHandler.doApproveOrder.selector;
        sel[9] = StateHandler.doApproveOrders.selector;
        sel[10] = StateHandler.doRevokeApproval.selector;
        sel[11] = StateHandler.doSetOrderSigner.selector;
        sel[12] = StateHandler.doSetOrderSignerWithSig.selector;
        sel[13] = StateHandler.doWarp.selector;
        sel[14] = StateHandler.doMatchSettle.selector;
        sel[15] = StateHandler.doDonate.selector;
        // The other hand-armed fill entries + the size sentinel on every one of them
        // (audit 2026-09-30 CORE-FILL-2).
        sel[16] = StateHandler.doFillVia.selector;
        // The netted walk with a pre-funded order forced into slot 0 and a targeted
        // "hoist one pre-funded item" schedule mutation (task 31).
        sel[17] = StateHandler.doMatchSettlePreFund.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    // ═══════════════ 1. FILL STATE ═══════════════

    /// @notice Nothing ever moved `filled` — or the nonce a fill-once order records its
    ///         progress in — outside the fill or match that was entitled to move it,
    ///         `filled` never rewound, no fill ever mis-priced itself, and no netted
    ///         match ever settled off its signed arithmetic, incomplete, short, or
    ///         with an exactly-once step run twice.
    function invariant_fillState() public view {
        assertEq(bytes(handler.fillViolation()).length, 0, handler.fillViolation());
    }

    /// @notice The counter is bounded by the order's OWN denominator, always. The only
    ///         value above it is the cancellation sentinel, which is unambiguous
    ///         because a token amount can never reach 2^256-1.
    function invariant_fillNeverExceedsTheOrderTotal() public view {
        for (uint256 i; i < handler.N_ORDERS(); ++i) {
            uint256 f = settlement.filled(handler.orderHashes(i));
            if (f == CANCELLED) continue;
            assertLe(f, handler.orderTotal(i), "filled exceeded the order's denominator");
        }
    }

    /// @notice A fill-once order keeps NO counter — its progress is the consumed nonce
    ///         — so its `filled` slot must stay at zero for its whole life. (The
    ///         sentinel is the one other value it may hold: {cancelOrder} parks it
    ///         there.) If this ever fails, the opt-in is silently paying for a storage
    ///         slot it was created to avoid, and worse, the two progress records can
    ///         disagree.
    function invariant_fillOnceOrdersKeepNoCounter() public view {
        for (uint256 i; i < handler.N_ORDERS(); ++i) {
            if (!handler.isFillOnce(i)) continue;
            uint256 f = settlement.filled(handler.orderHashes(i));
            assertTrue(f == 0 || f == CANCELLED, "a fill-once order accrued a filled counter");
        }
    }

    // ═══════════════ 2. CANCELLATION STATE ═══════════════

    /// @notice No cancelled nonce ever came back, no rollback floor ever retreated, and
    ///         no actor ever wrote into a maker's bitmap but that maker (or that
    ///         maker's own fill-once order consuming its own nonce).
    function invariant_cancellationState() public view {
        assertEq(bytes(handler.cancelViolation()).length, 0, handler.cancelViolation());
    }

    // ═══════════════ 3. APPROVAL STATE ═══════════════

    /// @notice On-chain order approval stayed self-keyed: only a maker ever set or
    ///         cleared its own record, no sigless fill ever settled without a live
    ///         record, `approveOrders` never half-applied, and a revoked approval on a
    ///         touched order always escalated to the full cancel that closes the
    ///         first-fill signature skip.
    function invariant_approvalState() public view {
        assertEq(bytes(handler.approvalViolation()).length, 0, handler.approvalViolation());
    }

    // ═══════════════ 4. DELEGATION STATE ═══════════════

    /// @notice The delegate registry stayed maker-keyed: nobody nominated a signer for
    ///         somebody else, no forged permit wrote a maker's row, no relayed
    ///         nomination touched an ORDER nonce (it consumes only the reserved half),
    ///         and no non-delegate opened an untouched order.
    function invariant_delegationState() public view {
        assertEq(bytes(handler.delegationViolation()).length, 0, handler.delegationViolation());
    }

    /// @notice `address(0)` is never a valid signer. `ecrecover` yields it for every
    ///         malformed signature, so one authorized zero entry would promote every
    ///         unrecoverable signature in the system to a valid delegated one — the
    ///         single highest-severity cell in the whole registry.
    function invariant_zeroAddressIsNeverADelegate() public view {
        for (uint256 m; m < 3; ++m) {
            assertEq(settlement.orderSignerExpiry(handler.makers(m), address(0)), 0, "address(0) became a signer");
        }
    }

    // ═══════════════ CROSS-CUTTING ═══════════════

    /// @notice The settler is a pass-through and custodies nothing between fills —
    ///         except what was DONATED to it, which it holds forever and to the wei.
    ///         Above the donation is a stranded maker/filler payment or an item's
    ///         proceeds nobody reconciled — the residue class that shows up in every
    ///         settlement-layer audit; below it is a sweep or a proceeds window that
    ///         reached past its snapshot into money that was already there.
    /// @notice The shared pre-fund module holds EXACTLY its residue — the seed plus
    ///         every donation into it — in both tokens. Every pre-funded spend ends at
    ///         its floor (`balance − amount`), so above the residue is a delivery no
    ///         item consumed (an order whose item never ran yet settled), and below it
    ///         is an item that spent residue or another order's delivery. And the
    ///         module's credit book agrees with what physically left it.
    function invariant_preFundModuleHoldsOnlyResidue() public view {
        address mod = address(handler.supply());
        assertEq(tA.balanceOf(mod), handler.moduleResidue(address(tA)), "tA in the pre-fund module != residue");
        assertEq(tB.balanceOf(mod), handler.moduleResidue(address(tB)), "tB in the pre-fund module != residue");
        uint256 sum;
        for (uint256 m; m < 3; ++m) {
            sum += handler.supply().supplied(handler.makers(m));
        }
        address sink = handler.supply().SINK();
        assertEq(tB.balanceOf(sink), sum, "supplied credits != tokens the module spent");
        assertEq(tA.balanceOf(sink), 0, "the module spent a token no order delivered");
    }

    function invariant_settlementCustodiesOnlyDonations() public view {
        assertEq(tA.balanceOf(address(settlement)), handler.donated(address(tA)), "tA in the settler != donated");
        assertEq(tB.balanceOf(address(settlement)), handler.donated(address(tB)), "tB in the settler != donated");
        assertEq(tA.balanceOf(address(permit3)), 0, "tA stranded in Permit3");
        assertEq(tB.balanceOf(address(permit3)), 0, "tB stranded in Permit3");
    }

    // ═══════════════ PRE-FUNDED ITEMS: ORDERING ═══════════════

    /// @dev The task-31 ordering rule under load, deterministically: 64 schedules
    ///      over the same plan (orders 9 + 10 pre-funded on the SHARED module, order 6
    ///      the counter-side, 1,001-unit slices so nothing exhausts), each the
    ///      canonical schedule mutated by a hashed seed — half by the generic
    ///      mutations (shuffled, PULL duplicated, step dropped, PRESEND inserted,
    ///      ITEM/DELIVER doubled), half by the targeted one-item hoist. The module holds
    ///      residue throughout, so an item hoisted ahead of its own DELIVER would find
    ///      enough there to "fund" it; only the core's delivery ledger refuses it.
    ///      Asserts some such plans were submitted (`earlyItemProbes`, counted only
    ///      when the plan's repaired twin — items moved back after their DELIVER —
    ///      actually settles), some plans did settle, and the
    ///      handler recorded nothing — in particular no hoisted plan settled. This is
    ///      the deterministic mutant-killer for {Batch._stepDeliver}'s
    ///      `st.fills[i].outs = amts` (moving it to open makes this fail).
    function test_preFundItemBeforeDeliverNeverSettles() public {
        uint256 slice = 2 | (1000 << 2); // mode 2 → a (1000 % remaining) + 1 = 1,001-unit slice
        uint256 fillSeed = slice | (slice << 128); // slots 0 and 2 sliced; slot 1 (>> 64) = exact demand
        for (uint256 k; k < 64; ++k) {
            uint256 sched = uint256(keccak256(abi.encode(k)));
            // Alternate the generic mutations with the targeted hoist (pairSeed 0/1:
            // order 9 or 10 in slot 0, the other in slot 2, one item hoisted).
            if (k % 2 == 0) handler.doMatchSettle(7, 0, 0, fillSeed, 3, sched);
            else handler.doMatchSettlePreFund((k >> 1) % 2, 0, 0, fillSeed, 3, sched);
        }
        assertGt(handler.earlyItemProbes(), 0, "no otherwise-settleable hoisted plan was ever submitted");
        assertGt(handler.preFundMatchesSettled(), 0, "no pre-funded plan settled at all");
        assertEq(bytes(handler.fillViolation()).length, 0, handler.fillViolation());
        assertEq(tB.balanceOf(address(handler.supply())), handler.moduleResidue(address(tB)), "module off its residue");
        emit log_named_uint("hoisted (otherwise settleable) plans submitted", handler.earlyItemProbes());
        emit log_named_uint("pre-funded plans settled", handler.preFundMatchesSettled());
    }

    // ═══════════════ ANTI-VACUITY ═══════════════

    /// @dev A walk in which every action reverted would satisfy all of the above and
    ///      prove nothing. This drives one of each family with fixed seeds and asserts
    ///      the counters actually moved, so the handler cannot silently rot into a
    ///      no-op (a wrong approval, a changed order shape, a renamed entry point).
    ///      Deterministic on purpose — no fuzzing, no flake.
    ///
    ///      The FUZZ walk's own liveness was measured the same way rather than gated:
    ///      an `afterInvariant()` probe asserting `fillsSettled > 0` passed all 64
    ///      runs (2026-08-31). It is not kept as a permanent assertion because it is
    ///      not guaranteed — a run whose opening moves happen to invalidate all three
    ///      makers' nonce words before the first fill attempt would settle nothing and
    ///      fail honestly but uselessly. `ordersCancelled > 0` DOES fail some runs (a
    ///      `cancelOrder` needs the caller to be that order's own maker, ~1 pick in 6),
    ///      which is why neither is a gate. This test is the rot guard instead.
    function test_handlerActuallyMutatesState() public {
        handler.doFill(0, 3, 0); //            order 0, filler 0, full remaining
        handler.doFill(8, 4, 1); //            order 8 (item-funded), filler 1, a 2-wei slice: the item's excess goes back
        handler.doDonate(5, 0, 0); //          attacker donates 1 wei of tA to the settler
        handler.doMatchSettle(2, 1, 1, 0, 3, 0); // order 2 vs order 7, canonical schedule
        handler.doMatchSettle(6, 0, 1, 0, 4, 0); // order 8 vs order 6: the item funds part, PULL the rest
        handler.doFill(9, 4, 400_001); //      order 9 on the hot path, a slice: filler 1 fronts tB to the module
        // Orders 9 + 10 (both pre-funded, one shared module) vs order 6, canonical
        // `PULL… DELIVER 9, DELIVER 6, DELIVER 10, ITEM 9, ITEM 10`: each item spends
        // exactly its own delivery, leaving the other's and the residue alone.
        handler.doMatchSettle(7, 0, 0, 0, 3, 0);
        handler.doDonate(3, 3, 7); //          filler 0 donates tB INTO the pre-fund module
        handler.doApproveOrder(1, 0); //       maker 0 approves its own order 1
        handler.doFillSigless(1, 4); //        filler 1 settles it with an empty sig
        handler.doSetOrderSigner(0, 1, 1); //  maker 0 nominates signers[1]
        handler.doSetOrderSignerWithSig(0, 1, 0, 0); // relayed, correctly signed
        handler.doCancelOrder(5, 2); //        maker 2 cancels its own order 5
        handler.doCancelNonces(1, 4, 5); //    maker 1 cancels two nonces

        assertGe(handler.fillsSettled(), 3, "no fill ever settled");
        assertEq(handler.matchesSettled(), 3, "the canonical matches did not settle");
        assertEq(handler.preFundMatchesSettled(), 1, "the pre-funded match did not settle");
        assertGe(handler.preFundFillsSettled(), 1, "no pre-funded hot-path fill settled");
        assertGe(handler.approvalsRecorded(), 1, "no approval was ever recorded");
        assertGe(handler.delegationsWritten(), 2, "no delegation was ever written");
        assertGe(handler.ordersCancelled(), 1, "no order was ever cancelled");
        assertGe(handler.noncesCancelled(), 1, "no nonce was ever cancelled");

        assertEq(settlement.filled(handler.orderHashes(5)), CANCELLED, "cancel sentinel not parked");
        assertEq(bytes(handler.fillViolation()).length, 0, handler.fillViolation());
        assertEq(bytes(handler.cancelViolation()).length, 0, handler.cancelViolation());
        assertEq(bytes(handler.approvalViolation()).length, 0, handler.approvalViolation());
        assertEq(bytes(handler.delegationViolation()).length, 0, handler.delegationViolation());
    }
}
