// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPriceModule} from "../interfaces/IPriceModule.sol";
import {SignatureVerification} from "../permit3/SignatureVerification.sol";

/// @title ClockFlooredQuoteModule
/// @notice {CosignedQuotePriceModule} with the dutch clock as a FLOOR under the
///         cosigner: the returned bump is `min(quotedBump, clockBump)`, so a quote
///         can only ever IMPROVE on the time-decay baseline and never undercut it.
///
///  Why this exists — the failure mode it removes
///  ─────────────────────────────────────────────
///  In {CosignedQuotePriceModule} a pinned module bump REPLACES the clock. That is
///  the documented `FALLBACK_BPS` footgun: a filler that simply omits the quote
///  clears at the fallback immediately, with no decay ramp, and a cosigner that is
///  absent, buggy, compromised or colluding can hand a filler the maker's floor on
///  the first block of the auction.
///
///  Flooring by the clock makes every one of those degrade to PLAIN DUTCH instead:
///    • no quote presented        → the clock bump (an ordinary dutch fill)
///    • cosigner offline          → the clock bump
///    • cosigner hostile/colluding→ at worst the clock bump; it can only lower it
///    • honest competitive auction→ better than the clock, which is the point
///  The cosigner is reduced to a pure improvement channel. It cannot cost the maker
///  anything relative to signing no module at all, which is what makes it safe to
///  point at a cosigner the maker does not fully trust — an open sealed-bid auction
///  run by a third party, say.
///
///  Since lower bump = better for the maker (0 = `start`, BPS = `end`), "floor" here
///  means a CEILING on the bump. The naming follows the maker's price, not the bps.
///
///  ⚠ THE CLOCK THIS APPLIES IS A SINGLE LINEAR SEGMENT over the maker's signed
///  `decayStartTime`/`decayDuration`, read from `orderTiming` bits [0:32)/[32:64) on
///  the order's own clock (bit 102 = blocks, else seconds). A price module receives
///  the `timing` word but NOT `order.curve` or `order.params`, so a piecewise curve
///  and the basefee gas bump are invisible here.
///
///  That is not a divergence this module introduces: `order.curve` and
///  `order.gasBumpBps` are ALREADY inert on any order that sets `pricingModule`,
///  because {DutchAuction.resolveBump} hands such an order to the module and
///  {DutchAuction.bumpBps} is never reached. Signing a curve alongside ANY price
///  module is a no-op. Do not do it here either: the linear ramp below IS the
///  order's clock, and a signed curve would be silently ignored while looking like
///  it was doing something.
///
///  ⚠ AN ORDER WITH `decayDuration == 0` ADMITS NO CONCESSION AT ALL. No decay
///  window means a clock bump of 0, hence `min(quote, 0) == 0`, hence the maker's
///  `start` on every fill regardless of what the cosigner signs. That is the
///  correct reading of "the maker signed a fixed price", but it also means the
///  quote channel is dead. A maker that wants an auction must sign a window for it
///  to bid inside.
///
///  ⚠ THIS MODULE MONOPOLISES THE `takerData` CHANNEL. `takerData` is ONE shared
///  blob per fill, handed to the price module, the fill module and every validator
///  alike. A non-empty blob that does not parse as a quote is rejected here
///  ({MalformedQuote}), so an order pairing this module with any OTHER takerData
///  consumer — {FillerAttestationValidator} being the one in tree — cannot be
///  filled at all: whichever party's encoding is presented, the other rejects it.
///  Pair it only with maker-signed-`data` validators (the {ChainlinkPriceGte} /
///  {ChainlinkPriceLte} family, {MinBalanceInvariant}), which ignore takerData.
///  Nothing detects this combination for you — {SettlementLens.validateOrder}
///  cannot know which validators read the blob. This is inherited from
///  {CosignedQuotePriceModule}, not new here.
///
///  ⚠ NOT COMPOSABLE WITH {ChainlinkTickFloorValidator}, which hard-reverts
///  {UnsupportedPricingMode} on any order carrying a `pricingModule`. That is
///  deliberate on its side: a validator runs BEFORE `_openFill`, so it cannot see
///  the pinned bump and would otherwise pass at a price the fill does not clear at.
///  It fails closed, so the pairing is unfillable rather than unsound.
///
///  Everything else — the packed quote layout, the digest binding, the filler
///  binding, the EIP-1271 cosigner breadth — is {CosignedQuotePriceModule}
///  unchanged. The quote digest hashes `address(this)`, so a quote minted for that
///  module cannot be replayed against this one, or between instances.
contract ClockFlooredQuoteModule is IPriceModule {
    uint256 internal constant BPS = 10_000;

    /// @notice The key whose quotes this instance accepts. May be an EOA or any
    ///         EIP-1271 contract (Safe, passkey wallet) — verification goes through
    ///         the same verifier the settlement uses for makers.
    address public immutable COSIGNER;

    /// @dev Same shape and same type string as {CosignedQuotePriceModule}: off-chain
    ///      quoting code signs one `PriceQuote` type for both, and the module address
    ///      hashed into the digest is what keeps the two instances apart.
    bytes32 private constant QUOTE_TYPEHASH =
        keccak256("PriceQuote(bytes32 orderHash,address filler,uint256 bumpBps,uint256 deadline)");

    error QuoteExpired();
    error MalformedQuote();
    error QuoteNotForFiller();
    error InvalidConfig();

    constructor(address cosigner) {
        if (cosigner == address(0)) revert InvalidConfig();
        COSIGNER = cosigner;
    }

    /// @notice The digest a cosigner signs. Exposed so off-chain quoting code cannot
    ///         drift from the on-chain check.
    function quoteDigest(bytes32 orderHash, address filler, uint256 bumpBps, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(QUOTE_TYPEHASH, orderHash, filler, bumpBps, deadline, block.chainid, address(this))
        );
    }

    /// @notice The dutch ceiling this instance floors quotes with, for a given signed
    ///         `timing` word. Public so a book, a filler or a maker can compute the
    ///         same number this module will apply, without simulating a fill.
    /// @dev    Mirrors {DutchAuction.bumpBps}'s single-linear-segment branch, with one
    ///         deliberate difference: a not-yet-started auction returns 0 rather than
    ///         reverting {AuctionNotStarted}. {IPriceModule} forbids reverting on the
    ///         preview shape, and 0 is the maker's `start` — the correct price for an
    ///         auction that has not begun to decay. On the FILL path this cannot be
    ///         reached with `t < startT` anyway: {DutchAuction.resolveBump} applies the
    ///         same "not before" gate before it calls a module.
    function clockBump(uint256 orderTiming) public view returns (uint256) {
        uint256 dur = uint32(orderTiming >> 32);
        // No decay window ⇒ the maker signed a fixed price ⇒ no concession is
        // available to quote against. See the ⚠ note on the contract.
        if (dur == 0) return 0;
        uint256 startT = uint32(orderTiming);
        // The order's OWN clock: blocks under `timing` bit 102, else unix seconds.
        uint256 t = (orderTiming >> 102) & 1 == 1 ? block.number : block.timestamp;
        if (t <= startT) return 0;
        unchecked {
            uint256 elapsed = t - startT;
            return elapsed >= dur ? BPS : (BPS * elapsed) / dur;
        }
    }

    /// @inheritdoc IPriceModule
    function bump(
        bytes32 orderHash,
        address, /*maker*/
        address filler,
        uint256, /*prevFilled*/
        uint256, /*total*/
        uint256 orderTiming,
        bytes calldata, /*legsIn*/
        bytes calldata, /*legsOut*/
        bytes calldata takerData
    ) external view returns (uint256) {
        uint256 ceilingBps = clockBump(orderTiming);
        // No quote ⇒ an ordinary dutch fill. This is the whole difference from
        // {CosignedQuotePriceModule}, whose unquoted path returns a pinned
        // `FALLBACK_BPS` and throws the decay ramp away.
        if (takerData.length == 0) return ceilingBps;
        // A malformed or expired quote REVERTS even when the ceiling is already 0 and
        // the result could not change. The filler chose to present a quote; telling it
        // the quote is bad is worth more than the gas saved by short-circuiting.
        uint256 quoted = _quote(orderHash, filler, takerData);
        return quoted < ceilingBps ? quoted : ceilingBps;
    }

    /// @dev Verify one cosigned quote and return its bump. Byte-identical layout to
    ///      {CosignedQuotePriceModule._quote} — see there for why it is packed rather
    ///      than `abi.encode`d:
    ///
    ///          takerData = filler(20) ‖ bumpBps(32) ‖ deadline(32) ‖ sig
    function _quote(bytes32 orderHash, address filler, bytes calldata takerData) private view returns (uint256) {
        if (takerData.length < 84) revert MalformedQuote();
        address quotedFiller = address(bytes20(takerData[:20]));
        uint256 bumpBps = uint256(bytes32(takerData[20:52]));
        uint256 deadline = uint256(bytes32(takerData[52:84]));
        if (block.timestamp > deadline) revert QuoteExpired();
        // A quote may name a filler (exclusive) or address(0) (open). On a PREVIEW the
        // caller's filler is address(0); an exclusive quote then simply fails this
        // check, so previews should be run either unquoted or with the real filler.
        if (quotedFiller != address(0) && quotedFiller != filler) revert QuoteNotForFiller();
        SignatureVerification.verify(takerData[84:], quoteDigest(orderHash, quotedFiller, bumpBps, deadline), COSIGNER);
        // The `min` below already bounds this by the clock, and the core clamps again,
        // but clamping here keeps the module's own return honest for anything reading
        // it directly (a book, a simulation).
        return bumpBps > BPS ? BPS : bumpBps;
    }
}
