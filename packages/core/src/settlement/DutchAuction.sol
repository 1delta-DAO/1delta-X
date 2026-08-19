// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPriceModule} from "../interfaces/IPriceModule.sol";
import {Order, OrderSide} from "./Structs.sol";
import {PackedArrays} from "./PackedArrays.sol";
import {Proportional} from "./Proportional.sol";

/// @title DutchAuction
/// @notice Dutch decay pricing. Every leg shares ONE clock and ONE normalized
///         decay `bumpBps ∈ [0, 10000]` (0 = the `start` price / best for maker,
///         10000 = the `end` price / worst). Each leg maps that shared bump
///         through its own `start`/`end` bounds. The shape of the bump over time
///         is either a single linear segment (`decayStartTime`/`decayDuration`)
///         or, if `curve` is non-empty, a piecewise-linear interpolation over the
///         signed packed `curve` blob. An optional gas bump adds decay proportional to
///         `block.basefee`, so the maker clears for less when gas is high.
///
///         Fixed legs (`end == 0`) ignore the bump; any leg with `end != 0` is
///         auctioned — outputs FALL (`end ≤ start`), inputs RISE (`start ≤ end`).
///         On SELL the falling outputs are the classic conversion auction and a
///         rising input is the relayer-fee leg; on BUY the rising inputs are the
///         conversion auction.
///
///         Also home to the {Order.timing} accessors — the three uint32 clocks
///         (`decayStartTime` | `decayDuration` | `exclusivityEndTime`) are packed
///         into one word; these unpack them (and the SDK mirrors the layout).
library DutchAuction {
    error AuctionNotStarted();
    error InvalidAuctionParams();
    /// @dev The maker's {IPriceModule} reverted, returned nothing, or returned less
    ///      than a full word. A price the core cannot read is not a price — fail the
    ///      fill rather than fall back to a clock the maker did not sign.
    error PriceModuleFailed();
    /// @dev The order delegates pricing to an {IPriceModule}, and the caller reached a
    ///      path that has no filler / fill-progress / taker blob to resolve it with.
    ///      Use the fill path (which pins the bump) or {SettlementLens.previewFill}.
    error PricingNeedsContext();

    uint256 internal constant BPS = 10_000;

    // ──────────────────── Packed `timing` accessors ────────────────────

    /// @notice Auction start (unix) — bits [0:32) of `order.timing`.
    function decayStartTime(Order calldata order) internal pure returns (uint256) {
        return uint32(order.timing);
    }

    /// @notice Decay window (seconds; 0 = no time decay) — bits [32:64).
    function decayDuration(Order calldata order) internal pure returns (uint256) {
        return uint32(order.timing >> 32);
    }

    /// @notice Exclusivity end — bits [64:96); ignored if `exclusiveFiller == 0`. Read
    ///         against the order's OWN clock ({nowTick}): a block number under
    ///         {blockClock}, else unix seconds — so it aligns with the decay clock rather
    ///         than sitting on a separate one. See {OrderGates.exclusivityOverride}.
    function exclusivityEndTime(Order calldata order) internal pure returns (uint256) {
        return uint32(order.timing >> 64);
    }

    /// @notice The maker's ITEM EXECUTION POLICY — bits [96:100). See {ItemPolicy}.
    /// @dev    `timing`'s three clocks occupy bits [0:96) and every accessor above
    ///         masks to `uint32`, so bits [96:256) were dead space in a word the
    ///         maker ALREADY SIGNS. Putting the policy there buys maker-enforced item
    ///         ordering with no new `Order` field, no EIP-712 typehash change, and no
    ///         golden-hash break — and every order signed before this existed reads
    ///         back {ItemPolicy.ANY}, which is exactly the behaviour it was signed
    ///         under. Bits [100:256) remain free for whatever comes next.
    function itemPolicy(Order calldata order) internal pure returns (uint256) {
        return (order.timing >> 96) & 0xf;
    }

    /// @notice The maker's FILL-ONCE opt-in — bit 100 of `timing`.
    /// @dev    When set, the order is settled against the maker's NONCE BITMAP instead
    ///         of a dedicated `filled[orderHash]` slot: the fill consumes
    ///         `nonceBitmap[maker][nonce >> 8]`'s bit, which every fill already SLOADs
    ///         for the cancellation gate, so the write lands on a WARM, usually
    ///         already-non-zero slot (~2,900 gas) instead of a fresh order-specific
    ///         slot's zero-to-one write (22,100). 256 orders share one word, so only
    ///         the first order in a word pays full price. 1inch LOP v4 calls this the
    ///         bit invalidator and picks it automatically for any order that forbids
    ///         partial or multiple fills; we make it an explicit maker opt-in.
    ///
    ///         Bit 100 was free space in a word the maker ALREADY SIGNS, so this costs
    ///         no new `Order` field, no typehash change and no golden-hash break —
    ///         and every previously signed order reads back 0, i.e. the classic
    ///         per-hash counter it was signed under.
    ///
    ///         ⚠ CONSEQUENCES the maker is opting into:
    ///           • The fill MUST be a full fill ({_openFill} reverts {FillOnceMustBeFull}
    ///             otherwise) — a partial fill would burn the nonce and strand the rest.
    ///           • The nonce is shared state. Filling this order invalidates EVERY
    ///             other order the maker signed with the same nonce, exactly as
    ///             {NonceManager.cancelOrders} would.
    ///           • `filled[orderHash]` stays 0 forever, so {SettlementLens.remaining}
    ///             keeps reporting the full size. Order status must be read from
    ///             {SettlementLens.getOrderRelevantState}, which consults the nonce
    ///             bitmap and reports the order as no longer fillable.
    function useNonceInvalidator(Order calldata order) internal pure returns (bool) {
        return (order.timing >> 100) & 1 == 1;
    }

    /// @notice The order's clock counts BLOCKS, not seconds — bit 102 of `timing`.
    /// @dev    `decayStartTime` and `decayDuration` (and every {CurvePoint.timeDelta})
    ///         are then block numbers and block counts. UniswapX moved its V3 reactor
    ///         to a block clock for the same reason: on a chain with 250ms blocks a
    ///         one-second timestamp tick is eight blocks of resolution, so a
    ///         timestamp-decayed auction cannot price the interval solvers actually
    ///         compete over. `uint32` holds any L2 block number for centuries.
    function blockClock(Order calldata order) internal pure returns (bool) {
        return (order.timing >> 102) & 1 == 1;
    }

    /// @notice The bump is bid in PRIORITY FEE rather than elapsed time — bit 103.
    /// @dev    The parity feature with UniswapX's `PriorityOrderReactor`, for chains
    ///         whose sequencer orders transactions by priority fee (OP-stack, and
    ///         Arbitrum's timeboost). The maker signs the band the other way round:
    ///         `start` is the ambitious price and `end` is the GUARANTEED FLOOR, so a
    ///         zero-priority-fee fill clears at `end` and every gwei bid moves the tick
    ///         toward `start`. The sequencer's own ordering then picks the highest
    ///         bidder; the losers revert on the `filled` guard they already run.
    ///
    ///         Note what this does NOT change: the floor is the same signed `end` the
    ///         core enforces for every other order, so a priority auction adds no way
    ///         to price outside the band. `decayStartTime` keeps its meaning as the
    ///         "not before" gate (a start BLOCK, with bit 102), which is how the maker
    ///         says "let the book see this first, then let solvers bid".
    ///
    ///         The basefee gas bump is IGNORED in this mode — it moves the tick toward
    ///         the floor as gas rises, which is precisely backwards when the filler is
    ///         bidding gas to move it the other way.
    function priorityAuction(Order calldata order) internal pure returns (bool) {
        return (order.timing >> 103) & 1 == 1;
    }

    /// @notice Deliver output legs by VERIFYING the recipient's balance delta instead
    ///         of pushing a nominal amount — bit 104 of `timing`.
    /// @dev    Fee-on-transfer / rebasing-safe delivery, and the generic outcome-based
    ///         settlement primitive. On a delta-verify order the FILLER delivers each
    ///         output leg out-of-band (typically inside the fill callback — pool →
    ///         recipient, aggregator, inventory), and {Core._deliverOutputs} requires
    ///         the recipient's MEASURED balance increase to be at least the leg's
    ///         priced amount ({Pricing.outputAt}) rather than transferring that amount
    ///         from the filler. Because the required amount is still `outputAt`, this
    ///         composes with EVERY pricing mode unchanged — the dutch clock, a priority
    ///         bid, a price module, and partial-fill scaling all flow through as-is;
    ///         a fixed leg is simply a flat floor. The recipient is snapshotted at fill
    ///         start (before the callback), so the check is a true start/end delta, not
    ///         an absolute floor — no signing-time balance to track. Bit 104 was free
    ///         space in a word the maker ALREADY signs, so this costs no new `Order`
    ///         field, no typehash change and no golden-hash break; an order that does
    ///         not set it delivers nominally exactly as before.
    ///
    ///         ⚠ CALLBACK-ONLY. Nothing in the settler delivers these legs, so such an
    ///         order is fillable ONLY through {Core.fillWithCallback}, where the filler
    ///         delivers inside its own callback. Plain `fill` / `fillUpTo` /
    ///         `batchFill` reach the check with nothing delivered and revert
    ///         {DeltaTooLow}; the netted `matchSettle` path rejects the order up front
    ///         ({DeltaVerifyNotBatchable}) because it has no per-order callback. And
    ///         the delivery must happen DURING the fill: the snapshot is taken at fill
    ///         start, so a pre-transfer lands under it and does not count.
    ///
    ///         ⚠ SHAPE RESTRICTIONS, enforced on-chain by {Core._snapshotOutRecipients}:
    ///         no two output legs may share a (token, recipient), and a maker-bound
    ///         output token may not also be an input token. A per-leg balance delta
    ///         only measures one leg when that leg alone moves the balance.
    ///
    ///         ⚠ REBASING / REFLECTION TOKENS. The check measures ANY balance increase
    ///         on the recipient across the fill, not specifically "sent by the filler".
    ///         For an ordinary fee-on-transfer token that is exactly right — it is what
    ///         makes the maker's floor net-of-fee. But a token that credits holders on
    ///         every transfer (reflection), or rebases upward mid-fill, can move the
    ///         recipient's balance on its own, and a filler may lean on that to deliver
    ///         less. Same trust posture as {MinBalanceInvariant}: the maker chose the
    ///         token. Prefer plain fee-on-transfer tokens here.
    function deltaVerifyOutputs(Order calldata order) internal pure returns (bool) {
        return (order.timing >> 104) & 1 == 1;
    }

    /// @notice Order expiry (unix SECONDS) — bits [160:208) of `order.timing`.
    /// @dev    Folded into `timing` rather than carried as its own `Order` word — the
    ///         1inch `makerTraits` expiration trick — which drops one calldata word and
    ///         one hash-preimage word from every order (and shrinks the `Order` ABI
    ///         decoder at every external entry point). `uint48` reaches unix year
    ///         ~8,921,556, so `type(uint48).max` reads as "never expires". Always a
    ///         WALL-CLOCK time: unlike the auction clocks above it ignores {blockClock},
    ///         because the expiry gate is `block.timestamp` on every chain.
    function expiry(Order calldata order) internal pure returns (uint256) {
        return uint48(order.timing >> 160);
    }

    // ──────────────────── Packed `params` accessors ────────────────────

    /// @notice Soft-exclusivity improvement — `params` bits [0:16).
    function overrideBps(Order calldata order) internal pure returns (uint256) {
        return uint16(order.params);
    }

    /// @notice Max extra decay the basefee bump adds — `params` bits [16:32).
    function gasBumpBps(Order calldata order) internal pure returns (uint256) {
        return uint16(order.params >> 16);
    }

    /// @notice Reference basefee (wei) at which the gas bump saturates — bits [32:96).
    /// @dev    64 bits is 18.4 ETH of wei; no reference basefee approaches it.
    function gasPriceRef(Order calldata order) internal pure returns (uint256) {
        return uint64(order.params >> 32);
    }

    /// @notice Priority fee (wei) that buys a FULL bump — `params` bits [96:160).
    ///         Only read under {priorityAuction}; 0 there is a signing error.
    function priorityScale(Order calldata order) internal pure returns (uint256) {
        return uint64(order.params >> 96);
    }

    /// @notice Pack the four auction scalars into a `params` word. Off-chain builders
    ///         mirror this exactly (the SDK's `packParams`).
    /// @dev    Reverts on an out-of-range field rather than silently truncating: this
    ///         word is HASHED INTO THE ORDER, so a truncated `priorityScale` would have
    ///         a contract maker sign an auction with a different bid scale than it
    ///         intended, with no revert. The SDK's `packParams` throws on exactly these
    ///         inputs — keep the two mirrors in agreement.
    function packParams(uint256 overrideBps_, uint256 gasBumpBps_, uint256 gasPriceRef_, uint256 priorityScale_)
        internal
        pure
        returns (uint256)
    {
        if (overrideBps_ > type(uint16).max || gasBumpBps_ > type(uint16).max) revert InvalidAuctionParams();
        if (gasPriceRef_ > type(uint64).max || priorityScale_ > type(uint64).max) revert InvalidAuctionParams();
        return overrideBps_ | (gasBumpBps_ << 16) | (gasPriceRef_ << 32) | (priorityScale_ << 96);
    }

    /// @notice Which side of the order is FIXED and which is auctioned — bit 101 of
    ///         `timing`. See {OrderSide}.
    /// @dev    It lived in its own `Order` field, which cost a full 32-byte calldata
    ///         word and one of the hash preimage's words for a single bit. It is NOT
    ///         derivable from the legs — a fixed-price order has `end == 0` on every
    ///         leg of both sides, and a SELL may carry a RISING relayer-fee input, so
    ///         "which side decays" identifies neither the auctioned side nor the
    ///         anchor. What it selects is which side gets the exactness guarantee
    ///         (SELL: exact-input, BUY: exact-output) and which leg 0 denominates the
    ///         fill. So it stays signed — just not in a word of its own.
    ///
    ///         `0` reads back {OrderSide.SELL}, matching the enum's zero value.
    function side(Order calldata order) internal pure returns (OrderSide) {
        return OrderSide((order.timing >> 101) & 1);
    }

    // ──────────────────── Decay clock ────────────────────

    /// @notice The tick this order's clock reads — seconds by default, BLOCKS under
    ///         {blockClock}. One accessor so the two decay branches and the priority
    ///         gate cannot disagree about which clock the order signed.
    function nowTick(Order calldata order) internal view returns (uint256) {
        return blockClock(order) ? block.number : block.timestamp;
    }

    /// @notice The shared normalized decay for this order at the current time,
    ///         in [0, 10000]. Piecewise if `curve` is set, else a single linear
    ///         segment; then the optional gas bump is added and the sum clamped.
    ///
    /// @dev    Three shapes exist for an order, but only the classic clock is handled
    ///         HERE (linear or piecewise, plus the basefee bump). The other two — an
    ///         EXTERNAL price module (`order.pricingModule`) and a PRIORITY auction —
    ///         are resolved once per fill by {resolveBump} and never reach this
    ///         function; see the ⚠ note below.
    ///
    ///         ⚠ THIS FUNCTION HANDLES THE CLOCK ONLY — not the PRIORITY auction, and
    ///         not an external price module. Both of those are resolved ONCE per fill
    ///         by {resolveBump}, called from {OrderState._openFill} (and
    ///         {SettlementLens._previewCtx}) and pinned in {FillCtx.bump}, which
    ///         {Pricing} reads in preference to this function. So no fill ever reaches
    ///         this function for such an order.
    ///
    ///         ⚠ AND THAT SPLIT IS A SIZE DECISION, NOT A STYLE ONE. MEASURED
    ///         2026-08-12: with the two extra modes branched INSIDE this function,
    ///         Settlement came to 27,254 bytes against EIP-170's 24,576. `bumpBps` is
    ///         reached through {Pricing}, which the optimizer inlines at every
    ///         delivery/payout/pull site in {Core}, {Batch} and the lens, so at
    ///         `optimizer_runs = 20000` every byte added here is paid ~8 times over.
    ///         Moving the two cold modes to a once-per-fill resolution returned
    ///         **1,343 bytes** for zero change in behaviour. Add nothing to this
    ///         function that only a minority of orders need.
    function bumpBps(Order calldata order) internal view returns (uint256 bps) {
        bytes calldata curve = order.curve;
        uint256 n = PackedArrays.validateFixed(curve, PackedArrays.CURVE_STRIDE);

        if (n == 0) {
            // Classic single linear segment.
            uint256 dur = decayDuration(order);
            if (dur != 0) {
                uint256 elapsed = _elapsed(order);
                bps = elapsed >= dur ? BPS : (BPS * elapsed) / dur;
            }
            // decayDuration == 0 ⇒ bps stays 0 (start price, no time decay).
        } else {
            // Piecewise-linear curve, timeDeltas relative to decayStartTime.
            uint256 elapsed = _elapsed(order);
            (uint256 tFirst, uint256 bFirst) = PackedArrays.curvePoint(curve, 0);
            (uint256 tLast, uint256 bLast) = PackedArrays.curvePoint(curve, n - 1);
            if (elapsed <= tFirst) {
                bps = bFirst;
            } else if (elapsed >= tLast) {
                bps = bLast;
            } else {
                // `n - 1` is deliberately left IN the condition. Hoisting it to a
                // local measured WORSE: this loop almost always matches on its first
                // iteration (curves are a handful of points), so the extra local
                // costs more than the re-subtraction it saves. The unchecked
                // increment is a clean win — `k < n - 1` cannot overflow.
                for (uint256 k; k < n - 1;) {
                    (uint256 t1, uint256 b1) = PackedArrays.curvePoint(curve, k + 1);
                    if (elapsed < t1) {
                        (uint256 t0, uint256 b0) = PackedArrays.curvePoint(curve, k);
                        // A well-formed curve is strictly increasing in time, and
                        // {SettlementLens.validateOrder} rejects one that is not. But
                        // the lens is off-chain advice, not a gate: a maker can sign a
                        // flat or decreasing pair anyway, and the settler would then
                        // surface a raw Panic(0x11)/Panic(0x12) from the subtraction
                        // and the divide below. Name it instead. One comparison, and
                        // only on the iteration that matched — this loop almost always
                        // matches on its first.
                        if (t1 <= t0) revert InvalidAuctionParams();
                        uint256 span = t1 - t0; // > 0 by the check above
                        // Interpolate; the curve may rise or fall between points.
                        bps = b1 >= b0
                            ? b0 + ((b1 - b0) * (elapsed - t0)) / span
                            : b0 - ((b0 - b1) * (elapsed - t0)) / span;
                        break;
                    }
                    unchecked {
                        ++k;
                    }
                }
            }
        }

        // Gas bump: extra decay proportional to basefee, capped at gasBumpBps.
        uint256 gb = gasBumpBps(order);
        uint256 ref = gasPriceRef(order);
        if (gb != 0 && ref != 0) {
            uint256 gasAdd = (gb * block.basefee) / ref;
            if (gasAdd > gb) gasAdd = gb;
            bps += gasAdd;
        }
        if (bps > BPS) bps = BPS;
    }

    /// @dev How far into the auction we are, on whichever clock the order signed, with
    ///      the "has it started" gate. Its own function rather than two locals in
    ///      {bumpBps}: the piecewise branch already carries eight live values through
    ///      the interpolation loop, and adding the clock pair to that frame overflows
    ///      the stack under the LEGACY (non-via-IR) profile the test suite compiles.
    function _elapsed(Order calldata order) private view returns (uint256) {
        uint256 startT = decayStartTime(order);
        uint256 t = nowTick(order);
        if (t < startT) revert AuctionNotStarted();
        unchecked {
            return t - startT;
        }
    }

    /// @notice Resolve the bump for a fill whose order does NOT price off the plain
    ///         clock — an external price module or a priority auction — and return
    ///         `bump + 1` for {FillCtx.bump}, or 0 when the order prices off the clock
    ///         and should be resolved lazily per decaying leg.
    /// @dev    ONE call site per fill ({OrderState._openFill}) and one in the lens.
    ///         Everything cold lives behind it; see the size note on {bumpBps}.
    function resolveBump(
        Order calldata order,
        bytes32 orderHash,
        uint256 total,
        address filler,
        uint256 prevFilled,
        bytes memory takerData
    ) internal view returns (uint256) {
        if (order.pricingModule != address(0)) {
            // "Not before" gate — the same `decayStartTime` field, the same meaning,
            // whichever pricing mode. A module order may signal "let the book see this
            // first" with a future start; without this it would price (and fill) before
            // the maker's signed start. Mirrors {priorityBump}'s gate.
            uint256 startT = decayStartTime(order);
            if (startT != 0 && nowTick(order) < startT) revert AuctionNotStarted();
            return priceBump(order, orderHash, total, filler, prevFilled, takerData) + 1;
        }
        if (priorityAuction(order)) return priorityBump(order) + 1;
        return 0;
    }

    /// @notice The PRIORITY-auction bump: the filler bids priority fee, and every wei
    ///         moves the tick from the maker's signed floor (`end`) toward its signed
    ///         ambition (`start`). See {priorityAuction} for the shape and why the
    ///         basefee bump is skipped.
    /// @dev    `tx.gasprice - block.basefee` is the effective priority fee the
    ///         sequencer is being paid. It cannot go negative on a well-formed chain,
    ///         but the subtraction is guarded anyway: an L2 that reports a gas price
    ///         below basefee should price at the floor, not panic every fill.
    function priorityBump(Order calldata order) internal view returns (uint256) {
        uint256 startT = decayStartTime(order);
        // "Not before" gate — the same field, the same meaning, whichever clock.
        if (startT != 0 && nowTick(order) < startT) revert AuctionNotStarted();
        uint256 scale = priorityScale(order);
        // A zero scale would divide by zero on the first bid; an order that opts into
        // the priority auction without one is malformed, not "unbid".
        if (scale == 0) revert InvalidAuctionParams();
        uint256 base = block.basefee;
        uint256 gp = tx.gasprice;
        uint256 prio = gp > base ? gp - base : 0;
        uint256 improve = (prio * BPS) / scale;
        // No bid ⇒ BPS ⇒ the maker receives `end`, its guaranteed floor.
        return improve >= BPS ? 0 : BPS - improve;
    }

    /// @notice Resolve the maker's EXTERNAL price module ({IPriceModule}) and CLAMP its
    ///         answer into [0, BPS]. The clamp is the security property: whatever the
    ///         module says, the resulting tick stays inside the `start`/`end` band the
    ///         maker signed (see {IPriceModule} for the full argument).
    /// @dev    The return is read into scratch space and capped at ONE WORD, so a
    ///         hostile module cannot bomb the caller's memory — the same shape as
    ///         {OrderGates.gatePasses}.
    function priceBump(
        Order calldata order,
        bytes32 orderHash,
        uint256 total,
        address filler,
        uint256 prevFilled,
        bytes memory takerData
    ) internal view returns (uint256 bps) {
        address target = order.pricingModule;
        // Built in its OWN frame: with `orderTiming` added, encoding the nine-value
        // call tuple alongside `target`/`ok`/`bps` overflows the stack under the LEGACY
        // (non-via-IR) profile the test suite compiles.
        bytes memory cd = _encodeBumpCall(order, orderHash, total, filler, prevFilled, takerData);
        bool ok;
        /// @solidity memory-safe-assembly
        assembly {
            ok := staticcall(gas(), target, add(cd, 0x20), mload(cd), 0x00, 0x20)
            ok := and(ok, gt(returndatasize(), 31))
            bps := mload(0x00)
        }
        if (!ok) revert PriceModuleFailed();
        if (bps > BPS) bps = BPS;
    }

    /// @dev ABI-encode the {IPriceModule.bump} call in its own frame — see the stack
    ///      note in {priceBump}.
    function _encodeBumpCall(
        Order calldata order,
        bytes32 orderHash,
        uint256 total,
        address filler,
        uint256 prevFilled,
        bytes memory takerData
    ) private pure returns (bytes memory) {
        return abi.encodeCall(
            IPriceModule.bump,
            (orderHash, order.maker, filler, prevFilled, total, order.timing, order.legsIn, order.legsOut, takerData)
        );
    }

    // ──────────────────── Per-leg ticks ────────────────────

    /// @notice Output tick for leg `j` given a PRECOMPUTED shared `bump` (bps).
    ///         `pure` — the caller computes `bumpBps(order)` once per fill and
    ///         reuses it across every leg. A FIXED leg (`end == 0`) returns `start`
    ///         and ignores `bump`.
    function amountOutAt(Order calldata order, uint256 j, uint256 bump) internal pure returns (uint256) {
        (, uint256 s0, uint256 e0,) = PackedArrays.legOut(order.legsOut, j);
        return outTick(s0, e0, bump);
    }

    /// @notice The output tick from a leg's ALREADY-DECODED bounds. Split out so a
    ///         caller that decoded the whole leg for other reasons ({Pricing}) does not
    ///         pay to decode it twice.
    function outTick(uint256 startOut, uint256 endOut, uint256 bump) internal pure returns (uint256) {
        if (endOut == 0) return startOut; // fixed leg — no bump
        if (startOut < endOut) revert InvalidAuctionParams(); // outputs must FALL
        return startOut - ((startOut - endOut) * bump) / BPS;
    }

    /// @notice Current auction tick for every output leg. Computes the shared
    ///         `bump` at most ONCE (lazily, only if some leg actually decays — so
    ///         an all-fixed order never calls `bumpBps`, preserving its behavior).
    function currentAmountOut(Order calldata order) internal view returns (uint256[] memory outs) {
        // These context-free per-leg views cannot resolve a price module (needs the
        // filler / taker blob / fill progress) or a priority auction (needs the bid),
        // so they would silently return the CLOCK tick — `start` for the typical
        // no-duration module order — while the fill clears at the pinned bump. Fail
        // loudly and send the caller to {SettlementLens.previewFill}/`previewBump`,
        // which resolve the bump the way the fill does.
        if (order.pricingModule != address(0) || priorityAuction(order)) revert PricingNeedsContext();
        uint256 n = PackedArrays.validateFixed(order.legsOut, PackedArrays.LEG_OUT_STRIDE);
        outs = new uint256[](n);
        uint256 bump;
        bool bumpSet;
        for (uint256 j; j < n;) {
            (, uint256 s0, uint256 e0,) = PackedArrays.legOut(order.legsOut, j);
            if (e0 != 0 && !bumpSet) {
                bump = bumpBps(order);
                bumpSet = true;
            }
            outs[j] = outTick(s0, e0, bump);
            unchecked {
                ++j;
            }
        }
    }

    /// @notice Input tick for leg `i` given a PRECOMPUTED shared `bump` (bps).
    ///         `pure` counterpart of `amountOutAt`. FIXED leg (`end == 0`) returns
    ///         `start`.
    function amountInAt(Order calldata order, uint256 i, uint256 bump) internal pure returns (uint256) {
        (, uint256 s0, uint256 e0) = PackedArrays.legIn(order.legsIn, i);
        // A {Proportional} leg has no tick: its amount is a live balance, which a
        // `pure` reader cannot see. Callers that need it (the lens) use
        // {currentAmountIn}, which is `view`. Fail loudly rather than hand back the
        // raw marker — it would read as a ~1.15e77 amount and silently poison any
        // price a validator derives from it.
        if (Proportional.isProportional(s0)) revert Proportional.InvalidProportionalLeg();
        return inTick(s0, e0, bump);
    }

    /// @notice The input tick from already-decoded bounds — see {outTick}.
    function inTick(uint256 startIn, uint256 endIn, uint256 bump) internal pure returns (uint256) {
        if (endIn == 0) return startIn; // fixed leg — no bump
        if (startIn > endIn) revert InvalidAuctionParams(); // inputs must RISE
        return startIn + ((endIn - startIn) * bump) / BPS;
    }

    /// @notice Current auction tick for every input leg. Shared `bump` computed at
    ///         most once (lazily), as in `currentAmountOut`.
    function currentAmountIn(Order calldata order) internal view returns (uint256[] memory ins) {
        // See {currentAmountOut}: a module/priority order has no context-free tick.
        if (order.pricingModule != address(0) || priorityAuction(order)) revert PricingNeedsContext();
        uint256 n = PackedArrays.validateFixed(order.legsIn, PackedArrays.LEG_IN_STRIDE);
        ins = new uint256[](n);
        uint256 bump;
        bool bumpSet;
        for (uint256 i; i < n;) {
            (address tk, uint256 s0, uint256 e0) = PackedArrays.legIn(order.legsIn, i);
            // A {Proportional} leg's "current amount" is its resolved balance slice,
            // not an auction tick — and on such a leg `e0` is the maker's cap, not a
            // ramp endpoint, so feeding the pair to `inTick` would either revert
            // ({InvalidAuctionParams}, since the marker exceeds any cap) or return
            // the raw marker. Resolve it the same way the settler does.
            if (Proportional.isProportional(s0)) {
                ins[i] = Proportional.resolve(tk, order.maker, s0, e0);
                unchecked {
                    ++i;
                }
                continue;
            }
            if (e0 != 0 && !bumpSet) {
                bump = bumpBps(order);
                bumpSet = true;
            }
            ins[i] = inTick(s0, e0, bump);
            unchecked {
                ++i;
            }
        }
    }
}
