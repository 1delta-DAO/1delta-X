// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPermit3} from "../interfaces/IPermit3.sol";
import {SafeTransferLib} from "../utils/SafeTransferLib.sol";
import {Permit3TransferLib} from "../utils/Permit3TransferLib.sol";
import {Order, OrderSide, CallbackMode, FillCtx} from "./Structs.sol";
import {OrderHash} from "./OrderHash.sol";
import {Pricing} from "./Pricing.sol";
import {Base} from "./Base.sol";

/// @title Core
/// @notice The single-order fill path — the HOT PATH. Public entrypoints (`fill`,
///         `fillWithCallback`, `fillWithPermit`, `batchFill`, `fillSelf`) and the
///         per-order settle flow (`_fillCore` → `_settleForward`/`_settlePostInputs`
///         → `_deliverOutputs`/`_payInputsToSolver`). One order settles against the
///         solver as counterparty; per-leg pricing is {Pricing}. The
///         netted-batch modes live in {Batch}, one level up.
abstract contract Core is Base {
    using OrderHash for Order;
    using Pricing for Order;




    // ──────────────────── Fill ────────────────────

    /// @notice Fill (up to) `fillAmount` of an order — in `tokenIn[0]` units for a
    ///         SELL, `tokenOut[0]` units for a BUY. Partial fills allowed.
    ///         Lending items are executed pro-rata for this fill's slice.
    /// @dev    Thin wrapper over the {takerData} overload with an empty blob, so
    ///         existing 3-arg call sites (solvers, SDK) keep working unchanged.
    function fill(Order calldata order, bytes calldata sig, uint256 fillAmount)
        external
        nonReentrant
        returns (uint256[] memory fillAmountsOut)
    {
        bytes32 orderHash = order.hash();
        _verifySignature(orderHash, sig, order.maker);
        return _fillCore(order, orderHash, fillAmount, msg.sender, address(0), "", CallbackMode.PreDelivery, "");
    }


    /// @notice Fill overload that carries a filler-supplied `takerData` blob into
    ///         the order's validators and invariants.
    /// @param  takerData  Adversarial, UNSIGNED, shared-per-fill data (see
    ///         {IOrderValidator}). It reaches every validator and invariant of this
    ///         fill but can only be *consumed by a validator* — a read-only gate —
    ///         so it can never alter the maker's signed outcome (amounts, tokens,
    ///         recipients). A validator that reads it MUST independently verify it
    ///         (e.g. recover a maker-trusted attester over a digest bound to
    ///         `msg.sender`). Lets a maker gate a fill on a proof only the filler
    ///         can produce (off-chain attestation, oracle update, ZK proof).
    function fill(Order calldata order, bytes calldata sig, uint256 fillAmount, bytes calldata takerData)
        external
        nonReentrant
        returns (uint256[] memory fillAmountsOut)
    {
        bytes32 orderHash = order.hash();
        _verifySignature(orderHash, sig, order.maker);
        return _fillCore(order, orderHash, fillAmount, msg.sender, address(0), "", CallbackMode.PreDelivery, takerData);
    }


    /// @notice Fill with a solver-supplied callback that runs just before output
    ///         delivery — the taker-interaction analogue. Lets a zero-inventory
    ///         solver source `tokenOut` just-in-time (flash / swap / route)
    ///         without a bespoke solver contract: the callback runs while the
    ///         fill's reentrancy guard is held, then Settlement pulls the outputs
    ///         the solver just acquired.
    ///
    ///  Safety: the `(callbackTarget, callbackData)` call is made by
    ///  {SolverCallbackExecutor} — an allowance-less trampoline — NOT by
    ///  Settlement, so it cannot abuse Settlement's Permit3 spender status to
    ///  move a maker's funds (e.g. `callbackTarget = PERMIT3` gains nothing). The
    ///  callback is filler-supplied and NOT part of the maker's signed order, so
    ///  it can only act with its own authority; the maker's funds stay gated by
    ///  their signature + Permit3 allowances exactly as in a plain `fill`.
    ///  Reentrancy into any fill is blocked by `nonReentrant`.
    ///
    ///  `mode` (filler-chosen) picks where the callback runs:
    ///    • PreDelivery — callback → deliver outputs → items → pay inputs. Works
    ///      for any order; the solver must source `tokenOut` from something that
    ///      does NOT depend on this fill's proceeds (flash / credit / inventory).
    ///    • PostInputs  — pay inputs → callback → deliver outputs. Item-free
    ///      orders only. The solver is paid its `tokenIn` FIRST, converts it in
    ///      the callback, then delivers `tokenOut` — a genuinely zero-inventory,
    ///      zero-flash plain-swap fill (the Fusion `takerInteraction` ordering).
    ///
    ///  The `mode` flag only permutes solver-side transfer order; it cannot change
    ///  the maker's signed outcome. In both modes the tx can only succeed if the
    ///  maker pays exactly the signed input and receives the signed output (a
    ///  mandatory, reverting delivery) and every invariant passes — so it is safe
    ///  for the filler, not the maker, to choose it.
    function fillWithCallback(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmount,
        address callbackTarget,
        bytes calldata callbackData,
        CallbackMode mode
    ) external nonReentrant returns (uint256[] memory fillAmountsOut) {
        bytes32 orderHash = order.hash();
        _verifySignature(orderHash, sig, order.maker);
        return _fillCore(order, orderHash, fillAmount, msg.sender, callbackTarget, callbackData, mode, "");
    }


    /// @notice {fillWithCallback} overload carrying a filler-supplied `takerData`
    ///         blob into the order's validators and invariants. See {fill}'s
    ///         takerData overload for the adversarial/validator-verified rule.
    function fillWithCallback(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmount,
        address callbackTarget,
        bytes calldata callbackData,
        CallbackMode mode,
        bytes calldata takerData
    ) external nonReentrant returns (uint256[] memory fillAmountsOut) {
        bytes32 orderHash = order.hash();
        _verifySignature(orderHash, sig, order.maker);
        return _fillCore(order, orderHash, fillAmount, msg.sender, callbackTarget, callbackData, mode, takerData);
    }


    /// @notice Single-signature fill: the maker's `sig` is over a Permit3
    ///         `PermitBatch` bound to this order's hash as a witness, so
    ///         one signature simultaneously authorises the order *and*
    ///         every Permit3 token + taker allowance the fill needs.
    ///         No standing approvals required.
    function fillWithPermit(
        Order calldata order,
        IPermit3.PermitBatch calldata batch,
        bytes calldata sig,
        uint256 fillAmount
    ) external nonReentrant returns (uint256[] memory fillAmountsOut) {
        bytes32 orderHash = order.hash();
        // Permit3 verifies the sig against (PermitBatchWitness + orderHash) and
        // applies all allowances. The order itself doesn't need a separate sig
        // — the witness binding makes the permit endorse this exact order.
        PERMIT3.permitBatchWithWitness(order.maker, batch, orderHash, OrderHash.WITNESS_TYPESTRING, sig);
        return _fillCore(order, orderHash, fillAmount, msg.sender, address(0), "", CallbackMode.PreDelivery, "");
    }


    /// @notice {fillWithPermit} overload carrying a filler-supplied `takerData`
    ///         blob into the order's validators and invariants. See {fill}'s
    ///         takerData overload for the adversarial/validator-verified rule.
    function fillWithPermit(
        Order calldata order,
        IPermit3.PermitBatch calldata batch,
        bytes calldata sig,
        uint256 fillAmount,
        bytes calldata takerData
    ) external nonReentrant returns (uint256[] memory fillAmountsOut) {
        bytes32 orderHash = order.hash();
        PERMIT3.permitBatchWithWitness(order.maker, batch, orderHash, OrderHash.WITNESS_TYPESTRING, sig);
        return _fillCore(order, orderHash, fillAmount, msg.sender, address(0), "", CallbackMode.PreDelivery, takerData);
    }


    /// @notice Fill a batch of orders in one transaction. Each order is attempted
    ///         independently; an order that reverts (expired, cancelled,
    ///         under-funded, over-fill, …) is SKIPPED and its `success[i]` is
    ///         false — unless `revertIfIncomplete`, in which case the first
    ///         failure reverts the whole batch. Mirrors 0x's `batchFill*` with
    ///         the `revertIfIncomplete` flag.
    /// @dev    Each fill runs via a `this.fillSelf` self-call so a revert unwinds
    ///         only that order, not the batch. The real filler (`msg.sender`) is
    ///         threaded through, so a skipped order costs the caller nothing and a
    ///         filled one settles against the caller exactly as a direct `fill`.
    function batchFill(
        Order[] calldata orders,
        bytes[] calldata sigs,
        uint256[] calldata fillAmounts,
        bool revertIfIncomplete
    ) external nonReentrant returns (uint256[][] memory fillAmountsOut, bool[] memory success) {
        uint256 n = orders.length;
        fillAmountsOut = new uint256[][](n);
        success = new bool[](n);
        address filler = msg.sender;
        for (uint256 i; i < n;) {
            // Empty takerData — the no-taker-blob path.
            try this.fillSelf(orders[i], sigs[i], fillAmounts[i], filler, "") returns (uint256[] memory outs) {
                fillAmountsOut[i] = outs;
                success[i] = true;
            } catch {
                if (revertIfIncomplete) revert BatchFillIncomplete(i);
            }
            unchecked {
                ++i;
            }
        }
    }


    /// @notice {batchFill} overload carrying a per-order filler-supplied `takerData`
    ///         blob, aligned 1:1 with `orders` (`takerDatas[i]` threads into order
    ///         `i`'s validators + invariants). See {fill}'s takerData overload for
    ///         the adversarial/validator-verified rule.
    /// @dev    Reverts {LengthMismatch} if `takerDatas.length != orders.length`.
    ///         The loop is inlined (not shared with the 4-arg overload) to stay
    ///         under the EVM stack limit without via-IR.
    function batchFill(
        Order[] calldata orders,
        bytes[] calldata sigs,
        uint256[] calldata fillAmounts,
        bool revertIfIncomplete,
        bytes[] calldata takerDatas
    ) external nonReentrant returns (uint256[][] memory fillAmountsOut, bool[] memory success) {
        uint256 n = orders.length;
        if (takerDatas.length != n) revert LengthMismatch();
        fillAmountsOut = new uint256[][](n);
        success = new bool[](n);
        address filler = msg.sender;
        for (uint256 i; i < n;) {
            try this.fillSelf(orders[i], sigs[i], fillAmounts[i], filler, takerDatas[i]) returns (uint256[] memory outs)
            {
                fillAmountsOut[i] = outs;
                success[i] = true;
            } catch {
                if (revertIfIncomplete) revert BatchFillIncomplete(i);
            }
            unchecked {
                ++i;
            }
        }
    }


    /// @notice Self-call fill target for {batchFill}. Verifies the maker signature
    ///         and runs the fill for an explicit `filler`, carrying this order's
    ///         `takerData`. `onlySelf` — external callers must use `fill`.
    function fillSelf(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmount,
        address filler,
        bytes calldata takerData
    ) external returns (uint256[] memory) {
        if (msg.sender != address(this)) revert OnlySelf();
        bytes32 orderHash = order.hash();
        _verifySignature(orderHash, sig, order.maker);
        return _fillCore(order, orderHash, fillAmount, filler, address(0), "", CallbackMode.PreDelivery, takerData);
    }


    function _fillCore(
        Order calldata order,
        bytes32 orderHash,
        uint256 fillAmount,
        address filler,
        address callbackTarget,
        bytes memory callbackData,
        CallbackMode mode,
        bytes memory takerData
    ) internal returns (uint256[] memory) {
        if (fillAmount == 0) revert ZeroFill();
        // Note: the anti-dust floor is checked in _openFill against the resolved
        // `delta` (the actual progress), not the requested `fillAmount` — for a
        // fill-module order the two can differ, and minFillAnchor must gate the
        // real advance. For an identity order delta == fillAmount, so behavior is
        // unchanged.
        if (block.timestamp > order.deadline) revert OrderExpired();

        uint256 overrideBps = _exclusivity(order, filler);
        if (_isNonceCancelled(order.maker, order.nonce)) revert NonceCancelled();
        _runValidators(order, filler, takerData);

        // `takerData` doubles as the filler's fill proposal for a fill-module
        // order (see {IFillModule}); a plain fungible order ignores it here.
        FillCtx memory ctx = _openFill(order, orderHash, fillAmount, overrideBps, filler, takerData);

        // The SAME takerData feeds the post-execution invariants (via the settle
        // helper), so a validator and an invariant see an identical filler blob.
        return mode == CallbackMode.PostInputs
            ? _settlePostInputs(order, ctx, callbackTarget, callbackData, takerData)
            : _settleForward(order, ctx, callbackTarget, callbackData, takerData);
    }


    /// @dev Forward flow: optional callback → deliver outputs → items → pay
    ///      inputs → invariants. The callback runs BEFORE any funds move, routed
    ///      through the allowance-less EXECUTOR (cannot leverage Settlement's
    ///      Permit3 spender status) and under `nonReentrant`.
    function _settleForward(
        Order calldata order,
        FillCtx memory ctx,
        address callbackTarget,
        bytes memory callbackData,
        bytes memory takerData
    ) internal returns (uint256[] memory outs) {
        if (callbackTarget != address(0)) EXECUTOR.execute(callbackTarget, callbackData);

        outs = _deliverOutputs(order, ctx);

        // Snapshot each tokenIn before items so the payout uses ONLY this fill's
        // TAKE proceeds — never a pre-existing/donated Settlement balance. Skipped
        // for item-free orders: with no TAKE legs there are no proceeds, so the
        // snapshot + the balanceOf re-read in `_payInputsToSolver` would just burn
        // two STATICCALLs per input leg on every plain swap.
        bool hasItems = order.items.length != 0;
        uint256[] memory tokenInBefore = hasItems ? _snapshotInputs(order.tokenIn) : new uint256[](0);
        _executeItems(order, ctx);
        _payInputsToSolver(order, ctx, tokenInBefore, hasItems);
        _runInvariants(order, ctx.filler, takerData);
        emit OrderFilled(ctx.orderHash, order.maker, ctx.filler);
    }


    /// @dev Reverse (PostInputs) flow: pay the solver its tokenIn FIRST, let the
    ///      callback convert it, THEN deliver tokenOut — a zero-inventory /
    ///      zero-flash swap (the Fusion takerInteraction order). Item-free only:
    ///      item flows have deposit→borrow dependencies that assume the forward
    ///      order. Delivery + invariants stay mandatory and reverting, so the
    ///      maker is made whole or the whole tx unwinds.
    function _settlePostInputs(
        Order calldata order,
        FillCtx memory ctx,
        address callbackTarget,
        bytes memory callbackData,
        bytes memory takerData
    ) internal returns (uint256[] memory outs) {
        if (order.items.length != 0) revert ReverseModeRequiresNoItems();
        // No items ⇒ no TAKE proceeds ⇒ proceeds are 0 by construction, so
        // `_payInputsToSolver` (hasItems=false) pulls exactly `owed` from the
        // maker → solver with no balance snapshot needed.
        _payInputsToSolver(order, ctx, new uint256[](0), false);
        if (callbackTarget != address(0)) EXECUTOR.execute(callbackTarget, callbackData);
        outs = _deliverOutputs(order, ctx);
        _runInvariants(order, ctx.filler, takerData);
        emit OrderFilled(ctx.orderHash, order.maker, ctx.filler);
    }



    /// @dev Deliver every output leg for this fill, solver → the leg's recipient
    ///      (`recipientOut[j]`, `address(0)` = the maker — so a fee leg is just an
    ///      output addressed to the originator).
    ///      • SELL: outputs are auction-priced — each leg is `ceil(fillAmount ·
    ///        currentAmountOut / anchor)` at the current tick, so the maker is
    ///        never underpaid.
    ///      • BUY: outputs are FIXED — each leg is the cumulative ceil slice of
    ///        `startAmountOut[j]`, summing to exactly `startAmountOut[j]` at full
    ///        fill (and to `fillAmount` for j==0). Each leg pulls the solver's
    ///        `tokenOut` via Permit3, falling back to a direct ERC20 transferFrom
    ///        when the solver approved Settlement directly (see
    ///        `_transferFromWithFallback`).
    function _deliverOutputs(Order calldata order, FillCtx memory ctx) internal returns (uint256[] memory outs) {
        uint256 n = order.tokenOut.length;
        outs = new uint256[](n);
        for (uint256 j; j < n;) {
            // Amount (incl. the maker-leg soft-exclusivity override) — see
            // {Pricing.outputAt}. The maker-leg test is recomputed here
            // only to route the transfer (never a fee leg's comp to a third party).
            uint256 amt = order.outputAt(ctx, j);
            if (amt != 0) {
                address to = order.recipientOut[j];
                bool makerLeg = to == address(0) || to == order.maker;
                outs[j] = amt;
                Permit3TransferLib.transferFromWithFallback(
                    PERMIT3, order.tokenOut[j], ctx.filler, makerLeg ? order.maker : to, amt
                );
            }
            unchecked {
                ++j;
            }
        }
    }


    /// @dev Pay every input leg to the solver for this fill.
    ///      • Fixed leg (`start == end`, the common SELL input): `owed_i` is the
    ///        cumulative floor slice of `startAmountIn[i]`, summing to exactly
    ///        `startAmountIn[i]` at full fill (and to `fillAmount` for i==0) —
    ///        the exact-input guarantee.
    ///      • Auctioned leg (`start != end`): `owed_i = floor(fillAmount ·
    ///        currentAmountIn / anchor)` at the current tick — rising
    ///        `start → end`, gas bump included; the maker is never overcharged
    ///        and the total never exceeds `endAmountIn[i]`. Every BUY conversion
    ///        input is such a leg; on SELL it is the relayer-fee auction for
    ///        orders with no conversion output to price a filler's compensation
    ///        into (e.g. a pure gasless deposit).
    ///
    ///      Soft exclusivity applies to every auctioned input leg: a
    ///      non-exclusive in-window filler charges `overrideBps` less — the
    ///      auction leg moves toward the maker.
    ///
    ///      Each leg uses ONLY the TAKE proceeds produced by THIS fill (the
    ///      balance delta since `tokenInBefore[i]`) — so a pre-existing/donated
    ///      Settlement balance can never be redirected to the solver. Any
    ///      shortfall is pulled from the maker via Permit3 (falling back to a
    ///      direct ERC20 transferFrom if the maker approved Settlement directly);
    ///      any surplus proceeds are returned to the maker, not stranded.
    function _payInputsToSolver(
        Order calldata order,
        FillCtx memory ctx,
        uint256[] memory tokenInBefore,
        bool hasItems
    ) internal {
        address maker = order.maker;
        address filler = ctx.filler;
        for (uint256 i; i < order.tokenIn.length; i++) {
            uint256 owed = order.inputOwed(ctx, i); // see {Pricing.inputOwed}
            address tokenIn = order.tokenIn[i];
            // Item-free orders have no TAKE proceeds ⇒ proceeds are 0 without a
            // balanceOf (the snapshot was skipped upstream). Item orders measure
            // this fill's proceeds as the balance delta since the snapshot.
            uint256 proceeds = hasItems ? SafeTransferLib.balanceOf(tokenIn, address(this)) - tokenInBefore[i] : 0;
            if (owed == 0) {
                // Nothing owed on this leg (dust slice, or a zero-amount leg),
                // but any TAKE proceeds for this token must still be returned to
                // the maker — never stranded in Settlement (there is no sweep).
                // Zero-guarded against no-op transfers on strict tokens.
                if (proceeds != 0) SafeTransferLib.safeTransfer(tokenIn, maker, proceeds);
                continue;
            }
            if (proceeds >= owed) {
                SafeTransferLib.safeTransfer(tokenIn, filler, owed);
                unchecked {
                    uint256 surplus = proceeds - owed; // proceeds >= owed
                    if (surplus > 0) SafeTransferLib.safeTransfer(tokenIn, maker, surplus);
                }
            } else {
                if (proceeds > 0) SafeTransferLib.safeTransfer(tokenIn, filler, proceeds);
                unchecked {
                    Permit3TransferLib.transferFromWithFallback(PERMIT3, tokenIn, maker, filler, owed - proceeds); // owed > proceeds
                }
            }
        }
    }
}
