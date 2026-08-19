// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPermit3} from "../interfaces/IPermit3.sol";
import {IMakerModule} from "../interfaces/IMakerModule.sol";
import {ISettlementModule} from "../interfaces/ISettlementModule.sol";
import {IOrderValidator} from "../interfaces/IOrderValidator.sol";
import {SafeTransferLib} from "../utils/SafeTransferLib.sol";
import {Order, ItemOp, FillCtx} from "./Structs.sol";
import {PackedArrays} from "./PackedArrays.sol";
import {DutchAuction} from "./DutchAuction.sol";
import {SolverCallbackExecutor} from "./SolverCallbackExecutor.sol";
import {Signatures} from "./Signatures.sol";
import {OrderGates} from "./OrderGates.sol";
import {OrderHash} from "./OrderHash.sol";

/// @title Base
/// @notice The settler's EXECUTION foundation, on top of the state
///         ({OrderState}/{NonceManager}) and authorization ({Signatures})
///         layers: the Permit3 hub + allowance-less callback executor, the
///         reentrancy lock, the validator/invariant gates, and the fill primitives
///         BOTH the single-order path ({Core}) and the netted-batch path
///         ({Batch}) build on — `_executeItems`, `_exclusivity`,
///         `_snapshotInputs`. (The `_openFill` COUNTER transition lives one layer
///         down in {OrderState}, with the storage it mutates.)
///
///         Read order (most-base → most-derived):
///           {NonceManager} → {OrderState} → {Signatures} → this →
///           {Core} → {Batch} → {Settlement}.
abstract contract Base is Signatures {
    using DutchAuction for Order;

    // ──────────────────── Storage ────────────────────

    IPermit3 public immutable PERMIT3;

    /// @notice Allowance-less trampoline for `fillWithCallback` (see the contract
    ///         for the security rationale). Deployed here so it is dedicated to
    ///         this Settlement and can never be an approved Permit3 spender.
    SolverCallbackExecutor public immutable EXECUTOR;

    uint256 private _locked = 1;

    // ──────────────────── Events ────────────────────

    /// @notice A fill occurred. Intentionally data-less: every amount is
    ///         recoverable from the ERC20 `Transfer` / protocol events in the same
    ///         tx (`tokenOut` legs are solver→maker transfers; the anchor
    ///         `fillAmountIn` is the `tokenIn[0]`/`tokenOut[0]` leg), and on-chain
    ///         callers get the per-leg outputs from the function return value. The
    ///         event exists only to bind those transfers to an `orderHash` (which
    ///         Transfer events don't carry) and to make fills filterable by
    ///         maker/solver — so it emits just those three topics, no log data.
    event OrderFilled(bytes32 indexed orderHash, address indexed maker, address indexed solver);

    // ──────────────────── Errors ────────────────────

    error OrderExpired();
    error Reentrancy();
    error ValidationFailed(uint256 index);
    error InvariantFailed(uint256 index);
    error OnlySelf();
    error BatchFillIncomplete(uint256 index);
    /// @dev `batchFill`'s `takerDatas` array is not aligned 1:1 with `orders`.
    error LengthMismatch();
    error ReverseModeRequiresNoItems();
    /// @dev {Core.fillWithPermitTake} completed without dispatching its one-shot
    ///      permit — so nothing verified the maker's signature. Reverts.
    error PermitTakeNotConsumed();
    /// @dev The constructor was given a `permit3` with no code. Load-bearing: every
    ///      maker/solver token move runs through
    ///      {Permit3TransferLib.transferFromWithFallback}, which probes Permit3 with
    ///      a LOW-LEVEL call and treats success as "the transfer happened". A call to
    ///      a codeless address returns success with empty returndata, so a
    ///      misconfigured hub would make every pull and every delivery a SILENT
    ///      no-op — orders would "settle" with no funds moving at all. Checked once
    ///      here rather than on every transfer.
    error InvalidPermit3();
    /// @dev A MAKE or TAKE item's per-fill slice exceeds `uint160`, the width of
    ///      Permit3's allowance book. Amounts are maker-signed so this is not
    ///      reachable adversarially, but the cast is on a value path: revert instead
    ///      of silently wrapping to a smaller move. (SETTLE is exempt — its module
    ///      interface is `uint256` and never narrows.)
    error AmountOverflow();
    /// @dev `fillUpTo`'s `minBumpBps` price floor was not met: the fill's resolved
    ///      shared decay bump came in below what the filler demanded. Every leg
    ///      price is monotone in the bump (outputs fall with it, inputs rise), so
    ///      the scalar floor is an exact filler-side price guard against the two
    ///      movers that can shift the tick maker-ward between quote and inclusion —
    ///      an oracle-pegged {IPriceModule} and a falling basefee shrinking the gas
    ///      bump.
    error BumpTooLow();
    /// @dev A DELTA-VERIFY output leg ({DutchAuction.deltaVerifyOutputs}) did not
    ///      land: the recipient's measured balance increase over the fill was below
    ///      the leg's priced amount ({Pricing.outputAt}). The filler was supposed to
    ///      deliver this leg out-of-band (its callback — pool/aggregator/inventory);
    ///      the core verified the outcome instead of pushing a nominal amount, so a
    ///      short or missing delivery (including a fee-on-transfer/rebase eating past
    ///      the priced amount) unwinds the whole fill rather than silently underpaying
    ///      the maker.
    error DeltaTooLow();
    /// @dev A {DutchAuction.deltaVerifyOutputs} order was offered to the netted
    ///      `matchSettle` path. That path delivers output legs NOMINALLY (no per-order
    ///      callback for the filler to source into, no recipient snapshot), so it
    ///      cannot honour the delta-verify contract — it would deliver the very way the
    ///      maker opted OUT of, silently. Fill such orders through the single-order
    ///      {Core.fillWithCallback} path.
    error DeltaVerifyNotBatchable();
    /// @dev A {DutchAuction.deltaVerifyOutputs} order carries two output legs with the
    ///      SAME (token, recipient). Both would verify their own priced amount against
    ///      the SAME starting balance, so a single delivery of `max(amt)` — rather than
    ///      the sum — satisfies both checks and the maker is underpaid. That defeats
    ///      the one property this mode exists to provide, so it is rejected ON-CHAIN
    ///      (the lens already reports a duplicate `(token, recipient)` pair as
    ///      malformed for every order; here it is load-bearing, not advice).
    ///      The nominal path is unaffected — it pushes each leg separately.
    error DeltaVerifyDuplicateLeg();
    /// @dev A {DutchAuction.deltaVerifyOutputs} order names the same token on an INPUT
    ///      leg and an output leg paid to the maker. The maker's input is pulled
    ///      between the snapshot and the check (the `PostInputs` ordering), so the
    ///      measured balance delta would be output MINUS input — a net figure — while
    ///      the check compares it against the GROSS output the maker signed for.
    ///      Rejected rather than mis-measured.
    error DeltaVerifySameToken();
    /// @dev A netted `matchSettle` left Settlement holding LESS of `token` than it
    ///      did before the context — the solver under-covered the residual, so the
    ///      settlement would have drawn down a pre-existing/donated balance. Reverts.
    error BatchNotWhole(address token);
    /// @dev A `matchSettle` order finished the context with LESS credit on an input
    ///      leg than the leg owes — no `PULL` step covered it and its items did not
    ///      produce enough. `(order, leg)` names the exact obligation that came up
    ///      short, so a solver can fix the schedule without bisecting it.
    error LegUnfunded(uint256 order, uint256 leg);
    /// @dev A `matchSettle` schedule step is malformed: an unknown kind, an
    ///      out-of-range order/leg/item/token/call index, or a REPEAT of a
    ///      deliver-outputs or execute-item unit that already ran. The repeat guard
    ///      is load-bearing — a second delivery drains the pool and a second item is
    ///      a second borrow against the maker — so it fires at the step, never as a
    ///      post-hoc completeness compare (which two executions would still pass).
    error PlanBadStep(uint256 index);
    /// @dev A `matchSettle` schedule ended without running every unit order `index`
    ///      was owed: its outputs were never delivered, or one of its items never
    ///      executed. Deliveries and items are scheduled, so completeness cannot be
    ///      structural — it is asserted here, in the deferred flush.
    error PlanIncomplete(uint256 index);
    /// @dev A `matchSettle` schedule ran order `order`'s item `item` in a position
    ///      the MAKER did not permit — out of signed sequence under
    ///      {ItemPolicy.ORDERED}, or with a foreign step wedged between it and its
    ///      predecessor under {ItemPolicy.ATOMIC}. Unlike the other plan errors this
    ///      is not a bug in the schedule builder so much as a mismatch between the
    ///      route it chose and the freedom the maker granted: the order is fillable,
    ///      just not that way.
    error ItemPolicyViolated(uint256 order, uint256 item);
    /// @dev A `matchSettle` order carries a SETTLE item. SETTLE routes the maker's
    ///      asset to the filler, not a pool counterparty — out of scope for the
    ///      netted flow (a shared-pool SETTLE needs its own design).
    error MatchSettleItemUnsupported();
    /// @dev A `matchSettle` order repeats an input token across two `legsIn` legs.
    ///      Item proceeds are attributed per token within a step window, so two
    ///      same-token legs would mis-account. Use distinct tokens
    ///      (leverage/repay/migrate orders already do).
    error MatchDuplicateInput();
    /// @dev A `matchSettle` internal invariant broke: a token was looked up in the
    ///      on-chain-derived token universe and was not there. Unreachable today —
    ///      `_collectTokens` is the union of exactly the legs every lookup comes
    ///      from — so this exists to make a future widening of the universe fail
    ///      LOUDLY rather than silently attribute to slot 0.
    error TokenNotInUniverse(address token);
    /// @dev A SETTLE item's pro-rata slice floored to 0 for this fill — the filler
    ///      would pay the maker's pro-rata price and receive nothing (an
    ///      indivisible exchange has no fractional delivery). Sign the order
    ///      full-fill (`minFillAnchor == anchor`, or a {FullFillModule}) and give
    ///      the item a non-zero `amount` sentinel; see {NftSettlementModule}.
    error SettleSliceZero();

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(address permit3) {
        if (permit3.code.length == 0) revert InvalidPermit3();
        PERMIT3 = IPermit3(permit3);
        EXECUTOR = new SolverCallbackExecutor();
    }

    /// @dev Snapshot Settlement's balance of every input leg's token before items run.
    function _snapshotInputs(bytes calldata legs) internal view returns (uint256[] memory bals) {
        uint256 n = PackedArrays.validateFixed(legs, PackedArrays.LEG_IN_STRIDE);
        bals = new uint256[](n);
        for (uint256 i; i < n;) {
            bals[i] = SafeTransferLib.balanceOf(PackedArrays.legInToken(legs, i), address(this));
            unchecked {
                ++i;
            }
        }
    }

    /// @dev For each item, execute the slice attributable to this fill:
    ///      slice = item.amount * newFilled / anchor
    ///            - item.amount * prevFilled / anchor
    ///      Sums to exactly item.amount once the order is fully filled.
    ///
    ///      ⚠ MAKER CONSTRAINT — a TAKE item's proceeds token MUST appear in
    ///      `order.legsIn`. Proceeds land here (when `item.recipient` is 0), and the
    ///      only code that pays them back out — `_payInputsToSolver` and
    ///      `_settleInputsToPool` — iterates `legsIn`. A token that matches no input
    ///      leg is therefore PERMANENTLY STRANDED: Settlement has no sweep and no
    ///      admin, so nothing can ever move it again.
    ///
    ///      It cannot be STOLEN — every payout is bounded by a balance delta
    ///      measured from a snapshot taken in the same fill, and the batch paths
    ///      additionally floor every touched token at its pre-batch balance — so a
    ///      stranded balance is invisible to later fills. It is simply lost.
    ///
    ///      ⚠ That floor is the PRE-BATCH balance, so it does NOT by itself cover
    ///      proceeds arriving DURING a `matchSettle` context. {Batch} closes the gap
    ///      on its own side by refunding any un-attributed item proceeds to the maker
    ///      as the item runs (see {Batch._creditItemProceeds}) — so on the netted
    ///      path such proceeds are returned rather than lost. Only THIS path, where
    ///      the token universe is not known, still strands them.
    ///
    ///      This is not enforceable here: an item's proceeds token is encoded inside
    ///      the module-specific `item.data`, which the core deliberately does not
    ///      decode (that is what keeps the core module-agnostic). Order construction
    ///      owns it — `validateOrder` in the SDK checks it, and a maker can pin the
    ///      outcome on-chain with a {MinBalanceInvariant} on the expected token.
    ///      Items are a length-prefixed RECORD blob, so this walks it with a cursor
    ///      rather than indexing — the settler only ever runs items in signed order.
    ///      `validateRecords` is the single bounds proof for the whole walk.
    function _executeItems(Order calldata order, FillCtx memory ctx) internal {
        bytes calldata items = order.items;
        uint256 n = PackedArrays.validateRecords(items, PackedArrays.ITEM_HEAD);
        uint256 cursor = PackedArrays.recordsStart();
        for (uint256 i; i < n;) {
            cursor = _executeItemAt(order, ctx, items, cursor);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Cursor form used by both the plain loop above and {Batch.matchSettle},
    ///      which needs to run ONE item at an arbitrary schedule position. Returns the
    ///      next cursor so a sequential walk needs no re-scan.
    function _executeItemAt(Order calldata order, FillCtx memory ctx, bytes calldata items, uint256 cursor)
        internal
        returns (uint256 next)
    {
        (uint256 op, address module, uint256 amount, address recipient, bytes calldata data, uint256 n2) =
            PackedArrays.itemAt(items, cursor);
        _runItem(order, ctx, op, module, amount, recipient, data);
        return n2;
    }

    /// @dev Byte-offset of item `index` — {Batch} schedules items by index, so it must
    ///      be able to seek. O(index), which is fine: an order's item list is tiny and
    ///      only the netted path pays this.
    function _itemCursor(bytes calldata items, uint256 index) internal pure returns (uint256 cursor) {
        cursor = PackedArrays.recordsStart();
        for (uint256 i; i < index;) {
            (,,,,, uint256 n2) = PackedArrays.itemAt(items, cursor);
            cursor = n2;
            unchecked {
                ++i;
            }
        }
    }

    /// @dev ONE item's slice — the body of {_executeItems}, split out so the
    ///      schedule-driven {Batch.matchSettle} can run items INDIVIDUALLY (an
    ///      order's borrow before its own delivery, interleaved with another
    ///      order's steps) while the single-order path keeps the plain loop above.
    ///      Byte-identical semantics: same slice math, same dispatch, same guards.
    /// @dev Execute one item from its ALREADY-DECODED fields. Same slice math, same
    ///      dispatch and same guards as before the packed encoding; only the decode
    ///      moved out to the caller so a sequential walk decodes each record once.
    function _runItem(
        Order calldata order,
        FillCtx memory ctx,
        uint256 op,
        address module,
        uint256 amount,
        address recipient,
        bytes calldata itemData
    ) internal {
        uint256 slice = ctx.fullFill
            ? amount
            : (amount * ctx.newFilled) / ctx.anchor - (amount * ctx.prevFilled) / ctx.anchor;
        if (slice == 0) {
            // A SETTLE slice that floors to 0 would charge the maker's
            // pro-rata payment while delivering NOTHING to this filler (an
            // indivisible exchange has no fractional delivery) — the footgun
            // {SettlementLens.validateOrder} flags off-chain. Enforce it
            // on-chain too: revert instead of silently skipping. MAKE/TAKE
            // dust slices keep the historical skip (they accumulate exactly
            // across fills). Cost: one calldata read, only on the dust branch.
            if (op == uint256(ItemOp.SETTLE)) revert SettleSliceZero();
            return;
        }

        if (op == uint256(ItemOp.MAKE)) {
            // Maker module pulls the funding token from order.maker via Permit3
            // internally — i.e. it narrows `slice` to Permit3's `uint160` book width
            // exactly as the TAKE branch does, just one frame further down. Every
            // shipped maker module does that narrowing UNCHECKED, so without this the
            // MAKE path would silently wrap a >2^160 slice to a smaller pull while
            // the TAKE path reverts on the identical value. Maker-signed, so not
            // adversarially reachable — but the asymmetry was gratuitous, and a value
            // path should not have two different overflow postures.
            if (slice > type(uint160).max) revert AmountOverflow();
            IMakerModule(module).makeOnBehalf(order.maker, slice, itemData);
        } else if (op == uint256(ItemOp.TAKE)) {
            // Taker: Permit3 enforces the gate and dispatches. `recipient = 0` is the
            // classic flow (proceeds to Settlement for tokenIn payout); signing a
            // non-zero recipient (e.g. the maker) chains output into a subsequent item.
            address to = recipient == address(0) ? address(this) : recipient;
            if (slice > type(uint160).max) revert AmountOverflow();
            // ONE-SHOT permit path: same dispatch, same proceeds accounting, but the
            // authority is a maker signature consumed here rather than a standing
            // allowance — so nothing is written and nothing survives the fill. The
            // witness binds it to THIS order, so it doubles as the order's
            // authorization (see {Core.fillWithPermitTake}).
            if (ctx.permitTake.length != 0) {
                _takeByPermit(order, ctx, to, itemData);
            } else {
                PERMIT3.take(module, order.maker, uint160(slice), to, itemData);
            }
        } else {
            // SETTLE deliberately keeps NO width check: {ISettlementModule.settle}
            // takes a `uint256` and never narrows, so a wide slice (an ERC-1155 id
            // count, a lot size) is meaningful there and must stay expressible.
            // SETTLE: generic solver↔maker exchange — the FILLER-AWARE fallback
            // for exchanges the typed legs can't express (see {ISettlementModule}).
            // The module acts under the maker's signature + its own maker approval;
            // passing `ctx.filler` lets the maker's asset route to whoever fills. The
            // maker's receipt is guaranteed by the mandatory tokenOut delivery (run
            // before items) and/or an invariant, not by the module.
            ISettlementModule(module).settle(order.maker, ctx.filler, slice, itemData);
        }
    }

    /// @dev Consume the fill's one-shot taker permit for this TAKE item. Its own
    ///      frame so the 7-argument call does not share {_runItem}'s stack.
    function _takeByPermit(Order calldata order, FillCtx memory ctx, address to, bytes calldata itemData) private {
        (IPermit3.PermitTake memory permit, bytes memory sig) =
            abi.decode(ctx.permitTake, (IPermit3.PermitTake, bytes));
        // MARK CONSUMED. `ctx` is a memory struct threaded by reference through
        // `_settleForward` → `_executeItems` → `_runItem`, so clearing here is visible
        // to {Core.fillWithPermitTake}, which REQUIRES it to be empty. That check is
        // load-bearing: on that entrypoint the permit's witness IS the order's
        // authorization, and it is only verified inside the call below — so an order
        // that never reaches a TAKE item (item-free, or a slice that floors to 0)
        // would otherwise settle with NO signature verified at all, pulling the
        // maker's inputs against their standing allowance. A second TAKE item finds
        // this empty and falls back to the ordinary `PERMIT3.take` allowance gate.
        ctx.permitTake = "";
        PERMIT3.permitTakeWithWitness(
            permit, order.maker, to, itemData, ctx.orderHash, OrderHash.WITNESS_TYPESTRING, sig
        );
    }

    // ──────────────────── Validators / invariants ────────────────────

    /// @dev MEASURED AND REJECTED (2026-08-10) — two attempts to buy back EIP-170
    ///      headroom by hand-rolling what solc already does. Both made Settlement
    ///      BIGGER under the `core-deploy` (via-IR) profile that is the one that has
    ///      to fit. Baseline 23,594 bytes:
    ///
    ///        • Hand-encoding the three item-dispatch calls (`makeOnBehalf`, `take`,
    ///          `settle`) through one shared assembly encoder, 0x-Settler style:
    ///          **+1,862 bytes (25,456 — over the cap).** Their win comes from
    ///          payloads solc encodes badly — nested structs plus a `string` — but
    ///          these are 2–4 words and one `bytes`, a shape whose encoder via-IR
    ///          already emits ONCE and shares across all three call sites. An
    ///          `internal` assembly helper is instead inlined three times.
    ///        • Merging `_runValidators`/`_runInvariants` into one `private` walk
    ///          parameterised by a `post` flag, to stop the {IOrderValidator}
    ///          encoder (which serialises the whole {Order}) being emitted twice:
    ///          **+389 bytes (23,983).** via-IR was already sharing it; the flag
    ///          only added a branch and blocked per-site specialisation.
    ///
    ///      The generalisation, and the reason not to retry this family: under
    ///      via-IR, solc's own deduplication is already better than hand-rolling for
    ///      any payload it can encode with a shared routine. Reach for assembly here
    ///      only where the encoder is genuinely bespoke per call site. See
    ///      [[settlement-size-via-ir]] for the alternatives rejected before these.

    /// @dev Pre-execution staticcall validators. `filler` is the address executing
    ///      this fill (threaded from msg.sender, or from batchFill's caller), so a
    ///      maker-signed validator can express filler-conditional policy. The shared
    ///      `takerData` (filler-supplied, unsigned, adversarial — see
    ///      {IOrderValidator}) is passed to every validator.
    function _runValidators(Order calldata order, address filler, bytes memory takerData) internal view {
        bytes calldata vs = order.validators;
        uint256 len = PackedArrays.validateRecords(vs, PackedArrays.VALIDATOR_HEAD);
        uint256 cursor = PackedArrays.recordsStart();
        for (uint256 i; i < len;) {
            (address target, bytes calldata data, uint256 next) = PackedArrays.validatorAt(vs, cursor);
            if (!OrderGates.gatePasses(target, order, filler, data, takerData)) revert ValidationFailed(i);
            cursor = next;
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Post-execution staticcall invariants. Same shape as validators
    ///      (including the threaded `filler` and the shared `takerData`) but run
    ///      AFTER items execute, so they can assert on the order's side effects
    ///      (e.g. "maker's Aave health factor ≥ 2.0").
    function _runInvariants(Order calldata order, address filler, bytes memory takerData) internal view {
        bytes calldata vs = order.invariants;
        uint256 len = PackedArrays.validateRecords(vs, PackedArrays.VALIDATOR_HEAD);
        uint256 cursor = PackedArrays.recordsStart();
        for (uint256 i; i < len;) {
            (address target, bytes calldata data, uint256 next) = PackedArrays.validatorAt(vs, cursor);
            if (!OrderGates.gatePasses(target, order, filler, data, takerData)) revert InvariantFailed(i);
            cursor = next;
            unchecked {
                ++i;
            }
        }
    }
}
