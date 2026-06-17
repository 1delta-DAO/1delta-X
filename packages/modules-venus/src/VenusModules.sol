// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {DustHandler} from "@core/dust/DustHandler.sol";

import {IVToken} from "./interfaces/IVenus.sol";

// ════════════════════════════════════════════════════════════════════════════
//  Venus (expanded Compound v2) single-op modules
//
//  Plain Compound v2 keys every position to `msg.sender`, so a router can't act
//  on a user's behalf. Venus expands the fork with an explicit on-behalf layer,
//  which is exactly what lets these modules drive a USER's position while being
//  funded by / sending to the module itself — the same shape as the Comet/Euler
//  packages, just over Compound's four named calls:
//
//    deposit  → mintBehalf(user, amount)            (value in, permissionless)
//    repay    → repayBorrowBehalf(user, amount)     (value in, permissionless)
//    borrow   → borrowBehalf(user, amount)          (value out, delegated)
//    withdraw → redeemUnderlyingBehalf(user, amount)(value out, delegated)
//
//  Authorisation splits by direction, mirroring Comet's `allow`:
//   • value-in (deposit/repay): no grant needed — Venus lets anyone fund another
//     account's position. The module pulls the underlying from the user via
//     Permit3, approves the vToken, and the behalf-call credits/pays the user.
//   • value-out (borrow/withdraw): the user must once call
//     `comptroller.updateDelegate(module, true)`. Venus then routes the proceeds
//     to `msg.sender` (this module), which forwards them to `receiver`. The
//     Permit3 taker allowance is what caps the per-fill amount.
//
//  `data` for every module is `abi.encode(vToken, underlying)` — `underlying` is
//  pinned into the order/taker ref so the user signs exactly which token moves,
//  saving a `vToken.underlying()` call.
//
//  Compound forks return a `uint` error code (0 == success) instead of reverting
//  on protocol-state rejections, so every behalf-call's code is checked.
// ════════════════════════════════════════════════════════════════════════════

// ──────────────────── Venus deposit maker module ────────────────────
//
// Single-op module: pulls `underlying` from the user via Permit3, then mints
// vTokens to the user via `mintBehalf` (collateral supply). Permissionless on
// behalf of the user — no delegation needed. `data = abi.encode(vToken, underlying)`.
//
contract VenusDepositModule is IMakerModule {
    IPermit3 public immutable permit3;

    error VenusError(uint256 code);

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        (address vToken, address underlying) = abi.decode(data, (address, address));

        permit3.transferFrom(onBehalfOf, address(this), underlying, uint160(amount));
        IERC20(underlying).approve(vToken, amount);
        uint256 err = IVToken(vToken).mintBehalf(onBehalfOf, amount);
        if (err != 0) revert VenusError(err);
    }
}

// ──────────────────── Venus repay maker module ────────────────────
//
// Closes the user's borrow, handling interest-accrual over-repay with a
// pull-exact strategy: read the live debt and repay `min(amount, debt)`. In
// SweepToUser the over-repay buffer is never pulled, so nothing sits in this
// module for a caller to redirect. On Recycle the module takes the full signed
// ceiling, repays, and re-supplies the surplus into the user's Venus position
// via `mintBehalf` (best-effort, sweep fallback).
//
// Repay is permissionless on behalf of the user, so no delegation is needed.
// `nonReentrant` guards weird-token transfer hooks.
// `data = abi.encode(vToken, underlying[, DustHandler.DustAction])` — trailing
// action optional; absent ⇒ SweepToUser.
//
contract VenusRepayModule is IMakerModule {
    IPermit3 public immutable permit3;

    uint256 private _locked = 1;

    error Reentrancy();
    error VenusError(uint256 code);

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;

        (address vToken, address underlying) = abi.decode(data, (address, address));
        DustHandler.DustAction action = DustHandler.readAction(data, 64); // base = (address,address)

        _pullAndRepay(vToken, underlying, amount, onBehalfOf, action == DustHandler.DustAction.Recycle);
        _disposeResidual(vToken, underlying, onBehalfOf, action);

        _locked = 1;
    }

    /// @dev Pull the funding token and repay. SweepToUser pulls only `toRepay`, so
    ///      the buffer never enters this contract; Recycle pulls the full signed
    ///      ceiling so the surplus can be re-minted into the user's position.
    function _pullAndRepay(address vToken, address underlying, uint256 amount, address onBehalfOf, bool recycle)
        private
    {
        uint256 toRepay;
        {
            uint256 debt = IVToken(vToken).borrowBalanceCurrent(onBehalfOf);
            toRepay = amount < debt ? amount : debt;
        }
        {
            uint256 toPull = recycle ? amount : toRepay;
            if (toPull > 0) permit3.transferFrom(onBehalfOf, address(this), underlying, uint160(toPull));
        }
        if (toRepay > 0) {
            IERC20(underlying).approve(vToken, toRepay);
            uint256 err = IVToken(vToken).repayBorrowBehalf(onBehalfOf, toRepay);
            if (err != 0) revert VenusError(err);
        }
    }

    /// @dev Re-supply (opt-in) the residual as a vToken collateral balance for the
    ///      user via `mintBehalf`, else sweep to the user. Best-effort recycle with
    ///      a guaranteed sweep fallback (a paused/capped mint returns an error code,
    ///      consumes nothing, and the untouched residual is swept).
    function _disposeResidual(address vToken, address underlying, address onBehalfOf, DustHandler.DustAction action)
        private
    {
        uint256 residual = IERC20(underlying).balanceOf(address(this));
        if (residual == 0) return;
        DustHandler.disposeResidual(
            underlying,
            residual,
            onBehalfOf,
            action,
            vToken,
            abi.encodeCall(IVToken.mintBehalf, (onBehalfOf, residual))
        );
    }
}

// ──────────────────── Venus take base (withdraw / borrow) ────────────────────
//
// Shared scaffolding for the value-out modules. Unlike Comet (where withdraw and
// borrow are the same `withdrawFrom` call) Venus splits them across distinct
// vToken calls, so each taker contract carries its own body; the base only holds
// the Permit3 gate and shared errors. Venus sends value-out proceeds to
// `msg.sender` (this module), so each body forwards them on to `receiver`.
//
// The user must have called `comptroller.updateDelegate(module, true)`. The
// `msg.sender == permit3` gate stops a direct `takeOnBehalf` from spending the
// victim's delegation outside the Permit3 allowance.
//
abstract contract VenusTakeBase is ITakerModule {
    IPermit3 public immutable permit3;

    error OnlyPermit3();
    error VenusError(uint256 code);

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }
}

// ──────────────────── Venus borrow taker module ────────────────────
//
// Borrow the underlying on the user's behalf via `borrowBehalf` (debt recorded
// on the user, proceeds to this module) and forward to `receiver`. Requires the
// user's `updateDelegate`. `data = abi.encode(vToken, underlying)`.
//
contract VenusBorrowModule is VenusTakeBase {
    constructor(address _permit3) VenusTakeBase(_permit3) {}

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data)
        external
        override
    {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        (address vToken, address underlying) = abi.decode(data, (address, address));

        uint256 err = IVToken(vToken).borrowBehalf(onBehalfOf, amount);
        if (err != 0) revert VenusError(err);
        IERC20(underlying).transfer(receiver, amount);
    }
}

// ──────────────────── Venus withdraw taker module ────────────────────
//
// Redeem collateral on the user's behalf and forward to `receiver`. Requires the
// user's `updateDelegate`.
//
// Default (Exact): `redeemUnderlyingBehalf(user, amount)` → forward `amount`.
//
// Optional `BalanceMode.Full` (trailing field): redeem the user's ENTIRE vToken
// balance (`redeemBehalf` of `balanceOf`), forward the signed `amount` to
// `receiver`, and sweep the underlying excess back to the user. Fill-or-kill
// only, and only after debt is cleared — the close-flow withdraw leg.
//
// `data = abi.encode(vToken, underlying[, DustHandler.BalanceMode])`.
//
contract VenusWithdrawModule is VenusTakeBase {
    constructor(address _permit3) VenusTakeBase(_permit3) {}

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data)
        external
        override
    {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        (address vToken, address underlying) = abi.decode(data, (address, address));

        if (DustHandler.readBalanceMode(data, 64) == DustHandler.BalanceMode.Full) {
            // Redeem the user's entire vToken balance to this module, forward the
            // signed `amount` to the order, sweep the underlying excess to the user.
            uint256 vBal = IVToken(vToken).balanceOf(onBehalfOf);
            uint256 err = IVToken(vToken).redeemBehalf(onBehalfOf, vBal);
            if (err != 0) revert VenusError(err);
            uint256 got = IERC20(underlying).balanceOf(address(this));
            IERC20(underlying).transfer(receiver, amount);
            if (got > amount) IERC20(underlying).transfer(onBehalfOf, got - amount);
        } else {
            uint256 err = IVToken(vToken).redeemUnderlyingBehalf(onBehalfOf, amount);
            if (err != 0) revert VenusError(err);
            IERC20(underlying).transfer(receiver, amount);
        }
    }
}
