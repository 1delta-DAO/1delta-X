// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order, ItemOp, ItemPolicy, MatchPlan, MatchStep, FillCtx} from "./Structs.sol";
import {PackedArrays} from "./PackedArrays.sol";
import {SafeTransferLib} from "../utils/SafeTransferLib.sol";
import {Permit3TransferLib} from "../utils/Permit3TransferLib.sol";
import {OrderHash} from "./OrderHash.sol";
import {Pricing} from "./Pricing.sol";
import {DutchAuction} from "./DutchAuction.sol";
import {OrderGates} from "./OrderGates.sol";
import {Core} from "./Core.sol";

/// @title Batch
/// @notice `matchSettle` — netted, deferred-check settlement. N orders clear
///         against the POOL (Settlement itself) rather than against a solver's
///         balance sheet, so a coincidence of wants needs no solver capital; the
///         single-order hot path in {Core} is untouched, so ordinary fills pay
///         nothing for any of this.
///
///         ONE engine covers both shapes that used to need their own entry point:
///           • plain item-free CoW (the former `batchSettle`) is the schedule
///             `[PULL…, PRESEND…, CALL, DELIVER…]`;
///           • an item-bearing match (the former `batchSettleItems`) interleaves
///             `ITEM` steps with deliveries — which is what its fixed per-order
///             body could not do, and why mutually-dependent orders previously
///             needed a flash loan or solver inventory.
///
///         Reuses `_openFill`, `_executeItem`, {Pricing}, and the `_sweepSurplus`
///         whole-check verbatim.
abstract contract Batch is Core {
    using OrderHash for Order;
    using Pricing for Order;
    using DutchAuction for Order;

    // ──────────────────── Shared netted primitives ────────────────────
    //
    // The pieces both the OPEN and FLUSH phases lean on: the touched-token
    // universe and its snapshot, the authorization sequence, the per-leg output
    // computation, and the wholeness backstop. Each is order-independent, which
    // is what lets the schedule in between be entirely solver-chosen.

    /// @dev Snapshot Settlement's balance of each token in a MEMORY list (the
    ///      context's token universe). Sibling of `_snapshotInputs`, which takes
    ///      calldata legs.
    function _snapshotBalances(address[] memory tokens) internal view returns (uint256[] memory bals) {
        uint256 n = tokens.length;
        bals = new uint256[](n);
        for (uint256 k; k < n;) {
            bals[k] = SafeTransferLib.balanceOf(tokens[k], address(this));
            unchecked {
                ++k;
            }
        }
    }

    /// @dev The wholeness backstop, run last: require the context left Settlement
    ///      no worse off on any touched token ({BatchNotWhole} else) and sweep any
    ///      residual — the filler's compensation, ~0 after a clean pre-send — to
    ///      `to`. Never touches `beforeBal`, so a pre-existing / donated balance is
    ///      unreachable. This check is END-STATE and therefore independent of the
    ///      schedule that produced it.
    ///
    ///      `to` is a DESTINATION ONLY, exactly as `fillUpTo`'s `recipient` is on the
    ///      single-order path: exclusivity, validators, item authority and every pull
    ///      still key on `msg.sender`, so naming another address grants no authority —
    ///      it routes money the filler received and could forward itself, saving a
    ///      contract filler a second transfer per token.
    /// @return swept `swept[k]` = the residual moved in `tokens[k]` — the filler's
    ///      realised P&L, returned so a caller need not diff its own balances.
    function _sweepSurplus(address[] memory tokens, uint256[] memory beforeBal, address to)
        internal
        returns (uint256[] memory swept)
    {
        uint256 n = tokens.length;
        swept = new uint256[](n);
        for (uint256 k; k < n;) {
            uint256 nowBal = SafeTransferLib.balanceOf(tokens[k], address(this));
            if (nowBal < beforeBal[k]) revert BatchNotWhole(tokens[k]);
            unchecked {
                uint256 surplus = nowBal - beforeBal[k]; // nowBal >= beforeBal[k]
                if (surplus != 0) {
                    swept[k] = surplus;
                    SafeTransferLib.safeTransfer(tokens[k], to, surplus);
                }
                ++k;
            }
        }
    }

    /// @dev The `_fillCore` gate set WITHOUT moving any funds: zero fill, expiry,
    ///      signature/approval, exclusivity, nonce, validators — then `_openFill`,
    ///      which writes `filled` before any external call in the context. Split out
    ///      so the authorization sequence exists once and is audited once,
    ///      independent of the shape assertions a caller layers on top. `takerData`
    ///      threads into the validators and (for a module order) `resolveFill`.
    function _openGated(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmount,
        address solver,
        bytes memory takerData
    ) internal returns (FillCtx memory ctx) {
        if (fillAmount == 0) revert ZeroFill();
        // Delta-verify delivery has no home on the netted path (see the error note):
        // it needs a per-order callback + a recipient snapshot, neither of which the
        // {matchSettle} PRESEND/DELIVER flow has. Reject rather than deliver nominally.
        if (order.deltaVerifyOutputs()) revert DeltaVerifyNotBatchable();
        if (block.timestamp > order.expiry()) revert OrderExpired();
        bytes32 orderHash = order.hash();
        _verifySignature(orderHash, sig, order.maker);
        _gateOrder(order, orderHash, solver, takerData, ctx);
        _openFill(order, fillAmount, solver, takerData, ctx);
    }

    /// @dev This fill's per-leg output amounts, WITHOUT transferring — computed at
    ///      open so `outstanding` (and hence the PRESEND bound) is known before any
    ///      delivery. The per-leg math — BUY fixed-output slices, SELL
    ///      auction-priced, soft exclusivity on maker legs only — is IDENTICAL to
    ///      the single-order `_deliverOutputs`; the amount is final (post-override),
    ///      so a DELIVER step just moves it.
    function _batchComputeOutputs(Order calldata order, FillCtx memory ctx)
        internal
        view
        returns (uint256[] memory outs)
    {
        uint256 n = PackedArrays.validateFixed(order.legsOut, PackedArrays.LEG_OUT_STRIDE);
        outs = new uint256[](n);
        for (uint256 j; j < n;) {
            outs[j] = order.outputAt(ctx, j); // same slice math as `_deliverOutputs`
            unchecked {
                ++j;
            }
        }
    }

    /// @dev This fill's per-INPUT-leg owed amounts — the mirror of
    ///      {_batchComputeOutputs}, resolved at open for the same reason and from
    ///      the same frozen {FillCtx}. The per-leg math (fixed cumulative slice,
    ///      auctioned tick, soft-exclusivity discount) is {Pricing.inputOwed}
    ///      unchanged; this only decides WHEN it runs.
    function _computeOwed(Order calldata order, FillCtx memory ctx) internal view returns (uint256[] memory owed) {
        uint256 n = PackedArrays.validateFixed(order.legsIn, PackedArrays.LEG_IN_STRIDE);
        owed = new uint256[](n);
        for (uint256 j; j < n;) {
            owed[j] = order.inputOwed(ctx, j);
            unchecked {
                ++j;
            }
        }
    }

    /// @dev The de-duplicated union of every order's `legsIn`/`legsOut` tokens.
    ///      Derived ON-CHAIN, never solver-declared, so the `BatchNotWhole` guard
    ///      and the PRESEND bound both cover every token the context can move.
    ///      O(legs²) — a match is small, and this never runs on the hot path.
    function _collectTokens(Order[] calldata orders) internal pure returns (address[] memory tokens) {
        uint256 maxLen;
        for (uint256 i; i < orders.length;) {
            maxLen += PackedArrays.countUnchecked(orders[i].legsIn) + PackedArrays.countUnchecked(orders[i].legsOut);
            unchecked {
                ++i;
            }
        }
        address[] memory buf = new address[](maxLen);
        uint256 count;
        for (uint256 i; i < orders.length;) {
            bytes calldata li = orders[i].legsIn;
            uint256 nIn = PackedArrays.validateFixed(li, PackedArrays.LEG_IN_STRIDE);
            for (uint256 k; k < nIn;) {
                count = _appendToken(buf, count, PackedArrays.legInToken(li, k));
                unchecked {
                    ++k;
                }
            }
            bytes calldata lo = orders[i].legsOut;
            uint256 nOut = PackedArrays.validateFixed(lo, PackedArrays.LEG_OUT_STRIDE);
            for (uint256 k; k < nOut;) {
                count = _appendToken(buf, count, PackedArrays.legOutToken(lo, k));
                unchecked {
                    ++k;
                }
            }
            unchecked {
                ++i;
            }
        }
        // Shrink `buf` in place rather than allocating a second array and copying
        // into it: the dedup already left the survivors contiguous at the front, so
        // the copy was pure overhead — one word write replaces `count` iterations
        // plus an allocation. Truncating a memory array's length is safe (the tail
        // stays allocated, just unreferenced) and `count <= maxLen` by construction.
        /// @solidity memory-safe-assembly
        assembly {
            mstore(buf, count)
        }
        tokens = buf;
    }

    /// @dev Append `t` to `buf[0..count)` if not already present; return the new
    ///      count. Linear scan — the token universe of one batch is tiny.
    function _appendToken(address[] memory buf, uint256 count, address t) private pure returns (uint256) {
        for (uint256 k; k < count;) {
            if (buf[k] == t) return count;
            unchecked {
                ++k;
            }
        }
        buf[count] = t;
        unchecked {
            return count + 1;
        }
    }

    // ──────────── Deferred match settle (schedule-driven, checks deferred) ────────────

    /// @dev The `matchSettle` working set — the WHOLE deferred context, and the
    ///      reason this feature needs neither storage nor transient storage. It is
    ///      one memory struct threaded by pointer through the phase helpers; it
    ///      never crosses a call boundary, so nothing outside this frame can read
    ///      or corrupt it. (EVC's checks-deferred context must live in transient
    ///      storage precisely because it DOES cross frames — arbitrary vaults call
    ///      back into it. Declaring the participants in calldata buys us the
    ///      cheaper home.) ~100 words for a 4-order match; the expansion cost is
    ///      noise next to one ERC20 transfer.
    struct MatchCtx {
        address[] tokens; //      touched-token universe (deduped, derived on-chain)
        uint256[] beforeBal; //   per-token pre-context balance snapshot
        uint256[] outstanding; // per-token output obligations NOT YET delivered
        FillCtx[] fills; //       per-order resolved fill context
        uint256[][] outs; //      per-order per-OUTPUT-leg amount (computed at open)
        uint256[][] owed; //      per-order per-INPUT-leg amount  (computed at open)
        uint256[][] credit; //    per-order per-input-leg credited value
        uint256[] done; //        per-order progress mask (item bits + DELIVERED_BIT)
        uint256 lastItem; //      `(order+1) << 16 | item` of the PREVIOUS step, 0 if
        //                        it was not an ITEM — all {ItemPolicy.ATOMIC} needs
        //                        to know, and the dispatcher is its only writer.
    }

    /// @dev `done[i]` bit marking "this order's outputs have been delivered". Item
    ///      `k` takes bit `k`, so an order is capped at 255 items (`_assertMatchShape`)
    ///      and the two ranges can never collide.
    uint256 private constant DELIVERED_BIT = 1 << 255;

    /// @notice Settle N orders as one netted match with DEFERRED CHECKS — the
    ///         inventory-free, callback-free, re-entrancy-free order-matching path.
    ///
    ///         The two entry points this replaces could only permute whole ORDERS
    ///         (`batchSettleItems`) or nothing at all (`batchSettle`'s fixed
    ///         phases): each order ran `deliver → items → settle inputs` as a fixed
    ///         body, so an order's borrow could never precede its own delivery and
    ///         a mutually-dependent pair (A's collateral funded by B's borrow *and*
    ///         B's collateral funded by A's borrow) had no valid ordering at all.
    ///         The escape was a flash loan or solver inventory.
    ///
    ///         Here the execution unit is a STEP. The solver supplies a flat
    ///         `schedule` (see {MatchStep}) and the settler runs it verbatim, then
    ///         performs every per-order check ONCE, at the end:
    ///
    ///           PHASE 1  OPEN      per order: gates → `_openFill` (writes `filled`)
    ///                              → compute outputs. Token universe + snapshot.
    ///           PHASE 2  SCHEDULE  the solver's steps, in order. The ONLY
    ///                              solver-controlled region.
    ///           PHASE 3  FLUSH     deferred: completeness → input reconciliation →
    ///                              invariants → pool whole-check → sweep.
    ///
    ///         Phases 1 and 3 are contract-owned loops over EVERY order, so a
    ///         schedule cannot skip a gate or a check — it can only choose the
    ///         order in which the middle happens.
    ///
    ///  Why there is no re-entrancy here to reason about
    ///  ────────────────────────────────────────────────
    ///  The composition a solver would otherwise express by re-entering `fill` from
    ///  a callback is expressed as a schedule instead. `nonReentrant` still spans
    ///  the whole call, unweakened — and it is now SUFFICIENT, because every
    ///  balance-delta window in this file (`PULL`, `ITEM`, `PRESEND`, the final
    ///  sweep) is measured inside this frame, where nothing else can run.
    ///
    ///  Deferring the checks (vs. running them per order)
    ///  ─────────────────────────────────────────────────
    ///  • INPUT FUNDING moves from "cover your legs at your own step" to a per-leg
    ///    CREDIT LEDGER reconciled in Phase 3. Credits are measured around the
    ///    single call that produces them, so attribution stays exact however the
    ///    solver interleaves orders — a strictly TIGHTER window than the
    ///    per-order one it replaces.
    ///  • INVARIANTS move to Phase 3, so they assert the end of the CONTEXT rather
    ///    than the end of an order. An invariant broken by one order and restored
    ///    by another now passes — the EVC account-status-check analogue, and what
    ///    makes a same-maker migration batchable. (Note this is a semantic change:
    ///    a maker appearing in two orders is judged on its final state.)
    ///  • `validators` deliberately do NOT move. They are pre-gates; deferring one
    ///    would run a fill whose precondition was never true.
    ///
    /// @dev  Safety is unchanged and order-independent, so any schedule yields a
    ///       correct settlement or a revert — never a wrong-but-successful one:
    ///       every delivery is a transfer that fully succeeds or reverts AND is
    ///       asserted to have happened ({PlanIncomplete}); every maker is charged
    ///       its own signed slice ({Pricing}, untouched); items run under the
    ///       maker's signature with `filled` written first; the pool must end at or
    ///       above its pre-context balance ({BatchNotWhole}); and the solver can
    ///       only ever receive `balanceOf − before` (pre-send and sweep alike), so
    ///       a donated balance is unreachable. The load-bearing NEW guard is
    ///       exactly-once execution ({PlanBadStep}) — a second delivery would drain
    ///       the pool and a second item would borrow twice against the maker, and
    ///       neither is catchable by a completeness compare after the fact.
    /// @return outs   `outs[i][j]` = order `i`'s delivered amount on output leg `j`.
    /// @return tokens the on-chain-derived touched-token universe.
    /// @return swept  `swept[k]` = the residual paid out in `tokens[k]` — the
    ///         filler's realised P&L. Returned (rather than left to a `balanceOf`
    ///         diff) so a settlement accounts for BOTH sides on its own, mirroring
    ///         `fillUpTo`'s `(delta, received, paid)`.
    function matchSettle(MatchPlan calldata p)
        external
        nonReentrant
        returns (uint256[][] memory outs, address[] memory tokens, uint256[] memory swept)
    {
        uint256 n = p.orders.length;
        if (p.sigs.length != n || p.fillAmounts.length != n || n > 256) revert LengthMismatch();
        // `takerDatas` is all-or-nothing: empty (no blob) or aligned 1:1.
        if (p.takerDatas.length != 0 && p.takerDatas.length != n) revert LengthMismatch();
        if (p.callTargets.length != p.callDatas.length) revert LengthMismatch();

        MatchCtx memory st;
        // The universe is derived on-chain, never solver-declared — the whole-check
        // and the pre-send bound both hinge on it covering every token that moves.
        st.tokens = _collectTokens(p.orders);
        st.beforeBal = _snapshotBalances(st.tokens);

        _matchOpenAll(p, st); //     PHASE 1 — contract-owned
        _matchRunSchedule(p, st); // PHASE 2 — solver-ordered
        _matchFlush(p, st); //       PHASE 3 — contract-owned

        // Destination only (see {_sweepSurplus}); `PRESEND` deliberately still pays
        // `msg.sender`, because that is working capital a `CALL` step must spend.
        swept = _sweepSurplus(st.tokens, st.beforeBal, p.profitRecipient == address(0) ? msg.sender : p.profitRecipient);
        return (st.outs, st.tokens, swept);
    }

    /// @dev PHASE 1. Open every order — the full gate set (shape, expiry,
    ///      signature, exclusivity, nonce, validators) then `_openFill`, which
    ///      writes `filled` BEFORE any external call in the context.
    ///
    ///      It also RESOLVES BOTH SIDES' AMOUNTS here, once: `outs[i][j]` per output
    ///      leg (which seeds `outstanding`, so a mid-schedule `PRESEND` knows what
    ///      the pool still owes) and `owed[i][j]` per input leg. Both are pure
    ///      functions of the {FillCtx} frozen a line above, so computing them at open
    ///      is result-identical to computing them at use — and it gives each side a
    ///      SINGLE source. An auditor never has to ask whether two copies of the
    ///      pricing agree, because there is only ever one.
    function _matchOpenAll(MatchPlan calldata p, MatchCtx memory st) internal {
        uint256 n = p.orders.length;
        st.fills = new FillCtx[](n);
        st.outs = new uint256[][](n);
        st.owed = new uint256[][](n);
        st.credit = new uint256[][](n);
        st.done = new uint256[](n);
        st.outstanding = new uint256[](st.tokens.length);
        address solver = msg.sender;
        for (uint256 i; i < n;) {
            Order calldata order = p.orders[i];
            // The shape assertion already proves `legsIn`, so its count is reused for
            // the credit ledger rather than re-validating the same blob.
            uint256 nIn = _assertMatchShape(order); // items allowed here — that is the point
            st.fills[i] = _openGated(order, p.sigs[i], p.fillAmounts[i], solver, _tdc(p.takerDatas, i));
            st.outs[i] = _batchComputeOutputs(order, st.fills[i]);
            st.owed[i] = _computeOwed(order, st.fills[i]);
            st.credit[i] = new uint256[](nIn);
            uint256 m = PackedArrays.validateFixed(order.legsOut, PackedArrays.LEG_OUT_STRIDE);
            // An order with no outputs (a pure gasless deposit) has nothing to
            // deliver, so its bit is pre-set and the schedule need not carry a
            // no-op DELIVER step for it.
            if (m == 0) st.done[i] = DELIVERED_BIT;
            for (uint256 j; j < m;) {
                st.outstanding[_tokenIndex(st.tokens, PackedArrays.legOutToken(order.legsOut, j))] += st.outs[i][j];
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev The three shape constraints the netted match relies on:
    ///        • no SETTLE item — it routes the maker's asset to the filler, not the
    ///          pool ({MatchSettleItemUnsupported});
    ///        • no repeated input token — item proceeds are attributed per token
    ///          within a step window, so a duplicate leg would double-count the
    ///          same arrival ({MatchDuplicateInput});
    ///        • at most 255 items, so item bit `k` can never collide with
    ///          {DELIVERED_BIT} and the Phase-3 completeness mask stays exact.
    ///      Runs once per order at open. O(items + legsIn²), tiny — and this is the
    ///      deliberate CoW path, never the single-order hot path (where the same
    ///      shapes are handled correctly and the guard would only cost gas).
    /// @return nIn the validated `legsIn` count, handed back so the caller can size
    ///         the credit ledger from it instead of validating the same blob twice.
    function _assertMatchShape(Order calldata order) internal pure returns (uint256 nIn) {
        bytes calldata items = order.items;
        // The packed count is a `uint8`, so the 255 ceiling is structural now rather
        // than checked — but the walk still proves the blob is well formed.
        uint256 nItems = PackedArrays.validateRecords(items, PackedArrays.ITEM_HEAD);
        uint256 cursor = PackedArrays.recordsStart();
        for (uint256 i; i < nItems;) {
            (uint256 op,,,,, uint256 next) = PackedArrays.itemAt(items, cursor);
            // `>=`, NOT `==`, and the difference is load-bearing. `op` is a RAW
            // BYTE out of the signed blob ({PackedArrays.itemAt} deliberately does
            // not narrow it), so the guard has to name a RANGE rather than one
            // value. It rejects three things at once:
            //   • SETTLE (2) — routes to the filler, not the pool;
            //   • TAKE_FOR (3) — its funding leg is usually one of the order's own
            //     `legsOut`, i.e. value the maker has to have RECEIVED before the
            //     item runs. This path lets the solver schedule items and
            //     deliveries independently, so that precondition is a scheduling
            //     obligation the netted engine does not currently enforce. Fill
            //     composite orders through the single-order path, which runs
            //     deliveries before items by construction;
            //   • anything above — a malformed record, which {Base._runItem}
            //     rejects too, so the guard and the dispatcher agree.
            if (op >= uint256(ItemOp.SETTLE)) revert MatchSettleItemUnsupported();
            cursor = next;
            unchecked {
                ++i;
            }
        }
        bytes calldata legsIn = order.legsIn;
        nIn = PackedArrays.validateFixed(legsIn, PackedArrays.LEG_IN_STRIDE);
        for (uint256 i; i < nIn;) {
            for (uint256 j = i + 1; j < nIn;) {
                if (PackedArrays.legInToken(legsIn, i) == PackedArrays.legInToken(legsIn, j)) {
                    revert MatchDuplicateInput();
                }
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev PHASE 2. Run the solver's steps verbatim. Every index is bounds-checked
    ///      and every repeatable unit is guarded at execution time, so a malformed
    ///      or hostile schedule reverts ({PlanBadStep}) — it can never mis-settle.
    function _matchRunSchedule(MatchPlan calldata p, MatchCtx memory st) internal {
        uint256 len = p.schedule.length;
        for (uint256 s; s < len;) {
            uint256 w = p.schedule[s];
            uint256 kind = w & 0xff;
            uint256 a = (w >> 8) & 0xffff;
            uint256 b = (w >> 24) & 0xffff;
            if (kind == MatchStep.ITEM) {
                _stepItem(p.orders, st, a, b, s);
                // Recorded AFTER the step so a revert cannot leave it stale; cleared
                // by every other kind, which is what makes "back-to-back" checkable
                // with one word instead of a scan.
                st.lastItem = ((a + 1) << 16) | b;
                unchecked {
                    ++s;
                }
                continue;
            }
            st.lastItem = 0;
            if (kind == MatchStep.PULL) {
                _stepPull(p.orders, st, a, b, s);
            } else if (kind == MatchStep.DELIVER) {
                _stepDeliver(p.orders, st, a, s);
            } else if (kind == MatchStep.PRESEND) {
                _stepPresend(st, a, s);
            } else if (kind == MatchStep.CALL) {
                // Allowance-less EXECUTOR — the solver's own contract, acting with
                // its own authority; it can never move the pool, and `nonReentrant`
                // blocks it from calling back into any fill.
                if (a >= p.callTargets.length) revert PlanBadStep(s);
                // Through {Core._execute} rather than a typed `EXECUTOR.execute(...)`:
                // identical call, but the typed form made solc emit a second general
                // `(address,bytes)` encoder — see the note there.
                _execute(p.callTargets[a], p.callDatas[a]);
            } else {
                revert PlanBadStep(s);
            }
            unchecked {
                ++s;
            }
        }
    }

    /// @dev PULL — maker → pool for one input leg, at the amount resolved at open.
    ///
    ///      The credit is the NOMINAL `owed`, not a measured balance delta. This is
    ///      the single-order path's own convention: `_payInputsToSolver` moves
    ///      nominal amounts, and `_settleForward` skips its balance snapshot entirely
    ///      for an item-free order precisely because measuring what cannot have been
    ///      produced "would just burn two STATICCALLs per input leg on every plain
    ///      swap". A pull produces nothing — it moves a known amount — so there is
    ///      nothing to measure, and doing so costs two STATICCALLs per leg for a
    ///      number already known. Measurement is reserved for {_stepItem}, where a
    ///      module genuinely produces an amount the settler cannot predict.
    ///
    ///      Consequence for non-standard tokens: a fee-on-transfer input credits more
    ///      than arrives, the pool ends short, and the context reverts
    ///      {BatchNotWhole} rather than {LegUnfunded}. Both revert, and such tokens
    ///      are already out of scope on the netted path (see the settlement README).
    ///
    ///      A duplicate PULL needs no exactly-once guard, but it does need this
    ///      function to pull the SHORTFALL rather than the nominal `owed`.
    ///
    ///      ⚠ IT USED TO PULL `owed` UNCONDITIONALLY, on the reasoning that a
    ///      duplicate "costs the solver gas and the maker nothing" because Phase 3
    ///      refunds the extra. The TOKENS are indeed refunded — but the Permit3
    ///      ALLOWANCE spent to move them is not. Against a finite, amount-gated
    ///      allowance (the model {IPermit3} is built around) a padded schedule
    ///      therefore consumed 2× the allowance for 1× the fill and left the maker
    ///      unable to fund their next one, and `matchSettle` is permissionless, so
    ///      any solver could do it. Makers on an infinite (`uint160.max`) allowance
    ///      were never affected — that value is a sentinel Permit3 never decrements.
    ///
    ///      Netting against `credit` fixes it without adding a guard, which keeps the
    ///      tolerant shape the schedule wants: a second PULL of the same leg now
    ///      needs nothing, moves nothing, and spends no allowance. It also makes
    ///      ITEM-then-PULL exact instead of over-pull-then-refund — the item's
    ///      proceeds already credited the leg, so only the remainder is drawn from
    ///      the maker. `credit` may EXCEED `owed` (an item can over-produce), so the
    ///      subtraction is guarded rather than `unchecked`.
    function _stepPull(Order[] calldata orders, MatchCtx memory st, uint256 i, uint256 j, uint256 s) internal {
        if (i >= orders.length) revert PlanBadStep(s);
        Order calldata order = orders[i];
        // `st.credit[i]` was sized from the validated leg count at open, so its
        // length IS that count — no need to re-validate the same blob per step.
        if (j >= st.credit[i].length) revert PlanBadStep(s);
        uint256 owed = st.owed[i][j]; // resolved at open — single source
        uint256 have = st.credit[i][j]; // already covered by an earlier PULL or ITEM
        // Draw only what is still missing. See the allowance note above for why this
        // is not merely an optimisation.
        uint256 need = owed > have ? owed - have : 0;
        if (need != 0) {
            Permit3TransferLib.transferFromWithFallback(
                PERMIT3, PackedArrays.legInToken(order.legsIn, j), order.maker, address(this), need
            );
            unchecked {
                st.credit[i][j] = have + need;
            }
        }
    }

    /// @dev DELIVER — pool → recipients for every output leg, and discharge that
    ///      much of the pool's `outstanding` obligation. The repeat guard is
    ///      load-bearing: a second delivery pays the maker twice out of funds the
    ///      other orders are owed.
    function _stepDeliver(Order[] calldata orders, MatchCtx memory st, uint256 i, uint256 s) internal {
        if (i >= orders.length) revert PlanBadStep(s);
        if (st.done[i] & DELIVERED_BIT != 0) revert PlanBadStep(s);
        st.done[i] |= DELIVERED_BIT;
        Order calldata order = orders[i];
        uint256[] memory amts = st.outs[i];
        uint256 n = amts.length;
        for (uint256 j; j < n;) {
            uint256 amt = amts[j];
            if (amt != 0) {
                (address token,,, address to) = PackedArrays.legOut(order.legsOut, j); // one decode
                // A LEG ADDRESSED AT SETTLEMENT IS NOT DELIVERABLE HERE, AND SILENTLY
                // PAYING IT TO THE SOLVER IS WORSE THAN REFUSING IT. On the
                // single-order path such a leg is a maker SELF-BURN: the filler pays
                // it into Settlement, which has no sweep, so it is stranded forever —
                // that is what the docs promise and what {Core._deliverOutputs} does.
                // The netted path cannot honour the same promise. The transfer would
                // be a SELF-transfer (pool → pool), leaving the balance untouched
                // while `outstanding` records the obligation as discharged — so the
                // amount lands above the pre-context floor and {_sweepSurplus} hands
                // it to the SOLVER. Same signed order, opposite outcome, and it gives
                // a solver positive-EV reason to hunt mis-authored orders and bundle
                // them with anything touching the same token.
                //
                // This is the exact hazard {_creditItemProceeds} already closes for
                // stray TAKE proceeds, and it is BROADER: an item's proceeds token may
                // be absent from the universe, but a `legsOut` token is always in it.
                // Refused rather than refunded because, unlike item proceeds, there is
                // no honest destination to refund to — the maker deliberately signed
                // the amount away. {SettlementLens.validateOrder} already reports the
                // shape as malformed for every order; on this path it is exploitable,
                // so the settler agrees with the lens instead of taking the money.
                if (to == address(this)) revert OutputToSettlement();
                bool makerLeg = to == address(0) || to == order.maker;
                SafeTransferLib.safeTransfer(token, makerLeg ? order.maker : to, amt);
                unchecked {
                    st.outstanding[_tokenIndex(st.tokens, token)] -= amt; // seeded at open
                }
            }
            unchecked {
                ++j;
            }
        }
    }

    /// @dev ITEM — execute ONE of an order's items. A TAKE produces value into the
    ///      pool, so its proceeds are measured around that single call and credited
    ///      to the order's input legs (anything landing OUTSIDE them goes back to the
    ///      maker — see {_creditItemProceeds}); a MAKE only consumes the maker's own
    ///      funds, so it needs no snapshot. Measuring per CALL rather than per ORDER is
    ///      what makes interleaving sound: the window is atomic with respect to the
    ///      schedule, so another order running in between cannot be misattributed.
    ///      The repeat guard is load-bearing — a second item is a second borrow
    ///      against the maker's credit.
    function _stepItem(Order[] calldata orders, MatchCtx memory st, uint256 i, uint256 k, uint256 s) internal {
        if (i >= orders.length) revert PlanBadStep(s);
        Order calldata order = orders[i];
        if (k >= PackedArrays.validateRecords(order.items, PackedArrays.ITEM_HEAD)) revert PlanBadStep(s);
        uint256 bit = uint256(1) << k; // k < 255 by `_assertMatchShape`
        if (st.done[i] & bit != 0) revert PlanBadStep(s);

        // The maker's item-execution policy (see {ItemPolicy}). ANY — the default,
        // and what every pre-existing order carries — costs one shifted mask and no
        // branch beyond this test.
        uint256 policy = order.itemPolicy();
        if (policy != ItemPolicy.ANY) {
            unchecked {
                uint256 lower = bit - 1; // every item below k
                // ORDERED: all of them must already have run.
                if (st.done[i] & lower != lower) revert ItemPolicyViolated(i, k);
                // ATOMIC: and k-1 must have been the step IMMEDIATELY before this one.
                if (policy == ItemPolicy.ATOMIC && k != 0 && st.lastItem != (((i + 1) << 16) | (k - 1))) {
                    revert ItemPolicyViolated(i, k);
                }
            }
        }
        st.done[i] |= bit;

        uint256 itemCursor = _itemCursor(order.items, k);
        (uint256 kOp,,,,,) = PackedArrays.itemAt(order.items, itemCursor);
        // ⚠ COUPLED TO `_assertMatchShape`. Only a TAKE produces proceeds this path
        // has to attribute, and `TAKE_FOR` — the other proceeds-producing op — is
        // refused up front, so it can never arrive here. If that refusal is ever
        // lifted, this test must widen with it or a composite item's proceeds go
        // uncredited and end up swept to the filler.
        if (kOp != uint256(ItemOp.TAKE)) {
            _executeItemAt(order, st.fills[i], order.items, itemCursor);
            return;
        }
        // Measured over the WHOLE token universe, not just this order's `legsIn` —
        // see {_creditItemProceeds} for why that difference is load-bearing.
        uint256[] memory pre = _snapshotBalances(st.tokens);
        _executeItemAt(order, st.fills[i], order.items, itemCursor);
        _creditItemProceeds(order, st, i, pre);
    }

    /// @dev Attribute everything a TAKE just produced, measured against `pre` (the
    ///      universe snapshot taken immediately before the item call).
    ///
    ///      A proceeds token that matches one of the order's `legsIn` credits that
    ///      leg, exactly as before. Anything ELSE goes straight back to the MAKER.
    ///
    ///      ⚠ The refund is the security-relevant half. `Base._executeItems` states
    ///      the maker constraint — a TAKE's proceeds token MUST appear in `legsIn` —
    ///      and argues that a violating order merely STRANDS the proceeds, because
    ///      "the batch paths additionally floor every touched token at its pre-batch
    ///      balance". That floor is the PRE-BATCH balance: proceeds arriving DURING
    ///      the context sit above it, so if the token appears in any OTHER order's
    ///      legs (hence in `st.tokens`, hence in the final sweep) {_sweepSurplus}
    ///      hands the maker's money to the filler. Same mis-authored order, but the
    ///      single-order path loses it to nobody while the netted path loses it to
    ///      the solver — which also gives a solver a reason to go looking for such
    ///      orders and bundle them with anything touching the same token.
    ///
    ///      Refunding is strictly better than stranding and costs nothing on a
    ///      well-formed order (the branch is only reached when a non-leg token
    ///      actually gained). It is the same rule {_matchReconcileInputs} already
    ///      applies to an over-credited leg: any excess goes to the maker, never to
    ///      the solver. The netted path can do this where `fill` cannot only because
    ///      it has the token universe in hand.
    ///
    ///      COST: this widens the measurement from `2·|legsIn|` to `2·|tokens|`
    ///      balance reads per TAKE step. Deliberate — `matchSettle` is the CoW path,
    ///      never the single-order hot path, and it already accepts O(legs²) scans
    ///      here; a correctness hole that pays out to the counterparty is not worth
    ///      a few staticcalls.
    function _creditItemProceeds(Order calldata order, MatchCtx memory st, uint256 i, uint256[] memory pre) private {
        uint256 n = st.tokens.length;
        bytes calldata legsIn = order.legsIn;
        // The leg count comes from `st.credit[i]`, which `_matchOpenAll` sized from
        // the ONE validation of this blob — per the {PackedArrays} safety contract,
        // validate once and keep the count. Re-deriving it here would re-validate the
        // same blob once per token in the universe.
        uint256 nIn = st.credit[i].length; // the validated leg count, kept from open
        for (uint256 t; t < n;) {
            address token = st.tokens[t];
            // A module can only ADD to Settlement's balance (the pool grants no
            // approvals), so this cannot underflow on any honest path — and a
            // checked revert is the right outcome if one ever did.
            uint256 gain = SafeTransferLib.balanceOf(token, address(this)) - pre[t];
            if (gain != 0) {
                (bool isLeg, uint256 j) = _legInIndexOf(legsIn, nIn, token);
                if (isLeg) {
                    st.credit[i][j] += gain;
                } else {
                    SafeTransferLib.safeTransfer(token, order.maker, gain);
                }
            }
            unchecked {
                ++t;
            }
        }
    }

    /// @dev Index of `token` among the order's input legs, if present. `n` is the
    ///      count the CALLER already proved with {PackedArrays.validateFixed} — see
    ///      that library's safety contract: validate once per blob, then index.
    ///      `_assertMatchShape` has already proved `legsIn` holds no duplicate token,
    ///      so the first match is the only match.
    function _legInIndexOf(bytes calldata legsIn, uint256 n, address token)
        private
        pure
        returns (bool found, uint256 index)
    {
        for (uint256 j; j < n;) {
            if (PackedArrays.legInToken(legsIn, j) == token) return (true, j);
            unchecked {
                ++j;
            }
        }
    }

    /// @dev PRESEND — hand the solver token `t`'s UNENCUMBERED surplus so it can
    ///      convert it into the batch's deficit, the zero-capital unlock for an
    ///      imbalanced match. Bounded twice over: the pooled amount is measured
    ///      from the pre-context snapshot (a donated balance is unreachable), and
    ///      obligations not yet delivered are netted out first — so unlike a
    ///      fixed-phase pre-send (which nets against ALL obligations before any
    ///      delivery has happened), this is correct at ANY point in the schedule.
    function _stepPresend(MatchCtx memory st, uint256 t, uint256 s) internal {
        if (t >= st.tokens.length) revert PlanBadStep(s);
        address token = st.tokens[t];
        uint256 bal = SafeTransferLib.balanceOf(token, address(this));
        // A schedule that already spent past the baseline fails HERE with the
        // wholeness error rather than as an arithmetic panic.
        if (bal < st.beforeBal[t]) revert BatchNotWhole(token);
        unchecked {
            uint256 avail = bal - st.beforeBal[t];
            uint256 owed = st.outstanding[t];
            if (avail > owed) SafeTransferLib.safeTransfer(token, msg.sender, avail - owed);
        }
    }

    /// @dev PHASE 3 — the deferred flush. Contract-owned, over EVERY order, so
    ///      nothing the schedule did (or failed to do) can escape it.
    function _matchFlush(MatchPlan calldata p, MatchCtx memory st) internal {
        uint256 n = p.orders.length;
        address solver = msg.sender;
        for (uint256 i; i < n;) {
            Order calldata order = p.orders[i];
            // Completeness: outputs delivered, and every item ran. Deliveries and
            // items are scheduled, so this cannot be structural — it is asserted.
            uint256 full = ((uint256(1) << PackedArrays.countUnchecked(order.items)) - 1) | DELIVERED_BIT;
            if (st.done[i] != full) revert PlanIncomplete(i);
            _matchReconcileInputs(order, st.owed[i], st.credit[i], i);
            // The deferred check itself: the order's post-conditions, judged on the
            // end state of the whole context.
            _runInvariants(order, solver, _tdc(p.takerDatas, i));
            emit OrderFilled(st.fills[i].orderHash, order.maker, solver);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev ONE reconciliation rule for every input leg, pulled and item-funded
    ///      alike: the leg must have been credited at least what the maker owes.
    ///      `owed` STAYS in the pool (it is what funds the other orders'
    ///      deliveries) and any excess — an over-borrow, a duplicate pull — goes
    ///      back to the maker, never to the solver.
    ///
    ///      Takes the `owed` resolved at open rather than recomputing {Pricing}: the
    ///      amount charged and the amount checked are then the SAME WORD, not two
    ///      computations an auditor has to prove equal.
    function _matchReconcileInputs(Order calldata order, uint256[] memory owedOf, uint256[] memory credit, uint256 idx)
        internal
    {
        uint256 n = credit.length; // sized from the validated leg count at open
        for (uint256 j; j < n;) {
            uint256 owed = owedOf[j];
            uint256 have = credit[j];
            if (have < owed) revert LegUnfunded(idx, j);
            unchecked {
                uint256 surplus = have - owed; // have >= owed
                if (surplus != 0) {
                    SafeTransferLib.safeTransfer(PackedArrays.legInToken(order.legsIn, j), order.maker, surplus);
                }
            }
            unchecked {
                ++j;
            }
        }
    }

    /// @dev Index of `token` in the derived universe. Every leg token is present by
    ///      construction (`_collectTokens` is the union of exactly these legs), so
    ///      the fall-through is unreachable — it reverts rather than returning a
    ///      sentinel, so a future caller that widens the universe fails loudly
    ///      instead of silently attributing to slot 0. A linear scan over a handful
    ///      of entries beats any on-chain map.
    /// @dev The fall-through carries its OWN error. It used to reuse
    ///      {LengthMismatch}, which made a broken internal invariant look like a
    ///      malformed call — the one thing the rest of this file is careful to keep
    ///      apart ({LegUnfunded}, {ItemPolicyViolated} both name the exact
    ///      obligation). Nothing can raise this today; if it ever does, it is a bug
    ///      here and should say so.
    function _tokenIndex(address[] memory tokens, address token) private pure returns (uint256) {
        uint256 n = tokens.length;
        for (uint256 k; k < n;) {
            if (tokens[k] == token) return k;
            unchecked {
                ++k;
            }
        }
        revert TokenNotInUniverse(token);
    }

    /// @dev `takerDatas[i]`, or an empty blob when the plan carries none.
    function _tdc(bytes[] calldata takerDatas, uint256 i) private pure returns (bytes memory) {
        return takerDatas.length == 0 ? bytes("") : takerDatas[i];
    }
}
