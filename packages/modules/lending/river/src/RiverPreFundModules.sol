// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";
import {IFundingSource} from "@core/interfaces/IFundingSource.sol";
import {ITakerForModule} from "@core/interfaces/ITakerForModule.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";

import {IRiverXApp, IRiverTroveManager} from "./interfaces/IRiver.sol";
import {RiverProceeds} from "./RiverModules.sol";

// ──────────────── River (Satoshi Protocol) PRE-FUNDED one-sided modules ────────────────
//
// "Add-collateral whatever the conversion delivered" and "repay whatever the
// conversion delivered", with ZERO receive-side TOKEN approvals: the maker signs
// the converted output leg with `recipient = module` and a pre-funded `MAKE` item
// whose leg-reference descriptor points at it. The core sizes `forAmount` to
// exactly what the fill delivered here ({Base._forSlice} → {Pricing.outputAt}),
// auction decay included, and this module adds/repays it from its own balance.
// The maker's only token grant is the one they had anyway: the ERC20+Permit3
// approval on the asset they are CONVERTING FROM (the input leg). No taker
// allowance is granted or spent — Settlement dispatches a `MAKE` directly. The
// received asset — the collateral on an add, satUSD on a repay —
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
//
//  THE PRE-FUNDED OPEN (op 2, `TAKE_FOR`) — River's side leg (review 2026-10-18 M-5)
//  ─────────────────────────────────────────────────────────────────────────
//  {RiverOpenModule} pulls the trove's collateral (`sideAmount`) from the maker's
//  wallet through a Permit3 token allowance. On a zero-capital "sell X, open a trove
//  on the collateral" order that is a grant for a token the maker never held. The
//  pre-funded open instead takes the collateral from a DELIVERED leg: the maker
//  signs that leg with `recipient = this module` and a `TAKE_FOR` item whose
//  leg-reference descriptor points at it, so the core sizes `forAmount` (the
//  collateral) to exactly what was delivered, and `amount` (the satUSD minted,
//  bounded by the maker's taker allowance) is the value-out side, settled to
//  `receiver` direction-agnostically ({RiverProceeds}).
//
//  It lives HERE, not on {RiverOpenModule}, because it consumes the same standing
//  grant this contract already needs — the diamond-wide delegate boolean — and
//  merging by grant is the rule ([credit-module-grant-merge]). The seams stay
//  disjoint: `makeOnBehalf` rejects op 2, `takeForOnBehalf` rejects ops 0/1, and
//  the descriptor is inside `ref = keccak256(data)`, so no taker grant can be
//  replayed across ops. Only the PRE-FUND descriptor is accepted
//  ({PreFundGuard.requireLegRef}); the pull form is {RiverOpenModule}.
//
//  FULL-FILL ONLY: a trove opens once (≤1 per user per TroveManager), so a second
//  slice would revert inside `openTrove` — {FullFillGuard} says so up front.
//
//  `data = abi.encode(OpenData{forDesc, xapp, tm, collateralToken, debtToken,
//  maxFeePercentage, upperHint, lowerHint, totalAmount})` — nine static words;
//  forDesc@0 (op 2 in bits [244,252), funding token = collateralToken), xapp@32,
//  tm@64, collateralToken@96, debtToken@128 (pinned to `tm.debtToken()`),
//  maxFee@160, upper@192, lower@224, totalAmount@256 (MANDATORY).


/// @notice ONE contract for every pre-funded one-sided op on River.
/// @dev    Replaces {RiverPreFundAddCollModule}, {RiverPreFundRepayModule}. `Op` rides in
///         descriptor bits [244,252) — see {PreFundModuleBase._preFundOp} for why the
///         discriminator lives in the word the maker already signs rather than in a
///         new `data` field. Merging is safe because the op is INSIDE `data`, and `data` is
///         inside the maker's ORDER signature: an item signed for one op cannot be
///         executed as another. Each op keeps its own decode, so the
///         per-op `data` layouts are unchanged apart from the descriptor bits.
contract RiverPreFundModule is PreFundModuleBase, IMakerModule, ITakerForModule, IFundingSource {
    enum Op {
        AddColl, // 0 — MAKE
        Repay, //   1 — MAKE
        Open //     2 — TAKE_FOR (collateral pre-funded, satUSD out)
    }

    /// @dev The op-2 blob. All-static, so byte-identical to the flat tuple.
    struct OpenData {
        uint256 forDesc;
        address xapp;
        address tm;
        address collateralToken;
        address debtToken;
        uint256 maxFeePercentage;
        address upperHint;
        address lowerHint;
        /// @dev The item's FULL maker-signed amount — {FullFillGuard}.
        uint256 totalAmount;
    }

    /// @dev The descriptor named an op this module does not implement.
    error BadOp(uint256 op);
    /// @dev The maker-named debt token is not the TroveManager's.
    error DebtTokenMismatch(address named, address actual);
    /// @dev A repay that would retire the WHOLE trove debt — the venue rejects it
    ///      (minimum net debt); a full close is `closeTrove`.
    error FullCloseNotSupported(uint256 entireDebt);


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
        // ({Base.ForLegInvalid}), but its TOKEN is not (F27/H-1). Underflows if
        // it did not; sound because `msg.sender == settlement` pins `forAmount`.
        // KEEP THE FLOOR, DO NOT DISCARD IT. `requireDelivered` proves the same delivery
        // and throws the number away; a venue that consumes LESS than instructed then
        // leaves the remainder resident on a SHARED SINGLETON — the residue that every
        // pre-fund drain so far has monetised. Measured against the pre-delivery floor,
        // never sized from the venue's return value (F27/C-3). Aligned with the aave-v3
        // sibling and every `_repay` half (F28, 2026-09-12).
        uint256 floor = PreFundGuard.floorOf(data, collateralToken, forAmount);
        SafeTransferLib.forceApprove(collateralToken, xapp, forAmount);
        IRiverXApp(xapp).addColl(tm, onBehalfOf, forAmount, upper, lower);
        SafeTransferLib.forceApprove(collateralToken, xapp, 0);
        PreFundGuard.sweepSurplus(collateralToken, onBehalfOf, floor);
    }

    function _repay(address onBehalfOf, uint256 forAmount, bytes calldata data) private {
        (, address xapp, address tm, address debtToken, address upper, address lower) =
            abi.decode(data, (uint256, address, address, address, address, address));
        // THE VENUE BURNS, IT DOES NOT PULL. The deployed diamond retires debt by
        // burning satUSD straight from `msg.sender` (this module) with NO allowance
        // (fork-verified 2026-09-12: `repayDebt` succeeds with zero approval to the
        // xapp) — the scoped approve below is inert, so it never tied the token
        // measured here to the token burned. A maker naming a worthless `debtToken`
        // had it pulled/delivered and swept straight back while the venue retired
        // their debt out of whatever REAL satUSD sat on this shared singleton.
        // Residue-bounded, but the class the rest of the tree closes with floors:
        // pin the named token to the TroveManager's own before measuring anything.
        // (2026-09-12 audit, finding 6; the earlier "same by construction" note
        // was wrong about the mechanism.)
        if (debtToken != IRiverTroveManager(tm).debtToken()) {
            revert DebtTokenMismatch(debtToken, IRiverTroveManager(tm).debtToken());
        }
        // The pre-existing floor — see {PreFundGuard}. A funding leg not addressed to
        // THIS module in THIS token underflows here, so the mis-pairing fails
        // closed; sound because `msg.sender == settlement` pins `forAmount` to the
        // core (F27/C-1, C-4).
        uint256 floor = PreFundGuard.floorOf(data, debtToken, forAmount);
        // Cap at the LIVE debt — the maker cannot know accrued interest at signing.
        // ⚠ The cap's saturating case is NOT a success path on River: retiring the
        // WHOLE debt via `repayDebt` breaks the diamond's minimum-net-debt rule
        // (`_requireAtLeastMinNetDebt`) and reverts inside the venue — a full close
        // is `closeTrove`, not wired. Fail closed HERE with the same named error as
        // the pull sibling {RiverRepayModule}, instead of an opaque venue revert
        // (2026-09-30 audit, L-LRG-4/L-CENSUS-3; River is a Liquity-v1-style venue,
        // unlike Liquity v2, which clamps). An over-delivery therefore cannot be
        // "repay all and sweep the rest" here — size the leg below the debt.
        (uint256 debt,,,) = IRiverTroveManager(tm).getEntireDebtAndColl(onBehalfOf);
        uint256 toRepay = forAmount < debt ? forAmount : debt;
        if (toRepay != 0 && toRepay == debt) revert FullCloseNotSupported(debt);
        if (toRepay != 0) {
            // Scoped approve + CLEAR — `xapp` is maker-data-choosable on a singleton.
            SafeTransferLib.forceApprove(debtToken, xapp, toRepay);
            IRiverXApp(xapp).repayDebt(tm, onBehalfOf, toRepay, upper, lower);
            SafeTransferLib.forceApprove(debtToken, xapp, 0);
        }
        // The delivered surplus belongs to the maker, not to this singleton.
        PreFundGuard.sweepSurplus(debtToken, onBehalfOf, floor);
    }


    /// @notice The pre-funded trove open: supply the delivered collateral, mint
    ///         `amount` satUSD, settle it to `receiver`.
    /// @param spender    the Permit3 caller — must be this module's Settlement.
    /// @param onBehalfOf the maker — the trove's owner.
    /// @param amount     satUSD to mint (the value-out leg, taker-allowance gated).
    /// @param forAmount  this fill's delivered collateral, core-sized.
    function takeForOnBehalf(
        address spender,
        address onBehalfOf,
        uint256 amount,
        uint256 forAmount,
        address receiver,
        bytes calldata data
    ) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();
        // `Permit3.takeFor` is permissionless: without this pin `forAmount` is the
        // caller's own argument and the floor below proves nothing (F27/C-1).
        PreFundGuard.requireSettlement(spender, settlement);
        // PRE-FUND descriptor only — the pull form of the open is {RiverOpenModule}.
        PreFundGuard.requireLegRef(data);
        uint256 op = _preFundOp(data);
        if (op != uint256(Op.Open)) revert BadOp(op);
        _open(onBehalfOf, amount, forAmount, receiver, data);
    }

    /// @dev Its own frame: the nine-word decode plus the measured settle is too much
    ///      for one optimizer-less stack.
    function _open(address onBehalfOf, uint256 amount, uint256 forAmount, address receiver, bytes calldata data)
        private
    {
        OpenData memory p = abi.decode(data, (OpenData));
        // A trove opens once; a sliced fill would re-run `openTrove` and revert.
        FullFillGuard.requireFullFill(amount, p.totalAmount);
        // The measured value-out token is the TroveManager's own (rule 16 / the
        // repay sibling's 2026-09-12 finding-6 pin): a maker-named token that is
        // not satUSD would measure zero and fail late, or measure the wrong asset.
        if (p.debtToken != IRiverTroveManager(p.tm).debtToken()) {
            revert DebtTokenMismatch(p.debtToken, IRiverTroveManager(p.tm).debtToken());
        }
        // The collateral must have landed HERE, in THIS token; the floor bounds the
        // sweep below to this fill's own delivery.
        uint256 floor = PreFundGuard.floorOf(data, p.collateralToken, forAmount);
        // Scoped approve + CLEAR: `xapp` is maker-data-choosable on a singleton.
        SafeTransferLib.forceApprove(p.collateralToken, p.xapp, forAmount);
        RiverProceeds.Snap memory s = RiverProceeds.snapshot(p.debtToken, onBehalfOf);
        IRiverXApp(p.xapp)
            .openTrove(p.tm, onBehalfOf, p.maxFeePercentage, forAmount, amount, p.upperHint, p.lowerHint);
        // Exactly `amount` to `receiver` from wherever the deployment landed it;
        // reverts {RiverProceeds.InsufficientProceeds} on a short mint.
        RiverProceeds.settle(permit3, p.debtToken, onBehalfOf, receiver, amount, s);
        SafeTransferLib.forceApprove(p.collateralToken, p.xapp, 0);
        // Collateral the diamond did not take (none on an honest open) goes back
        // to the maker, never to a later caller.
        PreFundGuard.sweepSurplus(p.collateralToken, onBehalfOf, floor);
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
        // Word 3 on every op: collateralToken (AddColl, Open) or debtToken (Repay).
        (,,, asset) = abi.decode(data, (uint256, address, address, address));
        available = type(uint256).max;
    }
}
