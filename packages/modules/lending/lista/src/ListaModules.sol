// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {DustHandler} from "@core/dust/DustHandler.sol";
import {PermitHelper} from "@core/utils/PermitHelper.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {IMoolah, IListaBroker, MarketParams, Position, Id, MarketParamsLib} from "./interfaces/ILista.sol";

// ════════════════════════════════════════════════════════════════════════════
//  Lista DAO (Moolah + LendingBroker) modules
//
//  Collateral lives in the Moolah singleton (a Morpho fork), so the
//  supply-collateral / withdraw-collateral legs mirror the Morpho Blue modules
//  and are gated by Moolah `setAuthorization(module, true)`. The debt side of a
//  brokered market runs through a `LendingBroker`:
//
//    supply-collateral / repay → value-in  (MAKE)
//    broker-borrow / withdraw-collateral → value-out (TAKE), forwarded to `receiver`
//
//  Only the FIXED-term broker borrow is delegable; the flex borrow is
//  `msg.sender`-only (out of scope). All market/broker/term identifiers are
//  maker-signed in `data`.
// ════════════════════════════════════════════════════════════════════════════

// ──────────────────── Lista supply-collateral maker module ────────────────────
//
// Pulls `collateralToken` via Permit3 and supplies it into the Moolah market on
// the user's behalf. Optional EIP-2612 permit replay.
// `data = abi.encode(moolah, MarketParams[, deadline, v, r, s])` — base = 192.
//
contract ListaSupplyCollateralModule is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;

    error NotSettlement();

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();

        (address moolah, MarketParams memory mp) = abi.decode(data, (address, MarketParams));

        // base = op-less: (address, MarketParams(5 words)) = 32 + 160 = 192 bytes.
        PermitHelper.replayIfPresent(data, 192, mp.collateralToken, onBehalfOf, address(permit3), amount);

        permit3.transferFrom(onBehalfOf, address(this), mp.collateralToken, uint160(amount));
        SafeTransferLib.forceApprove(mp.collateralToken, moolah, amount);
        IMoolah(moolah).supplyCollateral(mp, amount, onBehalfOf, "");
    }
}

// ──────────────────── Lista broker repay maker module ────────────────────
//
// Closes (up to `amount`) of the user's broker debt. Pulls the maker-signed
// ceiling, approves the broker, then calls `repay(0, …)` — the broker consumes
// exactly the debt from this module's balance and refunds the surplus here, which
// is then swept to the user (or recycled). `loanId == type(uint128).max` selects
// the flex position; any other value a fixed position.
//
// `nonReentrant` guards weird-token transfer hooks.
// `data = abi.encode(broker, loanToken, loanId[, DustAction[, deadline, v, r, s]])`
//   — base = 96; DustAction@96; permit@128.
//
contract ListaBrokerRepayModule is IMakerModule {
    uint256 private constant DYNAMIC_LOAN = type(uint128).max;

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

        (address broker, address loanToken, uint256 loanId) = abi.decode(data, (address, address, uint256));
        DustHandler.DustAction action = DustHandler.readAction(data, 96);
        PermitHelper.replayIfPresent(data, 128, loanToken, onBehalfOf, address(permit3), amount);

        if (amount > 0) {
            permit3.transferFrom(onBehalfOf, address(this), loanToken, uint160(amount));
            SafeTransferLib.forceApprove(loanToken, broker, amount);
            // `repay(0, …)` ⇒ repay as much as our balance covers, refund the rest here.
            if (loanId == DYNAMIC_LOAN) {
                IListaBroker(broker).repay(0, onBehalfOf);
            } else {
                IListaBroker(broker).repay(0, loanId, onBehalfOf);
            }
            SafeTransferLib.forceApprove(loanToken, broker, 0);
        }

        uint256 residual = IERC20(loanToken).balanceOf(address(this));
        if (residual != 0) SafeTransferLib.safeTransfer(loanToken, onBehalfOf, residual);
        // (action reserved for a future in-position recycle; broker has no
        //  re-supply target, so residual always sweeps to the user.)
        action;

        _locked = 1;
    }
}

// ──────────────────── Lista combined taker module ────────────────────
//
// Fuses the FIXED-term broker borrow and the Moolah withdraw-collateral value-out
// legs behind a leading `op` flag. Borrow-data and withdraw-data hash to
// different `keccak256(data)` refs (separate amount-gated taker allowances); both
// legs share the one Moolah `setAuthorization(module)` grant, per-address by
// construction.
//
//   op = 0 (Broker borrow):  data = abi.encode(uint8(0), broker, termId)
//   op = 1 (Withdraw coll):   data = abi.encode(uint8(1), moolah, MarketParams[, BalanceMode])
//     — for op 1: op@0, moolah@32, MarketParams@64 (base = 224); BalanceMode@224.
//
contract ListaTakerModule is ITakerModule {
    using MarketParamsLib for MarketParams;

    IPermit3 public immutable permit3;

    enum Op {
        Borrow, // 0 — fixed-term broker borrow
        WithdrawCollateral // 1 — Moolah collateral
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
            (, address broker, uint256 termId) = abi.decode(data, (uint8, address, uint256));
            IListaBroker(broker).borrow(amount, termId, onBehalfOf, receiver);
        } else if (op == uint8(Op.WithdrawCollateral)) {
            (, address moolah, MarketParams memory mp) = abi.decode(data, (uint8, address, MarketParams));
            if (DustHandler.readBalanceMode(data, 224) == DustHandler.BalanceMode.Full) {
                _withdrawFull(moolah, mp, onBehalfOf, amount, receiver);
            } else {
                IMoolah(moolah).withdrawCollateral(mp, amount, onBehalfOf, receiver);
            }
        } else {
            revert BadOp(op);
        }
    }

    /// @dev Full mode: withdraw the user's entire collateral to this module,
    ///      forward the signed `amount` to `receiver`, sweep the excess back to
    ///      the user — always to `onBehalfOf`, never a caller.
    function _withdrawFull(address moolah, MarketParams memory mp, address onBehalfOf, uint256 amount, address receiver)
        private
    {
        address collateralToken = mp.collateralToken;
        uint256 bal = IMoolah(moolah).position(mp.id(), onBehalfOf).collateral;
        uint256 before = IERC20(collateralToken).balanceOf(address(this));
        IMoolah(moolah).withdrawCollateral(mp, bal, onBehalfOf, address(this));
        uint256 received = IERC20(collateralToken).balanceOf(address(this)) - before;
        require(received >= amount, "insufficient withdrawn");
        SafeTransferLib.safeTransfer(collateralToken, receiver, amount);
        if (received > amount) SafeTransferLib.safeTransfer(collateralToken, onBehalfOf, received - amount);
    }
}
