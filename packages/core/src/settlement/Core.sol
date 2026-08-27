// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPermit3} from "../interfaces/IPermit3.sol";
import {SafeTransferLib} from "../utils/SafeTransferLib.sol";
import {Permit3TransferLib} from "../utils/Permit3TransferLib.sol";
import {Order, CallbackMode, FillCtx} from "./Structs.sol";
import {PackedArrays} from "./PackedArrays.sol";
import {DutchAuction} from "./DutchAuction.sol";
import {OrderHash} from "./OrderHash.sol";
import {Pricing} from "./Pricing.sol";
import {OrderGates} from "./OrderGates.sol";
import {Base} from "./Base.sol";
import {SolverCallbackExecutor} from "./SolverCallbackExecutor.sol";
import {ISettlementCallback} from "../interfaces/ISettlementCallback.sol";

/// @title Core
/// @notice The single-order fill path — the HOT PATH. Public entrypoints (`fill`,
///         `fillWithCallback`, `fillWithPermit`, `batchFill`, `fillSelf`, and the
///         custom-fill entry `fillUpTo`) and the per-order settle flow (`_fillCore`
///         → `_settleForward`/`_settlePostInputs` → `_deliverOutputs`/
///         `_payInputsToSolver`). One order settles against the solver as
///         counterparty; per-leg pricing is {Pricing}. The netted-batch
///         modes live in {Batch}, one level up.
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
        returns (uint256[] memory fillAmountsOut)
    {
        return _fillSigned(order, sig, fillAmount, "");
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
        returns (uint256[] memory fillAmountsOut)
    {
        return _fillSigned(order, sig, fillAmount, takerData);
    }

    /// @dev Shared body of both {fill} overloads — see {_fillWithPermitCore} for why
    ///      the overload pairs are funnelled through one body rather than duplicated.
    function _fillSigned(Order calldata order, bytes calldata sig, uint256 fillAmount, bytes memory takerData)
        private
        returns (uint256[] memory outs)
    {
        bytes32 orderHash = order.hash();
        // Read-only, and ahead of the guard on purpose — {Base._enter} explains the
        // rule this body has to keep.
        FillCtx memory ctx;
        _gateFillState(order, orderHash, ctx);
        _enter();
        _verifySignature(orderHash, sig, order.maker);
        outs = _fillCore(
            order, fillAmount, msg.sender, address(0), address(0), "",
            CallbackMode.PreDelivery, takerData, false, ctx
        );
        _exit();
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
    ) external returns (uint256[] memory fillAmountsOut) {
        return _fillCallback(order, sig, fillAmount, callbackTarget, callbackData, mode, "");
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
    ) external returns (uint256[] memory fillAmountsOut) {
        return _fillCallback(order, sig, fillAmount, callbackTarget, callbackData, mode, takerData);
    }

    /// @dev Shared body of both {fillWithCallback} overloads — see
    ///      {_fillWithPermitCore} for why the pairs are funnelled, not duplicated.
    function _fillCallback(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmount,
        address callbackTarget,
        bytes calldata callbackData,
        CallbackMode mode,
        bytes memory takerData
    ) private returns (uint256[] memory outs) {
        bytes32 orderHash = order.hash();
        FillCtx memory ctx;
        _gateFillState(order, orderHash, ctx);
        _enter();
        _verifySignature(orderHash, sig, order.maker);
        outs = _fillCore(
            order, fillAmount, msg.sender, address(0), callbackTarget, callbackData, mode, takerData, false, ctx
        );
        _exit();
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
    ) external returns (uint256[] memory fillAmountsOut) {
        return _fillWithPermitCore(order, batch, sig, fillAmount, "");
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
    ) external returns (uint256[] memory fillAmountsOut) {
        return _fillWithPermitCore(order, batch, sig, fillAmount, takerData);
    }

    /// @dev Shared body of both {fillWithPermit} overloads. Extracted because each
    ///      overload otherwise emits its OWN copy of the permit call's encoder — a
    ///      `PermitBatch` struct (two dynamic arrays of structs) plus the long
    ///      `WITNESS_TYPESTRING` constant — which is one of the largest single
    ///      encoders in the contract. MEASURED: **−200 bytes** of Settlement runtime,
    ///      with the external ABI unchanged.
    ///
    ///      IDEMPOTENT permit on purpose: the signature is still verified every time
    ///      (a bad `sig` reverts), but a nonce already spent — by an earlier partial
    ///      fill, or by a griefer who front-ran the permit straight out of this
    ///      calldata — is skipped instead of reverting {PermitNonceUsed}. Without
    ///      that, one cheap front-run permanently bricks the order (the maker signed
    ///      a PermitBatchWitness, not an Order, so no other entry can rescue it) and
    ///      partial fills are impossible. See
    ///      {SignedPermits.permitBatchWithWitnessIfNeeded}.
    function _fillWithPermitCore(
        Order calldata order,
        IPermit3.PermitBatch calldata batch,
        bytes calldata sig,
        uint256 fillAmount,
        bytes memory takerData
    ) private returns (uint256[] memory outs) {
        bytes32 orderHash = order.hash();
        FillCtx memory ctx;
        _gateFillState(order, orderHash, ctx);
        // The permit is an external call, so it goes INSIDE the guard — only the
        // read-only gate above may precede it. See {Base._enter}.
        _enter();
        PERMIT3.permitBatchWithWitnessIfNeeded(order.maker, batch, orderHash, OrderHash.WITNESS_TYPESTRING, sig);
        outs = _fillCore(
            order, fillAmount, msg.sender, address(0), address(0), "",
            CallbackMode.PreDelivery, takerData, false, ctx
        );
        _exit();
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
            try this.fillSelf(orders[i], sigs[i], fillAmounts[i], filler, takerDatas[i]) returns (
                uint256[] memory outs
            ) {
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
    ) external returns (uint256[] memory outs) {
        if (msg.sender != address(this)) revert OnlySelf();
        bytes32 orderHash = order.hash();
        FillCtx memory ctx;
        _gateFillState(order, orderHash, ctx);
        _verifySignature(orderHash, sig, order.maker);
        outs = _fillCore(
            order, fillAmount, filler, address(0), address(0), "", CallbackMode.PreDelivery, takerData, false, ctx
        );
    }

    /// @notice Single-signature fill whose TAKE item is funded by a ONE-SHOT
    ///         `PermitTake` instead of a standing taker allowance — so the maker's
    ///         borrow/withdraw authority is consumed by this fill and no ALLOWANCE
    ///         survives it. The permit's witness is this order's hash, so the one
    ///         signature authorises both the order and the position draw.
    ///
    ///  ⚠ WHAT DOES NOT SURVIVE, AND WHAT DOES. The taker AUTHORITY is genuinely
    ///  one-shot: nothing is written to the taker book, so no later fill — through
    ///  this entry or any other — can draw the maker's position again without a
    ///  fresh signature. The ORDER is a different object and outlives the permit.
    ///  A successful fill writes `filled[orderHash]` through {OrderState._openFill},
    ///  and {Signatures._verifySignature} skips re-verification once that counter is
    ///  non-zero — so any REMAINING size is thereafter fillable with an arbitrary
    ///  `sig`, funded by the maker's standing TOKEN allowances.
    ///
    ///  That is correct, not a gap, and it is the same rule every other entry runs
    ///  under: a non-zero counter proves some earlier fill presented valid
    ///  authorization for that maker-committing hash, and here the permit's witness
    ///  IS the order hash. It is also close to unreachable, because
    ///  {Base._takeByPermit} requires `permit.amount == slice` and a pro-rata slice
    ///  below the permit's amount cannot match — so this entry is implicitly
    ///  full-fill and normally leaves no remainder at all. A maker who wants the
    ///  remainder of a partly-filled order to stop dead should use {cancelOrder},
    ///  exactly as an EIP-1271 maker must.
    ///
    ///  Shape: the order carries its TAKE item exactly as it would for {fill}; only
    ///  the funding of that item changes ({Base._runItem} dispatches through
    ///  `permitTakeWithWitness` when {FillCtx.permitTake} is set). Everything else —
    ///  output delivery, the item loop's proceeds accounting, the solver payout,
    ///  invariants — is the ordinary path, unchanged and unduplicated.
    ///
    ///  The maker's authorization is verified INSIDE that dispatch rather than up
    ///  front. That is safe because the whole fill is atomic: a bad signature reverts
    ///  the `_openFill` counter write and every transfer with it.
    function fillWithPermitTake(
        Order calldata order,
        IPermit3.PermitTake calldata permit,
        bytes calldata sig,
        uint256 fillAmount
    ) external nonReentrant returns (uint256[] memory outs) {
        bytes32 orderHash = order.hash();
        if (fillAmount == 0) revert ZeroFill();
        if (block.timestamp > DutchAuction.expiry(order)) revert OrderExpired();
        FillCtx memory ctx;
        _gateOrder(order, orderHash, msg.sender, "", ctx);
        _openFill(order, fillAmount, msg.sender, "", ctx);
        ctx.permitTake = abi.encode(permit, sig);
        outs = _settleForward(order, ctx, address(0), "", "");
        // The permit MUST have been consumed — it is this fill's only authorization.
        // See the note in {Base._takeByPermit}.
        if (ctx.permitTake.length != 0) revert PermitTakeNotConsumed();
    }

    // ──────────────────── Custom fill ────────────────────

    /// @notice The CUSTOM-FILL entry: fill UP TO `fillAmount` — clamped to the
    ///         order's remaining size instead of reverting {OverFill} when a
    ///         competing fill landed first — and return full both-sides accounting.
    ///         The 0x-v4 `fillLimitOrder` shape.
    ///
    ///  Four things a caller assembling its own calldata wants and a plain {fill}
    ///  does not give it: a size that is CLAMPED rather than reverted, its own payout
    ///  `recipient`, its own `minBumpBps` price floor, and per-leg receipts back. A DEX
    ///  aggregator routing one hop is the obvious consumer, but an RFQ desk, a
    ///  smart-order router or any other caller building the fill itself wants exactly
    ///  the same four, so nothing here is specific to aggregation.
    ///
    ///  ⚠ The race tolerance covers IDENTITY orders only. A fill-module order
    ///  (`order.fillModule != 0`) passes through UNCLAMPED and can still revert
    ///  {OverFill} on a race — only the module knows what a partial acceptance of
    ///  its unit means, so the core cannot size it. See the clamping note below and
    ///  {IFillModule}. A caller that treats this entry as never-reverting must either
    ///  skip module orders or catch the revert itself.
    ///
    ///  Clamping (identity orders only): the executed delta is
    ///  `min(fillAmount, total - filled)`. A fill-module order's `fillAmount` is a
    ///  PROPOSAL in module units, so it passes through unclamped — the module
    ///  already receives `prevFilled` and owns its own clamp (see {IFillModule}).
    ///  A cancelled or fully-filled order still reverts with the classic errors
    ///  ({OrderCancelled} / {OverFill}): a dead hop must fail loudly, and callers
    ///  splitting across orders get skip semantics from their own adapter loop.
    ///  The maker-signed `minFillAnchor` floor still gates the CLAMPED delta
    ///  ({FillTooSmall}) — callers should skip orders whose remaining size is below
    ///  the floor (the lens reports it).
    ///
    /// @param  recipient Where the filler's input-leg proceeds are sent;
    ///         `address(0)` = `msg.sender`. Destination only — exclusivity,
    ///         validators, and output-leg pulls all stay on `msg.sender` — so this
    ///         grants no new authority (it routes money the filler could forward
    ///         anyway, saving the extra transfer on a route's last hop).
    /// @param  minBumpBps The filler's PRICE FLOOR on the resolved shared decay
    ///         bump, in bps of the band; `0` = no floor (the pre-existing
    ///         behaviour). The scalar is exact because every leg price is monotone
    ///         in the one shared bump — outputs (what the filler delivers) FALL
    ///         with it and inputs (what the filler receives) RISE — so "bump ≥ my
    ///         quote's bump" IS "price ≥ my quoted price", across every leg of both
    ///         baskets at once (the Pendle `maxTaking` / 0x taker-amount guard,
    ///         without a per-leg array). Three movers can shift the tick maker-ward
    ///         between quote and inclusion, and all three are covered, since the
    ///         check reads the very bump the fill priced at (the pinned
    ///         {FillCtx.bump} when one was pinned):
    ///           • an oracle-pegged {IPriceModule} re-reading its feed;
    ///           • a FALLING basefee shrinking the gas bump; and
    ///           • a FALLING basefee widening a PRIORITY bid. The bid is
    ///             `tx.gasprice - block.basefee - baseline`, and only the first term
    ///             is the filler's. A solver that names a gas price expecting to bid
    ///             the difference over the CURRENT basefee bids MORE than that if the
    ///             basefee drops before its transaction lands — so a priority order is
    ///             not "the filler's own bid" end to end, and a filler that wants its
    ///             quote to hold should pass this floor rather than skip it. (The
    ///             maker's signed `start` bounds the exposure either way, which the
    ///             unbounded-scaling designs do not.)
    ///         Quote the floor from {SettlementLens.previewFill} — at the gas price
    ///         you will actually send. Time decay and soft-exclusivity need no
    ///         protection: time moves the bump filler-ward and the override is signed
    ///         in the order. Reverts {BumpTooLow}.
    /// @param  takerData Filler-supplied blob for validators/invariants (and the
    ///         fill proposal for a fill-module order); `""` for plain orders.
    /// @return delta     The anchor-unit progress actually executed (post-clamp).
    /// @return received  Per-`legsIn` amounts paid to `recipient` — the filler's
    ///         receipts, exact because they are the very words the payout moved
    ///         (see {FillCtx.receipts}), not a second derivation of them.
    /// @return paid      Per-`legsOut` amounts the filler delivered.
    function fillUpTo(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmount,
        address recipient,
        uint256 minBumpBps,
        bytes calldata takerData
    ) external returns (uint256 delta, uint256[] memory received, uint256[] memory paid) {
        FillCtx memory ctx;
        // The whole prologue lives in a helper so `orderHash` never enters THIS frame:
        // with `minBumpBps`, `recipient` and `ctx` all live across the fill, the LEGACY
        // (non-via-IR) profile has no stack slot left for it. The helper also hoists the
        // clamp out of the `_fillCore` argument list for the same reason.
        fillAmount = _openCustomFill(order, sig, fillAmount, ctx);
        paid = _fillCore(
            order,
            fillAmount,
            msg.sender,
            recipient,
            address(0),
            "",
            CallbackMode.PreDelivery,
            takerData,
            true, // the custom-fill entry is the one caller that returns receipts
            ctx
        );
        if (minBumpBps != 0) {
            // The bump the fill actually priced at: the pinned one when the order
            // pins ({FillCtx.bump} — price module / priority auction), else the
            // clock, deterministic within the tx so re-reading it here is exact.
            // Checked AFTER the fill so a pinning order's price module is called
            // ONCE — the revert unwinds everything either way, and the happy path
            // (the only one anyone pays for) is one compare.
            uint256 bump = ctx.bump != 0 ? ctx.bump - 1 : DutchAuction.bumpBps(order);
            if (bump < minBumpBps) revert BumpTooLow();
        }
        unchecked {
            delta = ctx.newFilled - ctx.prevFilled; // _openFill guarantees newFilled >= prevFilled
        }
        received = ctx.receipts; // recorded by the payout itself — see {FillCtx.receipts}
        _exit();
    }

    /// @dev {fillUpTo}'s prologue: hash, the READ-ONLY fill-state gate, arm the guard,
    ///      verify, clamp. Kept together (and out of `fillUpTo`'s frame) so the order
    ///      hash dies here — see the note at the call site. The gate before {Base._enter}
    ///      is the point of the ordering, not an accident; {Base._enter} states the rule.
    ///
    ///      Named for {fillUpTo}'s own framing — a CALLER-SUPPLIED fill, not an
    ///      aggregator-specific one; see that entry's notice for the four things it
    ///      offers and who wants them.
    function _openCustomFill(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmount,
        FillCtx memory ctx
    ) private returns (uint256) {
        bytes32 orderHash = order.hash();
        _gateFillState(order, orderHash, ctx);
        _enter();
        _verifySignature(orderHash, sig, order.maker);
        return _clampToRemaining(order, orderHash, fillAmount);
    }

    /// @dev The order-progress clamp: cap an identity fill at the order's
    ///      remaining size. Costs one warm re-SLOAD of `filled` on this path only
    ///      — {_openFill} and its over-fill cap stay untouched as the universal
    ///      backstop. Cancelled (`filled == max`) and fully-filled orders take the
    ///      `prev >= total` branch and fall through unclamped to {_openFill}'s
    ///      precise reverts. Fill-module orders pass through: `fillAmount` is a
    ///      module-unit proposal only the module can size (it gets `prevFilled`).
    function _clampToRemaining(Order calldata order, bytes32 orderHash, uint256 fillAmount)
        internal
        view
        returns (uint256)
    {
        if (order.fillModule != address(0)) return fillAmount;
        // Clamping is ALREADY exactly right for a {Proportional} anchor and needs
        // no special case: such an order is unfilled (`prev == 0`), so `rem` is the
        // freshly resolved anchor, and a caller asking for more than the whole thing
        // is trimmed to precisely the one size a proportional fill accepts.
        // Asking for LESS stays below it and is rejected downstream as the partial
        // fill it is.
        uint256 total = order.fillTotal != 0 ? order.fillTotal : OrderGates.anchorTotal(order);
        uint256 prev = filled[orderHash];
        if (prev < total) {
            unchecked {
                uint256 rem = total - prev; // prev < total
                if (fillAmount > rem) return rem;
            }
        }
        return fillAmount;
    }

    /// @dev Also returns the fill's resolved {FillCtx} so a caller can account the
    ///      settled amounts (e.g. `fillUpTo` recomputes the filler's receipts via
    ///      {Pricing.inputOwed}) — a free memory-pointer return the classic
    ///      entrypoints simply discard. `payTo` redirects the input-leg payout
    ///      (`address(0)` = the filler); see {FillCtx.payTo}.
    function _fillCore(
        Order calldata order,
        uint256 fillAmount,
        address filler,
        address payTo,
        address callbackTarget,
        bytes memory callbackData,
        CallbackMode mode,
        bytes memory takerData,
        bool wantReceipts,
        FillCtx memory ctx
    ) internal returns (uint256[] memory outs) {
        if (fillAmount == 0) revert ZeroFill();
        // Note: the anti-dust floor is checked in _openFill against the resolved
        // `delta` (the actual progress), not the requested `fillAmount` — for a
        // fill-module order the two can differ, and minFillAnchor must gate the
        // real advance. For an identity order delta == fillAmount, so behavior is
        // unchanged.
        if (block.timestamp > DutchAuction.expiry(order)) revert OrderExpired();

        // `ctx` arrives seeded by {OrderState._gateFillState}, which every caller runs
        // before it arms the reentrancy guard — that ordering is what makes a lost
        // priority-fee race cheap. The rest of the gate runs here. See {Base._enter}.
        _gateOrderPost(order, filler, takerData, ctx);

        // `takerData` doubles as the filler's fill proposal for a fill-module
        // order (see {IFillModule}); a plain fungible order ignores it here.
        _openFill(order, fillAmount, filler, takerData, ctx);
        if (payTo != address(0)) ctx.payTo = payTo;
        // OPT-IN. Only `fillUpTo` returns per-leg receipts, and allocating the array
        // unconditionally measured +453 gas on every ordinary fill — more than the
        // 795 the custom-fill path saves on a simple order. Behind the flag the hot
        // path pays one stack word and one length test per leg; `fillUpTo` skips a
        // second {Pricing} pass worth 795 gas on a fixed leg and 3,583 on a two-leg
        // order with a rising leg.
        if (wantReceipts) {
            ctx.receipts = new uint256[](PackedArrays.validateFixed(order.legsIn, PackedArrays.LEG_IN_STRIDE));
        }

        // The SAME takerData feeds the post-execution invariants (via the settle
        // helper), so a validator and an invariant see an identical filler blob.
        // Bit 1 = typed: swap the callback PAYLOAD, never the ordering, so the two
        // settle flows below are untouched and still see only bytes.
        if (uint8(mode) & 2 == 2) callbackData = _typedPayload(order, ctx, callbackData);
        outs = uint8(mode) & 1 == 1
            ? _settlePostInputs(order, ctx, callbackTarget, callbackData, takerData)
            : _settleForward(order, ctx, callbackTarget, callbackData, takerData);
    }

    /// @dev `EXECUTOR.execute(target, data)`, hand-encoded.
    ///      The typed call makes solc emit a general `(address,bytes)` encoder; the
    ///      layout is fixed and known here, so it is four `mstore`s and a copy.
    ///      Reverts bubble raw so the executor's `CallbackFailed(bytes)` survives.
    ///
    ///      `internal`, not `private`, ON PURPOSE: {Batch}'s CALL step makes the SAME
    ///      call and used to make it typed, which emitted that general encoder a
    ///      SECOND time. Routing both through here measured −103 bytes of Settlement
    ///      (2026-08-25). Any new call site for the executor belongs here too.
    function _execute(address target, bytes memory data) internal {
        address executor = address(EXECUTOR);
        bytes4 sel = SolverCallbackExecutor.execute.selector;
        /// @solidity memory-safe-assembly
        assembly {
            let len := mload(data)
            let p := mload(0x40)
            mstore(p, sel)
            mstore(add(p, 0x04), target)
            mstore(add(p, 0x24), 0x40) // offset to the bytes tail
            mstore(add(p, 0x44), len)
            let src := add(data, 0x20)
            let dst := add(p, 0x64)
            for { let i := 0 } lt(i, len) { i := add(i, 0x20) } { mstore(add(dst, i), mload(add(src, i))) }
            // Bubble RAW, so every revert shape survives unchanged — a `require`
            // string (`Error(string)`), a custom error selector, `Panic(uint256)`,
            // and a bare `revert()` (returndatasize 0). Same behaviour solc emits
            // for a typed external call, so the taxonomy callers rely on is intact.
            //
            // Copied to `p` — our own buffer past the free pointer — NOT to offset
            // 0: scratch is only 0x00..0x3f, so a returndata larger than 64 bytes
            // would clobber the free memory pointer at 0x40 and break the
            // memory-safe annotation on this block. Harmless in isolation because
            // the revert is immediate, but it is a lie to the optimizer, and the
            // deploy profile is via-IR.
            if iszero(call(gas(), executor, 0, p, add(0x64, len), 0, 0)) {
                let rds := returndatasize()
                returndatacopy(p, 0, rds)
                revert(p, rds)
            }
        }
    }

    /// @dev The TYPED callback payload, in its own frame (the loop's locals push
    ///      {_fillCore} past the legacy-profile stack limit inline).
    ///
    ///      Prices the outputs EAGERLY so the taker receives AMOUNTS, not the raw
    ///      bump — see the ⚠ on {ISettlementCallback}: a clock-priced order leaves
    ///      `ctx.bump` at its "not pinned" sentinel of 0, so the bump alone tells a
    ///      taker nothing for the dominant order shape. `_deliverOutputs` re-prices
    ///      from the same pinned `ctx`, so the two cannot disagree.
    ///
    ///      ⚠ MEASURED 2026-08-23, and the cost is NOT where it looks. This helper
    ///      costs ~562 bytes, of which only ~180 is the loop and the encoder: the
    ///      rest is {_fillCore} sitting on a codegen cliff, where adding any
    ///      memory-returning call to its ten-argument frame cascades through the
    ///      optimizer's inlining. Things that did NOT help, each measured:
    ///        • dropping the `outputAt` call            −10 bytes
    ///        • `uint256[]` → a scalar in the encoder    −4 bytes
    ///        • building at the two callback sites      +43 bytes (worse)
    ///        • bundling the callback triple in a struct +543 bytes
    ///        • packing it into `bytes calldata`          +226 bytes
    ///        • carrying it on {FillCtx} (no new slots)   +863 bytes
    ///        • `bytes memory` + `abi.decode`           +1,030 bytes
    ///        • `encodePacked` + an ASSEMBLY decoder      +909 bytes
    ///      THE RULE, isolated 2026-08-23: it is not the encoding, it is the FRAME.
    ///      In the assembly variant the `encodePacked` cost only 64 bytes — the
    ///      other 909 was the three locals the decode introduced into {_fillCore}'s
    ///      BODY. Parameters are cheap because they live in the calling convention;
    ///      anything added to the body's live set pushes this function over a
    ///      codegen cliff and cascades through the optimizer's inlining. That is
    ///      also why {_typedPayload} costs ~562 when its own work is ~180. Do not
    ///      try to consolidate the parameter list — five variants were measured and
    ///      all of them LOSE. The only lever that can work is removing live values
    ///      from the body.
    ///      Do not micro-optimise this function; the win, if there is one, is in
    ///      {_fillCore}'s frame.
    function _typedPayload(Order calldata order, FillCtx memory ctx, bytes memory userData)
        private
        view
        returns (bytes memory)
    {
        uint256 nOut = PackedArrays.validateFixed(order.legsOut, PackedArrays.LEG_OUT_STRIDE);
        uint256[] memory priced = new uint256[](nOut);
        for (uint256 j; j < nOut;) {
            priced[j] = order.outputAt(ctx, j);
            unchecked {
                ++j;
            }
        }
        return abi.encodeCall(
            ISettlementCallback.onSettlementFill,
            (ctx.orderHash, ctx.prevFilled, ctx.newFilled, ctx.anchor, _pricedInputs(order, ctx), priced, userData)
        );
    }

    /// @dev The typed callback's INPUT half — this fill's per-`legsIn` amounts, the
    ///      very numbers `_payInputsToSolver` is about to pay out.
    ///
    ///      ⚠ IN ITS OWN FRAME, AND THAT IS THE WHOLE COST STORY. Same lesson as
    ///      {_typedPayload}'s own note — it is the FRAME, not the encoding. Split out
    ///      like this the feature costs +41 bytes of Settlement; every other shape
    ///      measured is worse, several of them by an order of magnitude. Figures are
    ///      `make size-check` deltas against a 24,548-byte baseline, all taken at the
    ///      `core-deploy` `optimizer_runs` of the day (400), 2026-08-25:
    ///        • THIS SHAPE, own frame                          +41
    ///        • both loops inline in {_typedPayload}            +91
    ///        • `nIn` folded into `new uint256[](...)`          +91
    ///        • one shared `_pricedLegs(.., bool outputs)`     +100  (solc re-inlines it
    ///                                                               at both call sites,
    ///                                                               so nothing is shared)
    ///        • `countUnchecked` instead of `validateFixed`    +101  (yes, the WEAKER
    ///                                                               check is bigger)
    ///        • writing into a pre-allocated `ctx.receipts`    +487  (the `wantReceipts ||`
    ///                                                               it needs in
    ///                                                               {_fillCore}'s body is
    ///                                                               a codegen cliff)
    ///      And the {Pricing.inputOwed} call itself is FREE: swapping it for a constant
    ///      measured +9 bytes — i.e. this third inline site shares with the two that
    ///      were already there. Do not try to save bytes by dropping the pricing.
    ///
    ///      ⚠ THE ABSOLUTE FIGURES ABOVE ARE WARM-CACHE and ran ~110 bytes low; the
    ///      shape RANKING is what they establish and it was re-confirmed clean. The
    ///      authoritative clean-build ladder — including the fact that the tree did
    ///      not fit BEFORE this work — is at `optimizer_runs` in foundry.toml. Wipe
    ///      `out/core-deploy` before trusting any size number you take here.
    ///
    ///      ⚠ EVEN AT +41 IT DID NOT FIT — the tree had no headroom to give. The
    ///      bytes were found by deleting two DUPLICATE ABI ENCODERS ({Batch} was
    ///      re-encoding the call {_execute} already hand-encodes; the three item ops now
    ///      share {Base._callWithTail}), not by touching `optimizer_runs`, which stayed
    ///      at 400. The story and what did NOT work are at the dial in foundry.toml.
    ///
    ///      ⚠ GAS. Pricing + encoding this array costs +4,233 on a one-input-leg typed
    ///      fill (`test_typed_contextMatchesTheFill` 310,716 → 314,949) and is paid ONLY
    ///      by the `*Typed` modes — an untyped fill measured −43, i.e. unchanged. The
    ///      taker's alternative is a second {Pricing} pass of its own (795 gas on one
    ///      fixed leg, 3,583 on a two-leg order with a rising leg) plus carrying the
    ///      order in its calldata, which is the cost this mode exists to remove.
    function _pricedInputs(Order calldata order, FillCtx memory ctx) private view returns (uint256[] memory owed) {
        uint256 nIn = PackedArrays.validateFixed(order.legsIn, PackedArrays.LEG_IN_STRIDE);
        owed = new uint256[](nIn);
        for (uint256 i; i < nIn;) {
            owed[i] = order.inputOwed(ctx, i);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Snapshot every output leg's recipient balance of that leg's token, for a
    ///      {DutchAuction.deltaVerifyOutputs} order. Indexed 1:1 with `legsOut`, taken
    ///      at fill start (before the callback) so the later check is a true delta.
    ///      Recipient resolution mirrors `_deliverOutputs`: `address(0)` ⇒ the maker.
    ///
    ///      ALSO THE SHAPE GATE for this mode, and both checks are load-bearing rather
    ///      than hygiene — see {DeltaVerifyDuplicateLeg} / {DeltaVerifySameToken}. A
    ///      per-leg balance delta is only a sound measure of "what this leg delivered"
    ///      when each leg's (token, recipient) balance moves for that leg ALONE. Both
    ///      shapes are already reported malformed by {SettlementLens.validateOrder} for
    ///      every order, but the lens is off-chain advice; on a delta-verify order they
    ///      are exploitable, so they are enforced here. Runs only for this mode, so the
    ///      nominal hot path pays nothing.
    function _snapshotOutRecipients(Order calldata order) internal view returns (uint256[] memory before) {
        uint256 n = PackedArrays.validateFixed(order.legsOut, PackedArrays.LEG_OUT_STRIDE);
        uint256 nIn = PackedArrays.validateFixed(order.legsIn, PackedArrays.LEG_IN_STRIDE);
        before = new uint256[](n);
        // The decoded (token, recipient) pairs are CACHED rather than re-decoded for
        // the duplicate scan: `PackedArrays.legOut` is an internal library call that
        // the optimizer inlines at every call site, so a second decode site costs far
        // more bytecode than the two memory arrays do (the +2,430-byte lesson recorded
        // on {Pricing.inputOwed}). One decode site, one pass.
        address[] memory toks = new address[](n);
        address[] memory recips = new address[](n);
        for (uint256 j; j < n;) {
            (address token,,, address to) = PackedArrays.legOut(order.legsOut, j);
            address recipient = to == address(0) ? order.maker : to;
            // No earlier leg may share this (token, recipient) — one delivery would
            // otherwise satisfy both legs' checks.
            for (uint256 k; k < j;) {
                if (toks[k] == token && recips[k] == recipient) revert DeltaVerifyDuplicateLeg();
                unchecked {
                    ++k;
                }
            }
            // A maker-bound leg whose token is also pulled FROM the maker as an input
            // would measure net, not gross.
            if (recipient == order.maker) {
                for (uint256 i; i < nIn;) {
                    if (PackedArrays.legInToken(order.legsIn, i) == token) revert DeltaVerifySameToken();
                    unchecked {
                        ++i;
                    }
                }
            }
            toks[j] = token;
            recips[j] = recipient;
            before[j] = SafeTransferLib.balanceOf(token, recipient);
            unchecked {
                ++j;
            }
        }
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
        // DELTA-VERIFY delivery: snapshot the output recipients BEFORE the callback
        // delivers, so `_deliverOutputs` can verify the measured delta. `outBefore`
        // stays a NULL array (no allocation) on the dominant nominal path — the hot
        // path pays only the one `timing` bit test.
        uint256[] memory outBefore;
        if (DutchAuction.deltaVerifyOutputs(order)) outBefore = _snapshotOutRecipients(order);
        if (callbackTarget != address(0)) _execute(callbackTarget, callbackData);

        outs = _deliverOutputs(order, ctx, outBefore);

        // Snapshot each tokenIn before items so the payout uses ONLY this fill's
        // TAKE proceeds — never a pre-existing/donated Settlement balance. Skipped
        // for item-free orders: with no TAKE legs there are no proceeds, so the
        // snapshot + the balanceOf re-read in `_payInputsToSolver` would just burn
        // two STATICCALLs per input leg on every plain swap.
        bool hasItems = PackedArrays.countUnchecked(order.items) != 0;
        uint256[] memory tokenInBefore = hasItems ? _snapshotInputs(order.legsIn) : new uint256[](0);
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
        if (PackedArrays.countUnchecked(order.items) != 0) revert ReverseModeRequiresNoItems();
        // DELTA-VERIFY delivery: snapshot output recipients before anything moves
        // (null array — no allocation — on the nominal path). Taken before the input
        // pull too, so a same-token in/out edge still measures a true delta.
        uint256[] memory outBefore;
        if (DutchAuction.deltaVerifyOutputs(order)) outBefore = _snapshotOutRecipients(order);
        // No items ⇒ no TAKE proceeds ⇒ proceeds are 0 by construction, so
        // `_payInputsToSolver` (hasItems=false) pulls exactly `owed` from the
        // maker → solver with no balance snapshot needed.
        _payInputsToSolver(order, ctx, new uint256[](0), false);
        if (callbackTarget != address(0)) _execute(callbackTarget, callbackData);
        outs = _deliverOutputs(order, ctx, outBefore);
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
    function _deliverOutputs(Order calldata order, FillCtx memory ctx, uint256[] memory outBefore)
        internal
        returns (uint256[] memory outs)
    {
        uint256 n = PackedArrays.validateFixed(order.legsOut, PackedArrays.LEG_OUT_STRIDE);
        outs = new uint256[](n);
        // DELTA-VERIFY delivery ({DutchAuction.deltaVerifyOutputs}): the filler already
        // delivered each leg out-of-band (its callback), so verify the recipient's
        // measured balance increase instead of pushing from the filler. `outBefore`
        // was snapshotted at fill start.
        bool verify = DutchAuction.deltaVerifyOutputs(order);
        for (uint256 j; j < n;) {
            // Amount (incl. the maker-leg soft-exclusivity override) — see
            // {Pricing.outputAt}. The maker-leg test is recomputed here
            // only to route the transfer (never a fee leg's comp to a third party).
            uint256 amt = order.outputAt(ctx, j);
            if (amt != 0) {
                // One decode for both field reads — see {Pricing.outputAt}.
                (address legToken,,, address to) = PackedArrays.legOut(order.legsOut, j);
                address recipient = to == address(0) || to == order.maker ? order.maker : to;
                outs[j] = amt;
                if (verify) {
                    // The required amount is the SAME priced `amt` — every pricing mode
                    // (dutch/priority/module/partial) flows through unchanged. Measured
                    // delta ≥ priced amount, fee-on-transfer / rebasing safe.
                    uint256 bal = SafeTransferLib.balanceOf(legToken, recipient);
                    if (bal < outBefore[j] || bal - outBefore[j] < amt) revert DeltaTooLow();
                } else {
                    Permit3TransferLib.transferFromWithFallback(PERMIT3, legToken, ctx.filler, recipient, amt);
                }
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
    function _payInputsToSolver(Order calldata order, FillCtx memory ctx, uint256[] memory tokenInBefore, bool hasItems)
        internal
    {
        address maker = order.maker;
        // Payment destination — `ctx.filler` on every classic path; `fillUpTo`'s
        // `recipient` when redirected (see {FillCtx.payTo}). Destination only:
        // authority (exclusivity, validators, output pulls) stays on `ctx.filler`.
        address payTo = ctx.payTo;
        // MEASURED, do not "optimize" by borrowing the count from `tokenInBefore`.
        // When `hasItems` that array IS `_snapshotInputs(order.legsIn)`, so its length
        // is already the validated leg count and `hasItems ? tokenInBefore.length :
        // validateFixed(...)` looks like a free saving. It is not: the branch costs
        // +23 gas on EVERY item-free fill — the dominant shape — to save ~230 on an
        // item-bearing one. Same trade the `receipts` array above resolves the same
        // way. 2026-08-09: hot path +23 with it, +0 without.
        uint256 n = PackedArrays.validateFixed(order.legsIn, PackedArrays.LEG_IN_STRIDE);
        for (uint256 i; i < n;) {
            uint256 owed = order.inputOwed(ctx, i); // see {Pricing.inputOwed}
            if (ctx.receipts.length != 0) ctx.receipts[i] = owed; // see {FillCtx.receipts}
            address tokenIn = PackedArrays.legInToken(order.legsIn, i);
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
            } else if (proceeds >= owed) {
                SafeTransferLib.safeTransfer(tokenIn, payTo, owed);
                unchecked {
                    uint256 surplus = proceeds - owed; // proceeds >= owed
                    if (surplus > 0) SafeTransferLib.safeTransfer(tokenIn, maker, surplus);
                }
            } else {
                if (proceeds > 0) SafeTransferLib.safeTransfer(tokenIn, payTo, proceeds);
                unchecked {
                    Permit3TransferLib.transferFromWithFallback(PERMIT3, tokenIn, maker, payTo, owed - proceeds); // owed > proceeds
                }
            }
            unchecked {
                ++i;
            }
        }
    }
}
