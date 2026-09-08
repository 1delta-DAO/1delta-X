// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";
import {IFundingSource} from "@core/interfaces/IFundingSource.sol";

import {IRiverXApp, IRiverTroveManager} from "./interfaces/IRiver.sol";

// ──────────────── River (Satoshi Protocol) PRE-FUNDED one-sided modules ────────────────
//
// "Add-collateral whatever the conversion delivered" and "repay whatever the
// conversion delivered", with ZERO receive-side TOKEN approvals: the maker signs
// the converted output leg with `recipient = module` and a `TAKE_FOR` item whose
// leg-reference descriptor points at it. The core sizes `forAmount` to exactly
// what the fill delivered here ({Base._forSlice} → {Pricing.outputAt}), auction
// decay included, and this module adds/repays it from its own balance. The
// maker's only token grants are the ones they had anyway: the ERC20+Permit3
// approval on the asset they are CONVERTING FROM (the input leg), and the taker
// allowance. The received asset — the collateral on an add, satUSD on a repay —
// is never approved to anything and never transits the maker's wallet.
//
//  ⚠ VENUE AUTHORIZATION KEPT — NOT a token approval. The deployed SatoshiXApp
//  diamond enforces its caller-or-delegate check on EVERY op, value-IN included
//  (✅ fork-validated in {RiverModules}: `addColl` by a non-delegate reverts
//  "Caller not approved"), so the maker still grants the diamond-wide
//  `setDelegateApproval(module, true)` — exactly the grant the pull-funded
//  {RiverAddCollModule}/{RiverRepayModule} rely on. What this variant removes is
//  the maker's Permit3 TOKEN allowance to the module and the on-chain ERC20
//  approval of the DELIVERED asset — the token side of the receive leg is empty
//  end to end.
//
//  The output-side routing quirk the package README documents (value-out landing
//  on `msg.sender` vs `account`, {RiverProceeds}) concerns the TAKE legs only:
//  these are value-IN ops — the module funds the diamond, nothing comes back.
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
// `data = abi.encode(forDesc, xapp, troveManager, collateralToken, upperHint,
// lowerHint)` — descriptor word FIRST; 192 bytes. (The repay sibling swaps
// `collateralToken` for `debtToken` at the same offset.)


/// @notice ONE contract for every pre-funded one-sided op on River.
/// @dev    Replaces {RiverPreFundAddCollModule}, {RiverPreFundRepayModule}. `Op` rides in
///         descriptor bits [244,252) — see {PreFundModuleBase._preFundOp} for why the
///         discriminator lives in the word the maker already signs rather than in a
///         new `data` field. Merging is safe because the op is INSIDE `data`, and `data` is
///         inside the maker's ORDER signature: an item signed for one op cannot be
///         executed as another. Each op keeps its own decode, so the
///         per-op `data` layouts are unchanged apart from the descriptor bits.
contract RiverPreFundModule is PreFundModuleBase, IMakerModule, IFundingSource {
    enum Op {
        AddColl,
        Repay
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
        if (op == uint256(Op.AddColl)) {
        _addColl(onBehalfOf, forAmount, data);
        } else if (op == uint256(Op.Repay)) {
        // Its own frame — see {RiverPreFundAddCollModule._addColl}.
        _repay(onBehalfOf, forAmount, data);
        } else {
            revert BadOp(op);
        }
    }


    /// @dev Its own frame: the six-field decode plus the venue call is too much
    ///      for one optimizer-less stack.
    function _addColl(address onBehalfOf, uint256 forAmount, bytes calldata data) private {
        (, address xapp, address tm, address collateralToken, address upper, address lower) =
            abi.decode(data, (uint256, address, address, address, address, address));
        // Scoped approve + CLEAR: `xapp` is decoded from order data on a shared
        // singleton, so it is attacker-choosable (F25 / lead A-3).
        // The delivery must have landed HERE, in THIS token — the funding leg's
        // recipient is bound by the core (descriptor bit 253) and CONSUMED
        // ({Base.ForLegReused}), but its TOKEN is not (F27/H-1). Underflows if
        // it did not; sound because `msg.sender == settlement` pins `forAmount`.
        PreFundGuard.requireDelivered(data, collateralToken, forAmount);
        SafeTransferLib.forceApprove(collateralToken, xapp, forAmount);
        IRiverXApp(xapp).addColl(tm, onBehalfOf, forAmount, upper, lower);
        SafeTransferLib.forceApprove(collateralToken, xapp, 0);
    }

    function _repay(address onBehalfOf, uint256 forAmount, bytes calldata data) private {
        (, address xapp, address tm, address debtToken, address upper, address lower) =
            abi.decode(data, (uint256, address, address, address, address, address));
        // The pre-existing floor — see {PreFundGuard}. A funding leg not addressed to
        // THIS module in THIS token underflows here, so the mis-pairing fails
        // closed; sound because `msg.sender == settlement` pins `forAmount` to the
        // core (F27/C-1, C-4). Unlike Liquity's sibling this module needs no extra
        // token-binding argument: the venue pulls through the scoped approval
        // below, so the token it takes and the token measured here are the same by
        // construction. (H-2 is specific to a venue that moves value WITHOUT an
        // approval — `repayBold` burns directly from `msg.sender`.)
        uint256 floor = PreFundGuard.floorOf(data, debtToken, forAmount);
        // Cap at the LIVE debt — the maker cannot know accrued interest at
        // signing, and the diamond rejects repaying more than is owed.
        (uint256 debt,,,) = IRiverTroveManager(tm).getEntireDebtAndColl(onBehalfOf);
        uint256 toRepay = forAmount < debt ? forAmount : debt;
        if (toRepay != 0) {
            // Scoped approve + CLEAR — `xapp` is maker-data-choosable on a singleton.
            SafeTransferLib.forceApprove(debtToken, xapp, toRepay);
            IRiverXApp(xapp).repayDebt(tm, onBehalfOf, toRepay, upper, lower);
            SafeTransferLib.forceApprove(debtToken, xapp, 0);
        }
        // The delivered surplus belongs to the maker, not to this singleton.
        PreFundGuard.sweepSurplus(debtToken, onBehalfOf, floor);
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
        (,,, asset) = abi.decode(data, (uint256, address, address, address));
        available = type(uint256).max;
    }
}
