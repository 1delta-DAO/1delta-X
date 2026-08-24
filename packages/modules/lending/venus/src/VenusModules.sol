// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {DustHandler} from "@lib/DustHandler.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

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
//     Permit3 taker allowance is what caps the per-fill amount. Both value-out
//     legs are fused into a single `VenusTakerModule`, multiplexed by a leading
//     `uint8 op` flag, so one delegation covers the whole leverage round-trip.
//
//  Maker `data` is `abi.encode(vToken, underlying)`; taker `data` is op-prefixed:
//  `abi.encode(uint8 op, vToken, underlying[, BalanceMode])`. `underlying` is
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
    using SafeTransferLib for address;

    IPermit3 public immutable permit3;
    address public immutable settlement;

    error VenusError(uint256 code);
    error NotSettlement();

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();

        (address vToken, address underlying) = abi.decode(data, (address, address));

        permit3.transferFrom(onBehalfOf, address(this), underlying, uint160(amount));
        underlying.forceApprove(vToken, amount);
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
    using SafeTransferLib for address;

    IPermit3 public immutable permit3;
    address public immutable settlement;

    uint256 private _locked = 1;

    error Reentrancy();
    error VenusError(uint256 code);
    error NotSettlement();

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();
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
            underlying.forceApprove(vToken, toRepay);
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
            underlying, residual, onBehalfOf, action, vToken, abi.encodeCall(IVToken.mintBehalf, (onBehalfOf, residual))
        );
    }
}

// ──────────────────── Venus combined taker module ────────────────────
//
// Fuses the Venus borrow and withdraw value-out legs into a SINGLE contract. A
// leading `op` flag in `data` selects the leg, so a user who runs the full
// leverage round-trip delegates ONE module address instead of two — a single
// `comptroller.updateDelegate(this, true)` covers both `borrowBehalf` and the
// `redeem*Behalf` calls. Unlike Comet (where withdraw and borrow are the same
// `withdrawFrom` call) Venus splits them across distinct vToken calls, so each
// leg carries its own body; Venus sends value-out proceeds to `msg.sender` (this
// module), so each body forwards them on to `receiver`.
//
// The user must have called `comptroller.updateDelegate(module, true)`. The
// `msg.sender == permit3` gate stops a direct `takeOnBehalf` from spending the
// victim's delegation outside the Permit3 allowance.
//
// Safety is unchanged from the split modules: the Permit3 taker allowance is
// keyed by `ref = keccak256(data)`, and `op` is the first word of `data`, so
// borrow-data and withdraw-data hash to DIFFERENT refs. The user therefore still
// grants a separate amount-gated allowance per leg — the flag cannot be flipped
// to spend a borrow allowance on a withdraw (or vice-versa). The only thing
// shared is the coarse Venus delegation boolean, which is per-address.
//
//   byte-map (op first; old single-op offsets shift +32):
//     op@0, vToken@32, underlying@64 — base = 96 bytes.
//
//   op = 0 (Borrow):
//     data = abi.encode(uint8(0), vToken, underlying)            — base = 96.
//       → `borrowBehalf(user, amount)` → forward `amount` to `receiver`.
//
//   op = 1 (Withdraw):
//     data = abi.encode(uint8(1), vToken, underlying[, BalanceMode])
//       — BalanceMode slot at byte 96.
//       → Exact: `redeemUnderlyingBehalf(user, amount)` → forward `amount`.
//       → Full:  `redeemBehalf(user, balanceOf)` to this module, forward the
//         signed `amount`, sweep the underlying excess back to the user.
//
contract VenusTakerModule is ITakerModule {
    using SafeTransferLib for address;

    IPermit3 public immutable permit3;

    enum Op {
        Borrow, // 0
        Withdraw // 1
    }

    error OnlyPermit3();
    error VenusError(uint256 code);
    error InsufficientWithdrawn();
    error BadOp(uint8 op);

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        // op@0, vToken@32, underlying@64 — all static, so a prefix decode is sound
        // even when op-specific trailing fields follow. An out-of-range op reverts.
        (uint8 op, address vToken, address underlying) = abi.decode(data, (uint8, address, address));

        if (op == uint8(Op.Borrow)) {
            uint256 err = IVToken(vToken).borrowBehalf(onBehalfOf, amount);
            if (err != 0) revert VenusError(err);
            underlying.safeTransfer(receiver, amount);
        } else if (op == uint8(Op.Withdraw)) {
            // BalanceMode slot at byte 96 (op@0 + vToken@32 + underlying@64).
            if (DustHandler.readBalanceMode(data, 96) == DustHandler.BalanceMode.Full) {
                // `Full` liquidates the user's ENTIRE live balance, so it cannot be
                // pro-rated — a sliced fill would unwind the whole position and brick
                // the rest of the order. Require the slice to be the whole item.
                FullFillGuard.requireFullFillFromData(data, 128, amount);
                // Redeem the user's entire vToken balance to this module, forward the
                // signed `amount` to the order, sweep the underlying excess to the user.
                // Measure the actually-received underlying via a balanceOf snapshot
                // around the redeem (the vToken credits this module), so a fee-on-transfer
                // or rounding shortfall can't silently forward more than was received.
                uint256 vBal = IVToken(vToken).balanceOf(onBehalfOf);
                uint256 balBefore = IERC20(underlying).balanceOf(address(this));
                uint256 err = IVToken(vToken).redeemBehalf(onBehalfOf, vBal);
                if (err != 0) revert VenusError(err);
                uint256 received = IERC20(underlying).balanceOf(address(this)) - balBefore;
                if (received < amount) revert InsufficientWithdrawn();
                underlying.safeTransfer(receiver, amount);
                if (received > amount) underlying.safeTransfer(onBehalfOf, received - amount);
            } else {
                uint256 err = IVToken(vToken).redeemUnderlyingBehalf(onBehalfOf, amount);
                if (err != 0) revert VenusError(err);
                underlying.safeTransfer(receiver, amount);
            }
        } else {
            revert BadOp(op);
        }
    }
}
