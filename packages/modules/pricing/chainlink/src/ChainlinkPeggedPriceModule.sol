// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPriceModule} from "@core/interfaces/IPriceModule.sol";
import {PackedArrays} from "@core/settlement/PackedArrays.sol";
import {Proportional} from "@core/settlement/Proportional.sol";
import {ChainlinkRead} from "@validators/ChainlinkPriceValidators.sol";

/// @title ChainlinkPeggedPriceModule
/// @notice ORACLE-PEGGED pricing: the fill clears at the oracle rate (less the
///         maker's spread), mapped into the band the maker signed. The market-maker
///         and pegged-asset order — "sell stETH at Chainlink −5 bps", "swap USDC↔USDT
///         at the feed" — which a time-decayed dutch auction cannot express and which
///         a boolean price validator can only reject, never price.
///
///  How the mapping works. The maker signs a band on the priced side: `start` (the
///  ambitious end, best for the maker) and `end` (the floor). This module computes
///  the FAIR amount from the oracle and returns the bump that lands the tick on it:
///
///      fair  = anchor · answer · NUM / DEN · (BPS − SPREAD_BPS) / BPS
///      bump  = (start − fair) · BPS / (start − end)          [clamped to 0 … BPS]
///
///  (shown for the common SELL with a FIXED input anchor; a SELL whose `legsIn[0]`
///  rises is solved jointly — see {bump} — and a BUY is the mirror image.)
///
///  so a fair price above the maker's ambition prices at `start`, one below the floor
///  prices at `end` (the core's clamp is the backstop), and anything between lands
///  proportionally. The band therefore remains the absolute bound it always was: this
///  module can only choose WHERE INSIDE IT the fill happens. That is the difference
///  between a bump provider and 1inch's amount getters, and it is why an oracle can
///  be wired in here without becoming a trusted price oracle for the maker's funds.
///
///  ⚠ PLAUSIBILITY, NOT JUST FRESHNESS. `MIN_ANSWER`/`MAX_ANSWER` are an absolute
///  sanity band on the feed itself, checked on top of {ChainlinkRead}'s staleness /
///  incomplete-round / non-positive guards. This closes the gap the validator set
///  documents: a feed that is FRESH AND WRONG (a depeg, a decimals misconfiguration,
///  a thin feed that got pushed) otherwise passes every freshness test. A quote
///  outside the band reverts the fill rather than pricing against it.
///
///  ⚠ CONFIGURATION IS IMMUTABLE AND IS WHAT THE MAKER SIGNS. One instance per
///  (feed, staleness, sanity band, scale, side, spread); identical configurations
///  land on the same CREATE2 address and are shared. See {IPriceModule} for why
///  there is no per-order config blob.
contract ChainlinkPeggedPriceModule is IPriceModule {
    uint256 internal constant BPS = 10_000;

    /// @notice The Chainlink aggregator this instance reads.
    address public immutable FEED;
    /// @notice Heartbeat: a round older than this reverts the fill.
    uint256 public immutable MAX_STALENESS;
    /// @notice Absolute sanity band on the raw feed answer (inclusive).
    int256 public immutable MIN_ANSWER;
    int256 public immutable MAX_ANSWER;
    /// @notice Fixed-point scale applied to `anchor · answer` so the product lands in
    ///         the priced leg's token units: `fair = anchor · answer · NUM / DEN`.
    ///         The deployer folds the feed's decimals and both tokens' decimals in.
    ///         Express a negative decimal exponent as a fraction (`NUM = 1, DEN =
    ///         1e20`), never as an integer `10**(negative)`: that evaluates to 0,
    ///         and `NUM == 0` is rejected ({InvalidConfig}) because it would price
    ///         every SELL at its floor whatever the feed says (audit 2026-09-30
    ///         PRICE-9, the sibling of the validators' `ZeroRatio` fix).
    uint256 public immutable NUM;
    uint256 public immutable DEN;
    /// @notice Which side carries the priced band: true = the OUTPUT band (a SELL,
    ///         where the maker's inputs are fixed and its outputs decay), false = the
    ///         INPUT band (a BUY).
    bool public immutable PRICE_OUTPUT;
    /// @notice The maker's edge over the oracle, in bps, applied against them.
    uint256 public immutable SPREAD_BPS;

    error ImplausiblePrice();
    error NoBand();
    error InvalidConfig();
    /// @dev The order's signed side ({DutchAuction.side}) does not match this
    ///      instance's `PRICE_OUTPUT`: a SELL prices its OUTPUT band, a BUY its INPUT
    ///      band. A mismatch would read the wrong (fixed) side as the band and price
    ///      the order nowhere near the peg, so reject it instead of pricing it wrong.
    error SideMismatch();

    constructor(
        address feed,
        uint256 maxStaleness,
        int256 minAnswer,
        int256 maxAnswer,
        uint256 num,
        uint256 den,
        bool priceOutput,
        uint256 spreadBps
    ) {
        if (feed == address(0) || num == 0 || den == 0 || minAnswer <= 0 || maxAnswer < minAnswer || spreadBps > BPS) {
            revert InvalidConfig();
        }
        FEED = feed;
        MAX_STALENESS = maxStaleness;
        MIN_ANSWER = minAnswer;
        MAX_ANSWER = maxAnswer;
        NUM = num;
        DEN = den;
        PRICE_OUTPUT = priceOutput;
        SPREAD_BPS = spreadBps;
    }

    /// @inheritdoc IPriceModule
    /// @dev Preview-safe: it reads nothing but the feed and the legs, so a book
    ///      quoting with `filler == 0` and empty `takerData` gets the same answer a
    ///      fill would.
    function bump(
        bytes32, /*orderHash*/
        address, /*maker*/
        address, /*filler*/
        uint256, /*prevFilled*/
        uint256 total,
        uint256 orderTiming,
        bytes calldata legsIn,
        bytes calldata legsOut,
        bytes calldata /*takerData*/
    ) external view returns (uint256) {
        // Config↔side sanity: a SELL (side bit 101 == 0) auctions its OUTPUT band, a
        // BUY (== 1) its INPUT band. Reject the mismatch loudly — otherwise `_band`
        // would read the FIXED side as the band and price the order at `start`
        // forever, silently ignoring the peg this module exists to track.
        bool isBuy = (orderTiming >> 101) & 1 == 1;
        if (PRICE_OUTPUT == isBuy) revert SideMismatch();

        int256 answer = ChainlinkRead.read(FEED, MAX_STALENESS);
        if (answer < MIN_ANSWER || answer > MAX_ANSWER) revert ImplausiblePrice();

        (uint256 anchor, uint256 rise, uint256 start, uint256 end) = _band(total, legsIn, legsOut);
        uint256 fair = (anchor * uint256(answer) * NUM) / DEN;
        // A fair amount that truncates to zero (an over-scaled DEN, a dust anchor)
        // would silently price every SELL at its floor: refuse it instead.
        if (fair == 0) revert ImplausiblePrice();

        if (PRICE_OUTPUT) {
            // OUTPUT band FALLS: `start` (best for the maker, most received) ≥ `end`
            // (the floor). A fixed leg (`end == 0`) or a degenerate band (`start ==
            // end`) has no room — the tick is `start`, so return 0.
            if (end == 0 || start <= end) return 0;
            // The maker RECEIVES this leg: its spread lowers what it asks for.
            fair = (fair * (BPS - SPREAD_BPS)) / BPS;
            if (fair >= start) return 0; // oracle better than the maker's ambition
            // A RISING anchor (`legsIn[0].end > start`) is charged
            // `inTick(s, e, b) = s + rise·b/BPS` at the SAME pinned bump that lowers
            // the output, so the peg must hold for both ticks at once:
            //     outTick(b) = r · inTick(b)
            //  ⇒  b = (start − r·s) · BPS / ((start − end) + r·rise)
            // where `r·s` is `fair` and `r·rise` is `fairRise` below. For a fixed
            // anchor `rise == 0` and this is exactly the plain mapping in the header.
            // (It used to ignore the rise and price the peg for `s` units while
            // charging up to `e`: audit 2026-09-30 PRICE-1.v3 / X-ARITH-1.v2.)
            uint256 fairRise;
            if (rise != 0) fairRise = (((rise * uint256(answer) * NUM) / DEN) * (BPS - SPREAD_BPS)) / BPS;
            // The floor beats the peg even at the input's cap → price at `end`.
            if (fair + fairRise <= end) return BPS;
            // Floor division lowers the bump, i.e. rounds toward the maker.
            return ((start - fair) * BPS) / ((start - end) + fairRise);
        } else {
            // INPUT band RISES: `start` (best for the maker, least paid) ≤ `end` (the
            // cap/floor). {DutchAuction.inTick} enforces this orientation, which is the
            // OPPOSITE of an output band — so the mapping below is mirrored, not shared.
            if (end == 0 || end <= start) return 0;
            // The maker PAYS this leg: its spread raises what it will pay.
            fair = (fair * (BPS + SPREAD_BPS)) / BPS;
            if (fair <= start) return 0; // oracle cheaper than the maker's ambition
            if (fair >= end) return BPS; // oracle at or through the cap
            return ((fair - start) * BPS) / (end - start);
        }
    }

    /// @dev The priced band (the auctioned side's leg 0), the anchor the fair amount
    ///      is priced against (the counterpart side's leg 0), and, for a SELL, how far
    ///      that anchor RISES. Which side is which is the instance's `PRICE_OUTPUT`
    ///      setting, cross-checked against the order's signed side in {bump}.
    ///
    ///  ⚠ THE ANCHOR IS THE COUNTERPART LEG'S WHOLE-ORDER AMOUNT, NOT `total`. The
    ///  band `start`/`end` is a whole-order amount and the core scales the band and
    ///  the counterpart by the same `delta / total`, so the fair amount must be
    ///  priced against the counterpart leg's whole-order amount:
    ///
    ///    • SELL: `legsIn[0].start`, EXCEPT when it is a {Proportional} marker. The
    ///      marker (`type(uint256).max − (BPS − bps)`, ≈1.15e77) is not an amount:
    ///      reading it raw overflowed `anchor · answer` and made the order
    ///      unfillable (F8). The amount it stands for is the maker's live balance,
    ///      which the core resolved BEFORE any funds moved and pinned as the fill
    ///      denominator, i.e. `total`. A marker is only legal with `fillTotal == 0`
    ///      and no `fillModule` ({Pricing.inputOwed} reverts otherwise), so `total`
    ///      is exactly that resolved balance whenever the marker branch is taken.
    ///    • BUY: `legsOut[0].start`. A BUY's outputs are always fixed.
    ///
    ///  It used to be `total` unconditionally (the F8 fix), which is right for an
    ///  ordinary order only because there `total == legsIn[0].start`. On an order
    ///  with a signed `fillTotal` ({FullFillModule}'s "typically 1", a TWAP in part
    ///  units, a bps denominator) `total` is a PROGRESS UNIT, not a token amount: the
    ///  fair amount collapsed to ~0 and every such SELL cleared at its floor, every
    ///  such BUY at its cap (audit 2026-09-30 PRICE-1 / X-ARITH-1).
    ///
    ///  ⚠ OTHER rising input legs (`legsIn[1..n]`, e.g. a relayer-fee leg in another
    ///  token) also move with the bump this module returns, so on a pegged SELL such a
    ///  fee grows with how far the oracle sits below the maker's ambition rather than
    ///  with time. The oracle cannot price a different token, so that coupling is the
    ///  maker's signed choice: sign the fee leg FIXED if it is not wanted.
    ///  Cross-reference: `docs/reference-audits.md` §C13, finding F8.
    function _band(uint256 total, bytes calldata legsIn, bytes calldata legsOut)
        private
        view
        returns (uint256 anchor, uint256 rise, uint256 start, uint256 end)
    {
        if (PackedArrays.validateFixed(legsIn, PackedArrays.LEG_IN_STRIDE) == 0) revert NoBand();
        if (PackedArrays.validateFixed(legsOut, PackedArrays.LEG_OUT_STRIDE) == 0) revert NoBand();
        if (PRICE_OUTPUT) {
            (, uint256 s0, uint256 e0) = PackedArrays.legIn(legsIn, 0);
            if (Proportional.isProportional(s0)) {
                // `e0` is the proportional CAP here, not a decay endpoint: the core
                // charges exactly the resolved amount (`total`), never `inTick`.
                anchor = total;
            } else {
                anchor = s0;
                if (e0 > s0) rise = e0 - s0;
            }
            (, start, end,) = PackedArrays.legOut(legsOut, 0);
        } else {
            (, anchor,,) = PackedArrays.legOut(legsOut, 0);
            (, start, end) = PackedArrays.legIn(legsIn, 0);
        }
    }
}
