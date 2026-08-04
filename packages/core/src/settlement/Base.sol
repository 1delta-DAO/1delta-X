// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPermit3} from "../interfaces/IPermit3.sol";
import {IMakerModule} from "../interfaces/IMakerModule.sol";
import {ISettlementModule} from "../interfaces/ISettlementModule.sol";
import {IOrderValidator} from "../interfaces/IOrderValidator.sol";
import {SafeTransferLib} from "../utils/SafeTransferLib.sol";
import {Order, Item, ItemOp, Validator, LegIn, FillCtx} from "./Structs.sol";
import {DutchAuction} from "./DutchAuction.sol";
import {SolverCallbackExecutor} from "./SolverCallbackExecutor.sol";
import {Signatures} from "./Signatures.sol";

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
    error NotExclusiveFiller();
    error OnlySelf();
    error BatchFillIncomplete(uint256 index);
    /// @dev `batchFill`'s `takerDatas` array is not aligned 1:1 with `orders`.
    error LengthMismatch();
    error ReverseModeRequiresNoItems();
    /// @dev The constructor was given a `permit3` with no code. Load-bearing: every
    ///      maker/solver token move runs through
    ///      {Permit3TransferLib.transferFromWithFallback}, which probes Permit3 with
    ///      a LOW-LEVEL call and treats success as "the transfer happened". A call to
    ///      a codeless address returns success with empty returndata, so a
    ///      misconfigured hub would make every pull and every delivery a SILENT
    ///      no-op — orders would "settle" with no funds moving at all. Checked once
    ///      here rather than on every transfer.
    error InvalidPermit3();
    /// @dev A TAKE item's per-fill slice exceeds `uint160`, the width of Permit3's
    ///      allowance book. Amounts are maker-signed so this is not reachable
    ///      adversarially, but the cast is on a value path: revert instead of
    ///      silently wrapping to a smaller take.
    error AmountOverflow();
    /// @dev `order.exclusivityOverrideBps` exceeds 100%. Above `BPS` the input-side
    ///      discount in {Pricing.inputOwed} underflows, so the order would be
    ///      unfillable by any non-exclusive filler; reject it explicitly rather than
    ///      surfacing an arithmetic panic.
    error InvalidOverrideBps();
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

    /// @dev Exclusivity gate. Inside the window only the nominated filler fills
    ///      for free; a non-exclusive filler is blocked (hard exclusivity) or
    ///      allowed against an `exclusivityOverrideBps` price improvement it must
    ///      pay the maker (soft exclusivity). Returns the override, 0 otherwise.
    function _exclusivity(Order calldata order, address filler) internal view returns (uint256 overrideBps) {
        if (
            order.exclusiveFiller != address(0) && block.timestamp < order.exclusivityEndTime()
                && filler != order.exclusiveFiller
        ) {
            if (order.exclusivityOverrideBps == 0) revert NotExclusiveFiller();
            if (order.exclusivityOverrideBps > DutchAuction.BPS) revert InvalidOverrideBps();
            overrideBps = order.exclusivityOverrideBps;
        }
    }

    /// @dev Snapshot Settlement's balance of every input leg's token before items run.
    function _snapshotInputs(LegIn[] calldata legs) internal view returns (uint256[] memory bals) {
        uint256 n = legs.length;
        bals = new uint256[](n);
        for (uint256 i; i < n;) {
            bals[i] = SafeTransferLib.balanceOf(legs[i].token, address(this));
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
    ///      This is not enforceable here: an item's proceeds token is encoded inside
    ///      the module-specific `item.data`, which the core deliberately does not
    ///      decode (that is what keeps the core module-agnostic). Order construction
    ///      owns it — `validateOrder` in the SDK checks it, and a maker can pin the
    ///      outcome on-chain with a {MinBalanceInvariant} on the expected token.
    function _executeItems(Order calldata order, FillCtx memory ctx) internal {
        for (uint256 i; i < order.items.length; i++) {
            _executeItem(order, ctx, i);
        }
    }

    /// @dev ONE item's slice — the body of {_executeItems}, split out so the
    ///      schedule-driven {Batch.matchSettle} can run items INDIVIDUALLY (an
    ///      order's borrow before its own delivery, interleaved with another
    ///      order's steps) while the single-order path keeps the plain loop above.
    ///      Byte-identical semantics: same slice math, same dispatch, same guards.
    function _executeItem(Order calldata order, FillCtx memory ctx, uint256 i) internal {
        Item calldata item = order.items[i];
        uint256 slice = ctx.fullFill
            ? item.amount
            : (item.amount * ctx.newFilled) / ctx.anchor - (item.amount * ctx.prevFilled) / ctx.anchor;
        if (slice == 0) {
            // A SETTLE slice that floors to 0 would charge the maker's
            // pro-rata payment while delivering NOTHING to this filler (an
            // indivisible exchange has no fractional delivery) — the footgun
            // {SettlementLens.validateOrder} flags off-chain. Enforce it
            // on-chain too: revert instead of silently skipping. MAKE/TAKE
            // dust slices keep the historical skip (they accumulate exactly
            // across fills). Cost: one calldata read, only on the dust branch.
            if (item.op == ItemOp.SETTLE) revert SettleSliceZero();
            return;
        }

        if (item.op == ItemOp.MAKE) {
            // Maker module pulls the funding token from order.maker via Permit3 internally.
            IMakerModule(item.module).makeOnBehalf(order.maker, slice, item.data);
        } else if (item.op == ItemOp.TAKE) {
            // Taker: Permit3 enforces the gate and dispatches. `recipient = 0` is the
            // classic flow (proceeds to Settlement for tokenIn payout); signing a
            // non-zero recipient (e.g. the maker) chains output into a subsequent item.
            address to = item.recipient == address(0) ? address(this) : item.recipient;
            if (slice > type(uint160).max) revert AmountOverflow();
            PERMIT3.take(item.module, order.maker, uint160(slice), to, item.data);
        } else {
            // SETTLE: generic solver↔maker exchange — the FILLER-AWARE fallback
            // for exchanges the typed legs can't express (see {ISettlementModule}).
            // The module acts under the maker's signature + its own maker approval;
            // passing `ctx.filler` lets the maker's asset route to whoever fills. The
            // maker's receipt is guaranteed by the mandatory tokenOut delivery (run
            // before items) and/or an invariant, not by the module.
            ISettlementModule(item.module).settle(order.maker, ctx.filler, slice, item.data);
        }
    }

    // ──────────────────── Validators / invariants ────────────────────

    /// @dev Pre-execution staticcall validators. `filler` is the address executing
    ///      this fill (threaded from msg.sender, or from batchFill's caller), so a
    ///      maker-signed validator can express filler-conditional policy. The shared
    ///      `takerData` (filler-supplied, unsigned, adversarial — see
    ///      {IOrderValidator}) is passed to every validator.
    function _runValidators(Order calldata order, address filler, bytes memory takerData) internal view {
        uint256 len = order.validators.length;
        for (uint256 i; i < len;) {
            Validator calldata v = order.validators[i];
            if (!_gatePasses(v.target, order, filler, v.data, takerData)) revert ValidationFailed(i);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Staticcall `target.validate(order, filler, data, takerData)` and return
    ///      whether it passed (call ok AND ≥32 bytes returned AND the bool word ==
    ///      1). The single-word return is read into scratch space, avoiding the
    ///      `bytes memory` return allocation the abstract call would make. `data` is
    ///      the maker-signed per-validator config; `takerData` is the shared
    ///      filler-supplied blob (a validator must independently verify it).
    function _gatePasses(
        address target,
        Order calldata order,
        address filler,
        bytes calldata data,
        bytes memory takerData
    ) private view returns (bool pass) {
        bytes memory cd = abi.encodeCall(IOrderValidator.validate, (order, filler, data, takerData));
        /// @solidity memory-safe-assembly
        assembly {
            let ok := staticcall(gas(), target, add(cd, 0x20), mload(cd), 0x00, 0x20)
            pass := and(and(ok, gt(returndatasize(), 31)), eq(mload(0x00), 1))
        }
    }

    /// @dev Post-execution staticcall invariants. Same shape as validators
    ///      (including the threaded `filler` and the shared `takerData`) but run
    ///      AFTER items execute, so they can assert on the order's side effects
    ///      (e.g. "maker's Aave health factor ≥ 2.0").
    function _runInvariants(Order calldata order, address filler, bytes memory takerData) internal view {
        uint256 len = order.invariants.length;
        for (uint256 i; i < len;) {
            Validator calldata v = order.invariants[i];
            if (!_gatePasses(v.target, order, filler, v.data, takerData)) revert InvariantFailed(i);
            unchecked {
                ++i;
            }
        }
    }
}
