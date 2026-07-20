// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order, Item, ItemOp, ItemsBatch, LegIn, LegOut, FillCtx} from "./Structs.sol";
import {SafeTransferLib} from "../utils/SafeTransferLib.sol";
import {Permit3TransferLib} from "../utils/Permit3TransferLib.sol";
import {OrderHash} from "./OrderHash.sol";
import {Pricing} from "./Pricing.sol";
import {Core} from "./Core.sol";

/// @title Batch
/// @notice The netted-batch settlement modes — coincidence of wants. `batchSettle`
///         (item-free CoW: pull inputs → pre-send surplus → interaction → deliver →
///         whole-check) and `batchSettleItems` (the item-aware generalization: a
///         spot order's pooled liquidity funds a leverage order's items). The pool
///         (Settlement itself) is the counterparty, not the solver. Reuses the
///         base primitives (`_openFill`, `_executeItems`) and {Pricing}
///         verbatim; the single-order hot path in {Core} is untouched.
abstract contract Batch is Core {
    using OrderHash for Order;
    using Pricing for Order;


    // ──────────────────── Batch settle (coincidence of wants) ────────────────────

    /// @notice Settle N orders as ONE netted batch — the coincidence-of-wants
    ///         (CoW) path. Every order's inputs are pooled into Settlement FIRST,
    ///         each maker's net SURPLUS is handed to the solver, a single solver
    ///         interaction converts that surplus into the net deficit, then every
    ///         output is delivered from the pool. Two mirror orders (`sell
    ///         WETH→USDC` and `sell USDC→WETH`) clear against each other with NO AMM
    ///         touched and, thanks to the surplus pre-send, ZERO solver capital even
    ///         when the batch is IMBALANCED (the solver swaps the surplus it is
    ///         handed into the deficit it must return — never fronting inventory).
    ///
    ///         This is a DEDICATED method: the single-order hot path is untouched,
    ///         so ordinary fills pay nothing for it. Unlike {batchFill} (which runs
    ///         each order independently and forces the solver to front the transient
    ///         peak), the pooled flow needs no solver inventory.
    ///
    ///         Flow (see `docs/batch-settle.md`):
    ///           1. per order: verify + open (`filled` written here) + pull inputs
    ///              → Settlement; then compute (not yet deliver) every output amount;
    ///           2. per token: PRE-SEND the batch's net surplus (pooled − owed, when
    ///              positive) to the solver — bounded to THIS batch's inputs, never a
    ///              donated balance;
    ///           3. one `interactionTarget` call via the allowance-less EXECUTOR —
    ///              the solver deposits the net-deficit token into Settlement (funded
    ///              by swapping the surplus it was just handed);
    ///           4. per order: deliver outputs (Settlement → maker/recipient) +
    ///              run invariants;
    ///           5. per touched token: require the balance did not drop below its
    ///              pre-batch snapshot (`BatchNotWhole` else) and sweep any residual.
    ///
    /// @dev    Item-free orders only ({BatchSettleNoItems}). Each maker is charged
    ///         and paid its OWN signed auction curve — identical to a single fill;
    ///         only the counterparty (the pool, not one solver) differs. This
    ///         overload passes an empty `takerData` to validators/invariants/fill
    ///         module; use the {batchSettle} `takerDatas` overload to thread a
    ///         per-order blob. `nonReentrant` spans the whole batch, so neither the
    ///         pre-send nor the interaction can re-enter, and every `filled` write
    ///         precedes both.
    /// @param  interactionTarget Optional (`address(0)` to skip) solver contract
    ///         called once between pre-send and deliver; returns the residual.
    /// @return outs `outs[i][j]` = order `i`'s delivered amount on output leg `j`.
    function batchSettle(
        Order[] calldata orders,
        bytes[] calldata sigs,
        uint256[] calldata fillAmounts,
        address interactionTarget,
        bytes calldata interactionData
    ) external nonReentrant returns (uint256[][] memory outs) {
        if (sigs.length != orders.length || fillAmounts.length != orders.length) revert LengthMismatch();
        return _batchSettle(orders, sigs, fillAmounts, new bytes[](0), interactionTarget, interactionData);
    }


    /// @notice {batchSettle} carrying a per-order filler-supplied `takerData` blob,
    ///         aligned 1:1 with `orders` — `takerDatas[i]` threads into order `i`'s
    ///         validators, invariants, and (for a fill-module order) `resolveFill`.
    ///         Same adversarial/validator-verified rule as {fill}'s takerData
    ///         overload: the blob is unsigned, so a validator must independently
    ///         verify anything it reads from it.
    /// @dev    Reverts {LengthMismatch} unless every array is `orders.length` long.
    function batchSettle(
        Order[] calldata orders,
        bytes[] calldata sigs,
        uint256[] calldata fillAmounts,
        bytes[] calldata takerDatas,
        address interactionTarget,
        bytes calldata interactionData
    ) external nonReentrant returns (uint256[][] memory outs) {
        uint256 n = orders.length;
        if (sigs.length != n || fillAmounts.length != n || takerDatas.length != n) revert LengthMismatch();
        return _batchSettle(orders, sigs, fillAmounts, takerDatas, interactionTarget, interactionData);
    }


    /// @dev Batch working set, bundled so `_batchSettle` holds ONE memory pointer
    ///      across the phases instead of four named locals (keeps the netted flow
    ///      under the EVM stack limit without via-IR).
    struct BatchState {
        address[] tokens; //     the touched-token universe (deduped)
        uint256[] beforeBal; //  per-token pre-batch balance snapshot
        FillCtx[] ctxs; //       per-order fill context (filled bookkeeping)
        uint256[][] outs; //     per-order per-leg output amounts (compute → deliver)
    }


    /// @dev Shared netted-settle implementation. `takerDatas` is either empty (the
    ///      no-blob overload) or `orders.length` long; `_td` picks per index. Runs
    ///      under the caller's `nonReentrant` lock (both public entry points hold
    ///      it). Phases are separate frames — the netted flow holds far more live
    ///      memory than the single-order path and is not stack-golfed for via-IR.
    function _batchSettle(
        Order[] calldata orders,
        bytes[] calldata sigs,
        uint256[] calldata fillAmounts,
        bytes[] memory takerDatas,
        address interactionTarget,
        bytes calldata interactionData
    ) internal returns (uint256[][] memory) {
        BatchState memory st;
        // Derive the touched-token universe on-chain (never trust the solver — the
        // pre-send bound and the whole-ness check both hinge on it) and snapshot.
        st.tokens = _collectTokens(orders);
        st.beforeBal = _snapshotBalances(st.tokens);

        // Phase 1: open every order (writes `filled`) + pool its inputs; then
        // compute — but do NOT yet deliver — every output amount, so the net
        // surplus per token is known before the interaction.
        st.ctxs = _batchOpenAll(orders, sigs, fillAmounts, takerDatas);
        st.outs = _batchComputeAllOutputs(orders, st.ctxs);

        // Phase 2: pre-send each token's net surplus to the solver (bounded to this
        // batch's own pooled inputs — donated balances stay put).
        _presendSurplus(st.tokens, st.beforeBal, orders, st.outs);

        // Phase 3: single residual interaction. Allowance-less EXECUTOR — the solver
        // returns the net-deficit token (funded by the surplus it was just handed)
        // but can never move the pool.
        if (interactionTarget != address(0)) EXECUTOR.execute(interactionTarget, interactionData);

        // Phase 4: deliver every order's outputs from the pool + run invariants.
        _batchDeliverAll(orders, st.ctxs, st.outs, takerDatas);

        // Phase 5: enforce the batch left Settlement whole and sweep any residual.
        _sweepSurplus(st.tokens, st.beforeBal);
        return st.outs;
    }


    /// @dev `takerDatas[i]` or an empty blob when the no-taker overload is used.
    function _td(bytes[] memory takerDatas, uint256 i) private pure returns (bytes memory) {
        return takerDatas.length == 0 ? bytes("") : takerDatas[i];
    }


    /// @dev Phase 1: open + pool inputs for every order. Own frame (stack).
    function _batchOpenAll(
        Order[] calldata orders,
        bytes[] calldata sigs,
        uint256[] calldata fillAmounts,
        bytes[] memory takerDatas
    ) internal returns (FillCtx[] memory ctxs) {
        uint256 n = orders.length;
        ctxs = new FillCtx[](n);
        address solver = msg.sender;
        for (uint256 i; i < n;) {
            ctxs[i] = _batchOpenAndPull(orders[i], sigs[i], fillAmounts[i], solver, _td(takerDatas, i));
            unchecked {
                ++i;
            }
        }
    }


    /// @dev Phase 1 (compute half): every order's per-leg output amounts, with NO
    ///      transfer, so the pre-send can net surplus vs. owed before delivering.
    ///      `view` — same math the delivery half replays exactly (same `ctx`, same
    ///      block), so compute and deliver never diverge.
    function _batchComputeAllOutputs(Order[] calldata orders, FillCtx[] memory ctxs)
        internal
        view
        returns (uint256[][] memory amounts)
    {
        uint256 n = orders.length;
        amounts = new uint256[][](n);
        for (uint256 i; i < n;) {
            amounts[i] = _batchComputeOutputs(orders[i], ctxs[i]);
            unchecked {
                ++i;
            }
        }
    }


    /// @dev Phase 2: hand each token's net surplus (`pooled − owed`, when positive)
    ///      to the solver so it can convert it into the deficit in the interaction —
    ///      the zero-capital unlock for imbalanced batches. `pooled` is measured as
    ///      the balance delta since the pre-batch snapshot, so the pre-send is
    ///      bounded to THIS batch's inputs and can never leak a donated balance.
    function _presendSurplus(
        address[] memory tokens,
        uint256[] memory beforeBal,
        Order[] calldata orders,
        uint256[][] memory amounts
    ) internal {
        address solver = msg.sender;
        for (uint256 k; k < tokens.length;) {
            address token = tokens[k];
            uint256 owed = _owedForToken(orders, amounts, token);
            uint256 pooled = SafeTransferLib.balanceOf(token, address(this)) - beforeBal[k]; // this batch only
            if (pooled > owed) {
                unchecked {
                    SafeTransferLib.safeTransfer(token, solver, pooled - owed);
                }
            }
            unchecked {
                ++k;
            }
        }
    }


    /// @dev Sum of every order's output amount denominated in `token` — the pool's
    ///      total obligation in that token, across makers and fee legs alike.
    function _owedForToken(Order[] calldata orders, uint256[][] memory amounts, address token)
        internal
        pure
        returns (uint256 owed)
    {
        for (uint256 i; i < orders.length;) {
            LegOut[] calldata tOut = orders[i].legsOut;
            for (uint256 j; j < tOut.length;) {
                if (tOut[j].token == token) owed += amounts[i][j];
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
    }


    /// @dev Phase 4: deliver the pre-computed amounts from the pool + invariants +
    ///      event for every order. Own frame.
    function _batchDeliverAll(
        Order[] calldata orders,
        FillCtx[] memory ctxs,
        uint256[][] memory amounts,
        bytes[] memory takerDatas
    ) internal {
        uint256 n = orders.length;
        address solver = msg.sender;
        for (uint256 i; i < n;) {
            _batchDeliverStored(orders[i], amounts[i]);
            _runInvariants(orders[i], solver, _td(takerDatas, i));
            emit OrderFilled(ctxs[i].orderHash, orders[i].maker, solver);
            unchecked {
                ++i;
            }
        }
    }


    /// @dev Snapshot Settlement's balance of each token in a MEMORY list (the batch
    ///      token universe). Sibling of `_snapshotInputs`, which takes calldata legs.
    function _snapshotBalances(address[] memory tokens) internal view returns (uint256[] memory bals) {
        bals = new uint256[](tokens.length);
        for (uint256 k; k < tokens.length;) {
            bals[k] = SafeTransferLib.balanceOf(tokens[k], address(this));
            unchecked {
                ++k;
            }
        }
    }


    /// @dev Phase 5: require the batch left Settlement no worse off on any touched
    ///      token ({BatchNotWhole} else) and sweep any residual — the solver's
    ///      compensation, ~0 after a clean pre-send + interaction — to the caller.
    ///      Never touches `beforeBal` (pre-existing / donated balances stay put).
    function _sweepSurplus(address[] memory tokens, uint256[] memory beforeBal) internal {
        address solver = msg.sender;
        for (uint256 k; k < tokens.length;) {
            uint256 nowBal = SafeTransferLib.balanceOf(tokens[k], address(this));
            if (nowBal < beforeBal[k]) revert BatchNotWhole(tokens[k]);
            unchecked {
                uint256 surplus = nowBal - beforeBal[k]; // nowBal >= beforeBal[k]
                if (surplus != 0) SafeTransferLib.safeTransfer(tokens[k], solver, surplus);
                ++k;
            }
        }
    }


    /// @dev Phase-1 body for one order: the full `_fillCore` gate set (item-free
    ///      guard, deadline, signature/approval, exclusivity, nonce, validators),
    ///      then `_openFill` (writes `filled`) and pool this order's inputs into
    ///      Settlement. `takerData` threads into the validators and the fill module.
    ///      Split out so the batch loop stays under the stack limit.
    function _batchOpenAndPull(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmount,
        address solver,
        bytes memory takerData
    ) internal returns (FillCtx memory ctx) {
        if (order.items.length != 0) revert BatchSettleNoItems();
        if (fillAmount == 0) revert ZeroFill();
        if (block.timestamp > order.deadline) revert OrderExpired();
        bytes32 orderHash = order.hash();
        _verifySignature(orderHash, sig, order.maker);
        uint256 overrideBps = _exclusivity(order, solver);
        if (_isNonceCancelled(order.maker, order.nonce)) revert NonceCancelled();
        _runValidators(order, solver, takerData);
        ctx = _openFill(order, orderHash, fillAmount, overrideBps, solver, takerData);
        _batchPullInputs(order, ctx);
    }


    /// @dev Pool this fill's input legs `maker → Settlement`. The owed-per-leg math
    ///      is IDENTICAL to `_payInputsToSolver` (fixed + auctioned legs, soft
    ///      exclusivity) minus the TAKE-proceeds branch — batch orders are
    ///      item-free, so proceeds are zero by construction. The maker is charged
    ///      exactly what a single fill would charge; only the destination differs.
    function _batchPullInputs(Order calldata order, FillCtx memory ctx) internal {
        address maker = order.maker;
        for (uint256 i; i < order.legsIn.length;) {
            uint256 owed = order.inputOwed(ctx, i); // see {Pricing.inputOwed}
            if (owed != 0) {
                Permit3TransferLib.transferFromWithFallback(PERMIT3, order.legsIn[i].token, maker, address(this), owed);
            }
            unchecked {
                ++i;
            }
        }
    }


    /// @dev Compute this fill's per-leg output amounts WITHOUT transferring — the
    ///      pre-send needs the totals before delivery. The per-leg math — BUY
    ///      fixed-output slices, SELL auction-priced, soft exclusivity on maker legs
    ///      only — is IDENTICAL to `_deliverOutputs`; the returned amount is final
    ///      (post-override), so `_batchDeliverStored` just moves it.
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


    /// @dev Deliver the pre-computed output amounts `Settlement → recipient` via
    ///      plain `transfer` (the pool, not the solver, is the source). A short pool
    ///      reverts here (atomic). `recipientOut[j] == 0` ⇒ the maker.
    function _batchDeliverStored(Order calldata order, uint256[] memory amts) internal {
        for (uint256 j; j < amts.length;) {
            uint256 amt = amts[j];
            if (amt != 0) {
                address to = order.legsOut[j].recipient;
                bool makerLeg = to == address(0) || to == order.maker;
                SafeTransferLib.safeTransfer(order.legsOut[j].token, makerLeg ? order.maker : to, amt);
            }
            unchecked {
                ++j;
            }
        }
    }


    /// @dev The de-duplicated union of every order's `tokenIn`/`tokenOut`. Derived
    ///      on-chain (not solver-supplied) so the `BatchNotWhole` guard covers every
    ///      token the batch could move. O(legs²) — batches are small, and this runs
    ///      only on the deliberate CoW path, never the single-order hot path.
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
        tokens = new address[](count);
        for (uint256 k; k < count;) {
            tokens[k] = buf[k];
            unchecked {
                ++k;
            }
        }
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


    // ─────────────── Item-aware netted settle (leverage ⋈ spot) ───────────────

    /// @notice The item-aware generalization of {batchSettle}: settle N orders as
    ///         one netted batch WHERE ORDERS MAY CARRY MAKE/TAKE ITEMS. This lets a
    ///         spot order's pooled liquidity fund a leverage order's conversion with
    ///         NO solver inventory, NO callback, and — in the match case — NO flash:
    ///         the spot order's input is delivered as the leverage order's collateral
    ///         and deposited BEFORE the borrow, bootstrapping it; the borrow proceeds
    ///         then pay the spot order out of the pool.
    ///
    ///         Because deliveries interleave with item execution (an order's output
    ///         is delivered, then its MAKE deposits it, then its TAKE borrows the
    ///         funding token into the pool), there is no "pull all → deliver all"
    ///         order. The solver supplies two hints the contract executes verbatim:
    ///
    ///           • `pullMask[i]` — bit `j` set ⇒ pull order `i`'s input leg `j` into
    ///             the pool up front (its SELF-FUNDED seeds: spot sells, equity
    ///             margin). Legs left unset are ITEM-FUNDED — satisfied by that
    ///             order's own TAKE proceeds during execution.
    ///           • `sequence` — a permutation of `[0, n)`: the order in which to run
    ///             each order's deliver-outputs + items + settle-inputs.
    ///
    ///         Neither hint can make an UNSAFE settlement succeed (see below); a bad
    ///         hint only reverts. Scheduling is thus the solver's job (liveness); the
    ///         contract owns correctness (safety):
    ///           - every output leg is a transfer that fully succeeds or reverts (no
    ///             maker under-delivered);
    ///           - each maker is charged its OWN signed slice, unchanged by netting;
    ///           - items run under the maker's signature + the maker's own Permit3
    ///             allowances (`_executeItems` is byte-identical to the single-order
    ///             path), `filled` written before any of it;
    ///           - the same pool whole-ness guard as {batchSettle}: every touched
    ///             token must end ≥ its pre-batch balance (`BatchNotWhole` else), so
    ///             a donated balance is never consumed and the solver can never
    ///             extract past the batch's genuine surplus.
    ///
    /// @dev    Flow: (1) open every order (writes `filled`) + pull `pullMask` legs →
    ///         pool; (2) one optional `interactionTarget` call (the solver seeds any
    ///         residual it must front, e.g. a dual-conversion equity leg); (3) run
    ///         orders in `sequence` — deliver outputs from pool, `_executeItems`
    ///         (TAKE proceeds → pool), settle inputs to pool (item-funded legs keep
    ///         `owed` in the pool from proceeds and return the surplus to the maker;
    ///         `BatchItemsInputUnfunded` if a non-pulled leg under-produces); (4)
    ///         whole-check + sweep. `nonReentrant`; SETTLE items are out of scope
    ///         (they route to the filler — a shared-pool version needs its own
    ///         design). Item tokens must lie within the orders' leg-token universe
    ///         (true for leverage/repay/migrate). v1 passes empty `takerData`.
    /// @return outs `outs[i][j]` = order `i`'s delivered amount on output leg `j`.
    function batchSettleItems(ItemsBatch calldata b) external nonReentrant returns (uint256[][] memory) {
        uint256 n = b.orders.length;
        if (b.sigs.length != n || b.fillAmounts.length != n || b.pullMask.length != n || n > 256) {
            revert LengthMismatch();
        }
        return _batchSettleItems(b);
    }


    function _batchSettleItems(ItemsBatch calldata b) internal returns (uint256[][] memory) {
        BatchState memory st;
        st.tokens = _collectTokens(b.orders);
        st.beforeBal = _snapshotBalances(st.tokens);

        // Phase 1: open every order (writes `filled`) + pull the self-funded seeds.
        _openAndPullAll(b.orders, b.sigs, b.fillAmounts, b.pullMask, st);

        // Phase 2: optional solver interaction — seed any residual the solver must
        // front (e.g. a dual-conversion equity leg). Allowance-less EXECUTOR.
        if (b.interactionTarget != address(0)) EXECUTOR.execute(b.interactionTarget, b.interactionData);

        // Phase 3: run each order against the pool in the solver-given sequence.
        _execSequence(b.orders, st, b.pullMask, b.sequence);

        // Phase 4: enforce the batch left Settlement whole and sweep any residual.
        _sweepSurplus(st.tokens, st.beforeBal);
        return st.outs;
    }


    /// @dev Phase 1: open + pull-seed every order. Item-bearing orders allowed.
    function _openAndPullAll(
        Order[] calldata orders,
        bytes[] calldata sigs,
        uint256[] calldata fillAmounts,
        uint256[] calldata pullMask,
        BatchState memory st
    ) internal {
        uint256 n = orders.length;
        st.ctxs = new FillCtx[](n);
        st.outs = new uint256[][](n);
        address solver = msg.sender;
        for (uint256 i; i < n;) {
            st.ctxs[i] = _openItemOrder(orders[i], sigs[i], fillAmounts[i], solver);
            _pullMaskedInputs(orders[i], st.ctxs[i], pullMask[i]);
            unchecked {
                ++i;
            }
        }
    }


    /// @dev The `_fillCore` gate set (deadline/sig/exclusivity/nonce/validators) +
    ///      `_openFill` (writes `filled`), WITHOUT pulling inputs or forbidding
    ///      items — the item-aware sibling of `_batchOpenAndPull`.
    function _openItemOrder(Order calldata order, bytes calldata sig, uint256 fillAmount, address solver)
        internal
        returns (FillCtx memory ctx)
    {
        if (fillAmount == 0) revert ZeroFill();
        if (block.timestamp > order.deadline) revert OrderExpired();
        _assertItemBatchShape(order);
        bytes32 orderHash = order.hash();
        _verifySignature(orderHash, sig, order.maker);
        uint256 overrideBps = _exclusivity(order, solver);
        if (_isNonceCancelled(order.maker, order.nonce)) revert NonceCancelled();
        _runValidators(order, solver, "");
        ctx = _openFill(order, orderHash, fillAmount, overrideBps, solver, "");
    }


    /// @dev Enforce the two shape constraints the netted item flow relies on (both
    ///      documented, now also checked): no SETTLE item (it routes to the filler,
    ///      not the pool — `BatchItemsSettleUnsupported`) and no repeated input token
    ///      (the pooled proceeds attribution keys on the token — a duplicate leg
    ///      would mis-account; `BatchItemsDuplicateInput`). Runs once per order at
    ///      open. O(items + tokenIn²), tiny — the deliberate CoW path.
    ///
    ///      The duplicate-input guard is INTENTIONALLY item-path-only. The single-
    ///      order (`_payInputsToSolver`) and item-free (`_batchPullInputs`) paths
    ///      handle a repeated tokenIn correctly: they move each leg's `owed` OUT of
    ///      Settlement (to the solver, or pull it fresh), so the per-leg
    ///      `balanceOf − snapshot` delta stays attributable and the totals conserve.
    ///      Only `_settleInputsToPool` RETAINS `owed` in the pool, so a second
    ///      same-token leg would re-read the first leg's retained balance as its own
    ///      proceeds and under-retain — hence the guard lives here, not on the hot
    ///      path (where adding it would reject valid orders and cost gas for nothing).
    function _assertItemBatchShape(Order calldata order) internal pure {
        Item[] calldata items = order.items;
        for (uint256 i; i < items.length;) {
            if (items[i].op == ItemOp.SETTLE) revert BatchItemsSettleUnsupported();
            unchecked {
                ++i;
            }
        }
        LegIn[] calldata legsIn = order.legsIn;
        for (uint256 i; i < legsIn.length;) {
            for (uint256 j = i + 1; j < legsIn.length;) {
                if (legsIn[i].token == legsIn[j].token) revert BatchItemsDuplicateInput();
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
    }


    /// @dev Pull ONLY the input legs whose `mask` bit is set (the self-funded
    ///      seeds), maker → pool. `owed` uses the shared {Pricing.inputOwed} slice math.
    function _pullMaskedInputs(Order calldata order, FillCtx memory ctx, uint256 mask) internal {
        for (uint256 i; i < order.legsIn.length;) {
            if ((mask >> i) & 1 == 1) {
                uint256 owed = order.inputOwed(ctx, i);
                if (owed != 0) {
                    Permit3TransferLib.transferFromWithFallback(
                        PERMIT3, order.legsIn[i].token, order.maker, address(this), owed
                    );
                }
            }
            unchecked {
                ++i;
            }
        }
    }


    /// @dev Phase 3: run each order once, in the solver-given `sequence` (validated
    ///      to be a permutation of `[0, n)` — wrong length, out-of-range, or a
    ///      duplicate reverts `BatchItemsBadSequence`).
    function _execSequence(
        Order[] calldata orders,
        BatchState memory st,
        uint256[] calldata pullMask,
        uint256[] calldata sequence
    ) internal {
        uint256 n = orders.length;
        if (sequence.length != n) revert BatchItemsBadSequence();
        address solver = msg.sender;
        uint256 seen;
        for (uint256 k; k < n;) {
            uint256 idx = sequence[k];
            if (idx >= n || (seen >> idx) & 1 == 1) revert BatchItemsBadSequence();
            seen |= (uint256(1) << idx);
            st.outs[idx] = _execOrderNetted(orders[idx], st.ctxs[idx], pullMask[idx], solver);
            unchecked {
                ++k;
            }
        }
    }


    /// @dev One order's netted forward flow: deliver outputs from the pool → run
    ///      items (TAKE proceeds → pool) → settle inputs into the pool → invariants.
    ///      The pool is the counterparty throughout; the solver never touches it.
    function _execOrderNetted(Order calldata order, FillCtx memory ctx, uint256 mask, address solver)
        internal
        returns (uint256[] memory amounts)
    {
        amounts = _batchComputeOutputs(order, ctx);
        _batchDeliverStored(order, amounts); // pool → maker/recipient (reverts if pool short)
        // Snapshot AFTER delivery, BEFORE items, so proceeds measure THIS order's
        // TAKE production only (other pooled funds cancel in the delta).
        uint256[] memory tokenInBefore = _snapshotInputs(order.legsIn);
        _executeItems(order, ctx);
        _settleInputsToPool(order, ctx, mask, tokenInBefore);
        _runInvariants(order, solver, "");
        emit OrderFilled(ctx.orderHash, order.maker, solver);
    }


    /// @dev Settle one order's input legs INTO the pool (not to a solver):
    ///      • self-funded leg (mask bit set) — `owed` was already pulled in Phase 1;
    ///        return any stray proceeds for the token to the maker (never strand).
    ///      • item-funded leg (mask bit unset) — its TAKE proceeds (the balance
    ///        delta since `tokenInBefore`) must cover `owed`; `owed` STAYS in the
    ///        pool (it funds other orders' deliveries) and the surplus returns to the
    ///        maker. `BatchItemsInputUnfunded` if proceeds < owed.
    function _settleInputsToPool(
        Order calldata order,
        FillCtx memory ctx,
        uint256 mask,
        uint256[] memory tokenInBefore
    ) internal {
        address maker = order.maker;
        for (uint256 i; i < order.legsIn.length;) {
            address token = order.legsIn[i].token;
            uint256 proceeds = SafeTransferLib.balanceOf(token, address(this)) - tokenInBefore[i];
            if ((mask >> i) & 1 == 1) {
                if (proceeds != 0) SafeTransferLib.safeTransfer(token, maker, proceeds);
            } else {
                uint256 owed = order.inputOwed(ctx, i);
                if (proceeds < owed) revert BatchItemsInputUnfunded();
                unchecked {
                    uint256 surplus = proceeds - owed; // owed stays pooled
                    if (surplus != 0) SafeTransferLib.safeTransfer(token, maker, surplus);
                }
            }
            unchecked {
                ++i;
            }
        }
    }
}
