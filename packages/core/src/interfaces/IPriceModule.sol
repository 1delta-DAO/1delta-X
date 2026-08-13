// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IPriceModule
/// @notice An EXTERNAL price provider for one order — the generalization of the
///         built-in decay clock. An order that sets `Order.pricingModule` delegates
///         "where between my signed endpoints does this fill price?" to a module,
///         which is what makes oracle-pegged, fill-progress (range) and
///         cosigner-quoted orders expressible without a new order field per idea.
///
///  Wiring. `Order.pricingModule` is a plain signed address; `address(0)` means no
///  module and the built-in clock prices the order (the default, which costs an
///  order nothing). There is deliberately NO per-order config blob — a seventh
///  dynamic `Order` member measured ~1,000 bytes of Settlement against a budget of
///  a few hundred. A module instead carries its configuration in its own
///  IMMUTABLES: deploy one instance per configuration, identical configs land on
///  the same CREATE2 address and are shared by every maker who wants them, and the
///  maker's signature over `pricingModule` IS the commitment to that configuration.
///  Everything order-specific — the band, the progress, the maker, the taker blob —
///  arrives as arguments.
///
///  ⚠ WHY THIS RETURNS A BUMP AND NOT AN AMOUNT — the whole security argument.
///  1inch's `IAmountGetter` returns the making/taking AMOUNT, so the getter *is*
///  the price and is trusted absolutely. This returns the shared decay bump, which
///  the core CLAMPS to [0, 10000] and then maps through each leg's own signed
///  `start`/`end` in {DutchAuction.outTick}/{inTick}. A hostile, buggy or simply
///  stale module can therefore move the price anywhere INSIDE the band the maker
///  signed and NOWHERE OUTSIDE IT. The maker's floor/ceiling remains exactly the
///  absolute bound it is for a plain dutch order.
///
///  ⚠ THE ARGUMENTS ARE THE LEGS AND THE `timing` WORD, NOT THE WHOLE ORDER, AND
///  THAT IS A SIZE DECISION. Passing `Order calldata` measured ~1,300 bytes of
///  Settlement (2026-08-12): the price call's argument tuple differs from the
///  validator's, so it needs its own full-order ABI encoder. The packed leg blobs
///  plus the scalars below carry everything a price module has been shown to need,
///  and they encode cheaply. `orderTiming` is the maker-signed `timing` word — its
///  bit 101 is the order SIDE ({DutchAuction.side}), which a side-oriented module
///  (e.g. {ChainlinkPeggedPriceModule}) reads to reject a config/side mismatch, and
///  bits [0:96) carry the clocks a future hybrid clock+oracle module would want.
///  Decode the blobs with {PackedArrays} — the same readers the settler uses.
///
///  Trust model: `pricingModule` is consensus-critical and maker-signed, exactly
///  like a validator or a fill module. It MUST be `view`. `takerData` is the
///  shared, UNSIGNED, adversarial filler blob — a module that reads it (a cosigned
///  quote, say) MUST verify it against `orderHash` and against a signer the module
///  itself is configured with.
///
///  ⚠ FILL PROGRESS: READ THE `prevFilled` ARGUMENT, NEVER `SETTLEMENT.filled()`.
///  The settler writes `filled[orderHash]` for this fill BEFORE it calls the module,
///  while the lens's preview passes the PRE-fill value. A module that reads the live
///  storage slot would therefore quote one progress in {SettlementLens.previewBump}
///  and price another during the fill — desynchronising the `minBumpBps` floor. The
///  `prevFilled`/`total` arguments are the same on both paths; use them.
///
///  Called ONCE per fill by {OrderState._openFill}, which pins the result in
///  {FillCtx.bump} for every leg of that fill — so a multi-leg order pays one
///  STATICCALL, not one per decaying leg.
///
///  ⚠ PREVIEW CALLS. {SettlementLens} resolves the module with whatever the caller
///  supplied, and a book quoting an order generally has no filler and no taker
///  blob: expect `filler == address(0)` and empty `takerData`. A module MUST NOT
///  revert on that shape — return the best quote it can (e.g. the pure-oracle tick,
///  ignoring a quote it would otherwise have required), or a book will drop the
///  order as unpriceable.
interface IPriceModule {
    /// @param orderHash  the EIP-712 order hash — what a cosigned quote must bind to
    /// @param maker      the order's maker
    /// @param filler     who is filling; `address(0)` on a preview — see above
    /// @param prevFilled cumulative filled before this fill, in denominator units
    /// @param total      the fill denominator (the progress axis is `prevFilled/total`)
    /// @param orderTiming the maker-signed `timing` word — side in bit 101, clocks in
    ///                   bits [0:96); see {DutchAuction} accessors
    /// @param legsIn     the packed {LegIn} blob — the maker's input band
    /// @param legsOut    the packed {LegOut} blob — the maker's output band
    /// @param takerData  the shared filler-supplied blob (adversarial; may be empty)
    /// @return bps       the shared decay bump; 0 = the `start` price (best for the
    ///                   maker), 10000 = the `end` price. The core clamps.
    function bump(
        bytes32 orderHash,
        address maker,
        address filler,
        uint256 prevFilled,
        uint256 total,
        uint256 orderTiming,
        bytes calldata legsIn,
        bytes calldata legsOut,
        bytes calldata takerData
    ) external view returns (uint256 bps);
}
