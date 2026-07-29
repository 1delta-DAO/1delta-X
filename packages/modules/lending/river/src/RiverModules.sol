// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {DustHandler} from "@core/dust/DustHandler.sol";
import {PermitHelper} from "@core/utils/PermitHelper.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {FullFillGuard} from "@core/utils/FullFillGuard.sol";

import {IRiverXApp, IRiverTroveManager} from "./interfaces/IRiver.sol";

// ════════════════════════════════════════════════════════════════════════════
//  River (Satoshi Protocol) CDP modules
//
//  All ops target the SatoshiXApp diamond (`xapp`) and pass `troveManager` +
//  `account`; the maker authorises the module once with the diamond-wide boolean
//  `setDelegateApproval(module, true)`, and the Permit3 allowances still cap every
//  fill. Troves are address-keyed (≤1 per user per TroveManager).
//
//  CDP value-out has NO receiver: `withdrawDebt` mints satUSD to `account` and
//  `withdrawColl` returns collateral to `account`. So the taker modules run the
//  op and then Permit3-sweep the proceeds from the maker to the order's
//  `receiver` (the maker grants a Permit3 TOKEN allowance on the output token to
//  the module, exactly like the Aave withdraw module pulls the aToken).
//
//  ⚠️ Fund-flow direction (value-in pulled from msg.sender / value-out landing on
//  `account`) is transcribed from the Prisma/Liquity-V1 lineage — validate on a
//  Hemi/Base fork against the deployed diamond before mainnet use.
//
//  Because that direction is unverified, every value-out leg MEASURES the maker's
//  balance delta across the CDP call and forwards only what the op actually
//  produced (`RiverProceeds.deliveredTo`). This is not defensive padding — it is
//  what makes the modules safe under the ambiguity:
//
//    • The taker legs pull the payout FROM THE MAKER'S WALLET, because River's
//      value-out ops carry no `receiver` and mint/return to `account`. Pulling a
//      fixed `amount` without measuring means a CDP call that delivers less than
//      expected — a borrow fee netted out of the mint, a fork whose proceeds land
//      on the caller instead, a delegate grant that silently no-ops — is paid for
//      out of the maker's PRE-EXISTING balance of that token. The Permit3 token
//      allowance is the only bound, and for this flow it is realistically large.
//    • So the failure mode was not "the fill reverts", it was "the solver is paid
//      out of the maker's wallet and the maker eats the difference", with nothing
//      on-chain noticing.
//
//  Measuring converts every one of those into a clean revert, and makes the
//  modules correct under BOTH fund-flow directions rather than only the assumed
//  one. Do not replace these deltas with a nominal `amount`.
// ════════════════════════════════════════════════════════════════════════════

/// @title RiverProceeds
/// @notice Measures what a River CDP op actually delivered to the maker.
/// @dev Mirrors the `_withdrawAndForward` / `_withdrawFull` discipline used by
///      every other taker package (Aave, Morpho, Liquity, Silo, Venus): snapshot,
///      call, require the delta covers the obligation, forward only that.
library RiverProceeds {
    /// @dev The CDP op produced less than the fill owes. Fail closed rather than
    ///      making up the difference from the maker's own balance.
    error InsufficientProceeds(uint256 delivered, uint256 required);

    function snapshot(address token, address account) internal view returns (uint256) {
        return SafeTransferLib.balanceOf(token, account);
    }

    function requireDelivered(address token, address account, uint256 before, uint256 required) internal view {
        uint256 delivered = SafeTransferLib.balanceOf(token, account) - before;
        if (delivered < required) revert InsufficientProceeds(delivered, required);
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

    /// @dev Mint satUSD to the maker, then sweep exactly `amount` to `receiver` —
    ///      but only once the mint is shown to have delivered it. Own frame (the
    ///      measured delta pushes the combined dispatch over the stack limit); the
    ///      hint/router locals are scoped so they are freed before the pull.
    function _borrow(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) private {
        // Decoded as a memory STRUCT rather than a flat tuple: the measured delta
        // pushes this frame past the stack limit otherwise, and a struct costs one
        // pointer instead of six slots. All members are static, so the wire format
        // is byte-identical to the previous tuple encoding — `data` is unchanged.
        BorrowParams memory p = abi.decode(data, (BorrowParams));
        uint256 before = RiverProceeds.snapshot(p.debtToken, onBehalfOf);
        IRiverXApp(p.xapp).withdrawDebt(p.tm, onBehalfOf, p.maxFee, amount, p.upper, p.lower);
        // Without this the pull below would silently draw on the maker's
        // PRE-EXISTING satUSD whenever the CDP op under-delivered.
        RiverProceeds.requireDelivered(p.debtToken, onBehalfOf, before, amount);
        permit3.transferFrom(onBehalfOf, receiver, p.debtToken, uint160(amount));
    }

    /// @dev Collateral leg of the same shape — see {_borrow}.
    function _withdrawColl(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) private {
        WithdrawParams memory p = abi.decode(data, (WithdrawParams));
        uint256 before = RiverProceeds.snapshot(p.collateralToken, onBehalfOf);
        IRiverXApp(p.xapp).withdrawColl(p.tm, onBehalfOf, amount, p.upper, p.lower);
        RiverProceeds.requireDelivered(p.collateralToken, onBehalfOf, before, amount);
        permit3.transferFrom(onBehalfOf, receiver, p.collateralToken, uint160(amount));
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

        uint256 before = RiverProceeds.snapshot(p.debtToken, onBehalfOf);
        IRiverXApp(p.xapp).openTrove(
            p.tm, onBehalfOf, p.maxFeePercentage, p.sideAmount, amount, p.upperHint, p.lowerHint
        );
        // satUSD minted to the maker → sweep the borrowed `amount` to `receiver`,
        // but only what the open actually minted.
        RiverProceeds.requireDelivered(p.debtToken, onBehalfOf, before, amount);
        permit3.transferFrom(onBehalfOf, receiver, p.debtToken, uint160(amount));

        // Leave nothing standing and nothing held: `xapp` comes from `data`, so a
        // residual allowance would be a claim on any future balance of this shared
        // module, and unconsumed collateral belongs to the maker.
        SafeTransferLib.forceApprove(p.collateralToken, p.xapp, 0);
        uint256 leftColl = SafeTransferLib.balanceOf(p.collateralToken, address(this));
        if (leftColl != 0) SafeTransferLib.safeTransfer(p.collateralToken, onBehalfOf, leftColl);
    }
}
