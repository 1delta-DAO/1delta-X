// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPermit3} from "../interfaces/IPermit3.sol";
import {IOrderValidator} from "../interfaces/IOrderValidator.sol";
import {IFillModule} from "../interfaces/IFillModule.sol";
import {SignatureVerification} from "../permit3/SignatureVerification.sol";
import {SafeTransferLib} from "../utils/SafeTransferLib.sol";

import {Order, Item, ItemOp, Validator, OrderSide, CurvePoint, FillCtx} from "../settlement/Structs.sol";
import {OrderHash} from "../settlement/OrderHash.sol";
import {DutchAuction} from "../settlement/DutchAuction.sol";
import {Pricing} from "../settlement/Pricing.sol";

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
        return _fillDenominator(order) - SETTLEMENT.filled(order.hash());
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
        bytes32 orderHash = order.hash();
        uint256 total = _fillDenominator(order);
        uint256 prevFilled = SETTLEMENT.filled(orderHash);
        if (prevFilled == type(uint256).max) revert OrderCancelled();

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
            _exclusivityOverride(order, filler),
            filler,
            filler,
            prevFilled == 0 && newFilled == total,
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
        received = new uint256[](order.legsIn.length);
        for (uint256 i; i < received.length; i++) {
            received[i] = order.inputOwed(ctx, i);
        }
        paid = new uint256[](order.legsOut.length);
        for (uint256 j; j < paid.length; j++) {
            paid[j] = order.outputAt(ctx, j);
        }
    }

    /// @dev Mirror of the settlement's `Base._exclusivity` gate, error for error,
    ///      so a preview fails exactly where the fill would.
    function _exclusivityOverride(Order calldata order, address filler) internal view returns (uint256 overrideBps) {
        if (
            order.exclusiveFiller != address(0) && block.timestamp < order.exclusivityEndTime()
                && filler != order.exclusiveFiller
        ) {
            if (order.exclusivityOverrideBps == 0) revert NotExclusiveFiller();
            if (order.exclusivityOverrideBps > DutchAuction.BPS) revert InvalidOverrideBps();
            overrideBps = order.exclusivityOverrideBps;
        }
    }

    // Mirrored settlement errors (same signatures ⇒ same selectors), so preview
    // reverts decode identically to execution reverts in any tooling.
    error ZeroFill();
    error OverFill();
    error FillTooSmall();
    error OrderCancelled();
    error NotExclusiveFiller();
    error InvalidOverrideBps();

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
        uint256 nIn = order.legsIn.length;
        uint256 nOut = order.legsOut.length;
        // The leg structs make token↔amount length mismatch impossible; only the
        // anchor-leg-presence check remains. SELL anchors on `legsIn[0]`, BUY on
        // `legsOut[0]` (unless `fillTotal` supplies the denominator directly), so a
        // BUY may have empty legsIn (an NFT-sale SETTLE) and a SELL empty legsOut.
        if (!moduleFill && ((nIn == 0 && order.side == OrderSide.SELL) || (nOut == 0 && order.side == OrderSide.BUY))) {
            return (OrderStatus.Invalid, 0);
        }
        if (block.timestamp > order.deadline) return (OrderStatus.Expired, 0);
        if (SETTLEMENT.isNonceCancelled(order.maker, order.nonce)) return (OrderStatus.Cancelled, 0);

        uint256 anchor = _fillDenominator(order);
        uint256 done = SETTLEMENT.filled(orderHash);
        if (done >= anchor) return (OrderStatus.Filled, 0);

        fillableAmount = anchor - done;
        // Plain orders: the maker funds tokenIn from their wallet, so cap the
        // fillable amount by their live capacity across every input leg. Skipped
        // for module orders — the fillable is in `fillTotal` units, not leg units.
        if (order.items.length == 0 && order.fillModule == address(0)) {
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
        uint256 nLegsIn = order.legsIn.length;
        for (uint256 i; i < nLegsIn; i++) {
            address token = order.legsIn[i].token;
            (uint160 allowed, uint48 expiration,) = PERMIT3.tokenAllowance(order.maker, spender, token);
            uint256 capacity = allowed;
            if (expiration != 0 && expiration < block.timestamp) capacity = 0; // allowance lapsed
            uint256 direct = _erc20Allowance(token, order.maker, spender);
            if (direct > capacity) capacity = direct; // fallback path funds the same pull
            uint256 bal = SafeTransferLib.balanceOf(token, order.maker);
            if (bal < capacity) capacity = bal;

            // Worst-case input cost of one anchor unit: the leg ceiling (`end`), or
            // `start` when the leg is fixed (`end == 0`).
            uint256 perUnitIn = order.legsIn[i].end == 0 ? order.legsIn[i].start : order.legsIn[i].end;
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

        // ── leg shape ── (token↔amount length mismatch is impossible: {LegIn}/{LegOut})
        uint256 nIn = order.legsIn.length;
        uint256 nOut = order.legsOut.length;
        // Anchor-leg presence. The fill denominator is the anchor side's leg 0 —
        // SELL reads `tokenIn[0]`, BUY reads `tokenOut[0]` — unless a maker-signed
        // `fillTotal` supplies it directly. So a BUY may have EMPTY tokenIn (its
        // consideration comes from items — e.g. an NFT-sale SETTLE), and a SELL
        // may have empty tokenOut (a gasless deposit). A fill module with
        // `fillTotal == 0` still derives its total from the anchor leg, so it
        // needs that leg too.
        if (!moduleFill) {
            if (order.side == OrderSide.SELL && nIn == 0) {
                return (false, order.fillModule != address(0) ? "fill module without denominator" : "sell requires tokenIn");
            }
            if (order.side == OrderSide.BUY && nOut == 0) {
                return (false, order.fillModule != address(0) ? "fill module without denominator" : "buy requires tokenOut");
            }
            // Empty tokenOut on a SELL is the deposit shape (items) or the
            // invariant-protected PURCHASE shape (the maker pays the input leg
            // and a signed invariant proves what arrived — e.g. an NFT via
            // {Erc721OwnerInvariant}, delivered by the filler's callback). With
            // neither items nor invariants the maker gives tokenIn away for
            // nothing.
            if (order.side == OrderSide.SELL && nOut == 0 && order.items.length == 0 && order.invariants.length == 0) {
                return (false, "no tokenOut and no items (giveaway)");
            }
        }

        // ── structural / economic sanity (time-independent) ──
        uint256 anchor = _fillDenominator(order);
        if (anchor == 0) return (false, "anchor amount is zero");
        // Input legs are FIXED (`end == 0`) or RISE to a ceiling (`end ≥ start`) —
        // a rising leg is the relayer-fee/conversion auction. Same rule both sides.
        for (uint256 i; i < nIn; i++) {
            if (order.legsIn[i].end != 0 && order.legsIn[i].end < order.legsIn[i].start) {
                return (false, "input end < start (must rise)");
            }
        }
        if (order.side == OrderSide.SELL) {
            // Outputs decay DOWN from a positive start (`end ≤ start`), or fixed.
            for (uint256 j; j < nOut; j++) {
                if (order.legsOut[j].start == 0) return (false, "output start is zero (giveaway)");
                if (order.legsOut[j].end != 0 && order.legsOut[j].start < order.legsOut[j].end) {
                    return (false, "output start < end (must fall)");
                }
            }
        } else {
            // BUY outputs are FIXED (exact-output); the canonical form is `end == 0`.
            for (uint256 j; j < nOut; j++) {
                if (order.legsOut[j].start == 0) return (false, "output start is zero (giveaway)");
                if (order.legsOut[j].end != 0) return (false, "buy output must be fixed (end == 0)");
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
        for (uint256 i; i < nIn; i++) {
            for (uint256 k = i + 1; k < nIn; k++) {
                if (order.legsIn[i].token == order.legsIn[k].token) return (false, "duplicate input token");
            }
            if (order.items.length == 0) {
                for (uint256 j; j < nOut; j++) {
                    if (order.legsIn[i].token == order.legsOut[j].token) return (false, "input token == output token");
                }
            }
        }
        for (uint256 j; j < nOut; j++) {
            // A leg addressed to the settlement contract permanently burns that
            // delivery (it lands in the anti-donation snapshot baseline and is
            // never swept). On-chain it's a maker self-burn, not an exploit, but
            // the preflight should catch the footgun.
            if (order.legsOut[j].recipient == address(SETTLEMENT)) return (false, "recipient is settlement (burn)");
            for (uint256 k = j + 1; k < nOut; k++) {
                if (
                    order.legsOut[j].token == order.legsOut[k].token
                        && order.legsOut[j].recipient == order.legsOut[k].recipient
                ) {
                    return (false, "duplicate output token+recipient");
                }
            }
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
            uint256 nItems = order.items.length;
            for (uint256 s; s < nItems; s++) {
                if (order.items[s].op == ItemOp.SETTLE && order.items[s].amount <= 1) {
                    return (false, "settle item requires full-fill");
                }
            }
        }
        if (order.decayDuration() != 0 && order.decayStartTime() == 0) return (false, "decay set without decayStartTime");

        // ── soft exclusivity override ──
        if (order.exclusivityOverrideBps != 0) {
            if (order.exclusiveFiller == address(0)) return (false, "override without exclusiveFiller");
            if (order.exclusivityOverrideBps > 10_000) return (false, "exclusivityOverrideBps > 10000");
        }
        // ── piecewise auction curve (monotonic time, bounded bump) ──
        uint256 nCurve = order.curve.length;
        for (uint256 c; c < nCurve; c++) {
            if (order.curve[c].bumpBps > 10_000) return (false, "curve bumpBps > 10000");
            if (c != 0 && order.curve[c].timeDelta <= order.curve[c - 1].timeDelta) {
                return (false, "curve timeDelta not increasing");
            }
        }
        if (order.curve.length != 0 && order.decayStartTime() == 0) return (false, "curve set without decayStartTime");
        // ── gas bump ──
        if (order.gasBumpBps != 0) {
            if (order.gasPriceRef == 0) return (false, "gasBump without gasPriceRef");
            if (order.gasBumpBps > 10_000) return (false, "gasBumpBps > 10000");
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
        uint256 len = order.validators.length;
        for (uint256 i; i < len; i++) {
            Validator calldata v = order.validators[i];
            if (!_gatePasses(v.target, order, filler, v.data, takerData)) return false;
        }
        return true;
    }

    /// @dev Byte-for-byte mirror of the settlement's validator gate (see
    ///      {Settlement._gatePasses}): single-word return read into
    ///      scratch space, no `bytes memory` return allocation.
    function _gatePasses(
        address target,
        Order calldata order,
        address filler,
        bytes calldata data,
        bytes calldata takerData
    ) private view returns (bool pass) {
        bytes memory cd = abi.encodeCall(IOrderValidator.validate, (order, filler, data, takerData));
        /// @solidity memory-safe-assembly
        assembly {
            let ok := staticcall(gas(), target, add(cd, 0x20), mload(cd), 0x00, 0x20)
            pass := and(and(ok, gt(returndatasize(), 31)), eq(mload(0x00), 1))
        }
    }

    /// @dev Live `token.allowance(owner, spender)` — best-effort staticcall; a
    ///      token without a readable allowance view reports 0 (never reverts the
    ///      preflight).
    function _erc20Allowance(address token, address owner, address spender) private view returns (uint256 a) {
        (bool ok, bytes memory ret) =
            token.staticcall(abi.encodeWithSignature("allowance(address,address)", owner, spender));
        if (ok && ret.length >= 32) a = abi.decode(ret, (uint256));
    }

    /// @dev The leg anchor: the FIXED side's leg 0 — `startAmountIn[0]` (SELL) or
    ///      `startAmountOut[0]` (BUY). Reverts on empty legs; only call when a
    ///      fungible anchor is known to exist.
    function _anchorTotal(Order calldata order) internal pure returns (uint256) {
        return order.side == OrderSide.BUY ? order.legsOut[0].start : order.legsIn[0].start;
    }

    /// @dev The fill denominator: the maker-signed `fillTotal` when set (module
    ///      orders — no leg access, so it's safe for empty-leg NFT swaps), else
    ///      the leg anchor. Mirrors the settlement's `_openFill`.
    function _fillDenominator(Order calldata order) internal pure returns (uint256) {
        return order.fillTotal != 0 ? order.fillTotal : _anchorTotal(order);
    }

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
    function _verifySignature(bytes32 orderHash, bytes calldata sig, address expected) internal view {
        if (sig.length == 0) {
            if (!SETTLEMENT.orderApproved(expected, orderHash)) revert OrderNotApproved();
            return;
        }
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", SETTLEMENT.DOMAIN_SEPARATOR(), orderHash));
        // Shared verifier: EOA (ecrecover), EIP-1271 contract wallets, and
        // EIP-7702 accounts (raw-key or delegated-1271) are all accepted.
        SignatureVerification.verify(sig, digest, expected);
    }
}
