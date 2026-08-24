// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {DustHandler} from "@lib/DustHandler.sol";
import {PermitHelper} from "@lib/PermitHelper.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";

import {IRiverXApp, IRiverTroveManager} from "./interfaces/IRiver.sol";

// ════════════════════════════════════════════════════════════════════════════
//  River (Satoshi Protocol) CDP modules
//
//  All ops target the SatoshiXApp diamond (`xapp`) and pass `troveManager` +
//  `account`; the maker authorises the module once with the diamond-wide boolean
//  `setDelegateApproval(module, true)`, and the Permit3 allowances still cap every
//  fill. Troves are address-keyed (≤1 per user per TroveManager).
//
//  CDP value-out has NO receiver parameter. ✅ FORK-VALIDATED (Hemi diamond
//  0x07Bb…AA4Ec): when a DELEGATE drives the op, the deployed diamond delivers
//  value-out to **`msg.sender` (the module)**, not to `account` — `openTrove`'s
//  mint was measured landing 100% on the delegate (see
//  test/leverage/Leverage.t.sol, which grew out of that probe). The original
//  Prisma-lineage transcription assumed `account`; a module built on that
//  assumption alone can never fill on the deployed diamond.
//
//  The taker legs therefore settle proceeds DIRECTION-AGNOSTICALLY
//  ({RiverProceeds.settle}): snapshot BOTH the module and the maker, run the op,
//  pay `receiver` first from what landed on the module (plain transfer), then
//  from what landed on the maker (Permit3 sweep — kept for chains whose
//  deployment routes to `account`), and return any module-held surplus to the
//  maker. Under-delivery — a fee netted from the mint, a silently no-op'd
//  delegate grant — is a clean {InsufficientProceeds} revert, never a pull from
//  the maker's pre-existing balance. Do not replace the measured deltas with the
//  nominal `amount`.
//
//  ✅ Also fork-validated: the deployed diamond enforces its caller-or-delegate
//  check on EVERY op, value-IN included — `addColl` by the module reverts
//  "Caller not approved" without `setDelegateApproval(module, true)`. Every
//  module in this package therefore needs the delegate grant (the README's
//  earlier "no protocol grant for value-in" was wrong for the live deployment).
// ════════════════════════════════════════════════════════════════════════════

/// @title RiverProceeds
/// @notice Direction-agnostic settlement of a River CDP op's value-out.
/// @dev Mirrors the measure-then-forward discipline used by every other taker
///      package (Aave, Morpho, Liquity, Silo, Venus), extended to two landing
///      spots because deployments differ on where value-out arrives (Hemi:
///      `msg.sender`; the Prisma lineage documents `account`).
library RiverProceeds {
    /// @dev The CDP op produced less than the fill owes. Fail closed rather than
    ///      making up the difference from the maker's own balance.
    error InsufficientProceeds(uint256 delivered, uint256 required);

    struct Snap {
        uint256 selfBefore;
        uint256 makerBefore;
    }

    function snapshot(address token, address maker) internal view returns (Snap memory s) {
        s.selfBefore = SafeTransferLib.balanceOf(token, address(this));
        s.makerBefore = SafeTransferLib.balanceOf(token, maker);
    }

    /// @notice Settle exactly `amount` of the op's proceeds to `receiver`:
    ///         module-held first (plain transfer), maker-held next (Permit3
    ///         sweep), module-held surplus back to the maker. Reverts
    ///         {InsufficientProceeds} if the op under-delivered across BOTH.
    function settle(IPermit3 permit3, address token, address maker, address receiver, uint256 amount, Snap memory s)
        internal
    {
        uint256 gotSelf = SafeTransferLib.balanceOf(token, address(this)) - s.selfBefore;
        uint256 gotMaker = SafeTransferLib.balanceOf(token, maker) - s.makerBefore;
        if (gotSelf + gotMaker < amount) revert InsufficientProceeds(gotSelf + gotMaker, amount);

        uint256 fromSelf = gotSelf >= amount ? amount : gotSelf;
        if (fromSelf != 0) SafeTransferLib.safeTransfer(token, receiver, fromSelf);
        uint256 fromMaker = amount - fromSelf;
        if (fromMaker != 0) permit3.transferFrom(maker, receiver, token, uint160(fromMaker));
        // Whatever landed here beyond the obligation is the maker's.
        if (gotSelf > fromSelf) SafeTransferLib.safeTransfer(token, maker, gotSelf - fromSelf);
    }
}

// ──────────────────── River add-collateral maker module ────────────────────
//
// Pulls collateral via Permit3 and adds it to the user's existing trove.
// `data = abi.encode(xapp, troveManager, collateralToken, upperHint, lowerHint[, deadline, v, r, s])`
//   — base = 160.
//
contract RiverAddCollModule is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;

    error NotSettlement();

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();

        (address xapp, address tm, address collateralToken, address upper, address lower) =
            abi.decode(data, (address, address, address, address, address));

        PermitHelper.replayIfPresent(data, 160, collateralToken, onBehalfOf, address(permit3), amount);

        permit3.transferFrom(onBehalfOf, address(this), collateralToken, uint160(amount));
        SafeTransferLib.forceApprove(collateralToken, xapp, amount);
        IRiverXApp(xapp).addColl(tm, onBehalfOf, amount, upper, lower);
    }
}

// ──────────────────── River repay-debt maker module ────────────────────
//
// Partial repay of the user's satUSD debt. Reads the live debt and repays
// `min(amount, debt)`; the maker-signed `amount` must be pre-sized to leave
// net debt ≥ minNetDebt (a full close is `closeTrove`, not this). Any satUSD not
// consumed by the burn is swept back to the maker.
//
// `nonReentrant` guards weird-token transfer hooks.
// `data = abi.encode(xapp, troveManager, debtToken, upperHint, lowerHint)` — base = 160.
//
contract RiverRepayModule is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;

    uint256 private _locked = 1;

    error Reentrancy();
    error NotSettlement();

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();
        if (_locked != 1) revert Reentrancy();
        _locked = 2;

        (address xapp, address tm, address debtToken, address upper, address lower) =
            abi.decode(data, (address, address, address, address, address));

        (uint256 debt,,,) = IRiverTroveManager(tm).getEntireDebtAndColl(onBehalfOf);
        uint256 toRepay = amount < debt ? amount : debt;

        if (toRepay > 0) {
            permit3.transferFrom(onBehalfOf, address(this), debtToken, uint160(toRepay));
            SafeTransferLib.forceApprove(debtToken, xapp, toRepay);
            IRiverXApp(xapp).repayDebt(tm, onBehalfOf, toRepay, upper, lower);
            SafeTransferLib.forceApprove(debtToken, xapp, 0);
        }

        // Sweep any satUSD not consumed by the burn back to the maker.
        uint256 residual = IERC20(debtToken).balanceOf(address(this));
        if (residual != 0) SafeTransferLib.safeTransfer(debtToken, onBehalfOf, residual);

        _locked = 1;
    }
}

// ──────────────────── River combined taker module ────────────────────
//
// Fuses borrow (`withdrawDebt`) and collateral-withdraw (`withdrawColl`) behind a
// leading `op` flag; each op then Permit3-sweeps the CDP proceeds from the maker
// to `receiver`. Borrow-data and withdraw-data hash to different taker refs, so
// the maker grants a separate amount-gated allowance per leg; both share the one
// diamond `setDelegateApproval(module)` grant.
//
//   op = 0 (Borrow):        data = abi.encode(uint8(0), xapp, tm, debtToken, maxFeePercentage, upperHint, lowerHint)
//   op = 1 (WithdrawColl):  data = abi.encode(uint8(1), xapp, tm, collateralToken, upperHint, lowerHint)
//
contract RiverTakerModule is ITakerModule {
    IPermit3 public immutable permit3;

    enum Op {
        Borrow, // 0
        WithdrawColl // 1
    }

    /// @dev All-static members, so these encode byte-identically to the flat
    ///      `abi.encode(uint8, address, …)` tuples documented above — the `data`
    ///      layout and therefore `ref = keccak256(data)` are unchanged.
    struct BorrowParams {
        uint8 op;
        address xapp;
        address tm;
        address debtToken;
        uint256 maxFee;
        address upper;
        address lower;
    }

    struct WithdrawParams {
        uint8 op;
        address xapp;
        address tm;
        address collateralToken;
        address upper;
        address lower;
    }

    error OnlyPermit3();
    error BadOp(uint8 op);

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        uint8 op = uint8(uint256(bytes32(data[:32])));

        if (op == uint8(Op.Borrow)) {
            _borrow(onBehalfOf, amount, receiver, data);
        } else if (op == uint8(Op.WithdrawColl)) {
            _withdrawColl(onBehalfOf, amount, receiver, data);
        } else {
            revert BadOp(op);
        }
    }

    /// @dev Mint satUSD via `withdrawDebt`, then settle exactly `amount` to
    ///      `receiver` from wherever the deployment landed it (Hemi: this module;
    ///      Prisma lineage: the maker) — see {RiverProceeds.settle}. Own frame
    ///      (the measured deltas push the combined dispatch over the stack
    ///      limit); struct decode keeps the frame at one pointer.
    function _borrow(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) private {
        BorrowParams memory p = abi.decode(data, (BorrowParams));
        RiverProceeds.Snap memory s = RiverProceeds.snapshot(p.debtToken, onBehalfOf);
        IRiverXApp(p.xapp).withdrawDebt(p.tm, onBehalfOf, p.maxFee, amount, p.upper, p.lower);
        RiverProceeds.settle(permit3, p.debtToken, onBehalfOf, receiver, amount, s);
    }

    /// @dev Collateral leg of the same shape — see {_borrow}.
    function _withdrawColl(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) private {
        WithdrawParams memory p = abi.decode(data, (WithdrawParams));
        RiverProceeds.Snap memory s = RiverProceeds.snapshot(p.collateralToken, onBehalfOf);
        IRiverXApp(p.xapp).withdrawColl(p.tm, onBehalfOf, amount, p.upper, p.lower);
        RiverProceeds.settle(permit3, p.collateralToken, onBehalfOf, receiver, amount, s);
    }
}

// ──────────────────── River open-trove module (Level B) ────────────────────
//
// Opens a fresh trove atomically: pulls `sideAmount` collateral from the maker
// (Permit3), mints `amount` (the taker value) of satUSD to the maker via
// `openTrove`, then sweeps that satUSD to `receiver`. One module signs the whole
// open under one `keccak256(data)` taker ref (amount-gated), plus the collateral
// Permit3 token allowance and the diamond delegate grant.
//
// `data = abi.encode(xapp, tm, collateralToken, debtToken, maxFeePercentage, sideAmount, upperHint, lowerHint)`.
//
contract RiverOpenModule is ITakerModule {
    IPermit3 public immutable permit3;

    struct OpenData {
        address xapp;
        address tm;
        address collateralToken;
        address debtToken;
        uint256 maxFeePercentage;
        uint256 sideAmount; // collateral to deposit
        address upperHint;
        address lowerHint;
        /// @dev The item's FULL maker-signed amount. Composite ops are full-fill
        ///      only — see {FullFillGuard}.
        uint256 totalAmount;
    }

    error OnlyPermit3();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        OpenData memory p = abi.decode(data, (OpenData));

        // Composite items execute a multi-leg position op whose side leg lives in
        // `data` and does NOT pro-rate. Reject a sliced fill outright — see {FullFillGuard}.
        FullFillGuard.requireFullFill(amount, p.totalAmount);

        permit3.transferFrom(onBehalfOf, address(this), p.collateralToken, uint160(p.sideAmount));
        SafeTransferLib.forceApprove(p.collateralToken, p.xapp, p.sideAmount);

        RiverProceeds.Snap memory s = RiverProceeds.snapshot(p.debtToken, onBehalfOf);
        IRiverXApp(p.xapp)
            .openTrove(p.tm, onBehalfOf, p.maxFeePercentage, p.sideAmount, amount, p.upperHint, p.lowerHint);
        // Settle the minted `amount` to `receiver` from wherever it landed
        // (Hemi mints to this module) — only what the open actually produced.
        RiverProceeds.settle(permit3, p.debtToken, onBehalfOf, receiver, amount, s);

        // Leave nothing standing and nothing held: `xapp` comes from `data`, so a
        // residual allowance would be a claim on any future balance of this shared
        // module, and unconsumed collateral belongs to the maker.
        SafeTransferLib.forceApprove(p.collateralToken, p.xapp, 0);
        uint256 leftColl = SafeTransferLib.balanceOf(p.collateralToken, address(this));
        if (leftColl != 0) SafeTransferLib.safeTransfer(p.collateralToken, onBehalfOf, leftColl);
    }
}
