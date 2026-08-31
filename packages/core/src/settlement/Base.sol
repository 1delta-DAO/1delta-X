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
import {Pricing} from "./Pricing.sol";
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
    using Pricing for Order;

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
    /// @dev The one-shot permit does not match the TAKE item it would fund — a
    ///      different module, or an amount that is not this fill's pro-rata slice.
    error PermitTakeMismatch();
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
    /// @dev A `TAKE_FOR` item's funding descriptor is unusable: `data` is too short
    ///      to hold the leading descriptor word, or the descriptor references a
    ///      `legsOut` index the order does not have. Maker-signed either way, so
    ///      this is a malformed order rather than an adversarial input — but it is
    ///      the difference between funding the wrong leg and not filling at all, so
    ///      it reverts instead of defaulting to leg 0.
    error ForLegMissing();
    /// @dev A BALANCE-relative `TAKE_FOR` funding leg was offered a partial fill. The
    ///      amount is a live `balanceOf` read, so it cannot pro-rate: every slice
    ///      would fund the FULL remaining balance again. Same rule, and the same
    ///      reasoning, as {Proportional}'s full-fill requirement — enforced here
    ///      because only the core knows the fill fraction.
    error ForBalanceNeedsFullFill();
    /// @dev A BALANCE-relative funding leg carries no cap (`data` word 1 absent or
    ///      zero). MANDATORY, for the reason {Proportional} spells out: a maker's
    ///      balance is not under their sole control — anyone can raise it by
    ///      transferring tokens to them — so an uncapped "fund with everything I
    ///      hold" is a standing offer to lock the maker's entire holding into a
    ///      position sized for much less. `0` is also what an unset word holds, so
    ///      the dangerous mode would otherwise be the default.
    error ForBalanceNeedsCap();
    /// @dev A BALANCE-relative funding leg resolved to ZERO — the maker holds none
    ///      of the token, or the descriptor names an address with no code (
    ///      {SafeTransferLib.balanceOf} multiplies by the staticcall's success, so a
    ///      codeless target reads as a zero balance rather than reverting).
    ///
    ///      Reverts rather than funding nothing, because the alternative FAILS OPEN:
    ///      the value-OUT leg would still execute in full, turning "deposit what I
    ///      hold and borrow against it" into a bare, uncollateralised borrow. That is
    ///      reachable without any malice — a maker's balance can be spent by an
    ///      earlier fill of one of their OWN orders, and the filler picks the order —
    ///      so the premise failing must stop the fill, not silently change its
    ///      shape. (A LITERAL or LEG funding slice that floors to zero on a dust fill
    ///      is different and is allowed: it accumulates exactly across slices.)
    ///
    ///      ⚠ ZERO IS ONLY THE FLOOR'S DEFAULT. Stopping at zero closed the boundary
    ///      but left every value NEAR it open, and the same sequencing that empties a
    ///      wallet can merely dent it: `min(balance, cap)` shrinks smoothly while the
    ///      value-OUT leg stays at its full signed size, so the position comes out
    ///      under-collateralised instead of unfunded. The maker therefore signs a
    ///      FLOOR in the descriptor (bits [160:176), bps of the cap) and this error
    ///      names any resolved amount below it — zero being the case where the floor
    ///      was left at its default.
    error ForBalanceBelowFloor();
    /// @dev A `TAKE_FOR` funding descriptor referenced an output leg the maker does
    ///      NOT receive (a fee/originator leg, `recipient` set to a third party).
    ///      See {_forSlice}: the leg-reference form exists so the funding leg IS the
    ///      delivery, which only holds for the maker's own legs.
    error ForLegNotMakers();
    /// @dev An item's `module` (or Permit3) has no code. Solc's own existence check on a
    ///      void external call; kept explicit now that {_callWithTail} hand-encodes.
    error ItemTargetHasNoCode();
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
    /// @dev A `matchSettle` order carries an output leg addressed at Settlement
    ///      itself — the maker "self-burn". The single-order path strands such a leg
    ///      forever (no sweep exists), which is what the maker signed for; the netted
    ///      path would instead pay it to the SOLVER, because a pool→pool self-transfer
    ///      leaves the balance above the pre-context floor while `outstanding` records
    ///      the obligation as met. Fill these through the single-order path, or fix
    ///      the recipient. NO ARGUMENTS, deliberately: naming `(order, leg)` the way
    ///      the sibling plan errors do measured **+37 bytes** of Settlement against a
    ///      53-byte EIP-170 budget. The lens reports the offending leg off-chain.
    error OutputToSettlement();
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
        _enter();
        _;
        _exit();
    }

    /// @dev Arm the reentrancy guard. Split out of {nonReentrant} so a fill can run its
    ///      READ-ONLY gate — the order hash, one `SLOAD` of `filled`, and the
    ///      denominator resolve, none of which touch another contract — BEFORE paying
    ///      for it. A losing priority-auction bid then reverts without the guard's
    ///      cold `SLOAD` + `SSTORE` (~5,000 gas at its own bid), and the winner is
    ///      unaffected: the same two operations, in the same order, a few opcodes later.
    ///
    ///      ⚠ THE RULE FOR CALLERS. An entry point that arms the guard by hand instead
    ///      of wearing {nonReentrant} may make NO STATE-CHANGING CALL before
    ///      `_enter()` — no permits, no modules, no callbacks, no transfers, and in
    ///      particular no signature verification (a contract maker's EIP-1271 check is
    ///      a call to maker-chosen code). Calldata decoding, hashing, storage reads and
    ///      pure arithmetic are fine; they never hand over control.
    ///
    ///      ONE `STATICCALL` does occur inside the pre-guard gate and is deliberate: a
    ///      {Proportional} anchor leg resolves through `balanceOf` ({OrderGates.anchorTotal}
    ///      → {Proportional.resolve}), and that token is maker-chosen. It is safe
    ///      because it is a STATICCALL — re-entering any fill from it hits `_enter()`'s
    ///      own `SSTORE` and reverts in the static context — and because
    ///      {OrderState._gateFillState} reads `filled` AFTER resolving the denominator,
    ///      so the fill counter the gate hands on cannot be stale. Both properties are
    ///      load-bearing: if `anchorTotal` ever gains a non-static call, or if that read
    ///      order is flipped, these four entries need the modifier back.
    ///
    ///      Every such entry must also reach {_exit}: a missed release leaves `_locked`
    ///      at 2 and bricks every later fill, which is why the hand-armed entries are
    ///      four straight-line private bodies (`_fillSigned`, `_fillCallback`,
    ///      `_fillWithPermitCore`, `_openCustomFill`) and everything with a loop, a
    ///      self-call or a branchy body keeps the modifier.
    function _enter() internal {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
    }

    /// @dev Release the guard. See {_enter} for the pairing rule.
    function _exit() internal {
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

    /// @dev THIS FILL'S SHARE of a signed total, by CUMULATIVE DIFFERENCING: what
    ///      the order owes at `newFilled` minus what it owed at `prevFilled`. N
    ///      partial fills therefore sum to exactly `total` with no per-fill rounding
    ///      drift, and the full fill skips the arithmetic entirely.
    ///
    ///      Shared by the item slice ({_runItem}) and the LITERAL funding descriptor
    ///      ({_forSlice}) because they are the same rule — and a composite item's two
    ///      legs disagreeing about how a partial fill divides is exactly the class of
    ///      defect `TAKE_FOR` exists to remove. One expression, one auditable rule.
    function _prorate(uint256 total, FillCtx memory ctx) private pure returns (uint256) {
        return ctx.fullFill
            ? total
            : (total * ctx.newFilled) / ctx.anchor - (total * ctx.prevFilled) / ctx.anchor;
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
        uint256 slice = _prorate(amount, ctx);
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

        // THE `uint160` WIDTH CHECK, ONCE, FOR EVERY OP THAT NARROWS. MAKE narrows
        // one frame further down (a maker module's own `permit3.transferFrom`, and
        // every shipped one does it UNCHECKED); TAKE and TAKE_FOR narrow at the
        // dispatch below. Written per branch it was the same comparison twice, in a
        // contract at the EIP-170 wall. SETTLE is the exemption and keeps it: its
        // module interface is `uint256` and never narrows, so a wide slice (an
        // ERC-1155 id count, a lot size) is meaningful there and must stay
        // expressible. An unknown op picks the check up too — it reverts either way,
        // just with this error rather than {PackedArrays.MalformedPackedArray} on the
        // one input that is both malformed AND wider than 2^160.
        if (op != uint256(ItemOp.SETTLE) && slice > type(uint160).max) revert AmountOverflow();

        if (op == uint256(ItemOp.MAKE)) {
            _callWithTail(
                module, IMakerModule.makeOnBehalf.selector, 2, uint160(order.maker), slice, 0, 0, 0, itemData
            );
        } else if (op == uint256(ItemOp.TAKE) || op == uint256(ItemOp.TAKE_FOR)) {
            // Taker: Permit3 enforces the gate and dispatches. `recipient = 0` is the
            // classic flow (proceeds to Settlement for tokenIn payout); signing a
            // non-zero recipient (e.g. the maker) chains output into a subsequent item.
            //
            // TAKE and TAKE_FOR share this branch because they ARE the same dispatch:
            // same taker-book bucket, same gate, same proceeds accounting, same
            // recipient rule. TAKE_FOR only adds a second static word — the funding
            // amount the core sized — between the amount and the receiver. Written as
            // two branches this cost a second full `_callWithTail` marshalling site
            // for a call that differs in one argument; see {ItemOp} for why the op is
            // nonetheless distinct.
            address to = recipient == address(0) ? address(this) : recipient;
            // ONE-SHOT permit path: same dispatch, same proceeds accounting, but the
            // authority is a maker signature consumed here rather than a standing
            // allowance — so nothing is written and nothing survives the fill. The
            // witness binds it to THIS order, so it doubles as the order's
            // authorization (see {Core.fillWithPermitTake}).
            //
            // ⚠ DELIBERATELY NOT WIRED FOR TAKE_FOR. A `PermitTake` witnesses
            // `(module, amount)` and nothing about the funding leg, so it cannot
            // authorise the composite shape; a fill carrying one that reaches only
            // TAKE_FOR items leaves it unconsumed and {Core.fillWithPermitTake}
            // reverts `PermitTakeNotConsumed` — fail closed, rather than silently
            // drawing a leg the permit never covered.
            if (op == uint256(ItemOp.TAKE) && ctx.permitTake.length != 0) {
                _takeByPermit(order, ctx, module, slice, to, itemData);
            } else {
                _dispatchTake(order, ctx, module, op, slice, to, itemData);
            }
        } else if (op == uint256(ItemOp.SETTLE)) {
            // SETTLE deliberately keeps NO width check: {ISettlementModule.settle}
            // takes a `uint256` and never narrows, so a wide slice (an ERC-1155 id
            // count, a lot size) is meaningful there and must stay expressible.
            // SETTLE: generic solver↔maker exchange — the FILLER-AWARE fallback
            // for exchanges the typed legs can't express (see {ISettlementModule}).
            // The module acts under the maker's signature + its own maker approval;
            // passing `ctx.filler` lets the maker's asset route to whoever fills. The
            // maker's receipt is guaranteed by the mandatory tokenOut delivery (run
            // before items) and/or an invariant, not by the module.
            _callWithTail(
                module,
                ISettlementModule.settle.selector,
                3,
                uint160(order.maker),
                uint160(ctx.filler),
                slice,
                0,
                0,
                itemData
            );
        } else {
            // AN UNKNOWN OP IS A MALFORMED RECORD, NOT A SETTLE. `op` is a raw byte
            // from the signed blob, so without this every `op >= 2` fell into the
            // SETTLE branch above — which quietly gave the batch path's SETTLE
            // prohibition ({Batch._assertMatchShape}) an equality test it could be
            // stepped around. That guard now asks `>=` and is sound on its own; this
            // is the second half, so the dispatcher and the guard agree about what
            // the byte means.
            //
            // Reuses {PackedArrays.MalformedPackedArray} rather than declaring a new
            // error: the selector is already in this runtime (the blob validators
            // raise it), and Settlement has 67 bytes of EIP-170 headroom — a fresh
            // error would spend a third of it on a revert reason for a state only a
            // maker can sign themselves into.
            revert PackedArrays.MalformedPackedArray();
        }
    }

    /// @dev The value-IN amount a `TAKE_FOR` item funds THIS fill with, resolved
    ///      from the descriptor word the maker signed at the head of `data`.
    ///
    ///      Two forms, and the choice is about where the number LIVES:
    ///
    ///        • top bit CLEAR — a LITERAL total, for a funding leg with no matching
    ///          output leg (the maker funds it from their own wallet: a fresh Fluid
    ///          position, a new trove). Sliced with the SAME differencing
    ///          {_runItem} applies to `amount`, so N partial fills sum EXACTLY to
    ///          the signed total — no per-fill ceil drift, and no constant amount
    ///          re-executed in full on every slice.
    ///
    ///        • top bit SET — a REFERENCE into `legsOut` (low 16 bits = index). The
    ///          amount, its token and its decimals live in the typed leg the maker
    ///          already signed, so there is exactly ONE copy of the number and a
    ///          mis-scaled second one cannot exist. It is the SAME
    ///          {Pricing.outputAt} call `_deliverOutputs` made moments earlier in
    ///          this fill, so the funding leg and the delivery cannot disagree —
    ///          whatever the pricing rule, including a decaying leg, where the
    ///          funding side tracks the auction instead of a fixed ratio. The
    ///          maker's net balance in that token over the fill is zero: what the
    ///          solver delivered is exactly what goes back into the position.
    ///
    ///        • top bits SET (255 and 254) — BALANCE-relative, the "deposit what I
    ///          hold" form, for the no-conversion shape where there is no output leg
    ///          AND the maker cannot know the amount at signing time (interest has
    ///          accrued, a transfer is in flight, the wallet is being swept). The
    ///          low 160 bits are the token; `data`'s SECOND word is a MANDATORY cap;
    ///          `forAmount = min(balanceOf(token, maker), cap)`, bounded BOTH WAYS —
    ///          by that cap above and by a FLOOR below, `floorBps` of the cap, in
    ///          descriptor bits [160:176). Anything under the floor REVERTS
    ///          ({ForBalanceBelowFloor}) rather than funding a fraction of the
    ///          position while the value-out leg still draws in full. FULL-FILL ONLY —
    ///          a live balance cannot pro-rate, so every slice would fund the whole
    ///          remaining balance again. This is {Proportional}'s rule, on the
    ///          funding side, enforced here because only the core knows the fraction.
    ///
    ///          ⚠ WHY THE FLOOR IS THE CAP'S SIBLING AND NOT OPTIONAL IN SPIRIT. The
    ///          cap exists because anyone can RAISE a maker's balance; the floor
    ///          exists because anyone who can sequence fills can LOWER it. Filling
    ///          another of the maker's live orders that draws the same token — an
    ///          ordinary, profitable act, and the filler chooses the order — shrinks
    ///          this leg without touching this fill, and the value-OUT `amount` does
    ///          not shrink with it. A `floorBps` of 0 keeps the historical "any
    ///          non-zero balance will do", so existing encodings are unchanged; the
    ///          SDK defaults it to 10000 (fund the full cap or do not fill), which is
    ///          the answer a levered order wants.
    ///
    ///      Out-of-range reverts rather than defaulting to leg 0: funding the wrong
    ///      leg is a worse outcome than not filling.
    ///
    ///      ⚠ WHEN THE BALANCE IS READ. Items run AFTER output delivery and BEFORE
    ///      `_payInputsToSolver`, so a BALANCE read sees anything the solver just
    ///      delivered but NOT the input legs the maker still owes. If the funding
    ///      token is also the relayer-fee leg's token, a 100%-of-balance funding leg
    ///      will deposit the tokens earmarked for that fee and the fee pull then
    ///      fails: size the cap to leave the fee behind, or fund and pay in
    ///      different tokens (the natural shape — borrow proceeds pay the fee,
    ///      wallet collateral funds the deposit).
    ///
    ///      ⚠ INTEGRATION NOTE for the leg-reference form. A SELL output leg is
    ///      priced per fill with a CEIL ({Pricing.outputAt}), so N partial fills can
    ///      deliver marginally MORE than the leg's signed total — in the maker's
    ///      favour, and pre-existing behaviour. The funding leg is the same number,
    ///      so it pulls exactly that too: a maker's Permit3 TOKEN allowance to a
    ///      composite module should carry a few units of margin over the leg total,
    ///      or the last slice reverts `InsufficientAllowance`. BUY output legs use
    ///      cumulative differencing and sum exactly, as does the literal form above.
    function _forSlice(Order calldata order, FillCtx memory ctx, bytes calldata itemData)
        private
        view
        returns (uint256)
    {
        if (itemData.length < 32) revert ForLegMissing();
        uint256 desc;
        /// @solidity memory-safe-assembly
        assembly {
            desc := calldataload(itemData.offset)
        }
        if (desc < (uint256(1) << 255)) {
            return _prorate(desc, ctx);
        }
        if (desc & (uint256(1) << 254) == 0) {
            uint256 j = desc & 0xffff;
            if (j >= PackedArrays.validateFixed(order.legsOut, PackedArrays.LEG_OUT_STRIDE)) revert ForLegMissing();
            // The leg must be one the MAKER receives. The whole guarantee of this
            // form is that what the solver just delivered is exactly what goes back
            // into the position — the maker's net balance in that token is zero. A
            // fee leg is delivered to a THIRD PARTY, so referencing one keeps the
            // arithmetic but breaks the invariant: the maker would fund the position
            // out of pocket, to the tune of someone else's fee. Maker-signed, but the
            // property this form is chosen for should hold unconditionally.
            (,,, address legRecipient) = PackedArrays.legOut(order.legsOut, j);
            if (legRecipient != address(0) && legRecipient != order.maker) revert ForLegNotMakers();
            return order.outputAt(ctx, j);
        }
        // BALANCE: `min(balanceOf(token, maker), cap)`. The token is the low 160
        // bits of the descriptor; the cap is `data`'s SECOND word, and both are
        // inside `ref = keccak256(data)`, so a filler can move neither.
        if (!ctx.fullFill) revert ForBalanceNeedsFullFill();
        if (itemData.length < 64) revert ForBalanceNeedsCap();
        uint256 cap;
        /// @solidity memory-safe-assembly
        assembly {
            cap := calldataload(add(itemData.offset, 32))
        }
        if (cap == 0) revert ForBalanceNeedsCap();
        uint256 bal = SafeTransferLib.balanceOf(address(uint160(desc)), order.maker);
        if (bal > cap) bal = cap;
        // The FLOOR, in bps of the cap — descriptor bits [160:176), so it rides in
        // the word the maker already signs and inside `ref = keccak256(data)`, and
        // costs neither a `data` field (which would shift every module's layout) nor
        // a typehash change. `cap / 10_000 * bps` rather than `cap * bps / 10_000`:
        // the cap is an unconstrained maker-signed word, and the product form panics
        // on a huge one — a floor that is a few wei lenient beats an arithmetic
        // revert on an order that used to fill. `bps == 0` ⇒ floor 0, and the
        // zero-balance test below is then the only bound, exactly as before.
        if (bal == 0 || bal < cap / 10_000 * ((desc >> 160) & 0xffff)) revert ForBalanceBelowFloor();
        return bal;
    }

    /// @dev The standing-allowance taker dispatch, for BOTH `TAKE` and `TAKE_FOR`.
    ///      Its own frame for the same reason {_takeByPermit} has one: the wide
    ///      `_callWithTail` argument list must not share {_runItem}'s stack, which is
    ///      at the legacy (non-via-IR) codegen's limit — inlined here it does not
    ///      compile under the profile the tests use.
    ///
    ///      The two ops ARE the same dispatch: same taker-book bucket, same gate,
    ///      same proceeds accounting, same recipient rule. `TAKE_FOR` only inserts a
    ///      second static word — the value-IN amount the CORE sized — between the
    ///      amount and the receiver. Sharing one call site instead of writing the
    ///      marshalling twice measured **−42 bytes** of Settlement runtime, which at
    ///      the current margin is most of the budget.
    function _dispatchTake(
        Order calldata order,
        FillCtx memory ctx,
        address module,
        uint256 op,
        uint256 slice,
        address to,
        bytes calldata itemData
    ) private {
        // The value-IN side, computed HERE from the descriptor the maker signed as
        // the first word of `data` — never a number the module invents;
        // {ITakerForModule} argues why that distinction is the whole point. Same
        // width posture as `slice`: Permit3's book and the funding pulls underneath
        // are `uint160`, so a wider value reverts rather than wrapping to a smaller
        // move.
        uint256 forSlice;
        if (op == uint256(ItemOp.TAKE_FOR)) {
            forSlice = _forSlice(order, ctx, itemData);
            if (forSlice > type(uint160).max) revert AmountOverflow();
        }
        // Slot 3 carries the funding amount for `takeFor` and the receiver for
        // `take`; slot 4 carries the receiver unconditionally, because at `n = 4`
        // {_callWithTail} overwrites that slot with the offset word — so the plain
        // take never sees it.
        _callWithTail(
            address(PERMIT3),
            op == uint256(ItemOp.TAKE_FOR) ? IPermit3.takeFor.selector : IPermit3.take.selector,
            op == uint256(ItemOp.TAKE_FOR) ? 5 : 4,
            uint160(module),
            uint160(order.maker),
            slice,
            op == uint256(ItemOp.TAKE_FOR) ? forSlice : uint160(to),
            uint160(to),
            itemData
        );
    }

    /// @dev Consume the fill's one-shot taker permit for this TAKE item. Its own
    ///      frame so the 7-argument call does not share {_runItem}'s stack.
    function _takeByPermit(
        Order calldata order,
        FillCtx memory ctx,
        address module,
        uint256 slice,
        address to,
        bytes calldata itemData
    ) private {
        (IPermit3.PermitTake memory permit, bytes memory sig) =
            abi.decode(ctx.permitTake, (IPermit3.PermitTake, bytes));
        // THE ITEM IS THE SOURCE OF TRUTH. Permit3 dispatches `permit.module` for
        // `permit.amount`, so without this the order's own `module`/`amount` would be
        // decorative: a PARTIAL fill would still draw the permit's FULL amount
        // (over-borrowing the maker, who gets the surplus back as tokens but keeps
        // the debt), and the permit could name a different module than the order
        // advertises. Requiring equality also makes this path implicitly full-fill:
        // a pro-rata `slice` below `permit.amount` cannot match.
        if (permit.module != module || permit.amount != slice) revert PermitTakeMismatch();
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
        // The HASH overload, not the string one: the witness type is fixed at compile
        // time here, so carrying the ~470-byte type string (and a `string` encoder)
        // in the settler's runtime bought nothing. Same digest — see
        // {OrderHash.PERMIT_TAKE_WITNESS_TYPEHASH}.
        PERMIT3.permitTakeWithWitnessHash(
            permit, order.maker, to, itemData, ctx.orderHash, OrderHash.PERMIT_TAKE_WITNESS_TYPEHASH, sig
        );
    }

    // ──────────────────── Validators / invariants ────────────────────

    /// @dev THE ENCODER-DEDUPLICATION LEDGER — one of these was later OVERTURNED, and
    ///      that reversal is the most useful thing on this page.
    ///
    ///      MEASURED 2026-08-10, against a 23,594-byte baseline. Two attempts to buy
    ///      back EIP-170 headroom by hand-rolling what solc already does; both made
    ///      Settlement BIGGER under the `core-deploy` (via-IR) profile that is the one
    ///      that has to fit:
    ///
    ///      ⚠ 2026-08-31 — a THIRD data point, and it is the one that pays: with
    ///      {Core._permitBatch} hand-encoded, Settlement is **297 bytes smaller**
    ///      than with the typed call, and every `fillWithPermit` runs ~590–1,660 gas
    ///      cheaper (scaling with permit-array content). The rule the three results
    ///      share is about the ARGUMENTS, not the call: solc's encoder is near-free
    ///      for words it can `mstore` one by one (the item dispatches above), and
    ///      expensive for a nested dynamic type it has to walk (`PermitBatch` = two
    ///      dynamic arrays of structs, 675 bytes with the call).
    ///      Measure the specific call, and prefer the ones with a dynamic argument.
    ///      `permitTakeWithWitnessHash` was measured and NOT converted: its 307 bytes
    ///      would mostly go back into a memory→memory copy of the signature (its
    ///      `sig` is an already-decoded `bytes memory`, and without `MCOPY` on every
    ///      target chain that is a loop), leaving ~100 for a second hand-rolled
    ///      encoder on a signature-verification path.
    ///
    ///        • Hand-encoding the three item-dispatch calls (`makeOnBehalf`, `take`,
    ///          `settle`) through one shared assembly encoder, 0x-Settler style:
    ///          **+1,862 bytes (25,456 — over the cap).**
    ///          ⚠ SUPERSEDED 2026-08-25 — see {_callWithTail}, which does exactly this
    ///          and measured **−65 bytes**. Nothing about via-IR changed; the
    ///          SURROUNDING CODE did. The 08-10 attempt was an `internal` helper the
    ///          optimizer re-inlined at all three sites, so it paid for three copies
    ///          and shared nothing; the shipped one is `private` with a flat scalar
    ///          head (`a0…a3` written unconditionally) that keeps its live set to a
    ///          single local, which is what lets it stay one body. Same idea, opposite
    ///          result, from a detail the original measurement could not see.
    ///        • Merging `_runValidators`/`_runInvariants` into one `private` walk
    ///          parameterised by a `post` flag, to stop the {IOrderValidator}
    ///          encoder (which serialises the whole {Order}) being emitted twice:
    ///          **+389 bytes (23,983).** via-IR was already sharing it; the flag
    ///          only added a branch and blocked per-site specialisation.
    ///          STILL TRUE — re-measured 2026-08-25 at **+158 bytes** against the
    ///          then-current tree. Do not retry this one.
    ///
    ///      SO THE GENERALISATION IS NOT "solc always wins", which is what this note
    ///      used to say and what {_callWithTail} disproves. It is: **this codegen is
    ///      cliff-dominated and non-monotonic.** The same transformation can cost
    ///      1,862 bytes in one tree and save 65 in another; a probe that DELETED the
    ///      three item encoders outright measured **+692**, i.e. removing code made the
    ///      contract bigger. Nothing here is predictable from first principles.
    ///
    ///      What that means in practice, and it is the whole rule: **measure the real
    ///      change with `make size-check`, never a probe and never a prediction, and
    ///      treat every figure on this page as a fact about one tree rather than a law.**
    ///      A rejected idea is worth re-measuring when the frame around it has moved.
    ///      See [[settlement-size-via-ir]] for the alternatives rejected before these,
    ///      and the `optimizer_runs` note in foundry.toml for the day this budget
    ///      nearly forced the dial down instead.

    /// @dev THE ORDER GATE — every authorization check a fill runs before it moves a
    ///      token, in one place and in the one order that is cheapest to be wrong in.
    ///
    ///      All three fill entries ({Core._fillCore}, {Core.fillWithPermitTake},
    ///      {Batch._openGated}) ran this exact sequence inline; sharing it keeps them
    ///      from drifting and pays for the reordering below in bytecode.
    ///
    ///      The order matters. {OrderState._gateFillState} runs FIRST because
    ///      `filled[orderHash] >= total` is the "you lost the race" signal in a
    ///      priority-fee auction ({DutchAuction.priorityAuction}), where every solver
    ///      but one lands and reverts and pays its own bid on whatever gas it burned
    ///      getting there. Nothing below can change that answer, so nothing below
    ///      should be paid for first.
    function _gateOrder(
        Order calldata order,
        bytes32 orderHash,
        address filler,
        bytes memory takerData,
        FillCtx memory ctx
    ) internal view {
        _gateFillState(order, orderHash, ctx);
        _gateOrderPost(order, filler, takerData, ctx);
    }

    /// @dev The gate MINUS its fill-state half, for the entries that already ran
    ///      {OrderState._gateFillState} themselves — which is every entry that arms the
    ///      reentrancy guard by hand, since running that gate early is the whole reason
    ///      they do (see {_enter}). `ctx` arrives seeded; this adds the rest.
    function _gateOrderPost(Order calldata order, address filler, bytes memory takerData, FillCtx memory ctx)
        internal
        view
    {
        ctx.overrideBps = OrderGates.exclusivityOverride(order, filler);
        if (_isNonceCancelled(order.maker, order.nonce)) revert NonceCancelled();
        _runValidators(order, filler, takerData);
    }

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
    /// @dev The tail EVERY settle flow ends with — the deferred gates, then the
    ///      fill's one log line. Shared by {Core._settleForward},
    ///      {Core._settlePostInputs} and {Batch._matchFlush} rather than written out
    ///      three times: the event has three indexed topics and the invariant walk a
    ///      full argument list, so each copy was real bytecode in a contract at the
    ///      EIP-170 wall — and "invariants run, THEN the fill is announced" is a rule
    ///      that should exist in one place anyway.
    function _closeFill(Order calldata order, address filler, bytes memory takerData, bytes32 orderHash) internal {
        _runInvariants(order, filler, takerData);
        emit OrderFilled(orderHash, order.maker, filler);
    }

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

    /// @dev `target.sel(a0 … a{n-1}, tail)` hand-encoded — `n` static head words
    ///      followed by one `bytes` argument, the shape EVERY item call shares.
    ///      Same trick as {Core._execute}: solc emits a general encoder per call
    ///      site, the layout here is fixed and known, so it is a handful of
    ///      `mstore`s reused by all three ops instead of three encoders.
    ///
    ///      ⚠ THE `extcodesize` CHECK IS DELIBERATE AND MUST STAY. All three
    ///      callees are void, and solc's own existence check (which it keeps for
    ///      exactly that case — it only drops the check when a call has return
    ///      values to size) is what makes a MAKE or SETTLE item pointed at a
    ///      code-less address REVERT instead of silently succeeding as a no-op.
    ///      Dropping it would turn a malformed maker-signed item into a skipped
    ///      funding step that the rest of the fill happily settles around.
    ///
    ///      Reverts bubble RAW, so a module's custom error survives to the filler
    ///      unchanged — same taxonomy guarantee {Core._execute} documents.
    function _callWithTail(
        address target,
        bytes4 sel,
        uint256 n,
        uint256 a0,
        uint256 a1,
        uint256 a2,
        uint256 a3,
        uint256 a4,
        bytes calldata tail
    ) private {
        // Kept in Solidity rather than hand-written next to the encoder: the check is
        // the load-bearing part, and a hand-rolled selector constant is the kind of
        // thing that goes stale silently.
        if (target.code.length == 0) revert ItemTargetHasNoCode();
        /// @solidity memory-safe-assembly
        assembly {
            let p := mload(0x40)
            mstore(p, sel)
            // The static head. Slots past `n` are overwritten by the offset word and
            // the tail below, so writing all five unconditionally is free — and it
            // keeps this block's live set to ONE local, which is what makes it
            // compile under the legacy (non-via-IR) profile the tests use. (Slot 4
            // is only live for the five-static `takeFor`; for every smaller `n` it
            // lands inside the region the offset word, the tail length or the
            // `calldatacopy` below rewrites.)
            mstore(add(p, 0x04), a0)
            mstore(add(p, 0x24), a1)
            mstore(add(p, 0x44), a2)
            mstore(add(p, 0x64), a3)
            mstore(add(p, 0x84), a4)
            n := shl(5, add(n, 1)) // reused as `off`: 32 * (n statics + 1 offset word)
            mstore(add(p, sub(n, 0x1c)), n) // the offset word, at head slot `n`
            mstore(add(p, add(n, 0x04)), tail.length)
            calldatacopy(add(p, add(n, 0x24)), tail.offset, tail.length)
            if iszero(call(gas(), target, 0, p, add(0x24, add(n, tail.length)), 0, 0)) {
                returndatacopy(p, 0, returndatasize())
                revert(p, returndatasize())
            }
        }
    }

}
