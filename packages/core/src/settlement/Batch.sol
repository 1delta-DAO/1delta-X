// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order, Item, ItemOp, ItemPolicy, MatchPlan, MatchStep, LegIn, LegOut, FillCtx} from "./Structs.sol";
import {SafeTransferLib} from "../utils/SafeTransferLib.sol";
import {Permit3TransferLib} from "../utils/Permit3TransferLib.sol";
import {OrderHash} from "./OrderHash.sol";
import {Pricing} from "./Pricing.sol";
import {DutchAuction} from "./DutchAuction.sol";
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


    /// @dev The `_fillCore` gate set WITHOUT moving any funds: zero fill, deadline,
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
        if (block.timestamp > order.deadline) revert OrderExpired();
        bytes32 orderHash = order.hash();
        _verifySignature(orderHash, sig, order.maker);
        uint256 overrideBps = _exclusivity(order, solver);
        if (_isNonceCancelled(order.maker, order.nonce)) revert NonceCancelled();
        _runValidators(order, solver, takerData);
        ctx = _openFill(order, orderHash, fillAmount, overrideBps, solver, takerData);
    }


    /// @dev This fill's per-leg output amounts, WITHOUT transferring — computed at
    ///      open so `outstanding` (and hence the PRESEND bound) is known before any
    ///      delivery. The per-leg math — BUY fixed-output slices, SELL
    ///      auction-priced, soft exclusivity on maker legs only — is IDENTICAL to
    ///      the single-order `_deliverOutputs`; the amount is final (post-override),
    ///      so a DELIVER step just moves it.
    function _batchComputeOutputs(Order calldata order, FillCtx memory ctx) internal view returns (uint256[] memory outs) {
        uint256 n = order.legsOut.length;
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
        uint256 n = order.legsIn.length;
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
            maxLen += orders[i].legsIn.length + orders[i].legsOut.length;
            unchecked {
                ++i;
            }
        }
        address[] memory buf = new address[](maxLen);
        uint256 count;
        for (uint256 i; i < orders.length;) {
            LegIn[] calldata li = orders[i].legsIn;
            for (uint256 k; k < li.length;) {
                count = _appendToken(buf, count, li[k].token);
                unchecked {
                    ++k;
                }
            }
            LegOut[] calldata lo = orders[i].legsOut;
            for (uint256 k; k < lo.length;) {
                count = _appendToken(buf, count, lo[k].token);
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
        swept = _sweepSurplus(
            st.tokens, st.beforeBal, p.profitRecipient == address(0) ? msg.sender : p.profitRecipient
        );
        return (st.outs, st.tokens, swept);
    }

    /// @dev PHASE 1. Open every order — the full gate set (shape, deadline,
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
            _assertMatchShape(order); // items allowed here — that is the point
            st.fills[i] = _openGated(order, p.sigs[i], p.fillAmounts[i], solver, _tdc(p.takerDatas, i));
            st.outs[i] = _batchComputeOutputs(order, st.fills[i]);
            st.owed[i] = _computeOwed(order, st.fills[i]);
            st.credit[i] = new uint256[](order.legsIn.length);
            uint256 m = order.legsOut.length;
            // An order with no outputs (a pure gasless deposit) has nothing to
            // deliver, so its bit is pre-set and the schedule need not carry a
            // no-op DELIVER step for it.
            if (m == 0) st.done[i] = DELIVERED_BIT;
            for (uint256 j; j < m;) {
                st.outstanding[_tokenIndex(st.tokens, order.legsOut[j].token)] += st.outs[i][j];
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
    function _assertMatchShape(Order calldata order) internal pure {
        Item[] calldata items = order.items;
        if (items.length > 255) revert LengthMismatch();
        for (uint256 i; i < items.length;) {
            if (items[i].op == ItemOp.SETTLE) revert MatchSettleItemUnsupported();
            unchecked {
                ++i;
            }
        }
        LegIn[] calldata legsIn = order.legsIn;
        for (uint256 i; i < legsIn.length;) {
            for (uint256 j = i + 1; j < legsIn.length;) {
                if (legsIn[i].token == legsIn[j].token) revert MatchDuplicateInput();
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
                EXECUTOR.execute(p.callTargets[a], p.callDatas[a]);
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
    ///      A duplicate PULL needs no exactly-once guard: the extra lands in `credit`
    ///      and Phase 3 returns it to the MAKER, so it costs the solver gas and the
    ///      maker nothing.
    function _stepPull(Order[] calldata orders, MatchCtx memory st, uint256 i, uint256 j, uint256 s) internal {
        if (i >= orders.length) revert PlanBadStep(s);
        Order calldata order = orders[i];
        if (j >= order.legsIn.length) revert PlanBadStep(s);
        uint256 owed = st.owed[i][j]; // resolved at open — single source
        if (owed != 0) {
            Permit3TransferLib.transferFromWithFallback(
                PERMIT3, order.legsIn[j].token, order.maker, address(this), owed
            );
            unchecked {
                st.credit[i][j] += owed;
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
                LegOut calldata leg = order.legsOut[j]; // one resolve for both reads
                address token = leg.token;
                address to = leg.recipient;
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
    ///      to the order's input legs; a MAKE only consumes the maker's own funds,
    ///      so it needs no snapshot. Measuring per CALL rather than per ORDER is
    ///      what makes interleaving sound: the window is atomic with respect to the
    ///      schedule, so another order running in between cannot be misattributed.
    ///      The repeat guard is load-bearing — a second item is a second borrow
    ///      against the maker's credit.
    function _stepItem(Order[] calldata orders, MatchCtx memory st, uint256 i, uint256 k, uint256 s) internal {
        if (i >= orders.length) revert PlanBadStep(s);
        Order calldata order = orders[i];
        if (k >= order.items.length) revert PlanBadStep(s);
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

        if (order.items[k].op != ItemOp.TAKE) {
            _executeItem(order, st.fills[i], k);
            return;
        }
        uint256[] memory pre = _snapshotInputs(order.legsIn);
        _executeItem(order, st.fills[i], k);
        uint256 m = order.legsIn.length;
        for (uint256 j; j < m;) {
            // A module can only ADD to Settlement's balance (the pool grants no
            // approvals), so this cannot underflow on any honest path — and a
            // checked revert is the right outcome if one ever did.
            st.credit[i][j] += SafeTransferLib.balanceOf(order.legsIn[j].token, address(this)) - pre[j];
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
            uint256 full = ((uint256(1) << order.items.length) - 1) | DELIVERED_BIT;
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
    function _matchReconcileInputs(
        Order calldata order,
        uint256[] memory owedOf,
        uint256[] memory credit,
        uint256 idx
    ) internal {
        uint256 n = order.legsIn.length; // hoisted: a calldata STRUCT member's
        // `.length` costs an offset load plus a length load on every re-read
        for (uint256 j; j < n;) {
            uint256 owed = owedOf[j];
            uint256 have = credit[j];
            if (have < owed) revert LegUnfunded(idx, j);
            unchecked {
                uint256 surplus = have - owed; // have >= owed
                if (surplus != 0) SafeTransferLib.safeTransfer(order.legsIn[j].token, order.maker, surplus);
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
    function _tokenIndex(address[] memory tokens, address token) private pure returns (uint256) {
        uint256 n = tokens.length;
        for (uint256 k; k < n;) {
            if (tokens[k] == token) return k;
            unchecked {
                ++k;
            }
        }
        revert LengthMismatch();
    }

    /// @dev `takerDatas[i]`, or an empty blob when the plan carries none.
    function _tdc(bytes[] calldata takerDatas, uint256 i) private pure returns (bytes memory) {
        return takerDatas.length == 0 ? bytes("") : takerDatas[i];
    }
}
