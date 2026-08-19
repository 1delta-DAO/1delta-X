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

/// @title Core
/// @notice The single-order fill path — the HOT PATH. Public entrypoints (`fill`,
///         `fillWithCallback`, `fillWithPermit`, `batchFill`, `fillSelf`, and the
///         aggregator entry `fillUpTo`) and the per-order settle flow (`_fillCore`
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
        nonReentrant
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
        nonReentrant
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
        _verifySignature(orderHash, sig, order.maker);
        (outs,) = _fillCore(
            order, orderHash, fillAmount, msg.sender, address(0), address(0), "",
            CallbackMode.PreDelivery, takerData, false
        );
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
    ) external nonReentrant returns (uint256[] memory fillAmountsOut) {
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
        _verifySignature(orderHash, sig, order.maker);
        (outs,) = _fillCore(
            order, orderHash, fillAmount, msg.sender, address(0), callbackTarget, callbackData, mode, takerData, false
        );
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
    ) external nonReentrant returns (uint256[] memory fillAmountsOut) {
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
        PERMIT3.permitBatchWithWitnessIfNeeded(order.maker, batch, orderHash, OrderHash.WITNESS_TYPESTRING, sig);
        (outs,) = _fillCore(
            order, orderHash, fillAmount, msg.sender, address(0), address(0), "",
            CallbackMode.PreDelivery, takerData, false
        );
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
        _verifySignature(orderHash, sig, order.maker);
        (outs,) = _fillCore(
            order, orderHash, fillAmount, filler, address(0), address(0), "", CallbackMode.PreDelivery, takerData, false
        );
    }

    /// @notice Single-signature fill whose TAKE item is funded by a ONE-SHOT
    ///         `PermitTake` instead of a standing taker allowance — so the maker's
    ///         borrow/withdraw authority is consumed by this fill and NOTHING
    ///         survives it. The permit's witness is this order's hash, so the one
    ///         signature authorises both the order and the position draw.
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
        uint256 overrideBps = OrderGates.exclusivityOverride(order, msg.sender);
        if (_isNonceCancelled(order.maker, order.nonce)) revert NonceCancelled();
        _runValidators(order, msg.sender, "");
        FillCtx memory ctx = _openFill(order, orderHash, fillAmount, overrideBps, msg.sender, "");
        ctx.permitTake = abi.encode(permit, sig);
        outs = _settleForward(order, ctx, address(0), "", "");
        // The permit MUST have been consumed — it is this fill's only authorization.
        // See the note in {Base._takeByPermit}.
        if (ctx.permitTake.length != 0) revert PermitTakeNotConsumed();
    }

    // ──────────────────── Aggregator fill ────────────────────

    /// @notice The DEX-aggregator entry: fill UP TO `fillAmount` — clamped to the
    ///         order's remaining size instead of reverting {OverFill} when a
    ///         competing fill landed first — and return full both-sides accounting.
    ///         The 0x-v4 `fillLimitOrder` shape.
    ///
    ///  ⚠ The race tolerance covers IDENTITY orders only. A fill-module order
    ///  (`order.fillModule != 0`) passes through UNCLAMPED and can still revert
    ///  {OverFill} on a race — only the module knows what a partial acceptance of
    ///  its unit means, so the core cannot size it. See the clamping note below and
    ///  {IFillModule}. An aggregator that treats this entry as never-reverting must
    ///  either skip module orders or catch the revert itself.
    ///
    ///  Clamping (identity orders only): the executed delta is
    ///  `min(fillAmount, total - filled)`. A fill-module order's `fillAmount` is a
    ///  PROPOSAL in module units, so it passes through unclamped — the module
    ///  already receives `prevFilled` and owns its own clamp (see {IFillModule}).
    ///  A cancelled or fully-filled order still reverts with the classic errors
    ///  ({OrderCancelled} / {OverFill}): a dead hop must fail loudly, and callers
    ///  splitting across orders get skip semantics from their own adapter loop.
    ///  The maker-signed `minFillAnchor` floor still gates the CLAMPED delta
    ///  ({FillTooSmall}) — aggregators should skip orders whose remaining size is
    ///  below the floor (the lens reports it).
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
    ///         without a per-leg array). Only two movers can shift the tick
    ///         maker-ward between quote and inclusion — an oracle-pegged
    ///         {IPriceModule} and a falling basefee shrinking the gas bump — and
    ///         both are covered, since the check reads the very bump the fill
    ///         priced at (the pinned {FillCtx.bump} when one was pinned). Quote the
    ///         floor from {SettlementLens.previewFill}. Time decay, the priority
    ///         auction, and soft-exclusivity need no protection: time moves the
    ///         bump filler-ward, the priority bid is the filler's own, and the
    ///         override is signed in the order. Reverts {BumpTooLow}.
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
    ) external nonReentrant returns (uint256 delta, uint256[] memory received, uint256[] memory paid) {
        bytes32 orderHash = order.hash();
        _verifySignature(orderHash, sig, order.maker);
        // Hoisted out of the `_fillCore` argument list: nested there, the extra
        // `minBumpBps` local pushes the LEGACY (non-via-IR) profile over the
        // stack limit; as its own statement, `fillAmount` dies before the call.
        fillAmount = _clampToRemaining(order, orderHash, fillAmount);
        FillCtx memory ctx;
        (paid, ctx) = _fillCore(
            order,
            orderHash,
            fillAmount,
            msg.sender,
            recipient,
            address(0),
            "",
            CallbackMode.PreDelivery,
            takerData,
            true // the aggregator entry is the one caller that returns receipts
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
        // freshly resolved anchor, and an aggregator asking for more than the whole
        // thing is trimmed to precisely the one size a proportional fill accepts.
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
        bytes32 orderHash,
        uint256 fillAmount,
        address filler,
        address payTo,
        address callbackTarget,
        bytes memory callbackData,
        CallbackMode mode,
        bytes memory takerData,
        bool wantReceipts
    ) internal returns (uint256[] memory outs, FillCtx memory ctx) {
        if (fillAmount == 0) revert ZeroFill();
        // Note: the anti-dust floor is checked in _openFill against the resolved
        // `delta` (the actual progress), not the requested `fillAmount` — for a
        // fill-module order the two can differ, and minFillAnchor must gate the
        // real advance. For an identity order delta == fillAmount, so behavior is
        // unchanged.
        if (block.timestamp > DutchAuction.expiry(order)) revert OrderExpired();

        uint256 overrideBps = OrderGates.exclusivityOverride(order, filler);
        if (_isNonceCancelled(order.maker, order.nonce)) revert NonceCancelled();
        _runValidators(order, filler, takerData);

        // `takerData` doubles as the filler's fill proposal for a fill-module
        // order (see {IFillModule}); a plain fungible order ignores it here.
        ctx = _openFill(order, orderHash, fillAmount, overrideBps, filler, takerData);
        if (payTo != address(0)) ctx.payTo = payTo;
        // OPT-IN. Only `fillUpTo` returns per-leg receipts, and allocating the array
        // unconditionally measured +453 gas on every ordinary fill — more than the
        // 795 the aggregator path saves on a simple order. Behind the flag the hot
        // path pays one stack word and one length test per leg; `fillUpTo` skips a
        // second {Pricing} pass worth 795 gas on a fixed leg and 3,583 on a two-leg
        // order with a rising leg.
        if (wantReceipts) {
            ctx.receipts = new uint256[](PackedArrays.validateFixed(order.legsIn, PackedArrays.LEG_IN_STRIDE));
        }

        // The SAME takerData feeds the post-execution invariants (via the settle
        // helper), so a validator and an invariant see an identical filler blob.
        outs = mode == CallbackMode.PostInputs
            ? _settlePostInputs(order, ctx, callbackTarget, callbackData, takerData)
            : _settleForward(order, ctx, callbackTarget, callbackData, takerData);
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
        if (callbackTarget != address(0)) EXECUTOR.execute(callbackTarget, callbackData);

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
        if (callbackTarget != address(0)) EXECUTOR.execute(callbackTarget, callbackData);
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
