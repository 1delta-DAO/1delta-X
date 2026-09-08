// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";
import {IFundingSource} from "@core/interfaces/IFundingSource.sol";

import {IExactlyMarket} from "./interfaces/IExactly.sol";

// NOTE: this file is where {IExactlyMarket.repayAtMaturity}'s wrong two-word
// return declaration was caught (verified against the live market on the
// Optimism fork — the deployed Market.sol returns ONE word, `actualRepayAssets`).
// The declaration is fixed in {IExactly.sol} itself as of 2026-09-03; the local
// corrected interface that used to live here is gone with it.

// ──────────────── Exactly PRE-FUNDED one-sided modules ────────────────
//
// "Deposit whatever the conversion delivered" and "repay whatever the conversion
// delivered", with ZERO receive-side approvals: the maker signs the converted
// output leg with `recipient = module` and a `TAKE_FOR` item whose leg-reference
// descriptor points at it. The core sizes `forAmount` to exactly what the fill
// delivered here ({Base._forSlice} → {Pricing.outputAt}), auction decay included,
// and this module supplies/repays it from its own balance. The maker's only
// grants are the ones they had anyway: the ERC20+Permit3 approval on the asset
// they are CONVERTING FROM (the input leg), and the taker allowance below. The
// received asset needs nothing — it never transits the maker's wallet, and
// Exactly's `deposit` / `depositAtMaturity` / `repay` / `repayAtMaturity` are
// PERMISSIONLESS on someone else's behalf, so the receive side is empty end to
// end. (Cross-margin still needs the maker's own `Auditor.enterMarket` for the
// deposit to COUNT as collateral — a maker-side permission, not a module call.)
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
//  Fixed-maturity coverage mirrors the existing MAKE modules
//  ─────────────────────────────────────────────────────────
//  {ExactlyDepositModule} / {ExactlyRepayModule} cover both books behind a
//  `maturity` word (`0` ⇒ floating, else that fixed pool), so the pre-fund variants
//  do too, with the SAME data positions and the same bound semantics:
//    • deposit: `minAssetsRequired` is the maker-signed FLOOR on the fixed
//      position credited (`depositAtMaturity`'s own slippage guard); ignored on
//      floating, exactly as in the MAKE module. It is NOT scaled with the fill —
//      applied to a slice a floor is STRICTER than signed, i.e. fail-closed
//      (see the ⚠ note in {ProratedBound} for why floors stay unscaled).
//    • repay: the fixed leg keeps `repayAtMaturity`'s positionAssets/maxAssets
//      shape — `positionAssets` (the face to retire) rides in `data` where the
//      MAKE module's pro-rated `amount` carried it, and the delivered `forAmount`
//      takes the `maxAssets` role: the budget the market may consume. A slice
//      whose delivery cannot cover the signed face reverts inside Exactly
//      (`Disagreement`) — fail-closed, so the fixed repay is in practice a
//      full-fill leg, like every unscaled-bound fixed leg in this package.


/// @notice ONE contract for every pre-funded one-sided op on Exactly.
/// @dev    Replaces {ExactlyPreFundDepositModule}, {ExactlyPreFundRepayModule}. `Op` rides in
///         descriptor bits [244,252) — see {PreFundModuleBase._preFundOp} for why the
///         discriminator lives in the word the maker already signs rather than in a
///         new `data` field. Merging is safe because the op is INSIDE `data`, and `data` is
///         inside the maker's ORDER signature: an item signed for one op cannot be
///         executed as another. Each op keeps its own decode, so the
///         per-op `data` layouts are unchanged apart from the descriptor bits.
contract ExactlyPreFundModule is PreFundModuleBase, IMakerModule, IFundingSource {
    enum Op {
        Deposit,
        Repay
    }

    /// @dev The descriptor named an op this module does not implement.
    error BadOp(uint256 op);

    error FaceTotalMissing();

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
        if (op == uint256(Op.Deposit)) {
        _deposit(onBehalfOf, forAmount, data);
        } else if (op == uint256(Op.Repay)) {
        // Its own frame: the fork profile compiles without the optimizer, where the
        // five-field decode plus the repay-and-sweep logic overflows this stack.
        _repayAndSweep(onBehalfOf, forAmount, data);
        } else {
            revert BadOp(op);
        }
    }


    /// @dev Its own frame: the five-field decode plus the venue call is too much
    ///      for one stack on an optimizer-less profile.
    function _deposit(address onBehalfOf, uint256 forAmount, bytes calldata data) private {
        (, address market, address asset, uint256 maturity, uint256 minAssetsRequired) =
            abi.decode(data, (uint256, address, address, uint256, uint256));
        // Scoped approve + CLEAR: `market` is decoded from order data on a shared
        // singleton, so it is attacker-choosable (F25 / lead A-3).
        // The delivery must have landed HERE, in THIS token — the funding leg's
        // recipient is bound by the core (descriptor bit 253) and CONSUMED
        // ({Base.ForLegReused}), but its TOKEN is not (F27/H-1). Underflows if
        // it did not; sound because `msg.sender == settlement` pins `forAmount`.
        PreFundGuard.requireDelivered(data, asset, forAmount);
        SafeTransferLib.forceApprove(asset, market, forAmount);
        if (maturity == 0) {
            IExactlyMarket(market).deposit(forAmount, onBehalfOf);
        } else {
            IExactlyMarket(market).depositAtMaturity(maturity, forAmount, minAssetsRequired, onBehalfOf);
        }
        SafeTransferLib.forceApprove(asset, market, 0);
    }

    function _repayAndSweep(address onBehalfOf, uint256 forAmount, bytes calldata data) private {
        (, address market, address asset) = abi.decode(data, (uint256, address, address));
        // The pre-existing floor: this fill's delivery is already on the balance,
        // so `entry - forAmount` is what was here before. A funding leg not
        // addressed to THIS module in THIS token underflows here — the mis-pairing
        // fails closed. Sound because `msg.sender == settlement` pins `forAmount` to
        // the core; with a caller-chosen `forAmount` the same subtraction proves
        // nothing (F27/C-1, C-4).
        uint256 floor = PreFundGuard.floorOf(data, asset, forAmount);
        {
            // Tail decode (maturity@96, positionAssets@128) via a calldata slice —
            // the {AaveV3PreFundRepayModule} pattern — to keep this frame flat.
            (uint256 maturity, uint256 positionAssets) = abi.decode(data[96:], (uint256, uint256));
            if (maturity == 0) {
                _repayFloating(market, asset, onBehalfOf, forAmount);
            } else {
                // Scoped approve + CLEAR — `market` is maker-data-choosable on a
                // singleton. `forAmount` is the budget: the market pulls
                // `actualRepay ≤ forAmount` or reverts (`Disagreement`).
                SafeTransferLib.forceApprove(asset, market, forAmount);
                IExactlyMarket(market).repayAtMaturity(
                    maturity, _scaledFace(data, positionAssets, forAmount), forAmount, onBehalfOf
                );
                SafeTransferLib.forceApprove(asset, market, 0);
            }
        }
        // The delivered surplus belongs to the maker, not to this singleton. Sweep
        // exactly this fill's excess (`forAmount − spent`), never the whole
        // balance — a wei of another fill's dust may legitimately sit here.
        PreFundGuard.sweepSurplus(asset, onBehalfOf, floor);
    }

    /// @dev Scale the maker-signed FACE with this fill's slice (F27/H-3).
    ///
    ///      The pull sibling gets this for free: there the face IS the item's
    ///      pro-rated `amount`. The pre-fund shape has no such number — its `amount` is
    ///      vestigial and the delivery arrives as `forAmount` — so `positionAssets`
    ///      rode unscaled and EVERY slice presented the whole face. With a large
    ///      early-repay discount the full face's `actualRepayAssets` can fall under
    ///      a partial slice's budget, so the first slice retired 100% of the fixed
    ///      position and later slices re-presented it against an empty one.
    ///
    ///      FLOOR, deliberately: slices sum to at most the face, so the tail of a
    ///      rounding-down series leaves a wei unretired rather than over-retiring.
    ///      Reads the maker-signed total at calldata offset 160 — the funding
    ///      leg's FULL amount, the denominator `forAmount` is a slice of.
    ///      BREAKING: this word is new in the blob.
    function _scaledFace(bytes calldata data, uint256 face, uint256 forAmount) private pure returns (uint256) {
        if (data.length < 192) revert FaceTotalMissing();
        uint256 total = uint256(bytes32(data[160:192]));
        if (total == 0) revert FaceTotalMissing();
        if (forAmount >= total) return face;
        return face * forAmount / total;
    }

    /// @dev Cap at the LIVE floating debt, exactly as {ExactlyRepayModule} does.
    function _repayFloating(address market, address asset, address onBehalfOf, uint256 forAmount)
        private
        returns (uint256 spent)
    {
        uint256 debt = IExactlyMarket(market).previewDebt(onBehalfOf);
        uint256 toRepay = forAmount < debt ? forAmount : debt;
        if (toRepay != 0) {
            SafeTransferLib.forceApprove(asset, market, toRepay);
            (spent,) = IExactlyMarket(market).repay(toRepay, onBehalfOf);
            SafeTransferLib.forceApprove(asset, market, 0);
        }
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
        (,, asset) = abi.decode(data, (uint256, address, address));
        available = type(uint256).max;
    }
}
