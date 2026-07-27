// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {DustHandler} from "@core/dust/DustHandler.sol";
import {PermitHelper} from "@core/utils/PermitHelper.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

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
// ════════════════════════════════════════════════════════════════════════════

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

    error OnlyPermit3();
    error BadOp(uint8 op);

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        uint8 op = uint8(uint256(bytes32(data[:32])));

        if (op == uint8(Op.Borrow)) {
            (, address xapp, address tm, address debtToken, uint256 maxFee, address upper, address lower) =
                abi.decode(data, (uint8, address, address, address, uint256, address, address));
            // Mint satUSD to the maker, then sweep exactly `amount` to `receiver`.
            IRiverXApp(xapp).withdrawDebt(tm, onBehalfOf, maxFee, amount, upper, lower);
            permit3.transferFrom(onBehalfOf, receiver, debtToken, uint160(amount));
        } else if (op == uint8(Op.WithdrawColl)) {
            (, address xapp, address tm, address collateralToken, address upper, address lower) =
                abi.decode(data, (uint8, address, address, address, address, address));
            IRiverXApp(xapp).withdrawColl(tm, onBehalfOf, amount, upper, lower);
            permit3.transferFrom(onBehalfOf, receiver, collateralToken, uint160(amount));
        } else {
            revert BadOp(op);
        }
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
    }

    error OnlyPermit3();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        OpenData memory p = abi.decode(data, (OpenData));

        permit3.transferFrom(onBehalfOf, address(this), p.collateralToken, uint160(p.sideAmount));
        SafeTransferLib.forceApprove(p.collateralToken, p.xapp, p.sideAmount);

        IRiverXApp(p.xapp).openTrove(
            p.tm, onBehalfOf, p.maxFeePercentage, p.sideAmount, amount, p.upperHint, p.lowerHint
        );

        // satUSD minted to the maker → sweep the borrowed `amount` to `receiver`.
        permit3.transferFrom(onBehalfOf, receiver, p.debtToken, uint160(amount));
    }
}
