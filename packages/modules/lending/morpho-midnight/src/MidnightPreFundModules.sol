// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";
import {IFundingSource} from "@core/interfaces/IFundingSource.sol";

import {IMidnight, Market, MidnightIdLib} from "./interfaces/IMidnight.sol";

// ──────────────── Morpho Midnight PRE-FUNDED one-sided modules ────────────────
//
// "Supply whatever the conversion delivered as collateral" and "repay whatever
// the conversion delivered", with ZERO receive-side approvals: the maker signs
// the converted output leg with `recipient = module` and a `TAKE_FOR` item whose
// leg-reference descriptor points at it. The core sizes `forAmount` to exactly
// what the fill delivered here ({Base._forSlice} → {Pricing.outputAt}), auction
// decay included, and this module supplies/repays it from its own balance. The
// maker's only grants are the ones they had anyway: the ERC20+Permit3 approval
// on the asset they are CONVERTING FROM (the input leg), and the taker allowance
// below. The received asset needs nothing — it never transits the maker's
// wallet, and Midnight's `supplyCollateral` / `repay` are PERMISSIONLESS on
// someone else's behalf (benign inflows, no `setIsAuthorized`), so the receive
// side is empty end to end.
//
//  WHICH Midnight ops fit the pre-fund shape — and which don't
//  ───────────────────────────────────────────────────────
//  Midnight is an order-book venue, so its three value-in ops split:
//    • `supplyCollateral` and `repay` consume EXACTLY the amount the caller
//      instructs, pulled from `msg.sender` (callback forced to 0), crediting
//      `onBehalf` — the same contract shape as Aave's `supply`/`repay`, so the
//      pre-fund seam fits verbatim. These two are implemented below.
//    • The LEND leg (`take` on an `offer.buy == false` offer) does NOT fit and
//      is deliberately absent: `take` consumes `buyerAssets` — a figure fixed by
//      the signed offer's `units` and tick economics, NOT sized by the delivery
//      — so "fund the op with whatever was delivered" cannot hold; the leg is
//      full-fill-only (its `units` cannot pro-rate, {MidnightLendModule}'s
//      guard) which forfeits the pacing the descriptor exists to provide; and
//      it needs the maker's `setIsAuthorized` anyway, so the zero-grant receive
//      side — the shape's other half — is unreachable. Lend stays a pull-funded
//      MAKE ({MidnightLendModule}).
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
//  module has no delivery for (its balance fails closed, but the revert is
//  clearer here), and a BALANCE descriptor reads the MAKER's wallet while this
//  module funds from its own — a mis-pairing by construction. Both are rejected
//  up front.
//
//  As everywhere in this package, the Midnight singleton is an IMMUTABLE fixed at
//  deploy (the `Market` tuple's own `midnight` field is not dispatched on) and
//  approvals are still SCOPED + cleared around each venue call — see the D-1
//  resolution note in {MidnightSupplyCollateralModule} for why the scoping is
//  kept even against an immutable venue.


/// @notice ONE contract for every pre-funded one-sided op on Morpho Midnight.
/// @dev    Replaces {MidnightPreFundSupplyCollateralModule}, {MidnightPreFundRepayModule}. `Op` rides in
///         descriptor bits [244,252) — see {PreFundModuleBase._preFundOp} for why the
///         discriminator lives in the word the maker already signs rather than in a
///         new `data` field. Merging is safe because the op is INSIDE `data`, and `data` is
///         inside the maker's ORDER signature: an item signed for one op cannot be
///         executed as another. Each op keeps its own decode, so the
///         per-op `data` layouts are unchanged apart from the descriptor bits.
contract MidnightPreFundModule is PreFundModuleBase, IMakerModule, IFundingSource {
    enum Op {
        SupplyCollateral,
        Repay
    }


    /// @dev The venue, pinned at construction rather than read from order data.
    IMidnight public immutable midnight;

    /// @dev The descriptor named an op this module does not implement.
    error BadOp(uint256 op);


    constructor(address _permit3, address _settlement, address _midnight)
        PreFundModuleBase(_permit3, _settlement)
    {
        midnight = IMidnight(_midnight);
    }

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
        } else if (op == uint256(Op.Repay)) {
        // Its own frame — see the supply sibling.
        _repayAndSweep(onBehalfOf, forAmount, data);
        } else {
            revert BadOp(op);
        }
    }


    /// @dev Its own frame: the dynamic `Market` decode plus the venue call is too
    ///      much for one optimizer-less stack (the fork-profile convention every
    ///      pre-fund sibling follows).
    function _supplyCollateral(address onBehalfOf, uint256 forAmount, bytes calldata data) private {
        (, Market memory market, uint256 collateralIndex) = abi.decode(data, (uint256, Market, uint256));
        address collateralToken = market.collateralParams[collateralIndex].token;
        // Scoped approve + CLEAR — kept even against the immutable venue (D-1).
        // The delivery must have landed HERE, in THIS token — the funding leg's
        // recipient is bound by the core (descriptor bit 253) and CONSUMED
        // ({Base.ForLegReused}), but its TOKEN is not (F27/H-1). Underflows if
        // it did not; sound because `msg.sender == settlement` pins `forAmount`.
        PreFundGuard.requireDelivered(data, collateralToken, forAmount);
        SafeTransferLib.forceApprove(collateralToken, address(midnight), forAmount);
        midnight.supplyCollateral(market, collateralIndex, forAmount, onBehalfOf);
        SafeTransferLib.forceApprove(collateralToken, address(midnight), 0);
    }

    function _repayAndSweep(address onBehalfOf, uint256 forAmount, bytes calldata data) private {
        (, Market memory market) = abi.decode(data, (uint256, Market));
        // The pre-existing floor — see {PreFundGuard}. A funding leg not addressed to
        // THIS module in THIS token underflows here, so the mis-pairing fails
        // closed; sound because `msg.sender == settlement` pins `forAmount` to the
        // core (F27/C-1, C-4).
        uint256 floor = PreFundGuard.floorOf(data, market.loanToken, forAmount);
        // Cap at the LIVE debt — Midnight reverts on over-repay, and the maker
        // cannot know the exact figure at signing.
        //
        // ⚠ UNITS vs LOAN TOKENS (F27, Midnight lead). `debt` is denominated in
        // DEBT UNITS and `forAmount` in loan tokens, so the `min` below compares
        // two dimensions and `toRepay` then serves as both an approval (tokens)
        // and a repay argument (units). That rests on "1 unit == 1 loan token at
        // repayment", which this repo asserts in a comment and confirms with no
        // on-chain read — Midnight is a ZERO-COUPON, fixed-maturity book, and a
        // zero-coupon instrument repaid before maturity normally settles BELOW
        // face. There is no deployed Midnight to fork against, so the equality
        // stays unverified.
        //
        // What that costs is now bounded, which is why this is a note and not a
        // finding. The sweep below returns everything above the floor rather than
        // `forAmount - toRepay`, so a discount that makes the pull smaller than
        // `toRepay` is swept back to the maker instead of stranding on the
        // singleton (that subtraction — loan tokens minus units — WAS the leak).
        // If a unit ever costs MORE than a token the scoped approval is short and
        // the venue reverts. Both directions fail safe; only the cap is imprecise.
        uint256 debtUnits = midnight.debt(MidnightIdLib.toId(market), onBehalfOf);
        uint256 toRepay = forAmount < debtUnits ? forAmount : debtUnits;
        if (toRepay != 0) {
            // Scoped approve + CLEAR — kept even against the immutable venue (D-1).
            SafeTransferLib.forceApprove(market.loanToken, address(midnight), toRepay);
            // callback = 0 ⇒ Midnight pulls the loan token from this module.
            midnight.repay(market, toRepay, onBehalfOf, address(0), "");
            SafeTransferLib.forceApprove(market.loanToken, address(midnight), 0);
        }
        // The delivered surplus belongs to the maker, not to this singleton.
        PreFundGuard.sweepSurplus(market.loanToken, onBehalfOf, floor);
    }


    /// @inheritdoc IFundingSource
    /// @dev Funded by the fill's OWN delivery — a wallet/allowance read would
    ///      preview a self-funding order as short.
    function fundingSource(address, bytes calldata data)
        external
        pure
        override
        returns (address asset, uint256 available)
    {
        // PER-OP, because the two layouts differ: SupplyCollateral carries a
        // trailing `collateralIndex` that Repay does not, so a single decode
        // reads out of bounds on one of them.
        if (_preFundOp(data) == uint256(Op.Repay)) {
            (, Market memory market) = abi.decode(data, (uint256, Market));
            asset = market.loanToken;
        } else {
            (, Market memory market, uint256 collateralIndex) = abi.decode(data, (uint256, Market, uint256));
            asset = market.collateralParams[collateralIndex].token;
        }
        available = type(uint256).max;
    }
}
