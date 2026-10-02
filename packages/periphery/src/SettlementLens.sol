// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IOrderValidator} from "@core/interfaces/IOrderValidator.sol";
import {IFillModule} from "@core/interfaces/IFillModule.sol";
import {SignatureVerification} from "@core/permit3/SignatureVerification.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {Order, ItemOp, OrderSide, FillCtx} from "@core/settlement/Structs.sol";
import {SettlementLensChecks} from "./SettlementLensChecks.sol";
import {OrderHash} from "@core/settlement/OrderHash.sol";
import {PackedArrays} from "@core/settlement/PackedArrays.sol";
import {DutchAuction} from "@core/settlement/DutchAuction.sol";
import {Pricing} from "@core/settlement/Pricing.sol";
import {OrderGates} from "@core/settlement/OrderGates.sol";
import {Proportional} from "@core/settlement/Proportional.sol";

/// @dev The subset of {Settlement}'s public/external surface this lens
///      reads. All are views on the live settlement, so the lens never needs the
///      settler's internal storage layout — only its already-exposed getters.
interface ISettlementState {
    function filled(bytes32 orderHash) external view returns (uint256);
    function isNonceCancelled(address maker, uint256 nonce) external view returns (bool);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function PERMIT3() external view returns (IPermit3);
    /// @dev The signature-less authorization record ({OrderState.approveOrder}).
    ///      Read so the lens can attest an empty-`sig` order instead of reporting
    ///      it unauthorized — see {SettlementLens._verifySignature}.
    function orderApproved(address maker, bytes32 orderHash) external view returns (bool);
    /// @dev The maker-keyed delegated-signer registry. Mirrored so the preflight
    ///      accepts exactly the signatures the settler accepts — a lens that is
    ///      STRICTER here silently drops fillable orders from an orderbook.
    function orderSignerExpiry(address maker, address signer) external view returns (uint256);
    /// @dev The settler's allowance-less callback trampoline. Read ONCE, at
    ///      construction, so {validateOrder} can flag an output leg addressed to it.
    function EXECUTOR() external view returns (address);
}

/// @title SettlementLens
/// @notice Read-only companion to {Settlement}. Holds the entire
///         off-chain preflight / preview / well-formedness surface a solver,
///         relayer, or maker UI calls BEFORE signing or submitting an order.
///         None of it runs during a fill, so it lives out here to keep the core
///         settler under the EIP-170 runtime-bytecode limit.
///
///         Every function is a pure/view helper over the order struct plus the
///         settlement's public state (`filled`, the nonce bitmap, live Permit3
///         allowances), read through {ISettlementState}. The lens holds no funds
///         and no approvals; it can only ever read.
contract SettlementLens {
    /// @dev Worst-case input cost of ONE anchor unit on an input leg — the leg
    ///      ceiling (`end`), or `start` when the leg is fixed (`end == 0`), or a
    ///      {Proportional} leg's resolved amount.
    /// @dev Its own frame purely to keep {_makerFillableCap} under the stack limit
    ///      without via-IR — the lens builds under the legacy profile.
    function _perUnitIn(address maker, address token, uint256 lgStart, uint256 lgEnd)
        private
        view
        returns (uint256)
    {
        if (Proportional.isProportional(lgStart)) return Proportional.resolve(token, maker, lgStart, lgEnd);
        return lgEnd == 0 ? lgStart : lgEnd;
    }

    using OrderHash for Order;
    using DutchAuction for Order;
    using Pricing for Order;

    /// @notice The settlement this lens reports on.
    ISettlementState public immutable SETTLEMENT;
    /// @notice Cached from the settlement at deploy — the Permit3 whose maker
    ///         allowances bound how much a plain order can actually fill.
    IPermit3 public immutable PERMIT3;

    /// @notice Lifecycle status for the solver-preflight view. Mirrors 0x's
    ///         `OrderStatus` so an off-chain filler can classify an order from a
    ///         single `getOrderRelevantState` call.
    /// @dev ⚠ `Cancelled` MEANS "cancelled, or a completed fill-once order", AND THAT
    ///      AMBIGUITY IS NOT FIXABLE HERE. The settler tracks lifecycle on two axes:
    ///      the per-hash `filled` counter (with its cancellation sentinel) and the
    ///      nonce bitmap. A {DutchAuction.useNonceInvalidator} order deliberately
    ///      keeps NO per-order counter — its progress IS the consumed nonce — so a
    ///      fill-once order that FILLED and one whose nonce the maker CANCELLED leave
    ///      byte-identical chain state. No view can separate them.
    ///
    ///      Consumers that need the distinction must read the `OrderFilled` event,
    ///      which the settler emits on the fill and not on the cancel. An indexer
    ///      following events already has this; a pure state poll never will.
    ///
    ///      Every OTHER case is exact: a per-hash `cancelOrder` reports `Cancelled`
    ///      (it used to report `Filled` — see the note in {_orderState}), and an
    ///      ordinary counted order reports `Filled` only when its counter actually
    ///      reached the denominator.
    enum OrderStatus {
        Invalid, // malformed, or a shape every fill reverts on (reserved nonce, see {SettlementLensChecks.deadShape}) — can never fill
        Fillable, // open, at least one unit still fillable
        Filled, // fully filled
        Cancelled, // per-hash sentinel, nonce bit set, below the rollback floor — or a
        // completed fill-once order (see the ambiguity note above)
        Expired, // past expiry
        Inconclusive // batch only: the order's own preflight exhausted its gas budget
        // ({ORDER_STATE_GAS}) or the call could no longer afford to start it
        // ({ORDER_STATE_ROW_GAS}) — NOT a verdict about the order. Appended last so
        // every existing value keeps its number; the ABI type stays `uint8`.
    }

    /// @notice Gas each order's preflight may spend inside {getOrderRelevantStates}.
    /// @dev    The per-order `try` used to forward all available gas. Every external
    ///         call an order triggers — its tokens' `balanceOf`/`allowance`, a 1271
    ///         `isValidSignature`, its validators — is maker-chosen code, so one order
    ///         whose token burns all gas took 63/64 of the CALL's budget with it, and
    ///         every later order in the batch ran out and read `Invalid`. An orderbook
    ///         evicting on `Invalid` then dropped a whole chunk of honest orders for one
    ///         poisoned one. Capping each order keeps the blast radius to that order.
    ///
    ///         A real order costs roughly 25–60k here (hash, cold balance/allowance
    ///         reads, one staticcall per validator); 500k is ~10× the heavy end, room
    ///         for several nontrivial validators and a Safe-style 1271 check.
    ///
    ///         An order that needs more is NOT always reported as "not evaluated" — an
    ///         earlier version of this note promised "Inconclusive, never Invalid",
    ///         which holds for only one of the three places the gas can run out:
    ///
    ///           • in the order's OWN frame (a token read, the hash, the state walk)
    ///             → the row reverts having spent the budget and reads
    ///             {OrderStatus.Inconclusive}: "not evaluated", never `Invalid`, so a
    ///             caller re-checks it (e.g. through the uncapped single-order
    ///             {getOrderRelevantState}) instead of discarding it;
    ///           • inside the SIGNATURE check → it depends. That check is its own
    ///             inner `try this.checkSignature`, handed 63/64 of what is left; its
    ///             out-of-gas is SWALLOWED there, and the row carries on with the
    ///             1/64 slices each call level kept back (~15–25k). If the state reads
    ///             fit in that, the row comes back `isSignatureValid = false` with a
    ///             real status (measured: an item order reads `Fillable`); if not, it
    ///             runs dry in its own frame and reads `Inconclusive` (measured: a
    ///             plain order, whose funding-cap reads are dearer). So a 1271 wallet
    ///             that verifies in pure Solidity — e.g. a P256 passkey wallet at
    ///             ~470k+ on a chain without the RIP-7212 precompile — CAN read here
    ///             as a bad signature;
    ///           • inside a VALIDATOR → `validatorsPass = false`, with the status and
    ///             signature verdicts intact: {OrderGates.gatePasses} reads a failed
    ///             staticcall as a rejection, exactly as for a rejecting validator.
    ///
    ///         So on a batch row, `isSignatureValid == false` and `validatorsPass ==
    ///         false` each mean "false, OR too expensive to tell under this cap". A
    ///         caller that evicts on either should confirm through the uncapped
    ///         {getOrderRelevantState} first, which has no cap of its own.
    uint256 public constant ORDER_STATE_GAS = 500_000;

    /// @dev Headroom a row needs ON TOP of {ORDER_STATE_GAS} before its capped call
    ///      starts: the call's own argument encoding (a copy of the order into
    ///      memory, outside the budget), the call overhead, EIP-150's 1/64 withheld
    ///      share, and the row's result writes.
    ///
    ///      The capped call receives the FULL budget whenever the order's encoding
    ///      costs under ~40k — every realistic order. That is NOT a guarantee (an
    ///      earlier version of this note said "always"): an order carrying ~130KB+
    ///      of blobs spends more than that on memory expansion alone, EIP-150 then
    ///      forwards less than {ORDER_STATE_GAS}, and the encoding also eats into
    ///      the per-row reserve kept for later rows ({ORDER_STATE_ROW_GAS}). The
    ///      CLASSIFICATION survives it — the OOG test in {_cappedState} measures
    ///      from BEFORE the encoding, so encoding plus a starved call still sums
    ///      past the budget and reads `Inconclusive`, never `Invalid` — only the
    ///      budget, and at worst the batch's ability to finish, shrink.
    uint256 private constant ORDER_STATE_RESERVE = 50_000;

    /// @dev What each row still to be written costs AFTER a capped call has spent
    ///      its whole budget: the short-circuit `Inconclusive` path (calldata
    ///      offset checks on `orders[i]`/`sigs[i]`/`takerDatas[i]`, the gas test, four
    ///      array writes) plus that row's share of ABI-encoding the four return
    ///      arrays. A row may start its capped call only while
    ///      `ORDER_STATE_GAS + ORDER_STATE_RESERVE + rowsLeft * ORDER_STATE_ROW_GAS`
    ///      is left, so however the budgeted row ends, every later row can still be
    ///      MARKED and the call still RETURNS.
    ///
    ///      Without this term the reserve was per-row only, and a batch whose early
    ///      row burned its budget could not afford to mark the rest: a poison row 0
    ///      under a 560k call reverted the WHOLE call from n ≥ 35 (and at 575k,
    ///      n = 60 / 100) — the eviction-of-the-chunk failure the cap exists to stop,
    ///      moved from the honest rows to the call itself.
    ///
    ///      MEASURED 2026-09-29, slope over n = 1 → 51 → 101 short-circuited rows,
    ///      return encoding included: **1,870 gas/row** under the legacy `periphery`
    ///      profile, **1,663** under the deployed via-IR settings. 4,000 is ~2×
    ///      the dearer one. The margin is for memory expansion: every EVALUATED row
    ///      leaves its call buffer (~1.3KB for a plain order) allocated, so the
    ///      return encoding at the end pays a higher per-word price the more rows ran
    ///      before it — still under +100 gas/row at 100 rows. Cost of the margin: a
    ///      batch of `n` rows needs `n × 4k` more than before to START its first
    ///      row (400k at n = 100), and near the end of a tight budget the last
    ///      rows are marked a little earlier than they strictly had to be.
    uint256 private constant ORDER_STATE_ROW_GAS = 4_000;

    /// @dev An empty `sig` with no matching on-chain approval. Mirrors
    ///      {Signatures.OrderNotApproved}; surfaces through `checkSignature` and
    ///      as `isSignatureValid == false`.
    error OrderNotApproved();

    constructor(address settlement) {
        SETTLEMENT = ISettlementState(settlement);
        PERMIT3 = ISettlementState(settlement).PERMIT3();
        CHECKS = new SettlementLensChecks(settlement);
    }

    // ──────────────────── Order hash / previews ────────────────────

    function hashOrder(Order calldata order) external pure returns (bytes32) {
        return order.hash();
    }

    /// @notice Current output tick for every leg — the auction price for SELL, the
    ///         fixed output for BUY.
    function previewAmountOut(Order calldata order) external view returns (uint256[] memory) {
        return order.currentAmountOut();
    }

    /// @notice Current input tick for every leg — fixed where `start == end`,
    ///         the rising auction price where `start != end` (BUY conversion
    ///         inputs, SELL relayer-fee legs).
    function previewAmountIn(Order calldata order) external view returns (uint256[] memory) {
        return order.currentAmountIn();
    }

    /// @notice Remaining fillable amount, in denominator units (`fillTotal` when
    ///         set, else `tokenIn[0]` for SELL / `tokenOut[0]` for BUY).
    /// @dev    A per-hash cancellation ({OrderState.cancelOrder}) parks `filled` at
    ///         `type(uint256).max`, which is ABOVE any real denominator — so without
    ///         the sentinel check the subtraction below underflows and this view
    ///         answers a plain `Panic(0x11)` instead of the {OrderCancelled} this
    ///         contract already declares and its sibling {_resolveState} already
    ///         raises. That inconsistency was the bug: `_resolveState`'s docstring
    ///         says it exists so the quote paths "can never disagree about the cancel
    ///         semantics", and this function had been left out of that consolidation.
    ///
    ///         Reverting (rather than answering 0) is deliberate: 0 is already the
    ///         truthful answer for a FULLY FILLED order, and collapsing the two would
    ///         hand callers the same number for "done" and "revoked". A caller that
    ///         needs a batch-safe, non-reverting answer over a whole book should use
    ///         {getOrderRelevantState}, which returns a status enum and never throws
    ///         for a cancelled order.
    ///
    ///         A {Proportional} order that has filled answers 0 (audit 2026-09-30
    ///         PERIPH-8). Its denominator is the maker's LIVE balance, so after a
    ///         100% sweep it resolves to 0 while `filled` holds the swept amount, and
    ///         the subtraction used to panic `0x11`. Any progress at all means it is
    ///         done: a proportional fill is whole ({Pricing.inputOwed} reverts
    ///         `ProportionalNeedsFullFill` on anything else), so no second fill can run
    ///         whatever the balance has become. The same `done >= denominator` guard
    ///         covers every other order whose denominator could sit below its counter.
    function remaining(Order calldata order) external view returns (uint256) {
        uint256 done = SETTLEMENT.filled(order.hash());
        if (done == type(uint256).max) revert OrderCancelled();
        uint256 total = OrderGates.fillDenominator(order);
        if (done >= total || (done != 0 && _proportionalAnchor(order))) return 0;
        return total - done;
    }

    /// @notice Preview EXACTLY what `Settlement.fillUpTo` would settle right now —
    ///         the custom-fill quote call. Runs the same clamp, the same exclusivity
    ///         override, and the same per-leg {Pricing} math the settlement runs, so
    ///         an `eth_call` here at block N equals a fill executed at block N.
    /// @dev    Scope: the AMOUNT pipeline only. Lifecycle gates (expiry, nonce,
    ///         cancellation, signature, validators, maker funding) are the job of
    ///         {getOrderRelevantState} — call both. Mirrored execution reverts are
    ///         kept where they change the answer: a hard-exclusive order previews as
    ///         {NotExclusiveFiller} for an outside filler, and a clamped delta under
    ///         the maker's floor as {FillTooSmall} — exactly as the fill would.
    ///         Time-sensitive: decay and the gas bump price off `block.timestamp` /
    ///         `basefee` at the call's block.
    /// @param  fillAmount The requested size (anchor units; a proposal for a
    ///         fill-module order). Clamped to remaining for identity orders,
    ///         resolved through the maker's `fillModule` otherwise. A {Proportional}
    ///         order is NOT clamped: a request above its live resolved anchor
    ///         previews as {OverFill}, exactly as the fill reverts — pass
    ///         `type(uint256).max` to accept whatever the balance is. For a
    ///         fill-module order `type(uint256).max` reaches the module as the
    ///         remainder, and a module delta above the request previews as
    ///         {OverFill}, as the settler reverts.
    /// @param  filler     The would-be `msg.sender` of the fill (exclusivity).
    /// @param  takerData  The blob the filler would submit (fill-module proposal);
    ///         `""` for plain orders.
    /// @return delta      Anchor-unit progress the fill would execute.
    /// @return received   Per-`legsIn` amounts the filler would be paid.
    /// @return paid       Per-`legsOut` amounts the filler would deliver.
    function previewFill(Order calldata order, uint256 fillAmount, address filler, bytes calldata takerData)
        external
        view
        returns (uint256 delta, uint256[] memory received, uint256[] memory paid)
    {
        // Split frames (ctx resolve / leg pricing) to stay under the stack limit
        // without via-IR, like the settlement's own settle helpers.
        FillCtx memory ctx = _previewCtx(order, fillAmount, filler, takerData);
        // The core's SECOND outsider-only refusal (audit 2026-09-30 PERIPH-2.v2): a
        // PRE-FUNDED leg-reference descriptor run under a live soft override reverts
        // `ForLegInvalid` in {Base._forSlice}, deep inside item execution, which this
        // preview never runs. Mirrored here so `previewFill` — and everything quoting
        // through it, {OriginSettler7683} included — refuses exactly the fills the
        // settler refuses. {OrderGates.exclusivityOverride} in {_previewCtx} already
        // mirrors the first (a hard window, or a soft one with no carrier). Here and
        // not inside {_previewCtx}, whose frame is at the legacy stack limit.
        if (ctx.overrideBps != 0 && _hasPreFundDescriptor(order)) revert ForLegInvalid();
        unchecked {
            delta = ctx.newFilled - ctx.prevFilled; // resolve guarantees new >= prev
        }
        (received, paid) = _previewAmounts(order, ctx);
    }

    /// @notice The resolved shared decay bump a fill by `filler` would price at
    ///         RIGHT NOW — the quote side of `fillUpTo`'s `minBumpBps` price
    ///         floor. Resolves exactly as the fill does: the pinned path for a
    ///         price-module / priority-auction order (with the real `filler`,
    ///         fill progress and taker blob), the clock otherwise. Pass the
    ///         returned value as `minBumpBps` and the fill executes at this
    ///         quote's price or better on every leg, or reverts `BumpTooLow`.
    /// @dev    Time-sensitive the same way {previewFill} is: an `eth_call` here
    ///         at block N equals a fill at block N. All-fixed orders (nothing
    ///         decays) return 0 — there is no price motion to protect against.
    ///
    ///         ⚠ PASS THE FLOOR ON EVERY ORDER WHOSE PRICE CAN MOVE MAKER-WARD
    ///         between quote and inclusion. Five movers do: a price module (oracle-,
    ///         state- or filler-keyed — including one keyed on the filler through a
    ///         wrapper contract); a PRIORITY bid, which a basefee drop (or a legacy
    ///         gas price) widens; a falling-basefee gas bump; and a descending curve
    ///         segment. PRIORITY-auction orders derive the bump from `tx.gasprice`,
    ///         so a default `eth_call` (gas price 0) quotes the NO-BID bump —
    ///         quote with the gas price you will actually send. Every fill entry
    ///         takes the floor: `fillUpTo`, `fillWithPermit`, `fillWithPermitTake`
    ///         and `batchFill` (per order).
    function previewBump(Order calldata order, address filler, bytes calldata takerData)
        external
        view
        returns (uint256 bump)
    {
        (bytes32 orderHash, uint256 total, uint256 prevFilled) = _resolveState(order);
        uint256 pinned = DutchAuction.resolveBump(order, orderHash, total, filler, prevFilled, takerData);
        return pinned != 0 ? pinned - 1 : DutchAuction.bumpBps(order);
    }

    /// @notice Capture what {previewFillInFlight} needs, BEFORE calling `fill`.
    ///         Two of the three cannot be recovered afterwards, so this call is
    ///         not optional for a callback taker.
    /// @return orderHash the order's hash, so the caller need not recompute it.
    /// @return prevFilled progress BEFORE this fill. Read live here; once the
    ///         fill runs, `filled` includes it and the pre-fill value is gone.
    /// @return anchor the fill denominator. A {Proportional} order resolves it
    ///         against the maker's LIVE balance, which `CallbackMode.PostInputs`
    ///         has already changed by callback time.
    function fillState(Order calldata order)
        external
        view
        returns (bytes32 orderHash, uint256 prevFilled, uint256 anchor)
    {
        orderHash = order.hash();
        prevFilled = SETTLEMENT.filled(orderHash);
        if (prevFilled == type(uint256).max) revert OrderCancelled();
        anchor = OrderGates.fillDenominator(order);
    }

    /// @notice Preview the fill CURRENTLY IN FLIGHT, from inside a solver's
    ///         callback — the amounts {Pricing} is about to demand.
    ///
    ///  ⚠ {previewFill} CANNOT BE USED FOR THIS, which is the reason this exists.
    ///  {OrderState._openFill} writes `filled[orderHash] = newFilled` BEFORE the
    ///  callback runs, so the ordinary preview reads a progress that already
    ///  includes this fill and prices the NEXT one.
    ///
    ///  ⚠ THE DELTA IS DISCOVERED, NOT ASSUMED. It would be tempting to take the
    ///  caller's `fillAmount` and subtract — and wrong: that holds only for an
    ///  IDENTITY order. A fill-module order's delta is whatever
    ///  {IFillModule.resolveFill} returned, which the settler accepted and the
    ///  caller never sees. So the pre-fill progress is CAPTURED ({fillState}) and
    ///  the post-fill value is read here, making `delta = newFilled - prevFilled`
    ///  true for every fill mechanism rather than for the common one.
    ///
    ///  One view call, and a callback taker then needs no order in its own
    ///  `callbackData` and no private copy of the settlement's pricing.
    ///
    /// @param  prevFilled  from {fillState}, captured before the fill.
    /// @param  anchor      from {fillState}. Pass `0` to re-derive — safe for
    ///                     everything except a {Proportional} order under
    ///                     `PostInputs`, where the maker has already paid.
    /// @param  filler      the fill's `msg.sender`; exclusivity and price modules
    ///                     key on it.
    /// @param  takerData   the same blob passed to the fill — a price module
    ///                     reads it, and omitting it re-prices the order.
    /// @return received    per-`legsIn` amounts the filler is paid.
    /// @return paid        per-`legsOut` amounts the filler must deliver.
    function previewFillInFlight(
        Order calldata order,
        uint256 prevFilled,
        uint256 anchor,
        address filler,
        bytes calldata takerData
    ) external view returns (uint256[] memory received, uint256[] memory paid) {
        FillCtx memory ctx = _inFlightCtx(order, prevFilled, anchor, filler);
        ctx.bump = DutchAuction.resolveBump(order, ctx.orderHash, ctx.anchor, filler, ctx.prevFilled, takerData);
        return _previewAmounts(order, ctx);
    }

    /// @notice The bump a PRICE-MODULE or PRIORITY-auction fill by `filler` will PIN,
    ///         plus one — `0` for a clock-priced order, which pins nothing. Capture it
    ///         alongside {fillState}, in the same transaction and immediately before
    ///         the fill, and hand it to {previewFillInFlightPinned}.
    /// @dev    Exact for the fill that follows: {OrderState._openFill} resolves the
    ///         same {DutchAuction.resolveBump} with the same filler, taker blob,
    ///         progress, block and gas price, and nothing between this call and that
    ///         one changes state the module could read.
    function pinnedBump(Order calldata order, address filler, bytes calldata takerData)
        external
        view
        returns (uint256)
    {
        (bytes32 orderHash, uint256 total, uint256 prevFilled) = _resolveState(order);
        return DutchAuction.resolveBump(order, orderHash, total, filler, prevFilled, takerData);
    }

    /// @notice {previewFillInFlight} at a bump captured BEFORE the fill
    ///         ({pinnedBump}) instead of one re-resolved from inside the callback.
    ///
    ///  ⚠ WHY THIS EXISTS (audit 2026-09-30 CORE-FILLER-5). The settlement resolves a
    ///  price-module or priority bump ONCE, in {OrderState._openFill}, and pins it for
    ///  the whole fill. {previewFillInFlight} resolves it AGAIN from inside the
    ///  callback — and a module that reads state the fill has since moved (a balance a
    ///  `PostInputs` payment changed, a pool the callback swapped through, an oracle
    ///  price pushed in the callback) then answers differently from the pin: an
    ///  under-statement reverts the fill, an over-statement over-sources inventory.
    ///  {previewFillInFlight} is therefore exact only for CLOCK-priced orders; for a
    ///  module or priority order use this, or the typed callback's
    ///  `pricedIn`/`pricedOut`, which carry the settlement's own figures.
    /// @param  pin  {pinnedBump}'s return value (`bump + 1`, or 0 for a clock order).
    function previewFillInFlightPinned(
        Order calldata order,
        uint256 prevFilled,
        uint256 anchor,
        address filler,
        uint256 pin
    ) external view returns (uint256[] memory received, uint256[] memory paid) {
        FillCtx memory ctx = _inFlightCtx(order, prevFilled, anchor, filler);
        ctx.bump = pin;
        return _previewAmounts(order, ctx);
    }

    /// @dev The in-flight {FillCtx}, rebuilt from a captured `prevFilled` plus the
    ///      live post-fill counter, with the bump left for the caller to set (resolved
    ///      afresh, or the captured pin). Deliberately NOT sharing {_previewCtx}: that
    ///      one resolves a delta FORWARD from pre-fill state (clamping, fill-module
    ///      dispatch, the Zero/OverFill gates), whereas this reads a delta that has
    ///      already been decided. Folding them would make one path's guards fire on
    ///      the other's inputs.
    function _inFlightCtx(Order calldata order, uint256 prevFilled, uint256 anchor, address filler)
        private
        view
        returns (FillCtx memory)
    {
        bytes32 orderHash = order.hash();
        uint256 total = anchor != 0 ? anchor : OrderGates.fillDenominator(order);

        uint256 newFilled;
        if (order.useNonceInvalidator()) {
            // A fill-once order never writes `filled` — it burns the nonce instead,
            // and {_openFill} accepts only a FULL fill. So the progress this fill
            // made is the whole order, whatever the counter says.
            newFilled = total;
            prevFilled = 0;
        } else {
            newFilled = SETTLEMENT.filled(orderHash);
            if (newFilled == type(uint256).max) revert OrderCancelled();
            if (newFilled < prevFilled) revert OverFill();
        }

        return FillCtx(
            orderHash,
            total,
            prevFilled,
            newFilled,
            OrderGates.exclusivityOverride(order, filler),
            filler,
            filler,
            prevFilled == 0 && newFilled == total,
            0, // the bump — set by the caller
            "",
            new uint256[](0), // no delivery ledger in a preview — nothing was delivered
            0,
            new uint256[](0),
            0 // no filler price floor in a preview
        );
    }

    /// @dev The state preamble both quote paths ({previewBump} and {_previewCtx})
    ///      resolve: the order hash, the fill denominator, and the pre-fill progress,
    ///      with the cancelled-sentinel check. Shared so the two can never disagree
    ///      about the progress axis or the cancel semantics — the exact drift a floor
    ///      quote (`previewBump`) diverging from the price (`previewFill`) would cause.
    ///      Stops BEFORE {DutchAuction.resolveBump} deliberately: `_previewCtx` must
    ///      run its Zero/OverFill/FillTooSmall checks first, so folding the bump in here
    ///      would reorder which revert surfaces.
    function _resolveState(Order calldata order)
        private
        view
        returns (bytes32 orderHash, uint256 total, uint256 prevFilled)
    {
        orderHash = order.hash();
        total = OrderGates.fillDenominator(order);
        prevFilled = SETTLEMENT.filled(orderHash);
        if (prevFilled == type(uint256).max) revert OrderCancelled();
    }

    /// @dev Whether the fill denominator is a {Proportional} anchor: a SELL order,
    ///      no `fillTotal`, a marker in `legsIn[0].start` — the exact predicate
    ///      `Core._clampToRemaining` tests. Callers must already know `legsIn` is
    ///      non-empty (the read is unchecked, as the core's is): {_previewCtx} via
    ///      {OrderGates.anchorTotal}'s `NoAnchorLeg`, {_orderState} via its own
    ///      anchor-leg shape gate.
    function _proportionalAnchor(Order calldata order) private pure returns (bool) {
        if (order.fillTotal != 0 || order.side() != OrderSide.SELL) return false;
        (, uint256 start0,) = PackedArrays.legIn(order.legsIn, 0);
        return Proportional.isProportional(start0);
    }

    /// @dev Mirror of `Core._clampToRemaining` + `OrderState._openFill`'s delta
    ///      resolution: identity orders clamp to remaining — EXCEPT an oversized
    ///      request on a {Proportional} anchor, which passes through unclamped and
    ///      reverts `OverFill` as the fill does (`type(uint256).max` excepted: it
    ///      is still trimmed); module orders resolve the proposal through the
    ///      maker's (view) fill module. Packages the result as the same {FillCtx}
    ///      the settlement would price with.
    function _previewCtx(Order calldata order, uint256 fillAmount, address filler, bytes calldata takerData)
        private
        view
        returns (FillCtx memory)
    {
        if (fillAmount == 0) revert ZeroFill();
        // Mirror of {Base._gateOrderPost}: the top half of the nonce space is the
        // delegated-signer permits' ({NonceManager.SIGNER_NONCE_NS}), and every fill
        // of an order in it reverts (audit 2026-09-30 PERIPH-5 — the F29 8b mirror
        // had reached {validateOrder} only).
        if (order.nonce >> 255 != 0) revert OrderNonceReserved();
        (bytes32 orderHash, uint256 total, uint256 prevFilled) = _resolveState(order);

        uint256 delta;
        if (order.fillModule == address(0)) {
            if (prevFilled < total) {
                uint256 rem = total - prevFilled;
                // ⚠ NEVER TRIM A {Proportional} REQUEST DOWN — mirror of the
                // re-audit 2026-09-29 rule in `Core._clampToRemaining`. A proportional
                // fill is whole and pays every output IN FULL whatever the anchor
                // resolves to, so the settler no longer shrinks a quoted size onto a
                // balance the maker drained since the quote: an oversized request
                // reaches {_openFill} unclamped and reverts `OverFill`. A preview that
                // still trimmed would quote the dust fill as a success — the exact
                // front-run the core closed. `type(uint256).max` stays the explicit
                // "whatever the balance is" opt-in and is trimmed, as it is there.
                if (fillAmount > rem && (fillAmount == type(uint256).max || !_proportionalAnchor(order))) {
                    fillAmount = rem;
                }
            }
            delta = fillAmount;
        } else {
            // Mirror of {OrderState._openFill} (audit 2026-09-30 CORE-FILL-4 /
            // CORE-FILLER-2): `max` is resolved to the remainder BEFORE the module
            // sees it, and the module's delta may never exceed the request. A
            // cancelled/complete order already reverted in {_resolveState} or
            // reverts `OverFill` below, so the subtraction is guarded.
            if (fillAmount == type(uint256).max && prevFilled < total) fillAmount = total - prevFilled;
            delta = IFillModule(order.fillModule).resolveFill(order, prevFilled, fillAmount, takerData);
            if (delta == 0) revert ZeroFill();
            if (delta > fillAmount) revert OverFill();
        }
        if (delta < order.minFillAnchor) revert FillTooSmall();
        uint256 newFilled = prevFilled + delta;
        if (newFilled > total) revert OverFill();
        // Mirror of {OrderState._openFill}: a FILL-ONCE order (timing bit 100) is
        // whole or nothing, and a preview that quoted a partial was quoting a fill
        // the settler reverts (F29 finding 8a).
        if (order.useNonceInvalidator() && newFilled != total) revert FillOnceMustBeFull();
        // Mirror of {Core._snapshotOutRecipients}: a DELTA-VERIFY order fills for its
        // named `exclusiveFiller` only, for its whole life (re-audit F30).
        if (order.deltaVerifyOutputs() && filler != order.exclusiveFiller) revert OrderGates.NotExclusiveFiller();

        return FillCtx(
            orderHash,
            total,
            prevFilled,
            newFilled,
            OrderGates.exclusivityOverride(order, filler),
            filler,
            filler,
            prevFilled == 0 && newFilled == total,
            // A price-module order is resolved with the REAL preview inputs here — the
            // filler and taker blob the caller supplied — rather than through
            // {DutchAuction.bumpBps}'s anonymous preview, so a quote from this lens is
            // exactly what that filler would get. Pinned the same way a fill pins it.
            DutchAuction.resolveBump(order, orderHash, total, filler, prevFilled, takerData),
            "", // no one-shot taker permit in a preview — see {FillCtx.permitTake}
            new uint256[](0), // no delivery ledger in a preview — nothing was delivered
            0,
            new uint256[](0), // preview prices legs directly; no payout ledger to record
            0 // no filler price floor in a preview
        );
    }

    /// @dev Whether any item carries a PRE-FUNDED leg-reference descriptor — word 0
    ///      of its `data` with top bits `101` (`>> 253 == 5`: bit 255 leg/balance
    ///      form, bit 254 clear = leg reference, bit 253 = pre-fund) on a `MAKE` or a
    ///      `TAKE_FOR`, the two ops {Base._runItem} sizes through {Base._forSlice}.
    ///      Any other op's word 0 is module data, never a descriptor.
    function _hasPreFundDescriptor(Order calldata order) private pure returns (bool) {
        uint256 n = PackedArrays.validateRecords(order.items, PackedArrays.ITEM_HEAD);
        uint256 cursor = PackedArrays.recordsStart();
        for (uint256 i; i < n; i++) {
            (uint256 op,,,, bytes calldata data, uint256 next) = PackedArrays.itemAt(order.items, cursor);
            if (
                (op == uint256(ItemOp.MAKE) || op == uint256(ItemOp.TAKE_FOR)) && data.length >= 32
                    && uint256(bytes32(data[0:32])) >> 253 == 5
            ) return true;
            cursor = next;
        }
        return false;
    }

    /// @dev Price every leg for the resolved ctx — the same {Pricing} calls the
    ///      fill's delivery/payout run.
    function _previewAmounts(Order calldata order, FillCtx memory ctx)
        private
        view
        returns (uint256[] memory received, uint256[] memory paid)
    {
        received = new uint256[](PackedArrays.validateFixed(order.legsIn, PackedArrays.LEG_IN_STRIDE));
        for (uint256 i; i < received.length; i++) {
            received[i] = order.inputOwed(ctx, i);
        }
        paid = new uint256[](PackedArrays.validateFixed(order.legsOut, PackedArrays.LEG_OUT_STRIDE));
        for (uint256 j; j < paid.length; j++) {
            paid[j] = order.outputAt(ctx, j);
        }
    }


    // Mirrored settlement errors (same signatures ⇒ same selectors), so preview
    // reverts decode identically to execution reverts in any tooling.
    // Re-declared rather than imported: an error's selector is derived from its
    // NAME and ARG TYPES, not from the contract that declares it, so each of these
    // decodes identically to the settler's own. A preview therefore fails with the
    // exact error the fill would.
    error ZeroFill();
    error OverFill();
    error FillTooSmall();
    error OrderCancelled();
    error FillOnceMustBeFull();
    error OrderNonceReserved();
    error ForLegInvalid();

    // ──────────────────── Solver preflight ────────────────────

    /// @notice One-call preflight for a solver/filler: classify the order, report
    ///         how much is ACTUALLY fillable right now (capped by the maker's live
    ///         Permit3 allowance + balance for plain orders), whether the
    ///         signature recovers to the maker, and whether the order's
    ///         pre-execution validators currently pass for `filler`. The 0x
    ///         `getOrderRelevantState` analogue — lets a filler skip orders that
    ///         would revert without simulating the whole fill.
    /// @dev    `fillableAmount` is in anchor units (`tokenIn[0]` for SELL,
    ///         `tokenOut[0]` for BUY). For orders WITH items the tokenIn is
    ///         (partly) produced on-chain by TAKE legs, which can't be known
    ///         statically, so the allowance/balance cap is applied only to plain
    ///         (item-free) orders; item orders report the full remaining amount.
    ///         For BUY orders the maker-capacity cap uses each leg's worst-case
    ///         (ceiling) input tick, so it is a conservative lower bound. This is a
    ///         best-effort hint, not a guarantee — the fill remains the truth.
    /// @param  filler The would-be filler the validators are previewed for
    ///         (validators receive the filler address, so filler-conditional
    ///         orders — e.g. per-order solver whitelists — preview correctly).
    ///         `validatorsPass` covers `order.validators` only; post-execution
    ///         invariants depend on the fill's side effects and are not
    ///         previewable statically.
    /// @param  takerData The filler-supplied blob the filler intends to submit with
    ///         the fill (unsigned/adversarial — see {IOrderValidator}); previewed
    ///         through the validators exactly as the settlement would pass it, so a
    ///         takerData-consuming validator (e.g. an off-chain attestation gate)
    ///         previews correctly. Pass empty (`""`) for orders that don't use it.
    function getOrderRelevantState(Order calldata order, bytes calldata sig, address filler, bytes calldata takerData)
        external
        view
        returns (OrderStatus status, uint256 fillableAmount, bool isSignatureValid, bool validatorsPass)
    {
        bytes32 orderHash = order.hash();
        try this.checkSignature(orderHash, sig, order.maker) {
            isSignatureValid = true;
        } catch {
            isSignatureValid = false;
        }
        (status, fillableAmount) = _orderState(order, orderHash);
        validatorsPass = _validatorsPass(order, filler, takerData);
    }

    /// @notice Batch preflight (one `filler`, many orders — the common solver
    ///         loop). Any order that reverts (malformed, etc.) degrades to
    ///         `Invalid` / 0 / false instead of failing the whole call — the 0x
    ///         "swallows reverts" batch-state behaviour.
    ///
    ///         Each order runs under its own {ORDER_STATE_GAS} budget. One that
    ///         spends all of it in its own frame, and every order the call no longer
    ///         has gas to start, reports {OrderStatus.Inconclusive} — "not
    ///         evaluated", which a caller must NOT treat as `Invalid`. (One that runs
    ///         out inside its signature check or a validator can instead read as a
    ///         `false` flag — see {ORDER_STATE_GAS}.) A row is started only while the
    ///         call can still afford to mark every row after it
    ///         ({ORDER_STATE_ROW_GAS}), so the call does not revert for running
    ///         short; it returns what it managed and marks the rest.
    /// @param  takerDatas Per-order filler-supplied blobs, aligned 1:1 with
    ///         `orders` (`takerDatas[i]` previews order `i`). Pass empty entries for
    ///         orders that don't consume it. Must be the same length as `orders`.
    function getOrderRelevantStates(
        Order[] calldata orders,
        bytes[] calldata sigs,
        address filler,
        bytes[] calldata takerDatas
    )
        external
        view
        returns (
            OrderStatus[] memory statuses,
            uint256[] memory fillableAmounts,
            bool[] memory sigValids,
            bool[] memory validatorsPass
        )
    {
        uint256 n = orders.length;
        statuses = new OrderStatus[](n);
        fillableAmounts = new uint256[](n);
        sigValids = new bool[](n);
        validatorsPass = new bool[](n);
        for (uint256 i; i < n; i++) {
            (statuses[i], fillableAmounts[i], sigValids[i], validatorsPass[i]) =
                _cappedState(orders[i], sigs[i], filler, takerDatas[i], n - i);
        }
    }

    /// @dev One batch row under its {ORDER_STATE_GAS} budget. Its own frame purely to
    ///      keep {getOrderRelevantStates} under the stack limit without via-IR.
    /// @param rowsLeft This row and every row after it — each must still be
    ///        affordable as a short-circuit `Inconclusive` once this row's budget is
    ///        gone ({ORDER_STATE_ROW_GAS}).
    function _cappedState(
        Order calldata order,
        bytes calldata sig,
        address filler,
        bytes calldata takerData,
        uint256 rowsLeft
    ) private view returns (OrderStatus, uint256, bool, bool) {
        uint256 before = gasleft();
        // The call's budget, not the order: say so rather than guess. The reserve
        // covers THIS row's overhead AND marking every later row — a row that may
        // burn its whole budget is only started if the call can still return after.
        if (before < ORDER_STATE_GAS + ORDER_STATE_RESERVE + rowsLeft * ORDER_STATE_ROW_GAS) {
            return (OrderStatus.Inconclusive, 0, false, false);
        }
        try this.getOrderRelevantState{gas: ORDER_STATE_GAS}(order, sig, filler, takerData) returns (
            OrderStatus s, uint256 f, bool v, bool vp
        ) {
            return (s, f, v, vp);
        } catch {
            // A revert that consumed the whole budget is an out-of-gas, which says
            // nothing about the order's validity. A near-budget ordinary revert lands
            // here too — conservative: it is re-checked, not discarded.
            return (
                before - gasleft() >= ORDER_STATE_GAS ? OrderStatus.Inconclusive : OrderStatus.Invalid, 0, false, false
            );
        }
    }

    /// @notice External wrapper so the (reverting) signature check can be caught
    ///         by `try/catch` from a `view`. Reverts iff the signature is invalid.
    function checkSignature(bytes32 orderHash, bytes calldata sig, address expected) external view {
        _verifySignature(orderHash, sig, expected);
    }

    /// @dev Status + live-fillable amount (anchor units), without touching the sig.
    function _orderState(Order calldata order, bytes32 orderHash)
        internal
        view
        returns (OrderStatus status, uint256 fillableAmount)
    {
        // Malformed shape → Invalid (guards the array indexing below). Each side
        // needs the leg its anchor reads: SELL anchors on `tokenIn[0]`, BUY on
        // `tokenOut[0]`. So a BUY may have empty tokenIn (consideration supplied
        // by items — e.g. an NFT-sale SETTLE) and a SELL may have empty tokenOut
        // (a gasless deposit). A `fillTotal != 0` order is denominated by
        // `fillTotal`, not a leg, so it may have both empty (a pure NFT swap).
        bool moduleFill = order.fillTotal != 0;
        uint256 nIn = PackedArrays.validateFixed(order.legsIn, PackedArrays.LEG_IN_STRIDE);
        uint256 nOut = PackedArrays.validateFixed(order.legsOut, PackedArrays.LEG_OUT_STRIDE);
        // The leg structs make token↔amount length mismatch impossible; only the
        // anchor-leg-presence check remains. SELL anchors on `legsIn[0]`, BUY on
        // `legsOut[0]` (unless `fillTotal` supplies the denominator directly), so a
        // BUY may have empty legsIn (an NFT-sale SETTLE) and a SELL empty legsOut.
        if (
            !moduleFill
                && ((nIn == 0 && order.side() == OrderSide.SELL) || (nOut == 0 && order.side() == OrderSide.BUY))
        ) {
            return (OrderStatus.Invalid, 0);
        }
        // Shapes EVERY fill reverts on, whatever the state — named `Invalid` rather
        // than read `Fillable`, because an orderbook admits on this view alone:
        //   • a nonce in the reserved signer-permit half: {Base._gateOrderPost}
        //     reverts `OrderNonceReserved` (audit 2026-09-30 PERIPH-5);
        //   • the structural defects {SettlementLensChecks.deadShape} names — a
        //     misplaced proportional marker, an auction leg moving the wrong way, a
        //     priority auction without a scale, an unknown item op, a malformed
        //     items / invariants / validators blob (G-LENS_PARITY-6). A probe that
        //     reverts is read as dead too: the settlement would revert on it.
        if (order.nonce >> 255 != 0 || !_shapeLive(order)) return (OrderStatus.Invalid, 0);
        if (block.timestamp > order.expiry()) return (OrderStatus.Expired, 0);

        // THE SETTLER TRACKS LIFECYCLE ON TWO AXES, AND THIS FUNCTION MUST NOT
        // COLLAPSE THEM. {OrderState.cancelOrder} records a PER-HASH cancellation by
        // parking `filled` at `type(uint256).max`; {NonceManager} records a BULK one
        // in the nonce bitmap. Reading only the bitmap meant a hash-cancelled order
        // fell through to the `done >= anchor` compare below — where the sentinel is
        // trivially ≥ any real denominator — and was reported as **Filled**. Indexers
        // and maker dashboards then showed a cancelled order as executed.
        //
        // Checked BEFORE the denominator is resolved, because for a cancelled order
        // that resolve is wasted work (and, for a {Proportional} anchor, a wasted
        // `balanceOf` staticcall).
        uint256 done = SETTLEMENT.filled(orderHash);
        if (done == type(uint256).max) return (OrderStatus.Cancelled, 0);
        if (SETTLEMENT.isNonceCancelled(order.maker, order.nonce)) return (OrderStatus.Cancelled, 0);

        // A {Proportional} order with ANY progress is done: its fill is whole
        // ({Pricing.inputOwed} reverts `ProportionalNeedsFullFill` otherwise), so no
        // second fill can run. Checked before the denominator, which a 100% sweep has
        // since resolved to 0 and which would read the executed sweep as `Fillable`
        // (audit 2026-09-30 PERIPH-8).
        if (done != 0 && _proportionalAnchor(order)) return (OrderStatus.Filled, 0);
        uint256 anchor = OrderGates.fillDenominator(order);
        // A {Proportional} anchor resolves from the maker's LIVE balance and can be
        // 0 right now; that is "nothing to fill yet", not "filled" (F29 finding 8f).
        if (anchor == 0) return (OrderStatus.Fillable, 0);
        if (done >= anchor) return (OrderStatus.Filled, 0);

        fillableAmount = anchor - done;
        // THE MINIMUM FILL IS THE THIRD "CANNOT FILL AT ALL" RULE (audit 2026-09-30
        // G-LENS_PARITY-2), beside the two below. Every fill whose delta is under
        // `minFillAnchor` reverts `FillTooSmall`, and no fill can execute more than
        // the remainder (`fill` reverts `OverFill` above it, `fillUpTo` clamps down to
        // it) — so a tail below the floor is dead for good, and was read `Fillable`.
        if (fillableAmount < order.minFillAnchor) return (OrderStatus.Fillable, 0);
        // Plain orders: the maker funds tokenIn from their wallet, so cap the
        // fillable amount by their live capacity across every input leg. Skipped
        // for module orders — the fillable is in `fillTotal` units, not leg units.
        if (PackedArrays.countUnchecked(order.items) == 0 && order.fillModule == address(0)) {
            (uint256 cap, bool capExact) = _makerFillableCap(order, anchor);
            if (cap < fillableAmount) {
                fillableAmount = cap;
                // The same floor against the FUNDING cap — but only where that cap is
                // exact rather than a worst-case lower bound on what the maker can
                // fund: zeroing a conservative figure would make this view stricter
                // than the settler.
                if (capExact && cap < order.minFillAnchor) fillableAmount = 0;
            }
        }
        // A FILL-ONCE order is whole or nothing: a capacity below the anchor means
        // it cannot fill at all, not that it can fill partially (F29 finding 8a).
        //
        // A {Proportional} order is the same shape of fact for a different reason:
        // {Pricing.inputOwed} reverts `ProportionalNeedsFullFill` on anything but a
        // fill from zero progress to the whole resolved anchor. So a funding cap
        // below that anchor is "cannot fill", not "can fill this much" — reporting
        // the cap invited a fill sized to it, which is a partial and reverts. The
        // same `!= anchor` test also zeroes a proportional order with progress
        // already recorded (`done != 0`), which no fill can ever complete.
        if ((order.useNonceInvalidator() || _proportionalAnchor(order)) && fillableAmount != anchor) {
            fillableAmount = 0;
        }
        status = OrderStatus.Fillable;
    }

    /// @dev Max fillable (anchor units) the maker can currently fund across all
    ///      input legs: min_i( capacity_i · anchor / perUnitIn_i ), where
    ///      capacity_i = min(balance, max(live Permit3 allowance, direct ERC20
    ///      allowance to the settlement)) and perUnitIn_i is the worst-case input
    ///      cost of one anchor unit — `endAmountIn[i]`, which equals the fixed
    ///      amount for `start == end` legs and the auction ceiling for rising legs
    ///      (so the cap is a conservative lower bound that never depends on the
    ///      not-yet-started auction tick).
    ///
    ///      The direct-allowance leg mirrors
    ///      {Base._pullViaPermit3}: a maker that granted a
    ///      plain ERC20 approval to the settlement (instead of routing through
    ///      Permit3) funds the very same pull via the fallback, so their live
    ///      capacity is the MAX of the two books — reading only Permit3 would
    ///      preview such makers as unfillable.
    ///
    ///      ⚠ THE PERMIT3 BOOK IS ONLY HALF OF A PERMIT3 PULL (audit 2026-09-30
    ///      G-LENS_PARITY-1). Permit3 spends its book entry by calling
    ///      `token.transferFrom(maker, …)` itself, which needs the maker's plain ERC-20
    ///      approval TO PERMIT3. A maker who revoked that approval — the standard
    ///      kill switch for a Permit2-style hub, which leaves the book untouched — or
    ///      whose book entry came from a relayed signed permit before any token
    ///      approval, has a book that funds nothing, and every fill reverts. So the
    ///      Permit3 term is `min(live book, allowance(maker, PERMIT3))`.
    /// @return cap   the fillable cap, in anchor units.
    /// @return exact whether `cap` is the true capacity rather than a conservative
    ///         lower bound on it: true only for a SELL whose inputs are all fixed
    ///         (`end == 0`) or proportional — a rising leg is costed at its ceiling,
    ///         and every BUY input can be discounted by a soft-exclusivity override.
    function _makerFillableCap(Order calldata order, uint256 anchor)
        internal
        view
        returns (uint256 cap, bool exact)
    {
        cap = type(uint256).max;
        exact = order.side() == OrderSide.SELL;
        address spender = address(SETTLEMENT);
        uint256 nLegsIn = PackedArrays.validateFixed(order.legsIn, PackedArrays.LEG_IN_STRIDE);
        for (uint256 i; i < nLegsIn; i++) {
            (address token, uint256 lgStart, uint256 lgEnd) = PackedArrays.legIn(order.legsIn, i);
            if (lgEnd != 0 && !Proportional.isProportional(lgStart)) exact = false;
            uint256 capacity = _permit3Capacity(order.maker, token);
            // A direct ERC-20 approval to the settlement funds the fallback pull —
            // unless the maker set Permit3 STRICT mode for this token, which is
            // exactly the switch that makes {Base._pullViaPermit3} refuse the
            // fallback (F29 finding 8d).
            uint256 direct = PERMIT3.isStrict(order.maker, token) ? 0 : _erc20Allowance(token, order.maker, spender);
            if (direct > capacity) capacity = direct; // fallback path funds the same pull
            uint256 bal = SafeTransferLib.balanceOf(token, order.maker);
            if (bal < capacity) capacity = bal;

            // Worst-case input cost of one anchor unit: the leg ceiling (`end`), or
            // `start` when the leg is fixed (`end == 0`).
            //
            // A {Proportional} leg is neither. Its cost for the whole (always full)
            // fill is its own resolved amount, and the fill is `anchor` units, so
            // that resolved amount IS the per-unit figure this formula wants — for
            // leg 0 it equals `anchor` exactly. Reading the raw marker instead would
            // make every proportional order preview as unfillable: a ~1.15e77
            // per-unit cost no maker can fund.
            uint256 perUnitIn = _perUnitIn(order.maker, token, lgStart, lgEnd);
            // Scale leg-i capacity back into anchor units. Guard the multiply: an
            // unbounded (e.g. max) allowance times a large `anchor` can exceed
            // uint256 — treat an overflowing product as "this leg imposes no
            // binding cap" so this preflight view never reverts. `capacity == 0`
            // still falls through to a binding 0.
            uint256 inUnits;
            if (perUnitIn == 0) {
                inUnits = type(uint256).max; // leg needs nothing → no constraint
            } else if (capacity > type(uint256).max / anchor) {
                inUnits = type(uint256).max; // product overflows → non-binding
            } else {
                inUnits = (capacity * anchor) / perUnitIn;
            }
            if (inUnits < cap) cap = inUnits;
        }
    }

    /// @dev The Permit3 half of one leg's capacity: the live (unexpired) book entry,
    ///      capped by the maker's ERC-20 approval to Permit3 that spending it needs.
    function _permit3Capacity(address maker, address token) private view returns (uint256 capacity) {
        (uint160 allowed, uint48 expiration) = PERMIT3.tokenAllowance(maker, address(SETTLEMENT), token);
        capacity = allowed;
        if (expiration != 0 && expiration < block.timestamp) capacity = 0; // allowance lapsed
        uint256 approved = _erc20Allowance(token, maker, address(PERMIT3));
        if (approved < capacity) capacity = approved;
    }

    /// @dev {SettlementLensChecks.deadShape} as a boolean that never reverts: a probe
    ///      that reverts is a blob the settlement would revert on too — UNLESS it ran
    ///      out of gas, which says nothing about the order. EIP-150 leaves this frame
    ///      1/64 of what it had when the probe starved, so a failure with that little
    ///      left reads "not proven dead"; the row then runs dry in its own frame and a
    ///      batch reports it `Inconclusive` ({ORDER_STATE_GAS}), never `Invalid`.
    function _shapeLive(Order calldata order) private view returns (bool) {
        uint256 before = gasleft();
        try CHECKS.deadShape(order) returns (bool dead) {
            return !dead;
        } catch {
            return gasleft() <= before / 32;
        }
    }

    // ──────────────────── Well-formedness and item preflights ────────────────────
    //
    // ⚠ THESE LIVE IN {CHECKS}, A SECOND READ-ONLY CONTRACT THIS LENS DEPLOYS, AND
    // ARE FORWARDED BY A PLAIN `STATICCALL` (audit 2026-09-30 remediation). The lens
    // sat 268 bytes under EIP-170 with a dozen preflight-parity fixes still to land,
    // each a few dozen to a few hundred bytes. Nothing here is a proxy: {CHECKS} is
    // immutable, holds no state and no funds, runs in its own context (never a
    // DELEGATECALL), is created by this constructor so its address is fixed by the
    // lens's own, and every one of its functions can be called on it directly. The
    // signatures below are unchanged, so no caller moves.

    /// @notice The {SettlementLensChecks} instance this lens forwards to.
    SettlementLensChecks public immutable CHECKS;

    /// @notice Off-chain / preview check for order well-formedness — see
    ///         {SettlementLensChecks.validateOrder}.
    function validateOrder(Order calldata order) external view returns (bool ok, string memory reason) {
        return CHECKS.validateOrder(order);
    }

    /// @notice Whether a fill should carry a `minBumpBps` floor (the price can move
    ///         maker-ward before inclusion) — see {SettlementLensChecks.bumpFloorAdvised}.
    function bumpFloorAdvised(Order calldata order) external view returns (bool advised, string memory mover) {
        return CHECKS.bumpFloorAdvised(order);
    }

    /// @notice Every TAKE / TAKE_FOR item's live Permit3 taker allowance — see
    ///         {SettlementLensChecks.previewTakerAllowances}.
    function previewTakerAllowances(Order calldata order) external view returns (TakerAllowances memory) {
        return CHECKS.previewTakerAllowances(order);
    }

    /// @notice The funding side of every MAKE / TAKE_FOR item — see
    ///         {SettlementLensChecks.previewItemFunding}.
    function previewItemFunding(Order calldata order) external view returns (ItemFunding memory) {
        return CHECKS.previewItemFunding(order);
    }

    /// @dev Memory bundle for {previewTakerAllowances}, so a helper carries one
    ///      pointer instead of four arrays (a stack-limit concession). Declared here,
    ///      where callers have always named it (`SettlementLens.TakerAllowances`).
    struct TakerAllowances {
        address[] modules;
        bytes32[] refs;
        uint160[] amounts;
        uint48[] expirations;
    }

    /// @dev Memory bundle for {previewItemFunding}, one slot per `MAKE`/`TAKE_FOR`
    ///      item. `assets[j] == address(0)` means the module did not answer:
    ///      `required[j]` is still meaningful (the CORE's rule computes it),
    ///      `available[j]` is not.
    struct ItemFunding {
        address[] modules;
        address[] assets;
        uint256[] required;
        uint256[] available;
    }


    // ──────────────────── Internal helpers ────────────────────

    /// @dev Preview the order's pre-execution validators for `filler` — the same
    ///      AND-composition the settlement runs in `_runValidators`, evaluated as
    ///      a view. Mirrors the settlement's gate exactly: staticcall
    ///      `target.validate(order, filler, data, takerData)`, pass iff the call
    ///      succeeds, returns ≥32 bytes, and the bool word is 1.
    function _validatorsPass(Order calldata order, address filler, bytes calldata takerData)
        internal
        view
        returns (bool)
    {
        bytes calldata vs = order.validators;
        uint256 len = PackedArrays.validateRecords(vs, PackedArrays.VALIDATOR_HEAD);
        uint256 vcur = PackedArrays.recordsStart();
        for (uint256 i; i < len; i++) {
            bool pass;
            (pass, vcur) = _oneGate(order, vs, vcur, filler, takerData);
            if (!pass) return false;
        }
        return true;
    }

    /// @dev One validator record: decode, gate, and hand back the next cursor. Its own
    ///      frame because holding the decoded record alongside the loop state pushed
    ///      {_validatorsPass} over the stack limit.
    function _oneGate(Order calldata order, bytes calldata vs, uint256 cursor, address filler, bytes calldata takerData)
        private
        view
        returns (bool, uint256)
    {
        (address target, bytes calldata data, uint256 next) = PackedArrays.validatorAt(vs, cursor);
        return (OrderGates.gatePasses(target, order, filler, data, takerData), next);
    }

    /// @dev Live `token.allowance(owner, spender)` — best-effort staticcall; a
    ///      token without a readable allowance view reports 0 (never reverts the
    ///      preflight).
    function _erc20Allowance(address token, address owner, address spender) private view returns (uint256 a) {
        (bool ok, bytes memory ret) =
            token.staticcall(abi.encodeWithSignature("allowance(address,address)", owner, spender));
        if (ok && ret.length >= 32) a = abi.decode(ret, (uint256));
    }

    /// @dev The leg anchor and the fill denominator, shared with the settler — see
    ///      {OrderGates}. These were local copies until the 2026-08 audit found the
    ///      anchor one had drifted (it was missing the empty-blob {NoAnchorLeg}
    ///      guard, so an order with no legs previewed against a denominator of 0).

    /// @dev Recompute the settlement's EIP-712 order digest and verify `sig`
    ///      against it. Uses the SETTLEMENT's domain separator (name +
    ///      verifyingContract are the settler's, not this lens's), so a signature
    ///      that verifies here is exactly one the settler will accept.
    ///
    ///      Mirrors {Signatures._verifySignature}, INCLUDING its empty-`sig`
    ///      branch: an order authorized on-chain via `approveOrder` carries no
    ///      signature, and reporting it as unauthorized would force every consumer
    ///      to special-case it. The lens reads the settler's own `orderApproved`
    ///      record, so a sigless order is attested here on exactly the terms the
    ///      settler will apply — not taken on trust from whoever submitted it.
    ///
    ///      ...and INCLUDING its FIRST-FILL SKIP, which this mirror was missing. The
    ///      settler returns early once `filled[orderHash] != 0`, on the reasoning
    ///      that a non-zero counter is itself proof some earlier fill presented valid
    ///      authorization for this exact (maker-committing) hash. Without the same
    ///      skip the lens was STRICTER than the settler: a partially-filled order
    ///      whose EIP-1271 maker has since rotated owners or revoked would be
    ///      reported unfillable here while `fill` would still settle it — so an
    ///      orderbook would drop live, fillable size. Divergence in this direction is
    ///      merely lost liquidity rather than a false attestation, but the point of a
    ///      preflight is to answer the question the settler will answer.
    function _verifySignature(bytes32 orderHash, bytes calldata sig, address expected) internal view {
        if (sig.length == 0) {
            if (!SETTLEMENT.orderApproved(expected, orderHash)) revert OrderNotApproved();
            return;
        }
        if (SETTLEMENT.filled(orderHash) != 0) return; // already authorized once — see above
        bytes calldata sigBody = sig;
        bytes32 structHash = orderHash;
        // BULK (Merkle) signature — mirrors {Signatures._verifySignature} EXACTLY:
        // `sig = innerSig(65) ‖ bytes32[] proof ‖ 0xB0` swaps in the `OrderRoot(root)`
        // digest and a 65-byte body, then every acceptance rule below applies
        // unchanged. WITHOUT this branch the lens is STRICTER than the settler — it
        // reports every bulk-signed leaf as unauthorized while `fill` settles it — so
        // an orderbook drops the whole ladder. This is exactly the lens/settler drift
        // this mirror exists to prevent.
        uint256 n = sig.length;
        if (n >= 98 && (n - 66) % 32 == 0 && uint8(sig[n - 1]) == 0xB0) {
            structHash = keccak256(abi.encode(OrderHash.ORDER_ROOT_TYPEHASH, _foldProof(orderHash, sig[65:n - 1])));
            sigBody = sig[:65];
        }
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", SETTLEMENT.DOMAIN_SEPARATOR(), structHash));
        // Mirrors {Signatures._verifySignature} EXACTLY, including the delegated
        // branch — the drift this whole lens/settler split has already been bitten
        // by once (see {OrderGates}). Maker first, then the maker-nominated signer.
        (bool standardLength, address signer) = SignatureVerification.tryRecoverSigner(sigBody, digest);
        if (standardLength && signer != address(0)) {
            if (signer == expected) return;
            uint256 expiry = SETTLEMENT.orderSignerExpiry(expected, signer);
            if (expiry != 0 && block.timestamp <= expiry) return;
        }
        // Contract-delegate envelope — mirrors {Signatures._verifySignature}
        // exactly, including the reachability conditions that make it
        // collision-free (non-ECDSA length AND a codeless maker).
        if (!standardLength && sigBody.length > 20 && expected.code.length == 0) {
            address contractSigner = address(bytes20(sigBody[:20]));
            uint256 expiry = SETTLEMENT.orderSignerExpiry(expected, contractSigner);
            if (expiry != 0 && block.timestamp <= expiry) {
                SignatureVerification.verify(sigBody[20:], digest, contractSigner);
                return;
            }
        }
        // Shared verifier: EOA (ecrecover), EIP-1271 contract wallets, and
        // EIP-7702 accounts (raw-key or delegated-1271) are all accepted.
        SignatureVerification.verify(sigBody, digest, expected);
    }

    /// @dev Fold an inclusion proof into its Merkle root, hashing SORTED pairs —
    ///      a byte-for-byte copy of {Signatures._foldProof} so the lens accepts
    ///      exactly the bulk signatures the settler does.
    function _foldProof(bytes32 leaf, bytes calldata proof) private pure returns (bytes32 h) {
        h = leaf;
        uint256 levels = proof.length / 32;
        for (uint256 i; i < levels;) {
            /// @solidity memory-safe-assembly
            assembly {
                let p := calldataload(add(proof.offset, mul(i, 32)))
                switch lt(h, p)
                case 1 {
                    mstore(0x00, h)
                    mstore(0x20, p)
                }
                default {
                    mstore(0x00, p)
                    mstore(0x20, h)
                }
                h := keccak256(0x00, 0x40)
            }
            unchecked {
                ++i;
            }
        }
    }

}
