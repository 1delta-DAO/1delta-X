// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;


import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";
import {IFundingSource} from "@core/interfaces/IFundingSource.sol";

import {IMoolah, IListaNativeProvider, IListaSmartProvider, MarketParams} from "./interfaces/ILista.sol";
import {IWETH} from "./ListaNativeModules.sol";

// ──────────────── Lista Moolah PRE-FUNDED one-sided module ────────────────
//
// "Supply-collateral whatever the conversion delivered", with ZERO receive-side
// approvals: the maker signs the converted output leg with `recipient = module`
// and a pre-funded `MAKE` item whose leg-reference descriptor points at it. The core
// sizes `forAmount` to exactly what the fill delivered here ({Base._forSlice} →
// {Pricing.outputAt}), auction decay included, and this module supplies it from
// its own balance. The maker's only grants are the ones they had anyway: the
// ERC20+Permit3 approval on the asset they are CONVERTING FROM (the input leg),
// and NO taker allowance (Settlement dispatches the `MAKE` directly). The received asset needs nothing — it never
// transits the maker's wallet, and Moolah's `supplyCollateral(…, onBehalf, …)`
// is Morpho-shaped and PERMISSIONLESS on someone else's behalf, so unlike the
// withdraw taker leg this needs no Moolah `setAuthorization` either: the
// receive side is empty end to end.
//
// ⚠ The pre-funded broker REPAY used to live here as op 1. It moved to
// {ListaBrokerModule}, which now carries both of its funding shapes behind one
// body — the duplication between this file and the pull-funded twin is what let
// the `repayAll` sentinel land on one and not the other.
//
//  ⚠ Provider-gated markets. Lista's Moolah diverges from Morpho Blue with a
//  per-market `providers[id][token]` gate: when a provider is registered for a
//  market's COLLATERAL token, `supplyCollateral` requires `msg.sender ==
//  provider` and reverts `"not provider"` for any module — the same structural
//  exclusion the pull-funded {ListaSupplyCollateralModule} documents. Off-chain
//  order construction must check `providers[id][collateralToken] == 0` before
//  offering the pre-funded supply-collateral leg on a Lista market.
//
//  Why these ride the MAKE seam
//  ────────────────────────────
//  These ops move NOTHING out of the position — they supply or retire whatever the
//  conversion delivered — so they ARE `MAKE` items, and until 2026-09 they could
//  not say so. A `MAKE` amount was a maker-signed total, pro-rated blind: it could
//  not track an auctioned delivery, and a module funding from its own balance
//  against a number the core did not size to an ENFORCED delivery lets one order's
//  item consume another order's delivery. The pre-fund leg-reference descriptor is now
//  that channel on BOTH seams — {Base._runItem} sizes a pre-funded `MAKE` through
//  {Base._forSlice}, exactly as it sizes a `TAKE_FOR`'s funding side — so the
//  composite costume these wore is gone.
//
//  What the move buys, beyond the honesty
//  ──────────────────────────────────────
//  Settlement dispatches `MAKE` DIRECTLY; `TAKE_FOR` goes through Permit3. So the
//  caller pin is `msg.sender`, asserted by the EVM, rather than a forwarded
//  `spender` word every module had to remember to compare — F27/C-1's channel does
//  not exist on this seam at all, because there is no permissionless entrypoint in
//  front of it. No taker allowance is granted or spent for a book whose purpose is
//  bounding what LEAVES a position. And `item.amount` stops being a "pacing figure"
//  distinct from the funded one: it is UNREAD here, so F27/C-2's two-denominator
//  strand cannot be expressed. Measured on Aave v3, the same swap-and-deposit fill:
//  860,684 → 820,877 gas.
//
//  LEG-REFERENCE ONLY, enforced. A LITERAL descriptor would instruct amounts this
//  module has no delivery for, and a BALANCE descriptor reads the MAKER's wallet
//  while this module funds from its own — a mis-pairing by construction. Both are
//  rejected up front.
//
// `data = abi.encode(forDesc, moolah, MarketParams)` — descriptor word FIRST
// (forDesc@0), the Moolah singleton @32, `MarketParams` (5 static words) @64;
// 224 bytes total — the same byte map as the Morpho Blue pre-fund siblings.
//
//  The two PROVIDER-market sinks (review 2026-10-18 M-5)
//  ─────────────────────────────────────────────────────
//  Moolah rejects any non-provider caller on a provider-gated market, so the
//  native (WBNB) and SmartLP markets have their own pull MAKEs
//  ({ListaNativeSupplyCollateralModule}, {ListaSmartSupplyCollateralModule}) — and
//  until now ONLY pull MAKEs: a zero-capital "sell X, supply as collateral" order on
//  those markets needed the maker to approve the module for a token they never held.
//  Both providers' supply is permissionless on behalf (no Moolah grant), exactly
//  like the direct op above, so they join THIS contract as ops 1 and 2: same
//  standing grant (none), same address.
//
//    Op.NativeSupplyCollateral (1):
//      `data = abi.encode(forDesc, provider, MarketParams)` — the op-0 byte map with
//      the native provider in the venue word (224 bytes). The funding leg is the
//      wrapped native, which IS `mp.collateralToken`; the module unwraps EXACTLY
//      `forAmount` and supplies the measured native through the provider's payable
//      3-arg `supplyCollateral`. Never a balance sweep: two makers' deliveries can
//      sit here at once on the netted path ({NativeUnwrapModule}'s rule). And no
//      leg-vs-item rounding gap: the size is the delivery ledger's, not a
//      pro-rated `item.amount`.
//    Op.SmartSupplyCollateral (2):
//      `data = abi.encode(forDesc, provider, coin, coinIndex, minLpRateE18,
//      MarketParams)` — forDesc@0, provider@32, coin@64, coinIndex@96,
//      minLpRate@128, MarketParams@160; 320 bytes. The pull sibling's byte map
//      behind the descriptor word; the LP floor stays RATE-scaled
//      (`forAmount · minLpRateE18 / 1e18`), which is what lets it follow an
//      auctioned delivery. `coin` must be `dex.coins(coinIndex)`; a mismatch fails
//      closed at the provider (it pulls the REAL coin, which was never approved).


/// @notice The pre-funded supply-collateral ops: Moolah direct, the native provider,
///         and the SmartLP provider — every Lista value-in sink that needs no grant.
/// @dev    Replaces {ListaPreFundSupplyCollateralModule}. `Op` rides in descriptor
///         bits [244,252) — see {PreFundModuleBase._preFundOp} for why the
///         discriminator lives in the word the maker already signs rather than in a
///         new `data` field: it is INSIDE `data`, and `data` is inside the maker's
///         ORDER signature, so an item signed for one op cannot be executed as
///         another. {ListaBrokerModule} numbers its own ops independently — the two
///         contracts are different addresses, so their op spaces never meet.
contract ListaPreFundModule is PreFundModuleBase, IMakerModule, IFundingSource {
    /// @dev Three ops, each with its own byte map (see the header). Ops 1 and 2 were
    ///      added 2026-10-18 at fresh values, so every op-0 blob signed before then
    ///      is byte-for-byte unchanged; any other value reverts {BadOp}.
    enum Op {
        SupplyCollateral, // 0 — Moolah direct (or ERC20-forwarding provider)
        NativeSupplyCollateral, // 1 — native provider, payable; WBNB leg unwrapped here
        SmartSupplyCollateral // 2 — SmartLP provider, one-coin zap
    }

    /// @dev The op-2 blob, decoded as one struct (all-static, so byte-identical to
    ///      the flat tuple) to keep the frame small on optimizer-less profiles.
    struct SmartData {
        uint256 forDesc;
        address provider;
        address coin;
        uint256 coinIndex;
        uint256 minLpRate;
        MarketParams mp;
    }

    /// @dev The descriptor named an op this module does not implement.
    error BadOp(uint256 op);


    constructor(address _permit3, address _settlement) PreFundModuleBase(_permit3, _settlement) {}

    /// @param onBehalfOf the maker — whose position this fill acts on.
    /// @param forAmount  this fill's delivered output leg, core-sized; supplied
    ///                   from this module's own balance.
    function makeOnBehalf(address onBehalfOf, uint256 forAmount, bytes calldata data) external override {
        _gatePreFundMake(data);
        // A dust slice can floor the funding leg to zero; skip, as every composite
        // module does — it accumulates exactly across fills.
        if (forAmount == 0) return;
        uint256 op = _preFundOp(data);
        if (op == uint256(Op.SupplyCollateral)) {
            _supplyCollateral(onBehalfOf, forAmount, data);
        } else if (op == uint256(Op.NativeSupplyCollateral)) {
            _nativeSupplyCollateral(onBehalfOf, forAmount, data);
        } else if (op == uint256(Op.SmartSupplyCollateral)) {
            _smartSupplyCollateral(onBehalfOf, forAmount, data);
        } else {
            revert BadOp(op);
        }
    }


    /// @dev Its own frame: the fork profiles elsewhere compile without the
    ///      optimizer, where the struct decode plus the venue call is too much
    ///      for one stack.
    function _supplyCollateral(address onBehalfOf, uint256 forAmount, bytes calldata data) private {
        (, address moolah, MarketParams memory mp) = abi.decode(data, (uint256, address, MarketParams));
        // Scoped approve + CLEAR: `moolah` is decoded from order data on a shared
        // singleton, so it is attacker-choosable (F25 / lead A-3).
        // The delivery must have landed HERE, in THIS token — the funding leg's
        // recipient is bound by the core (descriptor bit 253) and CONSUMED
        // ({Base.ForLegInvalid}), but its TOKEN is not (F27/H-1). Underflows if
        // it did not; sound because `msg.sender == settlement` pins `forAmount`.
        // KEEP THE FLOOR, DO NOT DISCARD IT. `requireDelivered` proves the same delivery
        // and throws the number away; a venue that consumes LESS than instructed then
        // leaves the remainder resident on a SHARED SINGLETON — the residue that every
        // pre-fund drain so far has monetised. Measured against the pre-delivery floor,
        // never sized from the venue's return value (F27/C-3). Aligned with the aave-v3
        // sibling and every `_repay` half (F28, 2026-09-12).
        uint256 floor = PreFundGuard.floorOf(data, mp.collateralToken, forAmount);
        SafeTransferLib.forceApprove(mp.collateralToken, moolah, forAmount);
        IMoolah(moolah).supplyCollateral(mp, forAmount, onBehalfOf, "");
        SafeTransferLib.forceApprove(mp.collateralToken, moolah, 0);
        PreFundGuard.sweepSurplus(mp.collateralToken, onBehalfOf, floor);
    }

    /// @dev Op 1: unwrap EXACTLY the delivered wrapped native and supply the measured
    ///      native through the provider's payable entrypoint.
    function _nativeSupplyCollateral(address onBehalfOf, uint256 forAmount, bytes calldata data) private {
        (, address provider, MarketParams memory mp) = abi.decode(data, (uint256, address, MarketParams));
        // The market's collateral token IS the wrapped native. The descriptor's
        // token must equal it ({PreFundGuard.floorOf}), and the core already bound
        // the descriptor to the delivered leg — so this unwraps the token that was
        // delivered here, no other.
        address wnative = mp.collateralToken;
        uint256 floor = PreFundGuard.floorOf(data, wnative, forAmount);
        uint256 ethFloor = address(this).balance;
        IWETH(wnative).withdraw(forAmount);
        // SPEND THE MEASURED DELTA, NOT `forAmount` — `wnative` is maker-named on a
        // shared singleton, and a fake wrapper's no-op `withdraw` must not let the
        // payable call below draw on native this module already held (the
        // {ListaNativeSupplyCollateralModule} rule).
        uint256 received = address(this).balance - ethFloor;
        IListaNativeProvider(provider).supplyCollateral{value: received}(mp, onBehalfOf, "");
        // Native left above the pre-call floor (none on an honest provider) wraps
        // back to the maker, as does any undelivered wrapped native above `floor`.
        uint256 bal = address(this).balance;
        if (bal > ethFloor) {
            IWETH(wnative).deposit{value: bal - ethFloor}();
        }
        PreFundGuard.sweepSurplus(wnative, onBehalfOf, floor);
    }

    /// @dev Op 2: zap the delivered pool coin into the SmartLP collateral.
    function _smartSupplyCollateral(address onBehalfOf, uint256 forAmount, bytes calldata data) private {
        SmartData memory p = abi.decode(data, (SmartData));
        uint256 floor = PreFundGuard.floorOf(data, p.coin, forAmount);
        // Scoped approve + CLEAR: `provider` is decoded from order data on a shared
        // singleton (F26/2c).
        SafeTransferLib.forceApprove(p.coin, p.provider, forAmount);
        // Checked math: an overflowing maker-signed rate reverts the fill.
        IListaSmartProvider(p.provider).supplyCollateral(
            p.mp,
            onBehalfOf,
            p.coinIndex == 0 ? forAmount : 0,
            p.coinIndex == 1 ? forAmount : 0,
            forAmount * p.minLpRate / 1e18
        );
        SafeTransferLib.forceApprove(p.coin, p.provider, 0);
        PreFundGuard.sweepSurplus(p.coin, onBehalfOf, floor);
    }

    /// @inheritdoc IFundingSource
    /// @dev Funded by the fill's OWN delivery — a wallet/allowance read would
    ///      preview a self-funding order as short. PER OP: ops 0 and 1 share the
    ///      `(forDesc, venue, MarketParams)` byte map; op 2 carries the coin.
    function fundingSource(address, bytes calldata data)
        external
        pure
        override
        returns (address asset, uint256 available)
    {
        if (_preFundOp(data) == uint256(Op.SmartSupplyCollateral)) {
            (,, asset) = abi.decode(data, (uint256, address, address));
        } else {
            (,, MarketParams memory mp) = abi.decode(data, (uint256, address, MarketParams));
            asset = mp.collateralToken;
        }
        available = type(uint256).max;
    }

    receive() external payable {} // native from IWETH.withdraw — must stay empty (WBNB pays via `transfer`)
}
