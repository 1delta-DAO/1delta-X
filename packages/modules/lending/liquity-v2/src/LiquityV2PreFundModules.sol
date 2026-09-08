// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";
import {IFundingSource} from "@core/interfaces/IFundingSource.sol";

import {LiquityV2TroveAuth} from "./LiquityV2Modules.sol";
import {ILiquityV2BorrowerOperations, ILiquityV2TroveManager, LatestTroveData} from "./interfaces/ILiquityV2.sol";

// ──────────────── Liquity V2 PRE-FUNDED one-sided modules ────────────────
//
// "Add-collateral whatever the conversion delivered" and "repay whatever the
// conversion delivered", with ZERO receive-side TOKEN approvals: the maker signs
// the converted output leg with `recipient = module` and a `TAKE_FOR` item whose
// leg-reference descriptor points at it. The core sizes `forAmount` to exactly
// what the fill delivered here ({Base._forSlice} → {Pricing.outputAt}), auction
// decay included, and this module adds/repays it from its own balance. The
// maker's only token grants are the ones they had anyway: the ERC20+Permit3
// approval on the asset they are CONVERTING FROM (the input leg), and the taker
// allowance. The received asset — the branch collateral on an add, BOLD on a
// repay — is never approved to anything and never transits the maker's wallet.
//
//  VENUE AUTHORIZATION — per-trove, and often NONE. Liquity's value-in ops are
//  gated by `_requireSenderIsOwnerOrAddManager`: while a trove has NO add
//  manager set, `addColl`/`repayBold` are PERMISSIONLESS for anyone, so these
//  modules need no grant at all; a maker who HAS set an add manager must point
//  it at the module (`setAddManager(troveId, module)`) — the same per-trove
//  manager grant the pull-funded {LiquityV2AddCollModule}/{LiquityV2RepayModule}
//  ride, a venue authorization, not a token approval. What this variant removes
//  is the maker's Permit3 TOKEN allowance to the module and the on-chain ERC20
//  approval of the DELIVERED asset.
//
//  OWNERSHIP BINDING KEPT. `data` names the branch by INDEX and the chain is
//  rooted at the IMMUTABLE {ICollateralRegistry} exactly as in
//  {LiquityV2TroveAuth} — both the ownership oracle and the dispatch target
//  derive from a root a caller cannot invent, and the trove must belong to the
//  Permit3 principal. For a value-in op the check is cheap insurance (a
//  mis-signed troveId gifts the delivery to a stranger's trove) and, more
//  importantly, it is what DERIVES `borrowerOperations` from trusted state
//  rather than from calldata.
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
// `data = abi.encode(forDesc, branchIndex, troveId, collateralToken)` —
// descriptor word FIRST; 128 bytes. The leading branch word is an INDEX resolved
// through the immutable registry, exactly as in every other module here.


/// @notice ONE contract for every pre-funded one-sided op on Liquity v2.
/// @dev    Replaces {LiquityV2PreFundAddCollModule}, {LiquityV2PreFundRepayModule}. `Op` rides in
///         descriptor bits [244,252) — see {PreFundModuleBase._preFundOp} for why the
///         discriminator lives in the word the maker already signs rather than in a
///         new `data` field. Merging is safe because the op is INSIDE `data`, and `data` is
///         inside the maker's ORDER signature: an item signed for one op cannot be
///         executed as another. Each op keeps its own decode, so the
///         per-op `data` layouts are unchanged apart from the descriptor bits.
contract LiquityV2PreFundModule is PreFundModuleBase, IMakerModule, IFundingSource {
    enum Op {
        AddColl,
        Repay
    }


    /// @dev The per-deployment branch registry — the ONLY trusted auth root
    ///      (F26/C-1). Immutable, so a caller may choose WHICH branch but cannot
    ///      invent one.
    address public immutable collateralRegistry;

    /// @dev The descriptor named an op this module does not implement.
    error BadOp(uint256 op);


    constructor(address _permit3, address _settlement, address _collateralRegistry)
        PreFundModuleBase(_permit3, _settlement)
    {
        collateralRegistry = _collateralRegistry;
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
        if (op == uint256(Op.AddColl)) {
        _addColl(onBehalfOf, forAmount, data);
        } else if (op == uint256(Op.Repay)) {
        // Its own frame — see {LiquityV2PreFundAddCollModule._addColl}.
        _repay(onBehalfOf, forAmount, data);
        } else {
            revert BadOp(op);
        }
    }


    /// @dev Its own frame: the decode plus the derived-auth call chain is too
    ///      much for one optimizer-less stack.
    function _addColl(address onBehalfOf, uint256 forAmount, bytes calldata data) private {
        (, uint256 branchIndex, uint256 troveId, address collateralToken) =
            abi.decode(data, (uint256, uint256, uint256, address));
        // Both the ownership oracle and `borrowerOps` derive from the IMMUTABLE
        // registry — see {LiquityV2TroveAuth} for the forged-root attack this shape
        // replaces.
        (address borrowerOps,) =
            LiquityV2TroveAuth.authorizeTrove(collateralRegistry, branchIndex, troveId, onBehalfOf);
        // Scoped approve + CLEAR: a standing allowance on this shared singleton
        // would be a claim on any future balance it holds (F25 / lead A-3).
        // The delivery must have landed HERE, in THIS token — the funding leg's
        // recipient is bound by the core (descriptor bit 253) and CONSUMED
        // ({Base.ForLegReused}), but its TOKEN is not (F27/H-1). Underflows if
        // it did not; sound because `msg.sender == settlement` pins `forAmount`.
        PreFundGuard.requireDelivered(data, collateralToken, forAmount);
        SafeTransferLib.forceApprove(collateralToken, borrowerOps, forAmount);
        ILiquityV2BorrowerOperations(borrowerOps).addColl(troveId, forAmount);
        SafeTransferLib.forceApprove(collateralToken, borrowerOps, 0);
    }

    function _repay(address onBehalfOf, uint256 forAmount, bytes calldata data) private {
        (, uint256 branchIndex, uint256 troveId, address boldToken) =
            abi.decode(data, (uint256, uint256, uint256, address));
        // `borrowerOps` is DERIVED, so the debt read, the repay and the ownership
        // check all share one trusted root. AUTHORIZE BEFORE MEASURING: the floor
        // below underflows on a mis-paired leg, and a foreign trove must report
        // `InvalidCaller` rather than an arithmetic panic.
        (address borrowerOps, address troveManager) =
            LiquityV2TroveAuth.authorizeTrove(collateralRegistry, branchIndex, troveId, onBehalfOf);
        // The pre-existing floor — see {PreFundGuard}. A funding leg not addressed to
        // THIS module in THIS token underflows here, so the mis-pairing fails
        // closed; sound because `msg.sender == settlement` pins `forAmount` to the
        // core (F27/C-1, C-4). For this module it ALSO binds the accounting token:
        // `repayBold` burns a root-derived asset with NO approval while the surplus
        // is measured on a `data`-supplied one, so the two could disagree (F27/H-2);
        // requiring the delivery in `boldToken` is what ties them back together.
        uint256 floor = PreFundGuard.floorOf(data, boldToken, forAmount);
        uint256 toRepay;
        {
            LatestTroveData memory d = ILiquityV2TroveManager(troveManager).getLatestTroveData(troveId);
            toRepay = forAmount < d.entireDebt ? forAmount : d.entireDebt;
        }
        if (toRepay != 0) {
            // BOLD needs no ERC20 approval (BorrowerOperations burns it directly);
            // the venue may clamp the burn at entireDebt − MIN_DEBT — see the header.
            ILiquityV2BorrowerOperations(borrowerOps).repayBold(troveId, toRepay);
        }
        // The delivered surplus belongs to the maker, not to this singleton.
        PreFundGuard.sweepSurplus(boldToken, onBehalfOf, floor);
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
        (,,, asset) = abi.decode(data, (uint256, uint256, uint256, address));
        available = type(uint256).max;
    }
}
