// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IFundingSource} from "@core/interfaces/IFundingSource.sol";
import {IProceedsAsset} from "@core/interfaces/IProceedsAsset.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {Order, ItemOp, OrderSide, FillCtx} from "@core/settlement/Structs.sol";
import {OrderHash} from "@core/settlement/OrderHash.sol";
import {PackedArrays} from "@core/settlement/PackedArrays.sol";
import {DutchAuction} from "@core/settlement/DutchAuction.sol";
import {Pricing} from "@core/settlement/Pricing.sol";
import {OrderGates} from "@core/settlement/OrderGates.sol";
import {Proportional} from "@core/settlement/Proportional.sol";

import {ISettlementState, SettlementLens} from "./SettlementLens.sol";

/// @title SettlementLensChecks
/// @notice The well-formedness and item-funding half of {SettlementLens}:
///         `validateOrder`, `previewTakerAllowances`, `previewItemFunding`, and the
///         structural dead-shape probe {SettlementLens.getOrderRelevantState} uses.
///
/// @dev    ⚠ A SPLIT FOR EIP-170, NOT A PROXY. The lens sat 268 bytes under the
///         runtime limit with the 2026-09-30 audit's preflight-parity fixes still to
///         land. Every function here was moved out of the lens verbatim, and the lens
///         keeps a one-line forwarder with the unchanged signature, so no caller
///         moves. This contract is created by the lens's constructor (its address is
///         fixed by the lens's), is immutable, holds no state, funds or approvals,
///         and is only ever reached by an ordinary STATICCALL — it runs in its own
///         context, never the lens's. It can be called directly, with identical
///         results.
contract SettlementLensChecks {
    using OrderHash for Order;
    using DutchAuction for Order;
    using Pricing for Order;

    /// @notice The settlement these checks report on.
    ISettlementState public immutable SETTLEMENT;
    /// @notice Cached from the settlement — the Permit3 whose taker book
    ///         {previewTakerAllowances} reads.
    IPermit3 public immutable PERMIT3;
    /// @dev Cached from the settlement at deploy — its {SolverCallbackExecutor}.
    ///      An output leg paid THERE is a maker footgun on both paths
    ///      ({validateOrder}): the netted path refuses it
    ///      ({Base.OutputToSettlement}), and on the single path whatever lands on
    ///      the executor is taken by the next callback solver, whose `CALL` runs
    ///      from it. Immutable because the settler's own is — the pair is fixed at
    ///      the settler's construction, so one read is exact forever.
    address private immutable EXECUTOR;

    constructor(address settlement) {
        SETTLEMENT = ISettlementState(settlement);
        PERMIT3 = ISettlementState(settlement).PERMIT3();
        EXECUTOR = ISettlementState(settlement).EXECUTOR();
    }

    /// @dev `recipient` of packed output leg `k` — small helper so the duplicate-leg
    ///      scan can compare recipients without decoding the whole leg twice.
    function _legOutRecipient(bytes calldata legs, uint256 k) private pure returns (address r) {
        (,,, r) = PackedArrays.legOut(legs, k);
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
            // Item-free orders: an input that is also an output is a no-op the
            // maker did not mean. DELTA-VERIFY orders (timing bit 104): the settler
            // rejects it for EVERY output leg, items or not
            // ({Core._snapshotOutRecipients} → `DeltaVerifySameToken`) — F29 8c.
            if (PackedArrays.countUnchecked(order.items) == 0 || order.deltaVerifyOutputs()) {
                for (uint256 j; j < nOut; j++) {
                    if (PackedArrays.legInToken(order.legsIn, i) == PackedArrays.legOutToken(order.legsOut, j)) {
                        return (false, "input token == output token");
                    }
                }
            }
        }
        for (uint256 j; j < nOut; j++) {
            // A leg addressed to the settlement contract is a footgun on BOTH paths,
            // in two different ways. On the single-order path it permanently burns
            // that delivery — it lands in the anti-donation snapshot baseline and is
            // never swept — which is a maker self-burn, not an exploit. On the netted
            // path it is REJECTED ({Base.OutputToSettlement}), because there it could
            // not be burned at all: a pool→pool self-transfer leaves the balance
            // untouched while the schedule marks the obligation discharged, so the
            // amount would clear the pre-context floor and reach the SOLVER in the
            // final sweep. Either way the preflight should catch it before a
            // signature exists.
            (address ojToken,,, address ojRecip) = PackedArrays.legOut(order.legsOut, j);
            if (ojRecip == address(SETTLEMENT)) return (false, "recipient is settlement (burn)");
            // The settler's {EXECUTOR} is the same hazard one hop out (re-audit
            // 2026-09-29), and WORSE on the single path: not burned but TAKEABLE. It
            // holds whatever lands on it and every callback solver's `CALL` runs from
            // it, so the next `fillWithCallback` anyone submits can sweep the leg to
            // itself. The netted path refuses it outright ({Base.OutputToSettlement}).
            if (ojRecip == EXECUTOR) return (false, "recipient is settlement executor (takeable)");
            // Recipients compared RESOLVED, `0 → maker`, on both sides — the core's
            // own reading ({Core._snapshotOutRecipients} resolves before its
            // `DeltaVerifyDuplicateLeg` test), so `(T → 0)` and `(T → maker)` are the
            // same delivery twice (audit 2026-09-30 G-LENS_PARITY-5).
            if (ojRecip == address(0)) ojRecip = order.maker;
            for (uint256 k = j + 1; k < nOut; k++) {
                address rk = _legOutRecipient(order.legsOut, k);
                if (ojToken == PackedArrays.legOutToken(order.legsOut, k) && ojRecip == (rk == address(0) ? order.maker : rk))
                {
                    return (false, "duplicate output token+recipient");
                }
            }
        }
        return (true, "");
    }

    /// @dev What the maker gets for what it gives, from the order's SHAPE (audit
    ///      2026-09-30 VAL-1 / VAL-1.v2). Two rules, applied to every order — the old
    ///      single rule sat inside `fillTotal == 0`, so every fill-module order (the
    ///      `FullFillModule` purchase and NFT-swap shapes) skipped it:
    ///
    ///      1. GIVEAWAY: no output leg, no item that acts on the maker's own position
    ///         (`MAKE`/`TAKE`/`TAKE_FOR` — a deposit is consideration), and no
    ///         invariant. A `SETTLE` item is NOT consideration: every one the core runs
    ///         moves the maker's asset TO the filler.
    ///      2. INVARIANT-ONLY CONSIDERATION: the receipt rests on an invariant — no
    ///         output leg at all, or a `SETTLE` hand-over priced against an
    ///         invariant — with no position item. An invariant checks an absolute
    ///         END STATE ("the maker owns NFT #7"), not a delivery by THIS filler, so
    ///         when the maker obtains the asset any other way (a second bid, another
    ///         venue, an earlier fill in the same block) ANY filler can collect the
    ///         maker's payment, or its `SETTLE`d asset, without delivering. Sound only
    ///         when the one party able to fill is the one trusted to deliver: a single
    ///         named HARD `exclusiveFiller` whose window covers the order's whole life.
    ///         Orders whose consideration is a leg or a position item keep their
    ///         invariants as extra safety and are not flagged.
    function _consideration(Order calldata order, uint256 nOut) private pure returns (bool, string memory) {
        uint256 nItems = PackedArrays.validateRecords(order.items, PackedArrays.ITEM_HEAD);
        uint256 cur = PackedArrays.recordsStart();
        uint256 settles;
        for (uint256 i; i < nItems; i++) {
            (uint256 op,,,,, uint256 nxt) = PackedArrays.itemAt(order.items, cur);
            if (op == uint256(ItemOp.SETTLE)) ++settles;
            cur = nxt;
        }
        // Items other than SETTLE act on the maker's own position.
        if (nItems != settles) return (true, "");
        bool invariants = PackedArrays.countUnchecked(order.invariants) != 0;
        if (nOut == 0 && !invariants) return (false, "no tokenOut and no items (giveaway)");
        if (invariants && (nOut == 0 || settles != 0) && !_exclusiveForLife(order)) {
            return (false, "invariant-only consideration needs a single hard exclusiveFiller for the order's life");
        }
        return (true, "");
    }

    /// @dev One named filler (not `0`, not the {OrderGates.FILLER_SET} sentinel), a
    ///      HARD window (no soft override admitting outsiders), and a window that does
    ///      not end before the order does. A block-clocked window cannot be compared
    ///      with the timestamp expiry, so it must be open-ended (`uint32` max).
    function _exclusiveForLife(Order calldata order) private pure returns (bool) {
        address ex = order.exclusiveFiller;
        if (ex == address(0) || ex == OrderGates.FILLER_SET || order.overrideBps() != 0) return false;
        return order.exclusivityEndTime() >= (order.blockClock() ? type(uint32).max : order.expiry());
    }

    /// @notice Whether `order` has a STRUCTURAL defect every fill reverts on, whatever
    ///         the chain state — the probe {SettlementLens.getOrderRelevantState} uses
    ///         to read such an order `Invalid` instead of `Fillable` (audit 2026-09-30
    ///         G-LENS_PARITY-6). Reverts on a malformed blob, which the lens reads as
    ///         dead too (the settlement reverts on it).
    /// @dev    Each rule is a settler revert, and ONLY settler reverts belong here —
    ///         this view must never be stricter about fillability than the fill:
    ///           • a {Proportional} marker anywhere but `legsIn[0]` of a plain SELL —
    ///             {Pricing.inputOwed} reverts `InvalidProportionalLeg` /
    ///             `ProportionalNeedsFullFill`;
    ///           • an auctioned input whose `end` is below its `start`, or an
    ///             auctioned SELL output whose `start` is below its `end` —
    ///             {DutchAuction.inTick}/{DutchAuction.outTick} revert
    ///             `InvalidAuctionParams` on every fill;
    ///           • a priority auction (no price module) with a zero scale or a gas
    ///             bump — {DutchAuction.priorityBump} reverts `InvalidAuctionParams`;
    ///           • an unknown item op — {Base._runItem} reverts `MalformedPackedArray`;
    ///           • a malformed `items`, `validators` or `invariants` blob, and a fill
    ///             denominator that cannot resolve — reverts here.
    function deadShape(Order calldata order) external view returns (bool) {
        OrderGates.fillDenominator(order);
        PackedArrays.validateRecords(order.validators, PackedArrays.VALIDATOR_HEAD);
        PackedArrays.validateRecords(order.invariants, PackedArrays.VALIDATOR_HEAD);
        uint256 n = PackedArrays.validateRecords(order.items, PackedArrays.ITEM_HEAD);
        uint256 cur = PackedArrays.recordsStart();
        for (uint256 i; i < n; i++) {
            (uint256 op,,,,, uint256 nxt) = PackedArrays.itemAt(order.items, cur);
            if (op > uint256(ItemOp.TAKE_FOR)) return true;
            cur = nxt;
        }
        bool sell = order.side() == OrderSide.SELL;
        bool plain = sell && order.fillTotal == 0 && order.fillModule == address(0);
        n = PackedArrays.validateFixed(order.legsIn, PackedArrays.LEG_IN_STRIDE);
        for (uint256 i; i < n; i++) {
            (, uint256 s, uint256 e) = PackedArrays.legIn(order.legsIn, i);
            if (Proportional.isProportional(s)) {
                if (i != 0 || !plain) return true;
            } else if (e != 0 && s > e) {
                return true;
            }
        }
        if (sell) {
            n = PackedArrays.validateFixed(order.legsOut, PackedArrays.LEG_OUT_STRIDE);
            for (uint256 j; j < n; j++) {
                (, uint256 s, uint256 e,) = PackedArrays.legOut(order.legsOut, j);
                if (e != 0 && s < e) return true;
            }
        }
        return order.pricingModule == address(0) && order.priorityAuction()
            && (order.priorityScale() == 0 || order.gasBumpBps() != 0);
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
    ///         Stranded-tail caveat: any `0 < minFillAnchor < anchor` lets a solver
    ///         leave a remainder smaller than `minFillAnchor` that can then never be
    ///         filled. The CONFIGURATION is not flagged (partial-fill-with-floor is
    ///         legitimate; only `minFillAnchor ∈ {0, anchor}` rules the tail out),
    ///         but an order whose live remainder HAS fallen below the floor is — it
    ///         is dead ("remaining below minFillAnchor (stranded tail)").
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
        }
        // ── consideration ── (every order, `fillTotal` or not — see {_consideration})
        {
            (bool okC, string memory whyC) = _consideration(order, nOut);
            if (!okC) return (false, whyC);
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
        {
            (bool okItems, string memory whyItems) = _validateItemSlices(order, anchor);
            if (!okItems) return (false, whyItems);
        }
        if (order.decayDuration() != 0 && order.decayStartTime() == 0) {
            return (false, "decay set without decayStartTime");
        }

        // ── soft exclusivity override ──
        if (order.overrideBps() != 0) {
            if (order.exclusiveFiller == address(0)) return (false, "override without exclusiveFiller");
            if (order.overrideBps() > 10_000) return (false, "overrideBps > 10000");
            // The third override rule — "some leg must be able to CARRY the premium"
            // ({_overrideHasCarrier}) — is checked LAST, in {_validateTakeForItems}'s
            // tail, not here: a pre-funded leg under an override is the more specific
            // defect (outsiders revert there even WITH a carrier), so its reason must
            // win when both apply.
        }
        // ── delta-verify needs ONE named filler ──
        // The settler fills a bit-104 order for its `exclusiveFiller` only, whatever
        // the window says ({Core._snapshotOutRecipients}): the balance delta cannot
        // tell this fill's delivery from the maker's other paid inflow, so the maker
        // must name who runs the callback. Zero and the filler-set sentinel can never
        // equal a caller — such an order is signable and dead (re-audit F30).
        if (
            order.deltaVerifyOutputs()
                && (order.exclusiveFiller == address(0) || order.exclusiveFiller == OrderGates.FILLER_SET)
        ) {
            return (false, "delta-verify order must name a single exclusiveFiller");
        }
        // ── filler set ({OrderGates.FILLER_SET}) ──
        // A set order carries `curve = [0x00] ‖ filler×N`. The leading COUNT BYTE is
        // zero, so the curve validation below reads it as "no curve points" and never
        // looks at the entries — nothing else in this function would ever inspect the
        // set. Without this check a malformed set is reported VALID here and then
        // reverts {OrderGates.MalformedFillerSet} on every fill, which is the worst of
        // both: the maker signed exclusivity and the order is simply dead. Mirror the
        // settler's shape test exactly so the two cannot drift.
        //
        // Deliberately NOT gated on the window still being open, even though the
        // settler only reaches its copy of this test in-window. A lapsed window makes
        // a broken set harmless (the gate is skipped and the order fills), so this is
        // strictly stricter than the fill — but it matches how the two exclusivity
        // shape rules directly above already behave: `override without
        // exclusiveFiller` also only bites in-window and is also unconditional. The
        // shape section reports what the maker SIGNED, so a defect stays reported
        // once the window lapses instead of quietly ageing out.
        if (order.exclusiveFiller == OrderGates.FILLER_SET) {
            uint256 setLen = order.curve.length;
            if (setLen < 21 || (setLen - 1) % 20 != 0 || order.curve[0] != 0) {
                return (false, "malformed filler set");
            }
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
        } else if (order.gasPriceRef() != 0) {
            // `gasPriceRef` is read by NOTHING but the gas bump. Set without one it is
            // inert, and the likeliest reason a builder set it is that it meant
            // {DutchAuction.baselinePriorityFeeWei} — a different field, in bits of its
            // own precisely so the two can never be confused for each other on-chain.
            return (false, "gasPriceRef without gasBump");
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
            // What a module CAN see decides what is a footgun here. {IPriceModule.bump}
            // is handed `order.timing` and the two leg blobs — and NOTHING else. So:
            //
            //   • `order.curve` and `order.params` are not passed at all. No price
            //     module can read them, whatever it does, so a signed CURVE or gas
            //     bump is PROVABLY inert on a module order. Both stay rejected.
            //
            //     ⚠ "curve" here means curve POINTS — `nCurve`, not `curve.length`.
            //     A {OrderGates.FILLER_SET} order stores its filler set in the very
            //     same `curve` blob behind a zero count byte, and that set is NOT
            //     inert: {OrderGates.exclusivityOverride} reads it on every fill,
            //     whatever prices the order. `nCurve` is 0 for such a blob, so the
            //     test below correctly lets a set + module order through. DO NOT
            //     "harden" it to `order.curve.length != 0` — that would reject every
            //     filler-set order that prices off a module. The set's own shape is
            //     validated in the filler-set branch above.
            //   • the `timing` word IS passed, so every field packed in it is fair
            //     game for a module to consume. `decayStartTime` (bits [0:32)) keeps
            //     its "not before" meaning ({DutchAuction.resolveBump} enforces it),
            //     and `decayDuration` (bits [32:64)) is NOT inert: a clock-consuming
            //     module reads it. {ClockFlooredQuoteModule} floors a cosigned quote
            //     with exactly that window, and REQUIRES a non-zero one — with
            //     `decayDuration == 0` its ceiling is a constant 0 and its quote
            //     channel is dead. Rejecting the pair would have declared every
            //     working quote-auction order invalid while blessing only the
            //     degenerate one, so it is deliberately NOT rejected.
            //
            // The lens cannot tell a clock-consuming module from a clock-ignoring one
            // without a capability probe, and it has no bytes for one (EIP-170). Given
            // the choice, a missed advisory on an inert field is much cheaper than a
            // false REJECT that makes a live feature unusable through any book gating
            // on this function.
            //
            // `priorityAuction` (bit 103) is different from the rest of `timing`: it is
            // not a field a module reads, it is a COMPETING core pricing mode, and
            // {DutchAuction.resolveBump} silently prefers the module. Still a conflict.
            if (order.priorityAuction()) return (false, "price module with priority auction");
            if (nCurve != 0) return (false, "price module with curve");
            if (order.gasBumpBps() != 0) return (false, "gas bump with price module");
        }

        // ── current fillability (time/state-dependent) ──
        // The top half of the nonce space is reserved for delegated-signer permits
        // ({NonceManager.SIGNER_NONCE_NS}); {Base._gateOrderPost} reverts
        // `OrderNonceReserved` on every fill of such an order (F29 finding 8b).
        if (order.nonce >> 255 != 0) return (false, "nonce in the reserved signer-permit half");
        if (order.expiry() < block.timestamp) return (false, "order expired");
        if (SETTLEMENT.isNonceCancelled(order.maker, order.nonce)) return (false, "nonce cancelled");
        // The per-hash cancellation sentinel, named as itself. `filled == max` is
        // ≥ any real `anchor`, so before this the next line reported a cancelled
        // order as "order fully filled" — the same two-axis conflation {_orderState}
        // carried. Both directions reject, so this only ever changed the REASON
        // string; it is fixed because a wrong reason is what an integrator reads.
        uint256 done = SETTLEMENT.filled(order.hash());
        if (done == type(uint256).max) return (false, "order cancelled");
        if (done >= anchor) return (false, "order fully filled");
        // Every fill under the floor reverts `FillTooSmall` and none can exceed the
        // remainder, so a remainder below the floor never fills (G-LENS_PARITY-2).
        if (anchor - done < order.minFillAnchor) return (false, "remaining below minFillAnchor (stranded tail)");

        // TAKE_FOR descriptors, LAST and returned directly. Every check it makes is
        // a revert at FILL time in {Base._forSlice}, so catching them here is the
        // difference between a maker learning at build time and holding a signed
        // order that is simply dead. It is tail-called rather than checked inline
        // because this function is already at the legacy codegen's stack limit —
        // binding its two return values to locals here is stack-too-deep.
        return _validateTakeForItems(order);
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
    ///         per TAKE or TAKE_FOR item in signed order (both consume the same
    ///         book; a TAKE_FOR's FUNDING leg is a token allowance, reported by the
    ///         token-side preflight instead). `refs[j] = keccak256(item.data)` (the
    ///         position key), `amounts[j]` the live allowance (`uint160.max` =
    ///         infinite), `expirations[j]` its expiry (`0` = never).
    function previewTakerAllowances(Order calldata order) external view returns (SettlementLens.TakerAllowances memory out) {
        bytes calldata items = order.items;
        uint256 n = PackedArrays.validateRecords(items, PackedArrays.ITEM_HEAD);
        // First pass: count TAKE items so the arrays are sized exactly.
        uint256 takes;
        uint256 cursor = PackedArrays.recordsStart();
        for (uint256 i; i < n;) {
            (uint256 op,,,,, uint256 next) = PackedArrays.itemAt(items, cursor);
            // TAKE_FOR passes through the SAME taker-book bucket as TAKE — its
            // value-out leg is gated by `(maker, settlement, module, keccak256(data))`
            // exactly as a plain take is — so it must be surfaced here too, or a
            // composite order preflights as needing no taker allowance at all.
            if (op == uint256(ItemOp.TAKE) || op == uint256(ItemOp.TAKE_FOR)) ++takes;
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

    /// @dev The item-slice half of {validateOrder}, in its own frame (that function
    ///      sits at the legacy codegen's stack limit). Mirrors the three per-item
    ///      reverts the settler raises before any item runs:
    ///
    ///        • an op byte above the enum → {Base.MalformedPackedArray} (F29 8e);
    ///        • an INDIVISIBLE SETTLE or TAKE_FOR (`amount <= 1`) on a partial-
    ///          fillable order → every partial slice floors to 0 and the settler
    ///          reverts {Base.SettleSliceZero}, so the order fills in one shot or
    ///          not at all. Divisible amounts are deliberately allowed: a dust fill
    ///          that floors to 0 is refused by the settler for THAT fill only, and
    ///          a larger fill goes through — that is a filler-side sizing rule, not
    ///          an unfillable order. TAKE_FOR joins SETTLE here (it reverts on a
    ///          zero slice too; it used to be unchecked). Full-fill-only orders
    ///          (`minFillAnchor == anchor`) and fill-module orders are exempt;
    ///        • two funding descriptors naming the SAME output leg →
    ///          {Base.ForLegInvalid} (the leg-reference forms only).
    function _validateItemSlices(Order calldata order, uint256 anchor) private pure returns (bool, string memory) {
        uint256 nItems = PackedArrays.validateRecords(order.items, PackedArrays.ITEM_HEAD);
        uint256 cur = PackedArrays.recordsStart();
        uint256 legsUsed;
        for (uint256 s; s < nItems; s++) {
            (bool ok, string memory why, uint256 nxt, uint256 legBit) = _itemSliceAt(order, cur, anchor);
            if (!ok) return (false, why);
            if (legBit != 0) {
                if (legsUsed & legBit != 0) return (false, "two items fund from the same output leg");
                legsUsed |= legBit;
            }
            cur = nxt;
        }
        return (true, "");
    }

    /// @dev One item's slice checks (see {_validateItemSlices}); returns the next
    ///      cursor and, for a leg-reference funding descriptor, the bit of the leg it
    ///      spends (0 otherwise). Its own frame: the wide `itemAt` tuple does not fit
    ///      beside the loop state under legacy codegen.
    function _itemSliceAt(Order calldata order, uint256 cursor, uint256 anchor)
        private
        pure
        returns (bool, string memory, uint256, uint256)
    {
        (uint256 iop,, uint256 iamt,, bytes calldata idata, uint256 nxt) = PackedArrays.itemAt(order.items, cursor);
        if (iop > uint256(ItemOp.TAKE_FOR)) return (false, "unknown item op", nxt, 0);
        if (order.fillModule == address(0) && order.minFillAnchor != anchor && iop >= uint256(ItemOp.SETTLE) && iamt <= 1) {
            return (false, "settle item requires full-fill", nxt, 0);
        }
        if (idata.length < 32) return (true, "", nxt, 0);
        uint256 desc = uint256(bytes32(idata[0:32]));
        // Leg-reference funding descriptors only: TAKE_FOR's, or a pre-fund MAKE's —
        // the core's own classification ({Base._runItem}'s `preFundMake` is `op ==
        // MAKE` only). A TAKE or SETTLE blob's word 0 is MODULE data, and one that
        // happened to open with bits `101` (an {OcoGroupModule} SETTLE's hashed group
        // id does, 1 time in 8) was read as a descriptor and could be falsely refused
        // for "two items fund from the same output leg" (audit 2026-09-30 G-BYTE_MAP-6).
        if (iop == uint256(ItemOp.MAKE) ? desc >> 253 != 5 : iop != uint256(ItemOp.TAKE_FOR)) {
            return (true, "", nxt, 0);
        }
        if (desc < (uint256(1) << 255) || desc & (uint256(1) << 254) != 0) return (true, "", nxt, 0);
        return (true, "", nxt, uint256(1) << (desc & 0xffff));
    }

    /// @dev The `TAKE_FOR` half of {validateOrder}, in its own frame because that
    ///      function is already at the legacy codegen's stack limit.
    ///
    ///      Mirrors {Base._forSlice} one-for-one — short data, an out-of-range leg,
    ///      a leg the maker does not receive, a missing/zero balance cap, and the
    ///      balance form's full-fill requirement — plus one footgun the core cannot
    ///      judge: a LITERAL funding total of zero, which is a composite item that
    ///      funds nothing, i.e. a plain `TAKE` wearing the wrong op.
    ///      Split into a per-item helper for the same reason {_takerItemAt} is: the
    ///      wide `itemAt` tuple plus the descriptor branches do not fit in one frame
    ///      under the legacy (non-via-IR) codegen this package builds with.
    ///
    ///      Its tail also carries {validateOrder}'s LAST rule, the soft-exclusivity
    ///      carrier check — here rather than in the override section so the more
    ///      specific pre-fund-under-override reason above wins when both apply.
    function _validateTakeForItems(Order calldata order) private view returns (bool, string memory) {
        uint256 n = PackedArrays.validateRecords(order.items, PackedArrays.ITEM_HEAD);
        uint256 cur = PackedArrays.recordsStart();
        for (uint256 i; i < n; i++) {
            (bool ok, string memory why, uint256 nxt) = _proceedsItemAt(order, cur);
            if (!ok) return (false, why);
            (ok, why,) = _takeForItemAt(order, cur);
            if (!ok) return (false, why);
            cur = nxt;
        }
        // ── soft exclusivity with nothing to charge it on ──
        // {OrderGates.exclusivityOverride} refuses an in-window OUTSIDER with
        // `NotExclusiveFiller` when no leg can carry the premium (re-audit
        // 2026-09-29): such a "soft" window is a HARD one, and the override the maker
        // signed is dead weight. Reported whatever the window's state, like the other
        // override shape rules — it is a fact about what was signed.
        if (order.overrideBps() != 0 && !_overrideHasCarrier(order)) {
            return (false, "override has no carrier leg (outsiders are refused in-window)");
        }
        return (true, "");
    }

    /// @dev Whether any leg can carry a soft-exclusivity premium — a copy of
    ///      `OrderGates._overrideHasCarrier`, which is `private` to that library and
    ///      so cannot be called from here. {Pricing} moves only three kinds of leg
    ///      toward the maker: every BUY input, an AUCTIONED (`end != 0`) SELL input,
    ///      and a SELL output addressed to the maker (`0` or `maker`). A
    ///      {Proportional} input never carries it, whatever its `end` (there, the
    ///      cap) — {Pricing.inputOwed} returns the pinned anchor for one, untouched.
    ///
    ///      The raw walk is copied rather than rewritten with the typed accessors,
    ///      for the same reason the library gives: the typed form inlines its whole
    ///      decode per call site and measured +245 bytes here (2026-09-29), against
    ///      a lens left with ~530 to spare. Same packed layout ({PackedArrays}: count byte, then
    ///      LegIn = token(20) | start(32) | end(32) at stride 84, LegOut = token(20) |
    ///      start(32) | end(32) | recipient(20) at stride 104), same predicate —
    ///      `test_lens_softExclusivity_noCarrier_refusedAndFlagged` holds the two
    ///      to agreeing, shape by shape, against the core's own gate.
    function _overrideHasCarrier(Order calldata order) private pure returns (bool has) {
        bool buy = order.side() == OrderSide.BUY;
        // Validated first, so the raw walks below stay inside the signed blobs.
        uint256 nIn = PackedArrays.validateFixed(order.legsIn, PackedArrays.LEG_IN_STRIDE);
        uint256 nOut = buy ? 0 : PackedArrays.validateFixed(order.legsOut, PackedArrays.LEG_OUT_STRIDE);
        bytes calldata legsIn = order.legsIn;
        bytes calldata legsOut = order.legsOut;
        address maker = order.maker;
        uint256 floor = Proportional.SENTINEL_FLOOR; // not assembly-addressable as a constant
        /// @solidity memory-safe-assembly
        assembly {
            // An input leg carries it: every BUY leg, or an auctioned SELL leg — and
            // never a proportional marker.
            let p := add(legsIn.offset, 1)
            for { let e := add(p, mul(nIn, 84)) } lt(p, e) { p := add(p, 84) } {
                if and(or(buy, iszero(iszero(calldataload(add(p, 52))))), iszero(gt(calldataload(add(p, 20)), floor))) {
                    has := 1
                    break
                }
            }
            // A SELL output carries it only if addressed to the maker (0 or maker).
            if iszero(has) {
                p := add(legsOut.offset, 1)
                for { let e := add(p, mul(nOut, 104)) } lt(p, e) { p := add(p, 104) } {
                    let to := shr(96, calldataload(add(p, 84)))
                    if or(iszero(to), eq(to, maker)) {
                        has := 1
                        break
                    }
                }
            }
        }
    }

    /// @dev One item's `TAKE_FOR` checks; a non-composite item passes straight
    ///      through. Returns the next cursor so the walk needs no re-scan.
    function _takeForItemAt(Order calldata order, uint256 cursor)
        private
        view
        returns (bool, string memory, uint256)
    {
        (uint256 op, address module,,, bytes calldata data, uint256 nxt) =
            PackedArrays.itemAt(order.items, cursor);
        // A PRE-FUNDED `MAKE` carries the very same funding descriptor as a
        // composite's value-IN side — {Base._runItem} sizes it through the same
        // {Base._forSlice} — so it needs the same preflight. It is opt-in at word 0,
        // and the test has to fail SOFT: a plain pull `MAKE` opens with an address
        // (`>> 253 == 0`) and is none of this function's business, so anything that
        // is not the pre-fund shape passes straight through rather than being
        // rejected for a descriptor it never claimed to carry.
        if (op == uint256(ItemOp.MAKE)) {
            if (data.length < 32 || uint256(bytes32(data[0:32])) >> 253 != 5) return (true, "", nxt);
        } else if (op != uint256(ItemOp.TAKE_FOR)) {
            return (true, "", nxt);
        }
        if (data.length < 32) return (false, "take_for missing funding descriptor", nxt);

        uint256 desc = uint256(bytes32(data[0:32]));
        if (desc < (uint256(1) << 255)) {
            // LITERAL total. Zero is a composite item that funds nothing — a plain
            // TAKE wearing the wrong op. The core cannot judge that; the maker can.
            if (desc == 0) return (false, "take_for funds nothing (zero literal)", nxt);
            return (true, "", nxt);
        }
        if (desc & (uint256(1) << 254) == 0) {
            // LEG REFERENCE — mirrors {Base.ForLegInvalid} (the missing and not-the-maker's rules).
            uint256 j = desc & 0xffff;
            if (j >= PackedArrays.validateFixed(order.legsOut, PackedArrays.LEG_OUT_STRIDE)) {
                return (false, "take_for leg index out of range", nxt);
            }
            // The maker's own legs are the classic pull-funded shape; a leg addressed
            // to the item's OWN module is the pre-funded one (the module supplies the
            // instructed `forAmount` from its balance — no receive-side approvals).
            // Whether the signed module actually funds from balance is a semantic the
            // lens cannot read; the asset cross-check below still applies to both
            // shapes, and a pull-style module under a module-addressed leg surfaces at
            // preflight as `available == 0` once the maker holds no funding allowance.
            address r = _legOutRecipient(order.legsOut, j);
            // ⚠ THE PRE-FUND BIT MAKES THE RULE STRICT, and the lens used to be
            // LOOSER here than the settler. {Base._forSlice} accepts a
            // maker-addressed leg only while bit 253 is CLEAR; with it set the leg
            // must be addressed to the item's own module, because the module funds
            // from a balance the delivery has to have landed in. A pre-fund
            // descriptor over a maker-addressed leg therefore reverts
            // `ForLegInvalid` at fill time — exactly the class of defect a
            // preflight exists to catch before a signature exists, and now the
            // dominant one, since every one-sided pre-fund op is this shape.
            //
            // The two shapes are DISJOINT, mirroring {Base._forSlice}'s bijection: the
            // pull form must NOT name the module either. Admitting it here (this used
            // to read `&& r != module`) whitelisted the one pairing that pulls a second
            // copy from the maker's wallet and strands the delivery on a shared
            // singleton — the residue an unbound funding token then makes claimable.
            // A preflight that accepts what the settler rejects is worse than no
            // preflight, so the two must agree exactly.
            if (desc & (uint256(1) << 253) != 0) {
                if (r != module) return (false, "pre-funded leg must be addressed to the item's module", nxt);
                // {Base._forSlice} refuses the pre-fund form whenever the soft-
                // exclusivity override is live — any in-window outsider's fill of
                // this order reverts `ForLegInvalid` (F29 finding 8e).
                if (order.overrideBps() != 0) {
                    return (false, "pre-funded leg with an exclusivity override (outsiders revert)", nxt);
                }
                // Bits [16:176) name the asset the module spends; the settler
                // requires the leg to be denominated in it.
                if (PackedArrays.legOutToken(order.legsOut, j) != address(uint160(desc >> 16))) {
                    return (false, "pre-funded leg token != the descriptor's funding token", nxt);
                }
            } else if (r != address(0) && r != order.maker) {
                return (false, "take_for funds a fee leg (not the maker's)", nxt);
            }
            // ── the ASSET half of the de-duplication ──
            // `TAKE_FOR` removes the duplicated funding AMOUNT; the funding ASSET is
            // still named inside `data`, in a per-module layout the core deliberately
            // never decodes. If it is not the leg's token, the leg's amount is applied
            // in the WRONG DECIMALS — the same silent mis-sizing this op exists to
            // remove, returning through the one door the descriptor left open. Only
            // the module can read its own blob, so it is asked
            // ({IFundingSource.fundingSource}); a module that cannot answer reports
            // `address(0)` and this degrades to the pre-existing gap rather than to a
            // false rejection of a fillable order.
            address asset = _fundingAsset(module, order.maker, data);
            if (asset != address(0) && asset != PackedArrays.legOutToken(order.legsOut, j)) {
                return (false, "take_for funds a different asset than the leg it is sized by", nxt);
            }
            return (true, "", nxt);
        }
        // BALANCE — mirrors {Base.ForBalanceInvalid} (the cap and full-fill rules).
        // The live-balance floor rule of {Base.ForBalanceInvalid} is deliberately NOT
        // mirrored: it is a live wallet read, so it is a fillability fact at the
        // moment of the fill, not a defect in the order the maker is about to sign.
        if (data.length < 64) return (false, "take_for balance leg needs a cap", nxt);
        if (uint256(bytes32(data[32:64])) == 0) return (false, "take_for balance cap is zero", nxt);
        // The FLOOR (descriptor bits [160:176), bps of the cap) is the other half of
        // the bound, and NO VALUE OF IT IS A DEFECT. The core resolves an unset floor
        // (0) to 10_000 — fund the whole cap or do not fill — and CLAMPS anything
        // above 10_000 to the same (`Base._forSlice`), so both read "the full cap":
        // the strictest encoding there is, filled by any balance ≥ the cap. This view
        // used to reject a floor above 10_000 as one "no balance can satisfy" — a
        // lens STRICTER than the settler, dropping fillable orders (audit 2026-09-30
        // G-LENS_PARITY-4). Leniency lives in an explicitly signed low `bps`.
        if (order.fillModule == address(0) && order.minFillAnchor != OrderGates.fillDenominator(order)) {
            return (false, "take_for balance leg requires full-fill", nxt);
        }
        // ── the ASSET half, for the BALANCE form ──
        // The same de-duplication the leg reference gets above, applied to the door
        // the balance descriptor leaves open. The core sizes `forAmount` from
        // `balanceOf(address(uint160(desc)), maker)` — a token named by the
        // DESCRIPTOR — while the module spends an asset named separately inside its
        // own `data`. Nothing on-chain reconciles the two, so a descriptor reading a
        // 6-decimal balance while the module funds an 18-decimal asset silently
        // mis-sizes the funding leg while the value-OUT leg still draws in full: a
        // 3,000e6 USDC read funding 3e-9 WETH. Both halves are maker-signed, so no
        // filler can choose either and this is a malformed-order footgun rather than
        // an attack — which is exactly what a preflight is for. Same degradation
        // rule as the leg form: a module that cannot answer reports `address(0)` and
        // this falls back to the pre-existing gap rather than rejecting a fillable
        // order. See `docs/audit-2026-09-leads.md` B-3.
        address balAsset = _fundingAsset(module, order.maker, data);
        if (balAsset != address(0) && balAsset != address(uint160(desc))) {
            return (false, "take_for balance leg reads a different asset than the module funds", nxt);
        }
        return (true, "", nxt);
    }

    /// @dev Decode the item at `cursor`; if it is a TAKE, read its
    ///      `(maker, settlement, module, ref)` taker allowance and write slot `k` of
    ///      `out`. Returns the next cursor and the advanced `k` (unchanged for a
    ///      non-TAKE). Takes `order` (not `maker`+`items` separately) to keep the
    ///      param count — and thus this frame — small.
    function _takerItemAt(Order calldata order, uint256 cursor, SettlementLens.TakerAllowances memory out, uint256 k)
        private
        view
        returns (uint256 next, uint256)
    {
        (uint256 op, address module,,, bytes calldata data, uint256 n2) = PackedArrays.itemAt(order.items, cursor);
        if (op != uint256(ItemOp.TAKE) && op != uint256(ItemOp.TAKE_FOR)) return (n2, k);
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

    // ──────────────── Funding-leg preflight (the TAKE_FOR value-IN side) ────────────────

    /// @dev `module.fundingSource(user, data)` — best-effort staticcall, the same
    ///      posture {_erc20Allowance} takes. A module that does not implement it, or
    ///      reverts on this blob, reports `(address(0), 0)` and every caller here
    ///      reads that as "unknown", never as "broken": these checks are ADDITIONS to
    ///      a preflight that shipped without them, so a module that cannot answer must
    ///      leave the caller with the old behaviour rather than a rejection it would
    ///      not previously have seen.
    function _fundingSource(address module, address user, bytes calldata data)
        private
        view
        returns (address asset, uint256 available)
    {
        (bool ok, bytes memory ret) =
            module.staticcall(abi.encodeCall(IFundingSource.fundingSource, (user, data)));
        if (ok && ret.length >= 64) (asset, available) = abi.decode(ret, (address, uint256));
    }

    /// @dev The PROCEEDS check for one item, and it applies to a plain `TAKE` as much
    ///      as to a composite one — which is why it is its own pass rather than a
    ///      branch inside {_takeForItemAt} (that frame is already at the legacy
    ///      codegen's stack limit, and this check predates `TAKE_FOR` entirely).
    ///
    ///      An item's proceeds are credited by MEASUREMENT — {Core._payInputsToSolver}
    ///      reads the balance delta of `legsIn[i].token` — while the token actually
    ///      delivered is named only inside `data`, in a layout the core never decodes.
    ///      Deliver a token no input leg names and the maker pays TWICE: every leg
    ///      measures zero proceeds, so the whole `owed` is pulled from their wallet,
    ///      AND the delivered token is credited to nobody and can never leave the
    ///      settler (`fill` has no sweep, and Settlement grants no ERC-20 approval to
    ///      anyone — the same invariant that makes the measurement sound).
    ///
    ///      Gated on `recipient == 0` because a signed recipient routes the proceeds
    ///      away from the settler deliberately. See {IProceedsAsset} and
    ///      `docs/reference-audits.md` §F22.
    function _proceedsItemAt(Order calldata order, uint256 cursor)
        private
        view
        returns (bool, string memory, uint256)
    {
        (uint256 op, address module,, address to, bytes calldata data, uint256 nxt) =
            PackedArrays.itemAt(order.items, cursor);
        if (to != address(0)) return (true, "", nxt);
        if (op != uint256(ItemOp.TAKE) && op != uint256(ItemOp.TAKE_FOR)) return (true, "", nxt);
        address got = _proceedsAsset(module, data);
        if (got != address(0) && !_isInputLegToken(order.legsIn, got)) {
            return (false, "item delivers a token no input leg can consume", nxt);
        }
        return (true, "", nxt);
    }

    /// @dev `module.proceedsAsset(data)` — best-effort, same posture as
    ///      {_fundingSource}: silence means "unknown", never "broken".
    function _proceedsAsset(address module, bytes calldata data) private view returns (address a) {
        (bool ok, bytes memory ret) = module.staticcall(abi.encodeCall(IProceedsAsset.proceedsAsset, (data)));
        if (ok && ret.length >= 32) a = abi.decode(ret, (address));
    }

    /// @dev Is `token` one the order's input legs can consume? SOME leg, deliberately
    ///      not leg 0 — a rising relayer-fee leg in a different token is legitimate,
    ///      and proceeds credited to any leg are proceeds that leave the settler.
    function _isInputLegToken(bytes calldata legsIn, address token) private pure returns (bool) {
        uint256 n = PackedArrays.validateFixed(legsIn, PackedArrays.LEG_IN_STRIDE);
        for (uint256 i; i < n; i++) {
            if (PackedArrays.legInToken(legsIn, i) == token) return true;
        }
        return false;
    }

    /// @dev The `asset` half alone — {_takeForItemAt} is stack-tight enough that
    ///      binding the second return value there does not fit.
    function _fundingAsset(address module, address user, bytes calldata data) private view returns (address a) {
        (a,) = _fundingSource(module, user, data);
    }

    /// @notice The FUNDING side of every item that pulls from the maker — `MAKE` and
    ///         `TAKE_FOR` alike. The half {previewTakerAllowances} does not report and
    ///         structurally cannot.
    ///
    /// @dev    An item that funds anything pulls it with
    ///         `permit3.transferFrom(maker, MODULE, asset, …)`, so the grant it spends
    ///         is `(maker, module, asset)`. Neither of the other two preflights reads
    ///         that book: {_makerFillableCap} walks `legsIn` with the SETTLER as
    ///         spender, and {previewTakerAllowances} reads the taker book, which gates
    ///         what LEAVES a position rather than what funds it. The funding asset
    ///         need not appear in `legsIn` at all.
    ///
    ///         `MAKE` is the common case and predates `TAKE_FOR` by a long way — every
    ///         deposit and every repay on every venue funds itself this way, and until
    ///         this view nothing previewed any of them (`docs/reference-audits.md`
    ///         §F21). A `TAKE_FOR` item is the same pull with the amount resolved from
    ///         a descriptor instead of read off the item head.
    ///
    ///         Without this view an order can pass {validateOrder}, pass
    ///         {previewTakerAllowances}, and revert on EVERY fill for want of a single
    ///         `approveToken` — the most likely first-integration failure of the op,
    ///         and the least legible, because the revert surfaces from inside Permit3
    ///         two calls deep with nothing naming the missing grant.
    ///
    ///         `required[j]` is this order's FULL-FILL funding amount, computed the
    ///         way {Base._forSlice} computes it, so `available[j] >= required[j]` is
    ///         the condition for the order to fill whole. It is the figure for the
    ///         DEAREST filler, because the funding a leg reference spends is whatever
    ///         that leg actually delivered (audit 2026-09-30):
    ///           • inside a live SOFT exclusivity window, an outsider — every fill
    ///             through `DestinationSettler7683` is one — delivers maker-addressed
    ///             SELL legs lifted by `overrideBps`, so `required` includes the lift
    ///             (PERIPH-2.v3); the named filler, or anyone after the window, needs
    ///             less;
    ///           • a PRICE-MODULE or PRIORITY-auction order has no context-free tick
    ///             (`currentAmountOut` reverts `PricingNeedsContext` for both, which
    ///             made this view unusable for them — PRICE-15), and the bump it pins
    ///             depends on the filler, so its legs are sized at the signed `start`,
    ///             the most any filler can deliver;
    ///           • a BALANCE descriptor's floor is mirrored: below it, or at a zero
    ///             balance, every fill reverts `ForBalanceInvalid`, and `required` is
    ///             the floor itself, so the comparison fails exactly when the fill
    ///             would (G-LENS_PARITY-3).
    ///
    ///         ⚠ `available >= required` IS NOT A GUARANTEE, for two deliberate
    ///         reasons. A SELL leg is priced per fill with a `ceil`, so N partial
    ///         fills can pull a few units MORE than the leg total — size the module's
    ///         token allowance with margin, not to `required` exactly. And this is a
    ///         live read: the maker can spend the balance or let the grant lapse
    ///         between here and the fill.
    function previewItemFunding(Order calldata order) external view returns (SettlementLens.ItemFunding memory out) {
        bytes calldata items = order.items;
        uint256 n = PackedArrays.validateRecords(items, PackedArrays.ITEM_HEAD);

        uint256 count;
        uint256 cursor = PackedArrays.recordsStart();
        for (uint256 i; i < n;) {
            (uint256 op,,,,, uint256 next) = PackedArrays.itemAt(items, cursor);
            if (op == uint256(ItemOp.MAKE) || op == uint256(ItemOp.TAKE_FOR)) ++count;
            cursor = next;
            unchecked {
                ++i;
            }
        }

        out.modules = new address[](count);
        out.assets = new address[](count);
        out.required = new uint256[](count);
        out.available = new uint256[](count);
        if (count == 0) return out;

        // Full-fill delivery per leg — what the leg-reference descriptor resolves to
        // when the whole order fills. Hoisted out of the walk: it is identical for
        // every item and it is the expensive part.
        uint256[] memory outs = _fullFillOutputs(order);

        uint256 k;
        cursor = PackedArrays.recordsStart();
        for (uint256 i; i < n;) {
            // One helper for the whole per-item decode+read+write, for the reason
            // {_takerItemAt} gives: the wide `itemAt` tuple must not share this frame.
            (cursor, k) = _fundingItemAt(order, outs, out, cursor, k);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev One item's funding row. Mirrors {Base._forSlice}'s three descriptor forms
    ///      at FULL fill; a non-composite item passes straight through.
    function _fundingItemAt(
        Order calldata order,
        uint256[] memory outs,
        SettlementLens.ItemFunding memory out,
        uint256 cursor,
        uint256 k
    ) private view returns (uint256, uint256) {
        (uint256 op, address module, uint256 amount,, bytes calldata data, uint256 n2) =
            PackedArrays.itemAt(order.items, cursor);
        if (op != uint256(ItemOp.MAKE) && op != uint256(ItemOp.TAKE_FOR)) return (n2, k);

        out.modules[k] = module;
        (out.assets[k], out.available[k]) = _fundingSource(module, order.maker, data);
        // A pull MAKE item's funding amount IS the item's own signed amount — there is
        // no descriptor, because there is nothing to de-duplicate: the number is
        // signed once, in the item head. A PRE-FUND MAKE (word 0 `>> 253 == 5`) is the
        // exception: {Base._runItem} sizes it from the descriptor through
        // {Base._forSlice} and never reads `amount` (the SDK signs 0 there), so it is
        // resolved like a `TAKE_FOR` (audit 2026-09-30 G-BYTE_MAP-6).
        bool pullMake = op == uint256(ItemOp.MAKE)
            && (data.length < 32 || uint256(bytes32(data[0:32])) >> 253 != 5);
        out.required[k] = pullMake ? amount : _requiredFunding(order, outs, data);
        unchecked {
            return (n2, k + 1);
        }
    }

    /// @dev The full-fill delivery of every output leg for the DEAREST filler — see
    ///      {previewItemFunding}. The same {Pricing.outputAt} the fill runs, on a
    ///      full-fill {FillCtx} carrying the soft-exclusivity override while the
    ///      window is live (an outsider's lift; an override above `BPS` admits no
    ///      outsider, so it lifts nothing), and a bump pinned at 0 — the signed
    ///      `start` — for a price-module or priority order, whose real bump depends on
    ///      a filler this view does not have.
    function _fullFillOutputs(Order calldata order) private view returns (uint256[] memory outs) {
        uint256 total = OrderGates.fillDenominator(order);
        uint256 ov;
        if (order.exclusiveFiller != address(0) && order.nowTick() < order.exclusivityEndTime()) {
            ov = order.overrideBps();
            if (ov > DutchAuction.BPS) ov = 0;
        }
        FillCtx memory ctx = FillCtx(
            bytes32(0),
            total,
            0,
            total,
            ov,
            address(0),
            address(0),
            true,
            order.pricingModule != address(0) || order.priorityAuction() ? 1 : 0, // pinned bump 0 = `start`
            "",
            new uint256[](0),
            0,
            new uint256[](0),
            0
        );
        outs = new uint256[](PackedArrays.validateFixed(order.legsOut, PackedArrays.LEG_OUT_STRIDE));
        for (uint256 j; j < outs.length; j++) {
            outs[j] = order.outputAt(ctx, j);
        }
    }

    /// @dev The full-fill `forAmount` for one item's descriptor. A malformed one
    ///      reports `0` rather than reverting — {validateOrder} is where malformed
    ///      orders are named, and this view must stay callable on a broken order so a
    ///      UI can show both diagnoses at once.
    function _requiredFunding(Order calldata order, uint256[] memory outs, bytes calldata data)
        private
        view
        returns (uint256)
    {
        if (data.length < 32) return 0;
        uint256 desc = uint256(bytes32(data[0:32]));
        if (desc < (uint256(1) << 255)) return desc; // literal total
        if (desc & (uint256(1) << 254) == 0) {
            uint256 j = desc & 0xffff;
            return j < outs.length ? outs[j] : 0; // leg reference
        }
        // BALANCE: `min(balanceOf(token, maker), cap)`, exactly as the core reads it —
        // AND the core's floor. {Base._forSlice} reverts `ForBalanceInvalid` when that
        // amount is 0 or under `need` (the floor bps of the cap; unset or above 10_000
        // means the whole cap). Reporting the short balance as `required` made a
        // maker who held too little read as funded, since `available` is bounded by
        // the same balance (G-LENS_PARITY-3). Below the floor the answer is the floor
        // (at least 1), which no such balance can meet.
        if (data.length < 64) return 0;
        uint256 cap = uint256(bytes32(data[32:64]));
        uint256 bal = SafeTransferLib.balanceOf(address(uint160(desc)), order.maker);
        if (bal > cap) bal = cap;
        uint256 fb = (desc >> 160) & 0xffff;
        if (fb == 0 || fb > 10_000) fb = 10_000;
        uint256 need;
        unchecked {
            // The core's exact, overflow-free form (`Base._forSlice`).
            need = cap / 10_000 * fb + (cap % 10_000) * fb / 10_000;
        }
        if (bal == 0 || bal < need) return need == 0 ? 1 : need;
        return bal;
    }

    // NOTE ON describe() (U-5): the human-readable per-position string comes from a
    // module's OPTIONAL {ITakerModuleDescribe.describe}, NOT from a lens method — a
    // batched `describeTakerAllowances` here measured +237 bytes and put this lens
    // over EIP-170. It does not need to be on-chain-batched: a frontend already holds
    // each TAKE item's `data` (it has the order), and {previewTakerAllowances} gives
    // it the modules, so it reads `module.describe(data)` directly (with its own
    // graceful fallback). The SDK exposes the ABI for exactly that call.
}
