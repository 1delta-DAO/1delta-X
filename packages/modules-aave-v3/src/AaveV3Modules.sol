// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {DustHandler} from "@core/dust/DustHandler.sol";

import {IAaveV3Pool} from "./interfaces/IAaveV3.sol";

// ──────────────────── Aave v3 deposit maker module ────────────────────
//
// Single-op module: pulls `asset` from the user via Permit3, then supplies
// on the user's behalf. `data = abi.encode(pool, asset)`.
//
contract AaveV3DepositModule is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;

    error NotSettlement();

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();

        (address pool, address asset) = abi.decode(data, (address, address));

        permit3.transferFrom(onBehalfOf, address(this), asset, uint160(amount));
        SafeTransferLib.forceApprove(asset, pool, amount);
        IAaveV3Pool(pool).supply(asset, amount, onBehalfOf, 0);
    }
}

// ──────────────────── Aave v3 repay maker module ────────────────────
//
// Handles interest-accrual over-repay cleanly with a pull-exact strategy:
//
//   1. Read the user's live debt — `IERC20(debtToken).balanceOf(user)`, where
//      `debtToken` is the variable/stable debt token matching `rateMode` — and
//      compute `toRepay = min(amount, debt)` (`amount` = maker-signed ceiling).
//   2. Pull exactly `toRepay` from the user via Permit3 and
//      `pool.repay(asset, toRepay, rateMode, user)`.
//
// In the default (SweepToUser) mode the over-repay buffer is never pulled, so no
// dust is created and nothing sits in this contract for a caller to redirect —
// the "anyone can call this and redirect dust" vector is removed at the source,
// without a `msg.sender == permit3` gate. When the maker-signed `data` opts into
// Recycle, the module instead takes custody of the full signed ceiling and, after
// repaying, re-supplies the surplus into the user's Aave position (best-effort,
// with a guaranteed sweep fallback if the supply reverts — cap reached, frozen,
// paused). Either way disposal is locked to `onBehalfOf` / the pool, never a
// caller-chosen address, so the redirect vector stays closed. The debt token
// lives in `data` (so it is maker-signed) rather than being derived from a
// version-fragile `getReserveData` layout.
//
// `nonReentrant` guards against weird-token transfer hooks.
// `data = abi.encode(pool, asset, rateMode, debtToken[, DustHandler.DustAction])`
// — the trailing dust action is optional; absent ⇒ SweepToUser.
//
contract AaveV3RepayModule is IMakerModule {
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

        // Decode only (pool, asset) here — both are needed for the dust step
        // below. The pull+repay runs in its own frame so its locals don't pile up
        // on the stack (avoids stack-too-deep). The base tuple is all-static, so a
        // prefix decode is sound.
        (address pool, address asset) = abi.decode(data, (address, address));
        DustHandler.DustAction action = DustHandler.readAction(data, 128); // base = (address,address,uint256,address)

        _pullAndRepay(data, amount, onBehalfOf, asset, pool, action == DustHandler.DustAction.Recycle);

        _disposeResidual(pool, asset, onBehalfOf, action);

        _locked = 1;
    }

    /// @dev Pull the funding token and repay. SweepToUser pulls only what the
    ///      debt needs — the over-repay buffer is never pulled, so the surplus
    ///      stays in the maker's wallet (the solver paid `tokenOut` straight to
    ///      them). Recycle takes custody of the full signed ceiling so the surplus
    ///      can be redirected into the user's position by `_disposeResidual`;
    ///      disposal stays locked to `onBehalfOf` / the pool, never a caller.
    function _pullAndRepay(
        bytes calldata data,
        uint256 amount,
        address onBehalfOf,
        address asset,
        address pool,
        bool recycle
    ) private {
        uint256 rateMode;
        uint256 toRepay;
        {
            address debtToken;
            (,, rateMode, debtToken) = abi.decode(data, (address, address, uint256, address));
            uint256 debt = IERC20(debtToken).balanceOf(onBehalfOf);
            toRepay = amount < debt ? amount : debt;
        }
        {
            uint256 toPull = recycle ? amount : toRepay;
            if (toPull > 0) permit3.transferFrom(onBehalfOf, address(this), asset, uint160(toPull));
        }
        if (toRepay > 0) {
            SafeTransferLib.forceApprove(asset, pool, toRepay);
            IAaveV3Pool(pool).repay(asset, toRepay, rateMode, onBehalfOf);
        }
    }

    /// @dev Dispose of any residual: re-supply into the user's Aave position
    ///      (Recycle, best-effort with a guaranteed sweep fallback) or sweep to
    ///      the user (default). In its own frame to keep the stack shallow.
    function _disposeResidual(address pool, address asset, address onBehalfOf, DustHandler.DustAction action)
        private
    {
        uint256 residual = IERC20(asset).balanceOf(address(this));
        if (residual == 0) return;
        DustHandler.disposeResidual(
            asset,
            residual,
            onBehalfOf,
            action,
            pool,
            abi.encodeCall(IAaveV3Pool.supply, (asset, residual, onBehalfOf, 0))
        );
    }
}

// ──────────────────── Aave v3 withdraw taker module ────────────────────
//
// Single-op taker module. Permit3 decrements the taker allowance on
// `keccak256(data)`, then invokes `takeOnBehalf` here. The module pulls
// the user's aToken via the Permit3 token allowance (the user infinite-
// approves the aToken to this module), then calls `pool.withdraw` which
// burns the module's aTokens and sends the underlying to `receiver`.
//
// Optional `BalanceMode.Full` (trailing field): withdraw the user's ENTIRE
// (rebasing) aToken balance, forward the signed `amount` to `receiver`, and
// sweep the accrued excess back to `onBehalfOf` — the TAKE-side mirror of the
// over-repay refund. Fill-or-kill only, and only after debt is cleared.
//
// `data = abi.encode(pool, asset, aToken[, DustHandler.BalanceMode])`.
//
contract AaveV3WithdrawModule is ITakerModule {
    IPermit3 public immutable permit3;

    error OnlyPermit3();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        (address pool, address asset, address aToken) = abi.decode(data, (address, address, address));

        if (DustHandler.readBalanceMode(data, 96) == DustHandler.BalanceMode.Full) {
            // Pull the user's entire (rebasing) aToken balance and withdraw it all
            // to this module; `withdraw(max)` mops up any 1-wei transfer rounding.
            // Measure the actually-received underlying via a balanceOf snapshot —
            // never trust the static `amount` against the pool's return value.
            uint256 bal = IERC20(aToken).balanceOf(onBehalfOf);
            permit3.transferFrom(onBehalfOf, address(this), aToken, uint160(bal));
            uint256 beforeBal = IERC20(asset).balanceOf(address(this));
            IAaveV3Pool(pool).withdraw(asset, type(uint256).max, address(this));
            uint256 received = IERC20(asset).balanceOf(address(this)) - beforeBal;
            require(received >= amount, "insufficient withdrawn");
            // Order flow gets `amount`; the accrued excess returns to the user.
            SafeTransferLib.safeTransfer(asset, receiver, amount);
            if (received > amount) SafeTransferLib.safeTransfer(asset, onBehalfOf, received - amount);
        } else {
            permit3.transferFrom(onBehalfOf, address(this), aToken, uint160(amount));
            IAaveV3Pool(pool).withdraw(asset, amount, receiver);
        }
    }
}

// ──────────────────── Aave v3 borrow taker module ────────────────────
//
// Single-op taker module. Issues a variable-rate borrow on behalf of the
// user and forwards proceeds to `receiver`. The user must have called
// `approveDelegation(module, cap)` on the relevant Aave variableDebtToken
// so Aave itself permits the module to incur debt on their account.
//
// `data = abi.encode(pool, asset, rateMode)`  (rateMode: 2 = variable)
//
contract AaveV3BorrowModule is ITakerModule {
    IPermit3 public immutable permit3;

    error OnlyPermit3();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        (address pool, address asset, uint256 rateMode) = abi.decode(data, (address, address, uint256));

        // Borrow lands `amount` of `asset` at `msg.sender` (this module).
        IAaveV3Pool(pool).borrow(asset, amount, rateMode, 0, onBehalfOf);
        // Forward to Permit3's requested receiver (Settlement in our flow).
        SafeTransferLib.safeTransfer(asset, receiver, amount);
    }
}
