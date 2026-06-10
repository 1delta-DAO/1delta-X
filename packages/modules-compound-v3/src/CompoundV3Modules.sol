// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";

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
// `data = abi.encode(comet, asset)`.
//
contract CometDepositModule is IMakerModule {
    IPermit3 public immutable permit3;

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        (address comet, address asset) = abi.decode(data, (address, address));

        permit3.transferFrom(onBehalfOf, address(this), asset, uint160(amount));
        IERC20(asset).approve(comet, amount);
        IComet(comet).supplyTo(onBehalfOf, asset, amount);
    }
}

// ──────────────────── Comet repay maker module ────────────────────
//
// Handles interest-accrual over-repay cleanly. Unlike Aave's `repay`, Comet's
// `supplyTo` does NOT cap at the outstanding debt — any excess silently becomes
// a positive base *supply* balance. So to preserve the maker's intent ("close
// my debt, give me back the rest") this module caps explicitly:
//
//   1. Pulls `amount` (a user-signed buffered value) from the user via Permit3.
//   2. Reads the live debt and supplies only `min(amount, debt)` — never
//      converting over-repay into a supply position.
//   3. Sweeps the residual back to `onBehalfOf` (the function argument, never a
//      field of `data`) — closing the "anyone can redirect dust" vector without
//      a `msg.sender == permit3` gate, exactly as the Aave repay module does.
//
// `nonReentrant` guards against weird-token transfer hooks.
// `data = abi.encode(comet, asset)`  (asset = the market's base token).
//
contract CometRepayModule is IMakerModule {
    IPermit3 public immutable permit3;

    uint256 private _locked = 1;

    error Reentrancy();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;

        (address comet, address asset) = abi.decode(data, (address, address));

        permit3.transferFrom(onBehalfOf, address(this), asset, uint160(amount));

        // Cap the repay at the live debt so surplus is refunded, not turned into
        // a supply position the maker never asked for.
        uint256 debt = IComet(comet).borrowBalanceOf(onBehalfOf);
        uint256 toRepay = amount < debt ? amount : debt;
        if (toRepay > 0) {
            IERC20(asset).approve(comet, toRepay);
            IComet(comet).supplyTo(onBehalfOf, asset, toRepay);
        }

        // Sweep residual (the over-repay buffer) back to the user. `balanceOf`
        // avoids depending on Comet's rounding.
        uint256 residual = IERC20(asset).balanceOf(address(this));
        if (residual > 0) IERC20(asset).transfer(onBehalfOf, residual);

        _locked = 1;
    }
}

// ──────────────────── Comet take base (withdraw / borrow) ────────────────────
//
// Withdrawing collateral and borrowing base are the SAME Comet call
// (`withdrawFrom`), so both taker modules share this body. Permit3 decrements
// the taker allowance on `keccak256(data)` and then invokes `takeOnBehalf`;
// `withdrawFrom` sends the asset straight to `receiver`.
//
// The maker must have called `comet.allow(module, true)` so Comet itself
// permits this module to act on their position. The Permit3 taker allowance is
// what actually caps the fill size.
//
// `data = abi.encode(comet, asset)`.
//
abstract contract CometTakeBase is ITakerModule {
    IPermit3 public immutable permit3;

    error OnlyPermit3();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        (address comet, address asset) = abi.decode(data, (address, address));

        // Withdraws collateral, or borrows base when `amount` exceeds the base
        // supply. Proceeds land directly at `receiver` (Settlement by default).
        IComet(comet).withdrawFrom(onBehalfOf, receiver, asset, amount);
    }
}

// ──────────────────── Comet withdraw taker module ────────────────────
//
// Withdraw collateral on the maker's behalf. `data`'s `asset` is a collateral
// token of the market.
//
contract CometWithdrawModule is CometTakeBase {
    constructor(address _permit3) CometTakeBase(_permit3) {}
}

// ──────────────────── Comet borrow taker module ────────────────────
//
// Borrow the market's base asset on the maker's behalf (a base `withdrawFrom`
// past the supply balance). `data`'s `asset` is the market's base token. A
// distinct contract from the withdraw module purely so the two legs occupy
// separate Permit3 module namespaces — the on-chain call is identical.
//
contract CometBorrowModule is CometTakeBase {
    constructor(address _permit3) CometTakeBase(_permit3) {}
}
