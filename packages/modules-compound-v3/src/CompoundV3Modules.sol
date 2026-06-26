// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {DustHandler} from "@core/dust/DustHandler.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {PermitHelper} from "@core/utils/PermitHelper.sol";
import {DelegationHelper} from "@core/utils/DelegationHelper.sol";

import {IComet} from "./interfaces/ICompoundV3.sol";

// ════════════════════════════════════════════════════════════════════════════
//  Compound v3 (Comet) single-op modules
//
//  Comet collapses Aave's four actions onto two calls — `supplyTo` (value in)
//  and `withdrawFrom` (value out) — because a market unifies (collateral, base)
//  and (supply, repay) and (withdraw, borrow). For 1:1 symmetry with the Aave
//  package we still expose four NAMED modules; under the hood deposit and repay
//  both supply, withdraw and borrow both withdraw. The distinct addresses give
//  each leg its own Permit3 module/ref namespace, exactly like Aave.
//
//  `data` for every module is `abi.encode(comet, asset)` — no rateMode (Comet
//  has a single rate) and no receipt token (positions are internal to Comet).
// ════════════════════════════════════════════════════════════════════════════

// ──────────────────── Comet deposit maker module ────────────────────
//
// Single-op module: pulls `asset` from the user via Permit3, then supplies it
// into `comet` on the user's behalf as collateral (or as base lend). Pool-
// agnostic — the same module drives any Comet market via `data`.
//
// Optional EIP-2612 permit replay for gasless deposits.
// `data = abi.encode(comet, asset[, deadline, v, r, s])`.
//
contract CometDepositModule is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;

    error NotSettlement();

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();

        (address comet, address asset) = abi.decode(data, (address, address));

        // Optional permit. base = (address,address) = 64 bytes.
        PermitHelper.replayIfPresent(data, 64, asset, onBehalfOf, address(permit3), amount);

        permit3.transferFrom(onBehalfOf, address(this), asset, uint160(amount));
        SafeTransferLib.forceApprove(asset, comet, amount);
        IComet(comet).supplyTo(onBehalfOf, asset, amount);
    }
}

// ──────────────────── Comet repay maker module ────────────────────
//
// Handles interest-accrual over-repay cleanly. Unlike Aave's `repay`, Comet's
// `supplyTo` does NOT cap at the outstanding debt — any excess silently becomes
// a positive base *supply* balance. So to preserve the maker's intent ("close
// my debt") this module reads the live debt up front and pulls only what it
// needs:
//
//   1. Read the live debt and compute `toRepay = min(amount, debt)`, where
//      `amount` is the maker-signed ceiling.
//   2. Pull exactly `toRepay` from the user via Permit3 and `supplyTo` it.
//
// In the default (SweepToUser) mode the over-repay buffer is never pulled, so no
// surplus sits in this module — there is nothing for a caller to redirect, which
// removes that vector at the source without a `msg.sender == permit3` gate. When
// `data` opts into Recycle, the module takes custody of the full signed ceiling
// and, after repaying, re-supplies the surplus into the user's Comet position (a
// positive base balance), best-effort with a guaranteed sweep fallback. Either
// way disposal is locked to `onBehalfOf` / comet, never a caller-chosen address.
//
// `nonReentrant` guards against weird-token transfer hooks.
// `data = abi.encode(comet, asset[, DustHandler.DustAction[, deadline, v, r, s]])`.
// Dust action optional (absent ⇒ SweepToUser); permit block optional after it.
//
contract CometRepayModule is IMakerModule {
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

        (address comet, address asset) = abi.decode(data, (address, address));
        // base = (address,address) = 64 bytes; DustAction at 64, permit at 96.
        DustHandler.DustAction action = DustHandler.readAction(data, 64);
        PermitHelper.replayIfPresent(data, 96, asset, onBehalfOf, address(permit3), amount);

        _pullAndRepay(comet, asset, amount, onBehalfOf, action == DustHandler.DustAction.Recycle);

        // Dispose of any residual: re-supplied into the user's position (Recycle,
        // best-effort with sweep fallback) or swept to the user (default), never
        // to a caller-controlled address.
        _disposeResidual(comet, asset, onBehalfOf, action);

        _locked = 1;
    }

    /// @dev Pull the funding token and repay (a `supplyTo` that pays down debt).
    ///      SweepToUser pulls only what the debt needs — the buffer is never
    ///      pulled and the surplus stays in the maker's wallet. Recycle takes
    ///      custody of the full signed ceiling so the surplus can be redirected
    ///      into the user's Comet position by `_disposeResidual`; disposal stays
    ///      locked to `onBehalfOf` / comet, never a caller.
    function _pullAndRepay(address comet, address asset, uint256 amount, address onBehalfOf, bool recycle) private {
        uint256 toRepay;
        {
            uint256 debt = IComet(comet).borrowBalanceOf(onBehalfOf);
            toRepay = amount < debt ? amount : debt;
        }
        {
            uint256 toPull = recycle ? amount : toRepay;
            if (toPull > 0) permit3.transferFrom(onBehalfOf, address(this), asset, uint160(toPull));
        }
        if (toRepay > 0) {
            SafeTransferLib.forceApprove(asset, comet, toRepay);
            IComet(comet).supplyTo(onBehalfOf, asset, toRepay);
        }
    }

    /// @dev Re-supply (opt-in) the residual into the user's Comet position (a
    ///      positive base balance), else sweep to the user. Best-effort recycle
    ///      with a guaranteed sweep fallback.
    function _disposeResidual(address comet, address asset, address onBehalfOf, DustHandler.DustAction action)
        private
    {
        uint256 residual = IERC20(asset).balanceOf(address(this));
        if (residual == 0) return;
        DustHandler.disposeResidual(
            asset,
            residual,
            onBehalfOf,
            action,
            comet,
            abi.encodeCall(IComet.supplyTo, (onBehalfOf, asset, residual))
        );
    }
}

// ──────────────────── Comet take base (withdraw / borrow) ────────────────────
//
// Withdrawing collateral and borrowing base are the SAME Comet call
// (`withdrawFrom`), so both taker modules share this body. Permit3 decrements
// the taker allowance on `keccak256(data)` and then invokes `takeOnBehalf`;
// `withdrawFrom` sends the asset straight to `receiver`.
//
// The maker must have called `comet.allow(module, true)` — or included an
// `allowBySig` block in `data` (see CometBorrowModule / CometWithdrawModule) —
// so Comet permits this module to act on their position.
//
// `data = abi.encode(comet, asset)`.
//
abstract contract CometTakeBase is ITakerModule {
    IPermit3 public immutable permit3;

    error OnlyPermit3();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data)
        external
        virtual
        override
    {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        (address comet, address asset) = abi.decode(data, (address, address));

        IComet(comet).withdrawFrom(onBehalfOf, receiver, asset, amount);
    }
}

// ──────────────────── Comet withdraw taker module ────────────────────
//
// Withdraw collateral on the maker's behalf. `data`'s `asset` is a collateral
// token of the market.
//
// Optional `BalanceMode.Full` (trailing field): withdraw the user's ENTIRE
// collateral balance, forward the signed `amount` to `receiver`, and sweep the
// excess back to `onBehalfOf`. Fill-or-kill only, after debt is cleared.
//
// Optional EIP-712 allow-by-sig: appending an allow block grants this module
// `withdrawFrom` rights on-the-fly — no prior on-chain `allow(module, true)`.
// The BalanceMode slot MUST be encoded explicitly (as 0 = Exact) when including
// the allow block so offsets are unambiguous.
//
// `data = abi.encode(comet, asset[, BalanceMode[, nonce, expiry, v, r, s]])`
//   — BalanceMode at 64, allow-by-sig block at 96 (5 × 32 = 160 bytes).
//
contract CometWithdrawModule is CometTakeBase {
    constructor(address _permit3) CometTakeBase(_permit3) {}

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data)
        external
        override
    {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        (address comet, address asset) = abi.decode(data, (address, address));

        // Optional Comet allow-by-sig at offset 96 (after BalanceMode slot at 64).
        DelegationHelper.replayCometAllow(data, 96, comet, onBehalfOf, address(this));

        if (DustHandler.readBalanceMode(data, 64) == DustHandler.BalanceMode.Full) {
            uint256 bal = IComet(comet).collateralBalanceOf(onBehalfOf, asset);
            uint256 beforeBal = IERC20(asset).balanceOf(address(this));
            IComet(comet).withdrawFrom(onBehalfOf, address(this), asset, bal);
            uint256 received = IERC20(asset).balanceOf(address(this)) - beforeBal;
            require(received >= amount, "insufficient withdrawn");
            SafeTransferLib.safeTransfer(asset, receiver, amount);
            if (received > amount) SafeTransferLib.safeTransfer(asset, onBehalfOf, received - amount);
        } else {
            IComet(comet).withdrawFrom(onBehalfOf, receiver, asset, amount);
        }
    }
}

// ──────────────────── Comet borrow taker module ────────────────────
//
// Borrow the market's base asset on the maker's behalf (a base `withdrawFrom`
// past the supply balance). `data`'s `asset` is the market's base token. A
// distinct contract from the withdraw module so the two legs have separate
// Permit3 module namespaces.
//
// Optional EIP-712 allow-by-sig: appending an allow block grants this module
// `withdrawFrom` rights on-the-fly — no prior on-chain `allow(module, true)`.
//
// `data = abi.encode(comet, asset[, nonce, expiry, v, r, s])`
//   — base = 64 bytes, allow-by-sig block at 64 (5 × 32 = 160 bytes).
//
contract CometBorrowModule is CometTakeBase {
    constructor(address _permit3) CometTakeBase(_permit3) {}

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data)
        external
        override
    {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        (address comet, address asset) = abi.decode(data, (address, address));

        // Optional Comet allow-by-sig at offset 64 (base = (comet, asset) = 64 bytes).
        DelegationHelper.replayCometAllow(data, 64, comet, onBehalfOf, address(this));

        IComet(comet).withdrawFrom(onBehalfOf, receiver, asset, amount);
    }
}
