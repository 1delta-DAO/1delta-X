// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";
import {IFundingSource} from "@core/interfaces/IFundingSource.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {IMorphoBlue, MarketParams, MarketParamsLib} from "./interfaces/IMorphoBlue.sol";

// ──────────────── Morpho Blue PRE-FUNDED one-sided modules ────────────────
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
// Morpho's `supply` / `supplyCollateral` / `repay` are PERMISSIONLESS on
// someone else's behalf, so unlike the borrow/withdraw taker legs these ops
// need no `setAuthorization` either: the receive side is empty end to end.
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
//  Unlike the pull-funded venue modules in {MorphoBlueModules}, `morpho` here is
//  NOT an immutable: these are shared singletons and the singleton address rides
//  in the maker-signed `data` — attacker-choosable from this contract's point of
//  view. So every approval is SCOPED (forceApprove for exactly `forAmount`, then
//  cleared), never the standing max the immutable-morpho modules keep.
//
// `data = abi.encode(forDesc, morpho, marketParams)` — descriptor word FIRST
// (forDesc@0), the Morpho Blue singleton @32, `MarketParams` (5 static words)
// @64; 224 bytes total.


/// @notice ONE contract for every pre-funded one-sided op on Morpho Blue.
/// @dev    Replaces {MorphoBluePreFundSupplyModule}, {MorphoBluePreFundSupplyCollateralModule}, {MorphoBluePreFundRepayModule}. `Op` rides in
///         descriptor bits [244,252) — see {PreFundModuleBase._preFundOp} for why the
///         discriminator lives in the word the maker already signs rather than in a
///         new `data` field. Merging is safe because the op is INSIDE `data`, and `data` is
///         inside the maker's ORDER signature: an item signed for one op cannot be
///         executed as another. Each op keeps its own decode, so the
///         per-op `data` layouts are unchanged apart from the descriptor bits.
contract MorphoBluePreFundModule is PreFundModuleBase, IMakerModule, IFundingSource {
    enum Op {
        Supply,
        SupplyCollateral,
        Repay
    }

    using MarketParamsLib for MarketParams;

    // Morpho's SharesMathLib virtual offsets, so the shares→assets round-up here
    // is bit-identical to what `repay(shares=…)` will pull.
    uint256 private constant VIRTUAL_SHARES = 1e6;
    uint256 private constant VIRTUAL_ASSETS = 1;

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
        if (op == uint256(Op.Supply)) {
        _supply(onBehalfOf, forAmount, data);
        } else if (op == uint256(Op.SupplyCollateral)) {
        _supplyCollateral(onBehalfOf, forAmount, data);
        } else if (op == uint256(Op.Repay)) {
        // Its own frame: the fork profile compiles without the optimizer, where the
        // struct decode plus the repay-and-sweep logic overflows this function's stack.
        _repayAndSweep(onBehalfOf, forAmount, data);
        } else {
            revert BadOp(op);
        }
    }


    /// @dev Its own frame: the fork profile compiles without the optimizer, where
    ///      the struct decode plus the venue call is too much for one stack.
    function _supply(address onBehalfOf, uint256 forAmount, bytes calldata data) private {
        (, address morpho, MarketParams memory marketParams) = abi.decode(data, (uint256, address, MarketParams));
        // Scoped approve + CLEAR: `morpho` is decoded from order data on a shared
        // singleton, so it is attacker-choosable (F25 / lead A-3).
        // The delivery must have landed HERE, in THIS token — the funding leg's
        // recipient is bound by the core (descriptor bit 253) and CONSUMED
        // ({Base.ForLegReused}), but its TOKEN is not (F27/H-1). Underflows if
        // it did not; sound because `msg.sender == settlement` pins `forAmount`.
        PreFundGuard.requireDelivered(data, marketParams.loanToken, forAmount);
        SafeTransferLib.forceApprove(marketParams.loanToken, morpho, forAmount);
        IMorphoBlue(morpho).supply(marketParams, forAmount, 0, onBehalfOf, "");
        SafeTransferLib.forceApprove(marketParams.loanToken, morpho, 0);
    }

    /// @dev Split frame for the optimizer-less fork profile (see the supply module).
    function _supplyCollateral(address onBehalfOf, uint256 forAmount, bytes calldata data) private {
        (, address morpho, MarketParams memory marketParams) = abi.decode(data, (uint256, address, MarketParams));
        // Scoped approve + CLEAR — `morpho` is maker-data-choosable on a singleton.
        // The delivery must have landed HERE, in THIS token — the funding leg's
        // recipient is bound by the core (descriptor bit 253) and CONSUMED
        // ({Base.ForLegReused}), but its TOKEN is not (F27/H-1). Underflows if
        // it did not; sound because `msg.sender == settlement` pins `forAmount`.
        PreFundGuard.requireDelivered(data, marketParams.collateralToken, forAmount);
        SafeTransferLib.forceApprove(marketParams.collateralToken, morpho, forAmount);
        IMorphoBlue(morpho).supplyCollateral(marketParams, forAmount, onBehalfOf, "");
        SafeTransferLib.forceApprove(marketParams.collateralToken, morpho, 0);
    }

    function _repayAndSweep(address onBehalfOf, uint256 forAmount, bytes calldata data) private {
        (, address morpho, MarketParams memory marketParams) = abi.decode(data, (uint256, address, MarketParams));
        // The pre-existing floor — see {PreFundGuard}. Fails closed on a funding leg
        // not addressed to THIS module in THIS token, and is what bounds the sweep
        // below.
        uint256 floor = PreFundGuard.floorOf(data, marketParams.loanToken, forAmount);
        // MEASURED, not reported (F27/C-3). `_repay`'s return value comes from
        // `morpho`, which is decoded from order data on a shared singleton — a
        // venue that pulls the whole scoped approval and then reports `repaid = 0`
        // would ask this sweep for a SECOND `forAmount`, extracting 2x. The
        // balance delta cannot lie, and the clamp below cannot dip under the floor
        // even if it did.
        _repay(morpho, marketParams, onBehalfOf, forAmount);
        // The delivered surplus belongs to the maker, not to this singleton. Sweep
        // exactly this fill's excess, never the whole balance — a wei of another
        // fill's dust may legitimately sit here.
        PreFundGuard.sweepSurplus(marketParams.loanToken, onBehalfOf, floor);
    }

    /// @dev Cap at the LIVE debt. Full closes go by shares (assets drift upward
    ///      as interest accrues, shares don't), partial repays by assets — a
    ///      partial `toSharesDown` is strictly below the live shares whenever the
    ///      assets are below their round-up value, so neither branch can underflow.
    function _repay(address morpho, MarketParams memory marketParams, address onBehalfOf, uint256 forAmount)
        private
    {
        uint256 borrowShares = IMorphoBlue(morpho).position(marketParams.id(), onBehalfOf).borrowShares;
        if (borrowShares == 0) return;
        // ACCRUE BEFORE APPROVING (F27/C-3b). `_debtAssetsUp` calls
        // `morpho.accrueInterest` — an external call into a maker-chosen address.
        // Granting the scoped approval first left it live across that call, so the
        // "venue" could pull it there and still return 0 from `repay` below. The
        // branch decision needs no allowance, so it belongs above the approve.
        bool full = forAmount >= _debtAssetsUp(morpho, marketParams, borrowShares);
        // Scoped approve + CLEAR — `morpho` is maker-data-choosable on a singleton.
        // `forAmount` upper-bounds either branch: shares repay pulls the round-up
        // debt (≤ forAmount by the branch condition), assets repay pulls forAmount.
        SafeTransferLib.forceApprove(marketParams.loanToken, morpho, forAmount);
        if (full) {
            IMorphoBlue(morpho).repay(marketParams, 0, borrowShares, onBehalfOf, "");
        } else {
            IMorphoBlue(morpho).repay(marketParams, forAmount, 0, onBehalfOf, "");
        }
        SafeTransferLib.forceApprove(marketParams.loanToken, morpho, 0);
    }

    /// @dev The live debt in assets, round-UP — exactly what `repay(shares=…)`
    ///      will pull. Accrue FIRST: the totals are stale since `lastUpdate`, and
    ///      the maker cannot know accrued interest at signing.
    function _debtAssetsUp(address morpho, MarketParams memory marketParams, uint256 borrowShares)
        private
        returns (uint256)
    {
        IMorphoBlue(morpho).accrueInterest(marketParams);
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = IMorphoBlue(morpho).market(marketParams.id());
        uint256 num = borrowShares * (uint256(totalBorrowAssets) + VIRTUAL_ASSETS);
        uint256 den = uint256(totalBorrowShares) + VIRTUAL_SHARES;
        return (num + den - 1) / den; // mulDivUp — Morpho's toAssetsUp
    }


    /// @inheritdoc IFundingSource
    /// @dev PER-OP: all three ops share one `data` layout but fund DIFFERENT members
    ///      of it — SupplyCollateral moves the collateral token, Supply and Repay
    ///      move the loan token. A single decode is not enough; the preflight has to
    ///      name the asset the op will actually spend, or {SettlementLens} rejects
    ///      the order as funding a different asset than the leg it is sized by.
    function fundingSource(address, bytes calldata data)
        external
        pure
        override
        returns (address asset, uint256 available)
    {
        (,, MarketParams memory marketParams) = abi.decode(data, (uint256, address, MarketParams));
        asset = _preFundOp(data) == uint256(Op.SupplyCollateral) ? marketParams.collateralToken : marketParams.loanToken;
        available = type(uint256).max;
    }
}
