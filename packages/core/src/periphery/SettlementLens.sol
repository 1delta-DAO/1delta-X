// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPermit3} from "../interfaces/IPermit3.sol";
import {IOrderValidator} from "../interfaces/IOrderValidator.sol";
import {IFillModule} from "../interfaces/IFillModule.sol";
import {SignatureVerification} from "../permit3/SignatureVerification.sol";
import {SafeTransferLib} from "../utils/SafeTransferLib.sol";

import {Order, ItemOp, OrderSide, FillCtx} from "../settlement/Structs.sol";
import {OrderHash} from "../settlement/OrderHash.sol";
import {PackedArrays} from "../settlement/PackedArrays.sol";
import {DutchAuction} from "../settlement/DutchAuction.sol";
import {Pricing} from "../settlement/Pricing.sol";
import {OrderGates} from "../settlement/OrderGates.sol";
import {Proportional} from "../settlement/Proportional.sol";

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

    /// @dev `recipient` of packed output leg `k` — small helper so the duplicate-leg
    ///      scan can compare recipients without decoding the whole leg twice.
    function _legOutRecipient(bytes calldata legs, uint256 k) private pure returns (address r) {
        (,,, r) = PackedArrays.legOut(legs, k);
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
    enum OrderStatus {
        Invalid, // malformed (bad array shape) — can never fill
        Fillable, // open, at least one unit still fillable
        Filled, // fully filled
        Cancelled, // nonce bit set, or below the maker's rollback floor
        Expired // past deadline
    }

    /// @dev An empty `sig` with no matching on-chain approval. Mirrors
    ///      {Signatures.OrderNotApproved}; surfaces through `checkSignature` and
    ///      as `isSignatureValid == false`.
    error OrderNotApproved();

    constructor(address settlement) {
        SETTLEMENT = ISettlementState(settlement);
        PERMIT3 = ISettlementState(settlement).PERMIT3();
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
    function remaining(Order calldata order) external view returns (uint256) {
        return OrderGates.fillDenominator(order) - SETTLEMENT.filled(order.hash());
    }

    /// @notice Preview EXACTLY what `Settlement.fillUpTo` would settle right now —
    ///         the aggregator quote call. Runs the same clamp, the same exclusivity
    ///         override, and the same per-leg {Pricing} math the settlement runs, so
    ///         an `eth_call` here at block N equals a fill executed at block N.
    /// @dev    Scope: the AMOUNT pipeline only. Lifecycle gates (deadline, nonce,
    ///         cancellation, signature, validators, maker funding) are the job of
    ///         {getOrderRelevantState} — call both. Mirrored execution reverts are
    ///         kept where they change the answer: a hard-exclusive order previews as
    ///         {NotExclusiveFiller} for an outside filler, and a clamped delta under
    ///         the maker's floor as {FillTooSmall} — exactly as the fill would.
    ///         Time-sensitive: decay and the gas bump price off `block.timestamp` /
    ///         `basefee` at the call's block.
    /// @param  fillAmount The requested size (anchor units; a proposal for a
    ///         fill-module order). Clamped to remaining for identity orders,
    ///         resolved through the maker's `fillModule` otherwise.
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
    ///         ⚠ PRIORITY-auction orders derive the bump from `tx.gasprice`, so a
    ///         default `eth_call` (gas price 0) quotes the NO-BID bump — higher
    ///         than any bid fill's. Either quote with the gas price you will
    ///         actually send, or skip the floor there: the bump is your own bid,
    ///         not a race.
    function previewBump(Order calldata order, address filler, bytes calldata takerData)
        external
        view
        returns (uint256 bump)
    {
        (bytes32 orderHash, uint256 total, uint256 prevFilled) = _resolveState(order);
        uint256 pinned = DutchAuction.resolveBump(order, orderHash, total, filler, prevFilled, takerData);
        return pinned != 0 ? pinned - 1 : DutchAuction.bumpBps(order);
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

    /// @dev Mirror of `Core._clampToRemaining` + `OrderState._openFill`'s delta
    ///      resolution: identity orders clamp to remaining; module orders resolve
    ///      the proposal through the maker's (view) fill module. Packages the
    ///      result as the same {FillCtx} the settlement would price with.
    function _previewCtx(Order calldata order, uint256 fillAmount, address filler, bytes calldata takerData)
        private
        view
        returns (FillCtx memory)
    {
        if (fillAmount == 0) revert ZeroFill();
        (bytes32 orderHash, uint256 total, uint256 prevFilled) = _resolveState(order);

        uint256 delta;
        if (order.fillModule == address(0)) {
            if (prevFilled < total) {
                uint256 rem = total - prevFilled;
                if (fillAmount > rem) fillAmount = rem;
            }
            delta = fillAmount;
        } else {
            delta = IFillModule(order.fillModule).resolveFill(order, prevFilled, fillAmount, takerData);
            if (delta == 0) revert ZeroFill();
        }
        if (delta < order.minFillAnchor) revert FillTooSmall();
        uint256 newFilled = prevFilled + delta;
        if (newFilled > total) revert OverFill();

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
            new uint256[](0) // preview prices legs directly; no payout ledger to record
        );
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
            try this.getOrderRelevantState(orders[i], sigs[i], filler, takerDatas[i]) returns (
                OrderStatus s, uint256 f, bool v, bool vp
            ) {
                statuses[i] = s;
                fillableAmounts[i] = f;
                sigValids[i] = v;
                validatorsPass[i] = vp;
            } catch {
                statuses[i] = OrderStatus.Invalid;
            }
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
        if (block.timestamp > order.deadline) return (OrderStatus.Expired, 0);
        if (SETTLEMENT.isNonceCancelled(order.maker, order.nonce)) return (OrderStatus.Cancelled, 0);

        uint256 anchor = OrderGates.fillDenominator(order);
        uint256 done = SETTLEMENT.filled(orderHash);
        if (done >= anchor) return (OrderStatus.Filled, 0);

        fillableAmount = anchor - done;
        // Plain orders: the maker funds tokenIn from their wallet, so cap the
        // fillable amount by their live capacity across every input leg. Skipped
        // for module orders — the fillable is in `fillTotal` units, not leg units.
        if (PackedArrays.countUnchecked(order.items) == 0 && order.fillModule == address(0)) {
            uint256 cap = _makerFillableCap(order, anchor);
            if (cap < fillableAmount) fillableAmount = cap;
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
    ///      {Permit3TransferLib.transferFromWithFallback}: a maker that granted a
    ///      plain ERC20 approval to the settlement (instead of routing through
    ///      Permit3) funds the very same pull via the fallback, so their live
    ///      capacity is the MAX of the two books — reading only Permit3 would
    ///      preview such makers as unfillable.
    function _makerFillableCap(Order calldata order, uint256 anchor) internal view returns (uint256 cap) {
        cap = type(uint256).max;
        address spender = address(SETTLEMENT);
        uint256 nLegsIn = PackedArrays.validateFixed(order.legsIn, PackedArrays.LEG_IN_STRIDE);
        for (uint256 i; i < nLegsIn; i++) {
            (address token, uint256 lgStart, uint256 lgEnd) = PackedArrays.legIn(order.legsIn, i);
            (uint160 allowed, uint48 expiration) = PERMIT3.tokenAllowance(order.maker, spender, token);
            uint256 capacity = allowed;
            if (expiration != 0 && expiration < block.timestamp) capacity = 0; // allowance lapsed
            uint256 direct = _erc20Allowance(token, order.maker, spender);
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

    // ──────────────────── Well-formedness ────────────────────
    /// @dev The duplicate / self-trade leg checks, split into their own frame purely
    ///      to keep {validateOrder} under the EVM stack limit without via-IR — the
    ///      packed decode yields several values per leg where the old typed access
    ///      read one field at a time. Pure relocation; the rules are unchanged.
    function _checkLegOverlaps(Order calldata order, uint256 nIn, uint256 nOut)
        private
        view
        returns (bool, string memory)
    {
        for (uint256 i; i < nIn; i++) {
            for (uint256 k = i + 1; k < nIn; k++) {
                if (PackedArrays.legInToken(order.legsIn, i) == PackedArrays.legInToken(order.legsIn, k)) {
                    return (false, "duplicate input token");
                }
            }
            if (PackedArrays.countUnchecked(order.items) == 0) {
                for (uint256 j; j < nOut; j++) {
                    if (PackedArrays.legInToken(order.legsIn, i) == PackedArrays.legOutToken(order.legsOut, j)) {
                        return (false, "input token == output token");
                    }
                }
            }
        }
        for (uint256 j; j < nOut; j++) {
            // A leg addressed to the settlement contract permanently burns that
            // delivery (it lands in the anti-donation snapshot baseline and is
            // never swept). On-chain it's a maker self-burn, not an exploit, but
            // the preflight should catch the footgun.
            (address ojToken,,, address ojRecip) = PackedArrays.legOut(order.legsOut, j);
            if (ojRecip == address(SETTLEMENT)) return (false, "recipient is settlement (burn)");
            for (uint256 k = j + 1; k < nOut; k++) {
                if (
                    ojToken == PackedArrays.legOutToken(order.legsOut, k)
                        && ojRecip == _legOutRecipient(order.legsOut, k)
                ) {
                    return (false, "duplicate output token+recipient");
                }
            }
        }
        return (true, "");
    }

    /// @notice Off-chain / preview check for order well-formedness. Intentionally
    ///         NOT called during `fill` — fills stay cheap and unopinionated — so
    ///         call this from a maker UI, relayer, or test before signing or
    ///         submitting, to catch self-inflicted misparameterizations. Returns
    ///         the first problem found (`ok == false`), else `(true, "")`.
    ///
    /// @dev    Trust model: a malformed order can only ever harm its own maker
    ///         (all token moves are gated by the maker's signature + Permit3
    ///         allowances), so these are footgun guards, not protocol invariants.
    ///         Scope: structural/economic sanity + current fillability. It does
    ///         NOT judge whether the price is *good*.
    ///
    ///         Stranded-tail caveat (not flagged here, as partial-fill-with-floor
    ///         is a legitimate config): any `0 < minFillAnchor < anchor` lets
    ///         a solver leave a remainder smaller than `minFillAnchor` that can
    ///         then never be filled. Only `minFillAnchor ∈ {0, anchor}`
    ///         guarantees no unfillable tail.
    function validateOrder(Order calldata order) external view returns (bool ok, string memory reason) {
        // A fill-module order is denominated by the maker-signed `fillTotal`, not
        // a leg, so it may carry empty tokenIn/tokenOut (a pure NFT swap). The
        // leg-shape economics below still apply to whatever legs it does have.
        bool moduleFill = order.fillTotal != 0;

        // ── leg shape ──
        // NOTE: `.length` on a packed member is the BYTE length, not the element
        // count — the count lives in the blob's prefix. Always go through
        // {PackedArrays}, which also proves the blob is well formed.
        uint256 nIn = PackedArrays.validateFixed(order.legsIn, PackedArrays.LEG_IN_STRIDE);
        uint256 nOut = PackedArrays.validateFixed(order.legsOut, PackedArrays.LEG_OUT_STRIDE);
        // Anchor-leg presence. The fill denominator is the anchor side's leg 0 —
        // SELL reads `tokenIn[0]`, BUY reads `tokenOut[0]` — unless a maker-signed
        // `fillTotal` supplies it directly. So a BUY may have EMPTY tokenIn (its
        // consideration comes from items — e.g. an NFT-sale SETTLE), and a SELL
        // may have empty tokenOut (a gasless deposit). A fill module with
        // `fillTotal == 0` still derives its total from the anchor leg, so it
        // needs that leg too.
        if (!moduleFill) {
            if (order.side() == OrderSide.SELL && nIn == 0) {
                return
                    (
                        false,
                        order.fillModule != address(0) ? "fill module without denominator" : "sell requires tokenIn"
                    );
            }
            if (order.side() == OrderSide.BUY && nOut == 0) {
                return
                    (
                        false,
                        order.fillModule != address(0) ? "fill module without denominator" : "buy requires tokenOut"
                    );
            }
            // Empty tokenOut on a SELL is the deposit shape (items) or the
            // invariant-protected PURCHASE shape (the maker pays the input leg
            // and a signed invariant proves what arrived — e.g. an NFT via
            // {Erc721OwnerInvariant}, delivered by the filler's callback). With
            // neither items nor invariants the maker gives tokenIn away for
            // nothing.
            if (
                order.side() == OrderSide.SELL && nOut == 0 && PackedArrays.countUnchecked(order.items) == 0
                    && PackedArrays.countUnchecked(order.invariants) == 0
            ) {
                return (false, "no tokenOut and no items (giveaway)");
            }
        }

        // ── structural / economic sanity (time-independent) ──
        uint256 anchor = OrderGates.fillDenominator(order);
        if (anchor == 0) return (false, "anchor amount is zero");
        // Input legs are FIXED (`end == 0`) or RISE to a ceiling (`end ≥ start`) —
        // a rising leg is the relayer-fee/conversion auction. Same rule both sides.
        for (uint256 i; i < nIn; i++) {
            (, uint256 inS, uint256 inE) = PackedArrays.legIn(order.legsIn, i);
            if (Proportional.isProportional(inS)) {
                // Mirror the settler's rule EXACTLY — see {Pricing.inputOwed}. A
                // preflight that is stricter drops fillable orders; one that is
                // looser passes orders that revert on-chain.
                if (
                    i != 0 || order.side() == OrderSide.BUY || order.fillTotal != 0
                        || order.fillModule != address(0)
                ) {
                    return (false, "proportional leg only allowed on legsIn[0] of a plain SELL order");
                }
                // The cap is mandatory on-chain, and `0` is what an unset field
                // holds — so this is the check most likely to catch a real mistake.
                if (inE == 0) return (false, "proportional leg has no cap (end == 0)");
                continue;
            }
            if (inE != 0 && inE < inS) {
                return (false, "input end < start (must rise)");
            }
        }
        if (order.side() == OrderSide.SELL) {
            // Outputs decay DOWN from a positive start (`end ≤ start`), or fixed.
            for (uint256 j; j < nOut; j++) {
                (, uint256 oS, uint256 oE,) = PackedArrays.legOut(order.legsOut, j);
                if (oS == 0) return (false, "output start is zero (giveaway)");
                if (oE != 0 && oS < oE) {
                    return (false, "output start < end (must fall)");
                }
            }
        } else {
            // BUY outputs are FIXED (exact-output); the canonical form is `end == 0`.
            for (uint256 j; j < nOut; j++) {
                (, uint256 oS2, uint256 oE2,) = PackedArrays.legOut(order.legsOut, j);
                if (oS2 == 0) return (false, "output start is zero (giveaway)");
                if (oE2 != 0) return (false, "buy output must be fixed (end == 0)");
            }
        }
        // Distinct within each array — a duplicate tokenIn shares one proceeds
        // snapshot (the first leg's payout corrupts the second leg's balance
        // delta); a duplicate (token, recipient) OUTPUT pair is a
        // double-delivery footgun (same token to DIFFERENT recipients — e.g. a
        // maker leg plus a fee leg — is legitimate and common).
        //
        // CROSS-overlap (tokenIn[i] == tokenOut[j]) is fine for orders WITH
        // items — the same-asset exit shape: delivery is solver→maker and runs
        // BEFORE the proceeds snapshot, so the two legs never share a measured
        // balance (proven by the same-asset withdraw fork tests). For item-FREE
        // orders the overlap is a pure self-trade (the maker pays the spread
        // for nothing) and stays flagged.
        {
            (bool okLegs, string memory whyLegs) = _checkLegOverlaps(order, nIn, nOut);
            if (!okLegs) return (false, whyLegs);
        }
        if (order.minFillAnchor > anchor) return (false, "minFillAnchor > anchor (unfillable)");
        // An INDIVISIBLE SETTLE item (`amount <= 1` — the ERC-721 sentinel, or a
        // broken zero) cannot slice: a partial fill floors it to 0, which the
        // core now rejects on-chain ({SettleSliceZero}) — so a partial-fillable
        // order would simply be unfillable except in one full shot. Require
        // full-fill unless a fill module fixes the unit. DIVISIBLE settle
        // quantities (`amount > 1`, e.g. {Erc1155SettlementModule}) compose with
        // partial fills — each fill transfers its exact pro-rata slice — and are
        // deliberately allowed through.
        if (order.fillModule == address(0) && order.minFillAnchor != anchor) {
            bytes calldata its = order.items;
            uint256 nItems = PackedArrays.validateRecords(its, PackedArrays.ITEM_HEAD);
            uint256 cur = PackedArrays.recordsStart();
            for (uint256 s; s < nItems; s++) {
                (uint256 iop,, uint256 iamt,,, uint256 nxt) = PackedArrays.itemAt(its, cur);
                if (iop == uint256(ItemOp.SETTLE) && iamt <= 1) {
                    return (false, "settle item requires full-fill");
                }
                cur = nxt;
            }
        }
        if (order.decayDuration() != 0 && order.decayStartTime() == 0) {
            return (false, "decay set without decayStartTime");
        }

        // ── soft exclusivity override ──
        if (order.overrideBps() != 0) {
            if (order.exclusiveFiller == address(0)) return (false, "override without exclusiveFiller");
            if (order.overrideBps() > 10_000) return (false, "overrideBps > 10000");
        }
        // ── piecewise auction curve (monotonic time, bounded bump) ──
        uint256 nCurve = PackedArrays.validateFixed(order.curve, PackedArrays.CURVE_STRIDE);
        for (uint256 c; c < nCurve; c++) {
            (uint256 cT, uint256 cB) = PackedArrays.curvePoint(order.curve, c);
            if (cB > 10_000) return (false, "curve bumpBps > 10000");
            (uint256 cTPrev,) = c == 0 ? (uint256(0), uint256(0)) : PackedArrays.curvePoint(order.curve, c - 1);
            if (c != 0 && cT <= cTPrev) {
                return (false, "curve timeDelta not increasing");
            }
        }
        if (nCurve != 0 && order.decayStartTime() == 0) return (false, "curve set without decayStartTime");
        // ── gas bump ──
        if (order.gasBumpBps() != 0) {
            if (order.gasPriceRef() == 0) return (false, "gasBump without gasPriceRef");
            if (order.gasBumpBps() > 10_000) return (false, "gasBumpBps > 10000");
        }
        // ── priority auction (bit 103) ──
        if (order.priorityAuction()) {
            if (order.priorityScale() == 0) return (false, "priority auction without priorityScale");
            // A priority auction prices from the FLOOR up on the pinned bid — the
            // clock/curve/gas-bump shapes never run, so signing any of them is a
            // mistake: they silently never apply. `decayStartTime` alone is fine (it
            // keeps its "not before" meaning).
            if (order.gasBumpBps() != 0) return (false, "gas bump with priority auction");
            if (order.decayDuration() != 0) return (false, "decay duration with priority auction");
            if (nCurve != 0) return (false, "curve with priority auction");
        }
        // ── external price module ──
        if (order.pricingModule != address(0)) {
            // A module pins the bump; the clock/curve/gas-bump never run, so — as with
            // the priority branch above — signing any of them is a footgun that never
            // applies. `decayStartTime` alone stays meaningful as the "not before" gate
            // ({DutchAuction.resolveBump} enforces it).
            if (order.priorityAuction()) return (false, "price module with priority auction");
            if (nCurve != 0) return (false, "price module with curve");
            if (order.decayDuration() != 0) return (false, "decay duration with price module");
            if (order.gasBumpBps() != 0) return (false, "gas bump with price module");
        }

        // ── current fillability (time/state-dependent) ──
        if (order.deadline < block.timestamp) return (false, "order expired");
        if (SETTLEMENT.isNonceCancelled(order.maker, order.nonce)) return (false, "nonce cancelled");
        if (SETTLEMENT.filled(order.hash()) >= anchor) return (false, "order fully filled");

        return (true, "");
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
        (bool standardLength, address signer) = SignatureVerification.recoverCalldata(sigBody, digest);
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

    // ──────────────────── Taker-allowance preflight (U-3) ────────────────────

    /// @notice For every TAKE item in `order`, the maker's live Permit3 taker
    ///         allowance that the fill will consume — the taker-book analogue of
    ///         {getOrderRelevantState}'s token-side capacity, which skips item
    ///         orders entirely. A solver quoting a leverage/withdraw order can read
    ///         this instead of hand-deriving `keccak256(item.data)` and querying
    ///         Permit3 itself. The allowance is keyed `(maker, settlement, module,
    ///         ref)`, exactly as {Base._runItem}'s `PERMIT3.take` consumes it.
    /// @return out `TakerAllowances{modules, refs, amounts, expirations}`, one entry
    ///         per TAKE item in signed order. `refs[j] = keccak256(item.data)` (the
    ///         position key), `amounts[j]` the live allowance (`uint160.max` =
    ///         infinite), `expirations[j]` its expiry (`0` = never).
    function previewTakerAllowances(Order calldata order) external view returns (TakerAllowances memory out) {
        bytes calldata items = order.items;
        uint256 n = PackedArrays.validateRecords(items, PackedArrays.ITEM_HEAD);
        // First pass: count TAKE items so the arrays are sized exactly.
        uint256 takes;
        uint256 cursor = PackedArrays.recordsStart();
        for (uint256 i; i < n;) {
            (uint256 op,,,,, uint256 next) = PackedArrays.itemAt(items, cursor);
            if (op == uint256(ItemOp.TAKE)) ++takes;
            cursor = next;
            unchecked {
                ++i;
            }
        }

        out.modules = new address[](takes);
        out.refs = new bytes32[](takes);
        out.amounts = new uint160[](takes);
        out.expirations = new uint48[](takes);

        uint256 k;
        cursor = PackedArrays.recordsStart();
        for (uint256 i; i < n;) {
            // The whole per-item decode+read+write is one helper (fewest params:
            // `order`, `cursor`, `out`, `k`) so the wide `itemAt` tuple never shares
            // this frame — otherwise legacy (non-via-IR) codegen goes stack-too-deep.
            (cursor, k) = _takerItemAt(order, cursor, out, k);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Memory bundle for {previewTakerAllowances}, so the helper carries one
    ///      pointer instead of four arrays (a stack-limit concession).
    struct TakerAllowances {
        address[] modules;
        bytes32[] refs;
        uint160[] amounts;
        uint48[] expirations;
    }

    /// @dev Decode the item at `cursor`; if it is a TAKE, read its
    ///      `(maker, settlement, module, ref)` taker allowance and write slot `k` of
    ///      `out`. Returns the next cursor and the advanced `k` (unchanged for a
    ///      non-TAKE). Takes `order` (not `maker`+`items` separately) to keep the
    ///      param count — and thus this frame — small.
    function _takerItemAt(Order calldata order, uint256 cursor, TakerAllowances memory out, uint256 k)
        private
        view
        returns (uint256 next, uint256)
    {
        (uint256 op, address module,,, bytes calldata data, uint256 n2) = PackedArrays.itemAt(order.items, cursor);
        if (op != uint256(ItemOp.TAKE)) return (n2, k);
        bytes32 ref = keccak256(data);
        (uint160 amt, uint48 exp) = PERMIT3.takerAllowance(order.maker, address(SETTLEMENT), module, ref);
        out.modules[k] = module;
        out.refs[k] = ref;
        out.amounts[k] = amt;
        out.expirations[k] = exp;
        unchecked {
            return (n2, k + 1);
        }
    }
}
