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
///  every lifecycle entry point, called by every actor (three makers, two fillers and
///  an unrelated attacker) in every order, *no write ever lands in a cell its caller
///  had no authority over*. {StateHandler} snapshots all 69 watched cells before each
///  action and diffs them after, so griefing, front-running and outright theft — all
///  of which reduce, on-chain, to a write in somebody else's cell — surface as an
///  unallowed diff rather than as an absent test.
///
///  On top of that the walk enforces the IRREVERSIBILITY laws that make the lifecycle
///  safe to build an orderbook on: `filled` never rewinds, a cancellation sentinel is
///  never cleared, a cancelled nonce never comes back to life, the rollback floor
///  never retreats — and each settled fill conserves value to the wei.
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

        bytes4[] memory sel = new bytes4[](14);
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
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    // ═══════════════ 1. FILL STATE ═══════════════

    /// @notice Nothing ever moved `filled` — or the nonce a fill-once order records its
    ///         progress in — outside the fill that was entitled to move it, `filled`
    ///         never rewound, and no fill ever mis-priced itself.
    function invariant_fillState() public view {
        assertEq(bytes(handler.fillViolation()).length, 0, handler.fillViolation());
    }

    /// @notice The counter is bounded by the order's OWN denominator, always. The only
    ///         value above it is the cancellation sentinel, which is unambiguous
    ///         because a token amount can never reach 2^256-1.
    function invariant_fillNeverExceedsTheOrderTotal() public view {
        for (uint256 i; i < 6; ++i) {
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
        for (uint256 i; i < 6; ++i) {
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

    /// @notice The settler is a pass-through and custodies nothing between fills. A
    ///         non-zero balance here is either a stranded maker/filler payment or a
    ///         pool anyone could sweep — the residue class that shows up in every
    ///         settlement-layer audit.
    function invariant_settlementCustodiesNothing() public view {
        assertEq(tA.balanceOf(address(settlement)), 0, "tA stranded in the settler");
        assertEq(tB.balanceOf(address(settlement)), 0, "tB stranded in the settler");
        assertEq(tA.balanceOf(address(permit3)), 0, "tA stranded in Permit3");
        assertEq(tB.balanceOf(address(permit3)), 0, "tB stranded in Permit3");
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
        handler.doApproveOrder(1, 0); //       maker 0 approves its own order 1
        handler.doFillSigless(1, 4); //        filler 1 settles it with an empty sig
        handler.doSetOrderSigner(0, 1, 1); //  maker 0 nominates signers[1]
        handler.doSetOrderSignerWithSig(0, 1, 0, 0); // relayed, correctly signed
        handler.doCancelOrder(5, 2); //        maker 2 cancels its own order 5
        handler.doCancelNonces(1, 4, 5); //    maker 1 cancels two nonces

        assertGe(handler.fillsSettled(), 2, "no fill ever settled");
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
