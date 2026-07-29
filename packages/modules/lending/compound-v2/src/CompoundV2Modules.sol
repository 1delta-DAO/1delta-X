// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {DustHandler} from "@core/dust/DustHandler.sol";
import {FullFillGuard} from "@core/utils/FullFillGuard.sol";

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {ICErc20} from "./interfaces/ICompoundV2.sol";

// ════════════════════════════════════════════════════════════════════════════
//  Compound v2 (vanilla cToken) modules — all ops EXCEPT borrow
//
//  Vanilla Compound v2 keys positions to `msg.sender` and, unlike Venus, has NO
//  `borrowBehalf`/delegation: borrowed funds and debt can only land on the caller.
//  A router therefore cannot borrow on a user's behalf, so this package ships no
//  borrow module — only the three ops that CAN act for the user:
//
//    deposit  → mint(amount)              cTokens minted to this module, then
//                                         forwarded to the user (the receipt token).
//    repay    → repayBorrowBehalf(user, amount)   the one native on-behalf call.
//    withdraw → redeemUnderlying(amount)  after pulling the user's cTokens via
//                                         Permit3 (the Aave-aToken pattern; cTokens
//                                         are NOT 1:1 with underlying, so the module
//                                         converts via the exchange rate).
//
//  Authorisation:
//   • deposit/repay are permissionless value-in — the module funds them; no grant.
//   • withdraw pulls the user's cTokens, so the user infinite-approves the cToken
//     to this module through Permit3 (mirrors Aave's aToken approval). The Permit3
//     taker allowance on `keccak256(data)` caps the per-fill underlying amount.
//
//  `data` for every module is `abi.encode(cToken, underlying)`.
//
//  Compound forks return a `uint` error code (0 == success); every call's code is
//  checked and reverts with `CompoundV2Error(code)` on failure.
// ════════════════════════════════════════════════════════════════════════════

// ──────────────────── Compound v2 deposit maker module ────────────────────
//
// Pulls `underlying` from the user via Permit3, `mint`s (cTokens land on THIS
// module — vanilla Compound v2 has no `mintBehalf`), then forwards the minted
// cTokens to the user, who holds the collateral receipt. `data = abi.encode(cToken, underlying)`.
//
contract CompoundV2DepositModule is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;

    error CompoundV2Error(uint256 code);
    error NotSettlement();

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();

        (address cToken, address underlying) = abi.decode(data, (address, address));

        permit3.transferFrom(onBehalfOf, address(this), underlying, uint160(amount));
        SafeTransferLib.forceApprove(underlying, cToken, amount);
        uint256 err = ICErc20(cToken).mint(amount);
        if (err != 0) revert CompoundV2Error(err);

        // cTokens were minted to this module — forward the receipt to the user.
        SafeTransferLib.safeTransfer(cToken, onBehalfOf, IERC20(cToken).balanceOf(address(this)));
    }
}

// ──────────────────── Compound v2 repay maker module ────────────────────
//
// Closes the user's borrow, handling interest-accrual over-repay with a
// pull-exact strategy: read the live debt and repay `min(amount, debt)` via
// `repayBorrowBehalf`. In SweepToUser the over-repay buffer is never pulled, so
// nothing sits in this module for a caller to redirect. On Recycle the module
// takes the full signed ceiling, repays, and re-supplies the surplus into the
// user's Compound position by `mint`-ing and forwarding the cTokens to the user
// (best-effort, with a guaranteed sweep fallback).
//
// Repay is permissionless on behalf of the user, so no grant is needed.
// `nonReentrant` guards weird-token transfer hooks.
// `data = abi.encode(cToken, underlying[, DustHandler.DustAction])` — trailing
// action optional; absent ⇒ SweepToUser.
//
contract CompoundV2RepayModule is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;

    uint256 private _locked = 1;

    error Reentrancy();
    error CompoundV2Error(uint256 code);
    error NotSettlement();

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();
        if (_locked != 1) revert Reentrancy();
        _locked = 2;

        (address cToken, address underlying) = abi.decode(data, (address, address));
        DustHandler.DustAction action = DustHandler.readAction(data, 64); // base = (address,address)

        _pullAndRepay(cToken, underlying, amount, onBehalfOf, action == DustHandler.DustAction.Recycle);
        _disposeResidual(cToken, underlying, onBehalfOf, action);

        _locked = 1;
    }

    /// @dev Pull the funding token and repay. SweepToUser pulls only `toRepay`, so
    ///      the buffer never enters this contract; Recycle pulls the full signed
    ///      ceiling so the surplus can be re-minted into the user's position.
    function _pullAndRepay(address cToken, address underlying, uint256 amount, address onBehalfOf, bool recycle)
        private
    {
        uint256 toRepay;
        {
            uint256 debt = ICErc20(cToken).borrowBalanceCurrent(onBehalfOf);
            toRepay = amount < debt ? amount : debt;
        }
        {
            uint256 toPull = recycle ? amount : toRepay;
            if (toPull > 0) permit3.transferFrom(onBehalfOf, address(this), underlying, uint160(toPull));
        }
        if (toRepay > 0) {
            SafeTransferLib.forceApprove(underlying, cToken, toRepay);
            uint256 err = ICErc20(cToken).repayBorrowBehalf(onBehalfOf, toRepay);
            if (err != 0) revert CompoundV2Error(err);
        }
    }

    /// @dev Dispose of any residual. Recycle re-supplies it as a cToken collateral
    ///      balance for the user — vanilla Compound v2 has no `mintBehalf`, so the
    ///      module mints to itself and forwards the receipt to the user. Because the
    ///      surplus is the RECEIPT token (not the underlying), this can't use
    ///      `DustHandler.disposeResidual` (which re-checks the underlying); it does
    ///      the equivalent best-effort recycle + sweep fallback inline. A
    ///      paused/failed mint leaves the underlying untouched and falls back to the
    ///      sweep floor.
    function _disposeResidual(address cToken, address underlying, address onBehalfOf, DustHandler.DustAction action)
        private
    {
        uint256 residual = IERC20(underlying).balanceOf(address(this));
        if (residual == 0) return;

        if (action == DustHandler.DustAction.Recycle) {
            SafeTransferLib.forceApprove(underlying, cToken, residual);
            (bool ok, bytes memory ret) = cToken.call(abi.encodeCall(ICErc20.mint, (residual)));
            SafeTransferLib.forceApprove(underlying, cToken, 0); // never leave a dangling allowance

            if (ok && (ret.length < 32 || abi.decode(ret, (uint256)) == 0)) {
                // Forward the freshly-minted cToken receipt to the user, then sweep
                // any underlying the mint didn't consume so the module ends empty.
                uint256 cBal = IERC20(cToken).balanceOf(address(this));
                if (cBal != 0) SafeTransferLib.safeTransfer(cToken, onBehalfOf, cBal);
                uint256 left = IERC20(underlying).balanceOf(address(this));
                if (left != 0) SafeTransferLib.safeTransfer(underlying, onBehalfOf, left);
                return;
            }
            // Mint reverted / returned an error (paused, deprecated market) — the
            // underlying was not consumed; fall through to the sweep floor.
        }

        SafeTransferLib.safeTransfer(underlying, onBehalfOf, residual);
    }
}

// ──────────────────── Compound v2 withdraw taker module ────────────────────
//
// Redeems collateral on the user's behalf. Vanilla Compound v2 has no redeem-on-
// behalf, so the module first pulls the user's cTokens via the Permit3 token
// allowance (the user infinite-approves the cToken to this module), then
// `redeemUnderlying`s and forwards the underlying to `receiver`.
//
// cTokens are NOT 1:1 with the underlying, so for the exact path the module reads
// the (accrued) exchange rate and pulls the ceiling number of cTokens needed to
// cover `amount`, redeems exactly `amount` underlying, and returns any 1-wei cToken
// remainder to the user.
//
// Optional `BalanceMode.Full` (trailing field): pull the user's ENTIRE cToken
// balance, `redeem` it all, forward the signed `amount` to `receiver`, and sweep
// the underlying excess back to the user. Fill-or-kill only, and only after debt
// is cleared — the close-flow withdraw leg.
//
// `data = abi.encode(cToken, underlying[, DustHandler.BalanceMode])`.
//
contract CompoundV2WithdrawModule is ITakerModule {
    IPermit3 public immutable permit3;

    error OnlyPermit3();
    error CompoundV2Error(uint256 code);

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data)
        external
        override
    {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        (address cToken, address underlying) = abi.decode(data, (address, address));

        if (DustHandler.readBalanceMode(data, 64) == DustHandler.BalanceMode.Full) {
            // `Full` liquidates the user's ENTIRE live balance, so it cannot be
            // pro-rated — a sliced fill would unwind the whole position and brick
            // the rest of the order. Require the slice to be the whole item.
            FullFillGuard.requireFullFillFromData(data, 96, amount);
            // Pull the user's entire cToken balance and redeem it all to this module;
            // forward the signed `amount`, sweep the underlying excess to the user.
            // Measure the underlying ACTUALLY received via a balanceOf snapshot around
            // the redeem (fee-on-transfer / non-standard underlyings can deliver less
            // than the nominal redeem), and require it covers the signed amount.
            uint256 cBal = IERC20(cToken).balanceOf(onBehalfOf);
            permit3.transferFrom(onBehalfOf, address(this), cToken, uint160(cBal));
            uint256 balBefore = IERC20(underlying).balanceOf(address(this));
            uint256 err = ICErc20(cToken).redeem(cBal);
            if (err != 0) revert CompoundV2Error(err);
            uint256 received = IERC20(underlying).balanceOf(address(this)) - balBefore;
            require(received >= amount, "insufficient withdrawn");
            SafeTransferLib.safeTransfer(underlying, receiver, amount);
            if (received > amount) SafeTransferLib.safeTransfer(underlying, onBehalfOf, received - amount);
        } else {
            // Pull the ceiling cTokens needed for `amount` underlying (rate accrued
            // to now == the rate `redeemUnderlying` will use this block), redeem
            // exactly `amount`, return any cToken remainder to the user.
            uint256 rate = ICErc20(cToken).exchangeRateCurrent();
            uint256 cAmount = (amount * 1e18 + rate - 1) / rate;
            permit3.transferFrom(onBehalfOf, address(this), cToken, uint160(cAmount));
            uint256 err = ICErc20(cToken).redeemUnderlying(amount);
            if (err != 0) revert CompoundV2Error(err);
            SafeTransferLib.safeTransfer(underlying, receiver, amount);
            uint256 leftC = IERC20(cToken).balanceOf(address(this));
            if (leftC != 0) SafeTransferLib.safeTransfer(cToken, onBehalfOf, leftC);
        }
    }
}
