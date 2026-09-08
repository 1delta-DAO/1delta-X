// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";
import {IFundingSource} from "@core/interfaces/IFundingSource.sol";

import {IAaveV3Pool} from "./interfaces/IAaveV3.sol";

// ──────────────── Aave v3 PRE-FUNDED one-sided modules ────────────────
//
// "Deposit whatever the conversion delivered" and "repay whatever the conversion
// delivered", with ZERO receive-side approvals: the maker signs the converted
// output leg with `recipient = module` and a `TAKE_FOR` item whose leg-reference
// descriptor points at it. The core sizes `forAmount` to exactly what the fill
// delivered here ({Base._forSlice} → {Pricing.outputAt}), auction decay included,
// and this module supplies/repays it from its own balance. The maker's only
// grants are the ones they had anyway: the ERC20+Permit3 approval on the asset
// they are CONVERTING FROM (the input leg), and the taker allowance below. The
// received asset needs nothing — it never transits the maker's wallet.
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

/// @notice ONE contract for both pre-funded one-sided ops on Aave v3.
/// @dev    `Op` rides in descriptor bits [244,252) — see {PreFundModuleBase._preFundOp}
///         for why the discriminator lives in the word the maker already signs
///         rather than in a new `data` field. The two ops share their leading
///         fields, so only the repay tail differs:
///
///           Supply: `abi.encode(forDesc, pool, asset)`
///           Repay:  `abi.encode(forDesc, pool, asset, rateMode, debtToken)`
///
///         Merging is safe here because the taker grant is keyed on
///         `keccak256(data)` and the op is inside `data`: a grant signed for
///         Supply cannot be replayed as Repay.
contract AaveV3PreFundModule is PreFundModuleBase, IMakerModule, IFundingSource {
    enum Op {
        Supply,
        Repay
    }

    /// @dev The descriptor named an op this module does not implement.
    error BadOp(uint256 op);

    constructor(address _permit3, address _settlement) PreFundModuleBase(_permit3, _settlement) {}

    /// @param onBehalfOf the maker — whose position is supplied into or repaid.
    /// @param forAmount  this fill's delivered output leg, core-sized from the pre-fund
    ///                   descriptor ({Base._forSlice}); supplied from this module's
    ///                   own balance. It is the item's ONLY amount — `item.amount`
    ///                   is not read on this seam.
    /// @dev ON THE MAKE SEAM, not `TAKE_FOR`. This op moves nothing OUT of the
    ///      position, so the composite shape it used to wear cost it a take side
    ///      that did nothing: a taker allowance for a book that bounds withdrawals,
    ///      a Permit3 hop whose only job was to forward a `spender` word, and a
    ///      "pacing" `amount` distinct from the funded one — the very gap F27/C-2
    ///      strands a delivery through. Here Settlement calls this module DIRECTLY,
    ///      so the caller pin is `msg.sender`, asserted by the EVM rather than
    ///      compared out of a parameter; there is no permissionless entrypoint in
    ///      front of it, so F27/C-1's channel does not exist; and the funded amount
    ///      IS the item amount.
    function makeOnBehalf(address onBehalfOf, uint256 forAmount, bytes calldata data) external override {
        _gatePreFundMake(data);
        // A dust slice can floor the funding leg to zero; skip, as every composite
        // module does — it accumulates exactly across fills.
        if (forAmount == 0) return;
        uint256 op = _preFundOp(data);
        if (op == uint256(Op.Supply)) {
            _supply(onBehalfOf, forAmount, data);
        } else if (op == uint256(Op.Repay)) {
            // Its own frame: the fork profile compiles without the optimizer, where
            // the five-field decode plus the repay call overflows this stack.
            _repay(onBehalfOf, forAmount, data);
        } else {
            revert BadOp(op);
        }
    }

    function _supply(address onBehalfOf, uint256 forAmount, bytes calldata data) private {
        (, address pool, address asset) = abi.decode(data, (uint256, address, address));
        // The delivery must have landed HERE, in THIS token — the core binds the
        // funding leg's RECIPIENT (descriptor bit 253) and now CONSUMES it
        // ({Base.ForLegReused}), but never its TOKEN. Underflows if it did not;
        // sound because `msg.sender == settlement` pins `forAmount` to the core.
        // ⚠ THE FLOOR IS KEPT, NOT DISCARDED — this half used the weaker
        // `requireDelivered`, which proves the same thing and then throws the number
        // away. A venue that consumes LESS than instructed then left the remainder
        // resident on a SHARED SINGLETON, and residue on a pre-fund singleton is the
        // precondition the unbound-token drain monetised. Its `_repay` sibling has
        // always taken the floor and swept to it; supply now matches.
        uint256 floor = PreFundGuard.floorOf(data, asset, forAmount);
        // Scoped approve + CLEAR: `pool` is decoded from order data on a shared
        // singleton, so it is attacker-choosable (F25 / lead A-3).
        SafeTransferLib.forceApprove(asset, pool, forAmount);
        IAaveV3Pool(pool).supply(asset, forAmount, onBehalfOf, 0);
        SafeTransferLib.forceApprove(asset, pool, 0);
        // Anything the venue did not take belongs to the maker — MEASURED against the
        // pre-delivery floor, never sized from the pre-call clamp (F27/C-3, M-1).
        PreFundGuard.sweepSurplus(asset, onBehalfOf, floor);
    }

    /// @dev Over-delivery (the auction cleared above the live debt, or interest
    ///      accrued less than the maker padded for) is swept to the maker: the
    ///      surplus is THEIRS — the solver already paid it — and must not pool here.
    function _repay(address onBehalfOf, uint256 forAmount, bytes calldata data) private {
        (, address pool, address asset) = abi.decode(data, (uint256, address, address));
        // The pre-existing floor: this fill's delivery is already on the balance,
        // so `entry - forAmount` is what was here before. A funding leg not
        // addressed to THIS module in THIS token underflows here — the mis-pairing
        // fails closed. Sound because `msg.sender == settlement` pins `forAmount` to
        // the core; with a caller-chosen `forAmount` the same subtraction proves
        // nothing (F27/C-1, C-4).
        uint256 floor = PreFundGuard.floorOf(data, asset, forAmount);
        {
            // Tail decode (rateMode @96, debtToken @128) via a calldata slice, as
            // {AaveV3RepayModule._pullAndRepay} does, to keep this frame flat.
            (uint256 rateMode, address debtToken) = abi.decode(data[96:], (uint256, address));
            // Cap at the LIVE debt — Aave reverts on repaying more than is owed with
            // a specific amount, and the maker cannot know accrued interest at
            // signing.
            uint256 debt = IERC20(debtToken).balanceOf(onBehalfOf);
            uint256 toRepay = forAmount < debt ? forAmount : debt;
            if (toRepay != 0) {
                SafeTransferLib.forceApprove(asset, pool, toRepay);
                IAaveV3Pool(pool).repay(asset, toRepay, rateMode, onBehalfOf);
                SafeTransferLib.forceApprove(asset, pool, 0);
            }
        }
        // Everything above the floor is this fill's unconsumed remainder and belongs
        // to the maker — MEASURED, never sized from the pre-call clamp (F27/C-3, M-1).
        PreFundGuard.sweepSurplus(asset, onBehalfOf, floor);
    }

    /// @inheritdoc IFundingSource
    /// @dev Funded by the fill's OWN delivery — a wallet/allowance read would
    ///      preview a self-funding order as short. Same slot for both ops.
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
