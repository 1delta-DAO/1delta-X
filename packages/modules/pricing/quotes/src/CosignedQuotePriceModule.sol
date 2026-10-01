// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPriceModule} from "@core/interfaces/IPriceModule.sol";
import {SignatureVerification} from "@core/permit3/SignatureVerification.sol";

/// @title CosignedQuotePriceModule
/// @notice A COSIGNER may improve the maker's price at fill time, without the maker
///         re-signing anything — UniswapX's cosigner mechanism, minus the trusted
///         party. The filler carries a quote signed by the cosigner in the shared
///         `takerData`; this module verifies it and returns the quoted bump.
///
///  What the cosigner can and cannot do — the whole point:
///    • it can only return a BUMP, which the core clamps to [0, BPS] and maps
///      through the maker's own signed `start`/`end`. So the best a cosigner can do
///      is move the fill INSIDE the band the maker already signed, and the worst it
///      can do is the band's floor — which is what the maker was already willing to
///      accept. It cannot price outside, cannot redirect funds, cannot change legs.
///    • it is not privileged infrastructure: the address is an immutable of this
///      instance, and an order opts in by signing this module's address. Any maker
///      may deploy an instance naming any cosigner (including itself, or a Safe);
///      any filler may present a quote. Nobody is whitelisted.
///
///  The quote binds to the ORDER HASH, the order's FILL PROGRESS (`prevFilled`),
///  this MODULE, the CHAIN, and a DEADLINE, so a quote cannot be replayed onto
///  another order, another deployment, another chain, after it goes stale — or onto
///  a LATER fill of the same order. `filler == address(0)` in a quote means "any
///  filler"; naming a filler makes the quote exclusive to it.
///
///  ⚠ PROGRESS BINDING (audit 2026-09-30 PRICE-10, BREAKING typehash). The digest
///  used to cover only (orderHash, filler, bumpBps, deadline, chain, module), so one
///  quote repriced EVERY partial fill of the order until its deadline — a round-1
///  winner could wait for a TWAP part to open and fill it at the round-1
///  concession, or front-run a round-2 winner. A quote now names the `prevFilled`
///  it was minted for and is valid for exactly one fill: the one that starts at
///  that progress. Two things it still does NOT bind, deliberately:
///    • the fill SIZE — {IPriceModule} is not told it; a quote prices "the next
///      fill", and an auction that wants to bound it runs on a fill module or an
///      exclusive filler.
///    • the SETTLEMENT — the module is reached by a staticcall whose `msg.sender` is
///      the settler on a fill but the lens on a preview, so it cannot tell the two
///      apart, and `orderHash` is the domain-free STRUCT hash ({OrderHash.hash}).
///      Replaying a quote on a second settlement needs the MAKER's signature to be
///      valid there too (the order signature is domain-bound), and the concession
///      stays inside the band the maker signed.
///
///  ⚠ FALLBACK_BPS IS NOT MAKER PROTECTION — CHOOSE IT DELIBERATELY. With empty
///  `takerData` this returns `FALLBACK_BPS`, per {IPriceModule}. But `takerData` is
///  FILLER-CONTROLLED on the real fill path too, and a pinned module bump REPLACES
///  the time-decay clock — so a filler that simply omits the quote clears at
///  `FALLBACK_BPS` immediately, with no decay ramp. The cosigner can only ever LOWER
///  the filler's take (improve the maker's price) when something external COMPELS a
///  quote (an off-chain auction plus `exclusiveFiller`, or a validator that requires
///  one); it can never raise the maker's floor. So:
///    • `FALLBACK_BPS = BPS` — an unquoted fill clears at the band's `end` (the
///      maker's signed floor) instantly. Correct ONLY when `end` already is the price
///      the maker is happy to accept and the quote is a filler-competition lever.
///    • `FALLBACK_BPS = 0` — an unquoted fill clears at `start` (the maker's
///      ambition), so a filler MUST present a quote to unlock any improvement. This is
///      the adversarial-safe / UniswapX shape; prefer it unless you specifically want
///      the floor-is-the-price behaviour above.
///  Either way the maker's signed `start`/`end` band is the absolute bound.
contract CosignedQuotePriceModule is IPriceModule {
    uint256 internal constant BPS = 10_000;

    /// @notice The key whose quotes this instance accepts. May be an EOA or any
    ///         EIP-1271 contract (Safe, passkey wallet) — verification goes through
    ///         the same verifier the settlement uses for makers.
    address public immutable COSIGNER;
    /// @notice The bump used when no quote is presented (previews, and fills the
    ///         filler chose not to quote). `BPS` = the maker's signed floor.
    uint256 public immutable FALLBACK_BPS;

    /// @dev EIP-712-style domain-bound quote. Not a full EIP-712 domain: the module
    ///      address and chain id are hashed into the digest directly, which binds the
    ///      same three things (contract, chain, type) with less code.
    bytes32 private constant QUOTE_TYPEHASH =
        keccak256("PriceQuote(bytes32 orderHash,address filler,uint256 bumpBps,uint256 deadline,uint256 prevFilled)");

    error QuoteExpired();
    error MalformedQuote();
    error QuoteNotForFiller();
    error InvalidConfig();

    constructor(address cosigner, uint256 fallbackBps) {
        if (cosigner == address(0) || fallbackBps > BPS) revert InvalidConfig();
        COSIGNER = cosigner;
        FALLBACK_BPS = fallbackBps;
    }

    /// @notice The digest a cosigner signs for the fill that starts at `prevFilled`.
    ///         Exposed so off-chain quoting code cannot drift from the on-chain check.
    function quoteDigest(bytes32 orderHash, address filler, uint256 bumpBps, uint256 deadline, uint256 prevFilled)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(QUOTE_TYPEHASH, orderHash, filler, bumpBps, deadline, prevFilled, block.chainid, address(this))
        );
    }

    /// @notice {quoteDigest} for the FIRST fill of an order (`prevFilled == 0`).
    function quoteDigest(bytes32 orderHash, address filler, uint256 bumpBps, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        return quoteDigest(orderHash, filler, bumpBps, deadline, 0);
    }

    /// @inheritdoc IPriceModule
    function bump(
        bytes32 orderHash,
        address, /*maker*/
        address filler,
        uint256 prevFilled,
        uint256, /*total*/
        uint256, /*orderTiming*/
        bytes calldata, /*legsIn*/
        bytes calldata, /*legsOut*/
        bytes calldata takerData
    ) external view returns (uint256) {
        if (takerData.length == 0) return FALLBACK_BPS;
        // The quote work lives in its own frame: `bump`'s eight arguments already fill
        // the stack under legacy codegen, and the verification needs four more live
        // values.
        return _quote(orderHash, filler, prevFilled, takerData);
    }

    /// @dev Verify one cosigned quote and return its bump.
    ///
    ///      PACKED, not `abi.encode`d: the shared verifier takes `bytes calldata` (so
    ///      it can hand an EIP-1271 cosigner the exact bytes it was given), and an
    ///      `abi.decode` would land the signature in memory. A packed layout keeps the
    ///      signature a calldata slice and costs the filler fewer bytes:
    ///
    ///          takerData = filler(20) ‖ bumpBps(32) ‖ deadline(32) ‖ sig
    function _quote(bytes32 orderHash, address filler, uint256 prevFilled, bytes calldata takerData)
        private
        view
        returns (uint256)
    {
        if (takerData.length < 84) revert MalformedQuote();
        address quotedFiller = address(bytes20(takerData[:20]));
        uint256 bumpBps = uint256(bytes32(takerData[20:52]));
        if (block.timestamp > uint256(bytes32(takerData[52:84]))) revert QuoteExpired();
        // A quote may name a filler (exclusive) or address(0) (open). On a PREVIEW the
        // caller's filler is address(0); an exclusive quote then simply fails this
        // check, so previews should be run either unquoted or with the real filler.
        if (quotedFiller != address(0) && quotedFiller != filler) revert QuoteNotForFiller();
        // `prevFilled` is the core's, never the filler's: a quote minted for another
        // point of the order's progress simply does not verify (PRICE-10).
        SignatureVerification.verify(
            takerData[84:],
            quoteDigest(orderHash, quotedFiller, bumpBps, uint256(bytes32(takerData[52:84])), prevFilled),
            COSIGNER
        );
        // The core clamps, but clamping here too keeps the module's own return value
        // honest for anything reading it directly (a book, a simulation).
        return bumpBps > BPS ? BPS : bumpBps;
    }
}
