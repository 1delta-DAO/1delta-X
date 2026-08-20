// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOrderValidator} from "../interfaces/IOrderValidator.sol";
import {Order, OrderSide} from "./Structs.sol";
import {PackedArrays} from "./PackedArrays.sol";
import {DutchAuction} from "./DutchAuction.sol";
import {Proportional} from "./Proportional.sol";

/// @title OrderGates
/// @notice The order-level rules that BOTH the settler and {SettlementLens} have to
///         apply, in one place so they cannot answer differently.
///
///  Why this exists
///  ───────────────
///  The lens is a separate deployed contract — it cannot inherit {Settlement}, which
///  is already near the EIP-170 cap — so it re-implemented the settler's gates. The
///  2026-08 audit found that two of those copies had ALREADY drifted, silently:
///
///    • `_anchorTotal` — the settler added an empty-blob guard ({NoAnchorLeg}) when
///      the legs moved to a packed encoding, because a blob is not an array: an
///      out-of-range read does not revert, `calldataload` pads past the end and
///      yields ZERO. The lens copy never got it, so an order with no legs and no
///      `fillTotal` produced a denominator of 0 where the settler reverts — an
///      underflow panic in `remaining()` and a misleading {OverFill} in `previewFill`.
///    • `_verifySignature` — the settler skips re-verification once
///      `filled[orderHash] != 0` (a non-zero counter already proves some earlier fill
///      presented valid authorization for that maker-committing hash). The lens copy
///      did not, so it was STRICTER than the settler and an orderbook would drop
///      live, fillable size. (That one stays in {SettlementLens}: it reads settler
///      STORAGE, which this pure/view library has no handle on.)
///
///  Neither was a theft path, and that is rather the point — a preflight that
///  disagrees with the settler fails quietly, in whichever direction, and nothing
///  catches it. So the rules that CAN be shared are shared here, and the errors are
///  declared alongside them rather than in each caller.
///
/// @dev All functions are `internal`, so they inline into the caller exactly as the
///      private copies they replace did — this is a de-duplication, not a
///      restructuring, and it is expected to be gas-neutral. The error SELECTORS are
///      unchanged (an error's selector is derived from its name and argument types,
///      never from the scope that declares it), so callers still decode identically.
library OrderGates {
    using DutchAuction for Order;

    /// @dev A non-exclusive filler tried to fill inside the exclusivity window of an
    ///      order that grants no soft-exclusivity override.
    error NotExclusiveFiller();
    /// @dev The order's `params` override (bps) exceeds 100%. Above `BPS` the input-side
    ///      discount in {Pricing.inputOwed} underflows, so the order would be
    ///      unfillable by any non-exclusive filler; reject it explicitly rather than
    ///      surfacing an arithmetic panic.
    error InvalidOverrideBps();
    /// @dev The order derives its fill denominator from leg 0 of the fixed side, but
    ///      that side is empty. Such an order must carry an explicit `fillTotal`.
    error NoAnchorLeg();

    /// @notice `Order.exclusiveFiller == FILLER_SET` — the exclusivity window names a
    ///         SET of fillers instead of one. The set rides the signed `curve` blob:
    ///
    ///             curve = [0x00] ‖ [20-byte filler]×N          (N ≥ 1)
    ///
    ///         The leading zero is the blob's COUNT BYTE: {PackedArrays.validateFixed}
    ///         reads it as "no curve points" and tolerates the trailing bytes, so
    ///         {DutchAuction.bumpBps} prices the order on the plain LINEAR clock and
    ///         never parses the set. That is also the trade a set order signs: a
    ///         piecewise curve and a filler set cannot share the blob — sets decay
    ///         linearly. The window and the soft override keep their existing homes
    ///         (`timing` bits [64:96), `params` bits [0:16)) and their existing
    ///         meanings, so a SET may be soft: an unlisted in-window filler fills
    ///         against the same `overrideBps` price improvement a single-filler
    ///         order charges. `address(1)` is the ecrecover precompile — it can
    ///         never be a fill's `msg.sender`, which is what makes it safe to
    ///         retask as a sentinel.
    address internal constant FILLER_SET = address(1);

    /// @dev A FILLER_SET order whose `curve` is not `[0x00] ‖ fillers×N, N ≥ 1`. A
    ///      malformed set is refused outright rather than read as "empty ⇒ open" —
    ///      the maker signed exclusivity, and a decode bug must not un-sign it.
    error MalformedFillerSet();

    /// @notice Exclusivity gate. Inside the window only the nominated filler — or any
    ///         member of the nominated SET ({FILLER_SET}) — fills for free; every
    ///         other filler is blocked (hard exclusivity) or allowed against an
    ///         `exclusivityOverrideBps` price improvement it must pay the maker
    ///         (soft exclusivity). Returns the override, 0 otherwise.
    function exclusivityOverride(Order calldata order, address filler) internal view returns (uint256 overrideBps) {
        // `exclusivityEndTime` is measured on the ORDER'S OWN clock — block numbers under
        // {DutchAuction.blockClock}, else unix seconds — so a block-clocked order's
        // exclusivity window aligns with its block-clocked decay instead of drifting on a
        // separate seconds clock. `nowTick` is `block.timestamp` for the timestamp orders
        // that are the norm, so their behaviour is unchanged. (UniswapX ties exclusivity
        // to `decayStartTime`, i.e. the same clock as the decay, for the same reason.)
        address ex = order.exclusiveFiller;
        if (ex != address(0) && order.nowTick() < order.exclusivityEndTime()) {
            bool excluded;
            if (ex == FILLER_SET) {
                bytes calldata set = order.curve;
                uint256 len = set.length;
                if (len < 21 || (len - 1) % 20 != 0 || set[0] != 0) revert MalformedFillerSet();
                excluded = true;
                // The length check above proves the blob is exactly [count byte][20-byte
                // entries], so the walk needs no per-entry bounds checks — raw calldata
                // loads, {PackedArrays} style.
                /// @solidity memory-safe-assembly
                assembly {
                    let end := add(set.offset, len)
                    for { let ptr := add(set.offset, 1) } lt(ptr, end) { ptr := add(ptr, 20) } {
                        if eq(shr(96, calldataload(ptr)), filler) {
                            excluded := false
                            break
                        }
                    }
                }
            } else {
                excluded = filler != ex;
            }
            if (excluded) {
                overrideBps = order.overrideBps();
                if (overrideBps == 0) revert NotExclusiveFiller();
                if (overrideBps > DutchAuction.BPS) revert InvalidOverrideBps();
            }
        }
    }

    /// @notice The fill denominator in anchor units: the FIXED side's leg 0 —
    ///         `legsIn[0].start` (SELL) or `legsOut[0].start` (BUY).
    /// @dev    The empty-blob check is NOT optional — see the contract note above.
    ///
    ///         A SELL anchor may carry a {Proportional} marker instead of an
    ///         absolute amount, in which case it is RESOLVED here against the
    ///         maker's live balance — this is the one and only balance read a
    ///         proportional fill performs, and `FillCtx.anchor` pins the result for
    ///         the rest of the fill (see {Proportional}). That is why this is
    ///         `view` rather than `pure`.
    /// @return the denominator, proportional markers already resolved.
    function anchorTotal(Order calldata order) internal view returns (uint256) {
        if (order.side() == OrderSide.BUY) {
            if (PackedArrays.validateFixed(order.legsOut, PackedArrays.LEG_OUT_STRIDE) == 0) revert NoAnchorLeg();
            (, uint256 start,,) = PackedArrays.legOut(order.legsOut, 0);
            // An OUTPUT is what the solver delivers, so a marker relative to the
            // MAKER's balance has no meaning here. Rejected explicitly: such a leg
            // would otherwise read as a ~1.15e77 absolute demand and fail deep in a
            // token transfer with no hint as to why.
            //
            // Only the anchor is checked. `legsOut[1..n]` are deliberately NOT,
            // because there the natural failure is already safe and total (the
            // solver simply cannot deliver 1e77), and a per-leg compare would tax
            // every output of every fill forever to improve one error message.
            if (Proportional.isProportional(start)) revert Proportional.InvalidProportionalLeg();
            return start;
        }
        if (PackedArrays.validateFixed(order.legsIn, PackedArrays.LEG_IN_STRIDE) == 0) revert NoAnchorLeg();
        (address token, uint256 startIn, uint256 endIn) = PackedArrays.legIn(order.legsIn, 0);
        if (Proportional.isProportional(startIn)) {
            // On a proportional leg `end` is not a ramp endpoint — there is nothing
            // to ramp — it is the maker's absolute CAP. See {Proportional} for why
            // an uncapped proportional order is a footgun and this is not optional
            // in practice. `0` keeps the historical "no second endpoint" meaning and
            // leaves the leg uncapped.
            return Proportional.resolve(token, order.maker, startIn, endIn);
        }
        return startIn;
    }

    /// @notice The fill denominator: the maker-signed `fillTotal` when set (module
    ///         orders — no leg access, so it is safe for empty-leg NFT swaps), else
    ///         the leg anchor.
    /// @dev    A `fillTotal` order never reaches {anchorTotal}, which is exactly why
    ///         {Pricing.inputOwed} rejects a proportional leg on one: the marker
    ///         would never be resolved and `FillCtx.anchor` would hold the signed
    ///         total instead of a balance.
    function fillDenominator(Order calldata order) internal view returns (uint256) {
        return order.fillTotal != 0 ? order.fillTotal : anchorTotal(order);
    }

    /// @notice Staticcall `target.validate(order, filler, data, takerData)` and return
    ///         whether it passed (call ok AND ≥32 bytes returned AND the bool word ==
    ///         1). The single-word return is read into scratch space, avoiding the
    ///         `bytes memory` return allocation the abstract call would make — and
    ///         capping the return copy at one word, so a hostile validator cannot
    ///         bomb the caller's memory. `data` is the maker-signed per-validator
    ///         config; `takerData` is the shared filler-supplied blob (a validator
    ///         must independently verify it).
    /// @dev MEASURED 2026-08-19 — the per-gate `abi.encodeCall` below re-encodes the
    ///      WHOLE order (6 blob copies) for every validator AND every invariant, and
    ///      is the largest single gas item left in the fill path. Priced with a
    ///      throwaway harness, per gate:
    ///
    ///        order shape        current    hoisted   saving/extra gate
    ///        1 leg,  0 items     3,152      1,603      −1,549
    ///        2 legs, 2 items     4,750      1,603      −3,147
    ///        4 legs, 4 items     4,903      1,603      −3,300
    ///
    ///      "Hoisted" = encode the order-bearing calldata ONCE per fill, then per gate
    ///      rewrite only the `data`/`takerData` tails and patch their head offsets.
    ///      It works, but it is NOT shipped, for three reasons:
    ///        • it costs **+136 gas on a single-gate order** — and one gate is the
    ///          common shape, so the majority case pays for the minority's win;
    ///        • the buffer must survive item execution (validators run pre-items,
    ///          invariants post-), so it has to be threaded through `_runValidators` →
    ///          `_runInvariants` and re-sized for the largest `data` in the walk;
    ///        • it puts hand-rolled ABI tail-patching on the SECURITY-GATE path, where
    ///          a mis-sized buffer would silently hand a validator the wrong bytes.
    ///      A verbatim `calldatacopy` of the order's calldata region is cheaper still
    ///      and was also rejected: the region's end is not knowable without walking
    ///      every blob, and a non-canonical-but-valid encoding could make the validator
    ///      decode a different order than execution uses.
    ///      Revisit only with a design + differential test of its own.
    function gatePasses(
        address target,
        Order calldata order,
        address filler,
        bytes calldata data,
        bytes memory takerData
    ) internal view returns (bool pass) {
        bytes memory cd = abi.encodeCall(IOrderValidator.validate, (order, filler, data, takerData));
        /// @solidity memory-safe-assembly
        assembly {
            let ok := staticcall(gas(), target, add(cd, 0x20), mload(cd), 0x00, 0x20)
            pass := and(and(ok, gt(returndatasize(), 31)), eq(mload(0x00), 1))
        }
    }
}
