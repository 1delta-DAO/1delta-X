// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPriceModule} from "@core/interfaces/IPriceModule.sol";
import {PackedArrays} from "@core/settlement/PackedArrays.sol";
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
        if (feed == address(0) || den == 0 || minAnswer <= 0 || maxAnswer < minAnswer || spreadBps > BPS) {
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

        (uint256 anchor, uint256 start, uint256 end) = _band(total, legsIn, legsOut);
        uint256 fair = (anchor * uint256(answer) * NUM) / DEN;

        if (PRICE_OUTPUT) {
            // OUTPUT band FALLS: `start` (best for the maker, most received) ≥ `end`
            // (the floor). A fixed leg (`end == 0`) or a degenerate band (`start ==
            // end`) has no room — the tick is `start`, so return 0.
            if (end == 0 || start <= end) return 0;
            // The maker RECEIVES this leg: its spread lowers what it asks for.
            fair = (fair * (BPS - SPREAD_BPS)) / BPS;
            if (fair >= start) return 0; // oracle better than the maker's ambition
            if (fair <= end) return BPS; // oracle at or through the floor
            return ((start - fair) * BPS) / (start - end);
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

    /// @dev The anchor (the fixed side's leg 0) and the priced band (the auctioned
    ///      side's leg 0). Which is which is the instance's `PRICE_OUTPUT` setting,
    ///      cross-checked against the order's signed side in {bump}.
    /// @dev The band, plus the anchor the fair amount is priced against.
    ///
    ///  ⚠ THE ANCHOR IS `total`, NOT THE RAW LEG, AND THAT IS LOAD-BEARING. This used
    ///  to re-read `legsIn[0].start` / `legsOut[0].start` out of the packed blob. For
    ///  an ordinary order the two are the same number — but for a {Proportional}
    ///  order they are not, and the raw read was a live bug:
    ///
    ///    • `legsIn[0].start` on such an order is a MARKER (`type(uint256).max −
    ///      (BPS − bps)`, ≈1.15e77), not an amount. `anchor · answer` then overflows
    ///      for every feed answer ≥ 2, the `staticcall` panics, and
    ///      {DutchAuction.priceBump} — which has no fallback — reverts
    ///      `PriceModuleFailed`. So the order was signable, passed
    ///      `SettlementLens.validateOrder`, and could never be filled by anyone.
    ///    • The non-overflowing cases were worse than the revert: they priced the
    ///      SENTINEL rather than the maker's live balance, so the peg this module
    ///      exists to track was silently ignored.
    ///
    ///  The core already hands us the answer. `total` is the fill denominator
    ///  {OrderGates.fillDenominator} resolved BEFORE any funds moved — a proportional
    ///  marker already resolved against the maker's live balance and pinned in
    ///  `FillCtx.anchor`, so this module now prices against exactly the amount the
    ///  fill will actually charge. It is the same value the settler and the lens both
    ///  use, which is what makes preview and fill agree by construction rather than by
    ///  two implementations happening to match.
    ///
    ///  For a `fillTotal` order `total` is that signed denominator rather than the leg
    ///  amount — which is likewise the right anchor, since that IS the unit the fill is
    ///  denominated in.
    ///
    ///  The blob is still validated and still read for the BAND (`start`/`end`), which
    ///  is genuinely per-leg and has no equivalent in the call's scalars.
    ///  Cross-reference: `docs/reference-audits.md` §C13, finding F8.
    function _band(uint256 total, bytes calldata legsIn, bytes calldata legsOut)
        private
        view
        returns (uint256 anchor, uint256 start, uint256 end)
    {
        if (PackedArrays.validateFixed(legsIn, PackedArrays.LEG_IN_STRIDE) == 0) revert NoBand();
        if (PackedArrays.validateFixed(legsOut, PackedArrays.LEG_OUT_STRIDE) == 0) revert NoBand();
        anchor = total;
        if (PRICE_OUTPUT) {
            (, start, end,) = PackedArrays.legOut(legsOut, 0);
        } else {
            (, start, end) = PackedArrays.legIn(legsIn, 0);
        }
    }
}
