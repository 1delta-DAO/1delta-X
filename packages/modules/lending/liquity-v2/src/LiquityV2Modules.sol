// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {DustHandler} from "@core/dust/DustHandler.sol";
import {PermitHelper} from "@core/utils/PermitHelper.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {ILiquityV2BorrowerOperations, ILiquityV2TroveManager, LatestTroveData} from "./interfaces/ILiquityV2.sol";

// ════════════════════════════════════════════════════════════════════════════
//  Liquity V2 CDP modules
//
//  Troves are ERC-721 sub-accounts under a per-branch `BorrowerOperations`. The
//  per-trove manager delegation maps directly onto MAKE/TAKE:
//    • the maker grants `setAddManager(troveId, module)` → the module may run the
//      MAKE legs (addColl / repayBold);
//    • the maker grants `setRemoveManagerWithReceiver(troveId, module, module)` →
//      the module may run the TAKE legs (withdrawColl / withdrawBold) with the
//      proceeds routed to the module, which forwards them to the order `receiver`.
//
//  The value-out ops carry no receiver; the module MEASURES what actually landed
//  (robust to a mis-set receiver — reverts cleanly if the grant is missing) and
//  forwards exactly `amount`, sweeping any excess to the maker. `troveId` and the
//  branch contracts are maker-signed in `data`.
// ════════════════════════════════════════════════════════════════════════════

// ──────────────────── Liquity V2 add-collateral maker module ────────────────────
//
// Pulls collateral via Permit3 and adds it to the user's trove (needs the
// add-manager grant). `data = abi.encode(borrowerOps, troveId, collateralToken[, deadline, v, r, s])`
//   — base = 96.
//
contract LiquityV2AddCollModule is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;

    error NotSettlement();

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();

        (address borrowerOps, uint256 troveId, address collateralToken) =
            abi.decode(data, (address, uint256, address));

        PermitHelper.replayIfPresent(data, 96, collateralToken, onBehalfOf, address(permit3), amount);

        permit3.transferFrom(onBehalfOf, address(this), collateralToken, uint160(amount));
        SafeTransferLib.forceApprove(collateralToken, borrowerOps, amount);
        ILiquityV2BorrowerOperations(borrowerOps).addColl(troveId, amount);
    }
}

// ──────────────────── Liquity V2 repay maker module ────────────────────
//
// Partial repay of the trove's BOLD debt (repay is free — no upfront fee, no
// approval; BOLD is a privileged burn). Reads the live debt and repays
// `min(amount, debt)`. BOLD is pulled to the module and burned by
// BorrowerOperations; any residual is swept back to the maker. A full close is
// `closeTrove`, wired separately.
//
// `nonReentrant` guards weird-token transfer hooks.
// `data = abi.encode(borrowerOps, troveManager, troveId, boldToken)` — base = 128.
//
contract LiquityV2RepayModule is IMakerModule {
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

        (address borrowerOps, address troveManager, uint256 troveId, address boldToken) =
            abi.decode(data, (address, address, uint256, address));

        LatestTroveData memory d = ILiquityV2TroveManager(troveManager).getLatestTroveData(troveId);
        uint256 toRepay = amount < d.entireDebt ? amount : d.entireDebt;

        if (toRepay > 0) {
            permit3.transferFrom(onBehalfOf, address(this), boldToken, uint160(toRepay));
            // BOLD needs no ERC20 approval (BorrowerOperations burns it directly).
            ILiquityV2BorrowerOperations(borrowerOps).repayBold(troveId, toRepay);
        }

        uint256 residual = IERC20(boldToken).balanceOf(address(this));
        if (residual != 0) SafeTransferLib.safeTransfer(boldToken, onBehalfOf, residual);

        _locked = 1;
    }
}

// ──────────────────── Liquity V2 combined taker module ────────────────────
//
// Fuses borrow (`withdrawBold`) and collateral-withdraw (`withdrawColl`) behind a
// leading `op` flag. With `setRemoveManagerWithReceiver(troveId, module, module)`
// the proceeds land on this module; it forwards exactly `amount` to `receiver`
// and sweeps any excess to the maker. Borrow-data and withdraw-data hash to
// different taker refs (separate amount-gated allowances).
//
//   op = 0 (Borrow):       data = abi.encode(uint8(0), borrowerOps, troveId, boldToken, maxUpfrontFee)
//   op = 1 (WithdrawColl):  data = abi.encode(uint8(1), borrowerOps, troveId, collateralToken)
//
contract LiquityV2TakerModule is ITakerModule {
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
            (, address borrowerOps, uint256 troveId, address boldToken, uint256 maxUpfrontFee) =
                abi.decode(data, (uint8, address, uint256, address, uint256));
            _withdrawAndForward(
                boldToken, onBehalfOf, amount, receiver, borrowerOps, troveId, maxUpfrontFee, true
            );
        } else if (op == uint8(Op.WithdrawColl)) {
            (, address borrowerOps, uint256 troveId, address collateralToken) =
                abi.decode(data, (uint8, address, uint256, address));
            _withdrawAndForward(collateralToken, onBehalfOf, amount, receiver, borrowerOps, troveId, 0, false);
        } else {
            revert BadOp(op);
        }
    }

    /// @dev Run the value-out op (proceeds → this module via the remove-manager
    ///      receiver), then forward exactly `amount` to `receiver` and sweep the
    ///      excess to the maker. Measuring the delta reverts cleanly if the
    ///      remove-manager grant is missing (nothing landed).
    function _withdrawAndForward(
        address token,
        address onBehalfOf,
        uint256 amount,
        address receiver,
        address borrowerOps,
        uint256 troveId,
        uint256 maxUpfrontFee,
        bool isBorrow
    ) private {
        uint256 before = IERC20(token).balanceOf(address(this));
        if (isBorrow) {
            ILiquityV2BorrowerOperations(borrowerOps).withdrawBold(troveId, amount, maxUpfrontFee);
        } else {
            ILiquityV2BorrowerOperations(borrowerOps).withdrawColl(troveId, amount);
        }
        uint256 received = IERC20(token).balanceOf(address(this)) - before;
        require(received >= amount, "proceeds not received");
        SafeTransferLib.safeTransfer(token, receiver, amount);
        if (received > amount) SafeTransferLib.safeTransfer(token, onBehalfOf, received - amount);
    }
}
