// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";

import {IAaveV3Pool} from "./interfaces/IAaveV3.sol";

// ──────────────────── Aave v3 deposit maker module ────────────────────
//
// Single-op module: pulls `asset` from the user via Permit3, then supplies
// on the user's behalf. `data = abi.encode(pool, asset)`.
//
contract AaveV3DepositModule is IMakerModule {
    IPermit3 public immutable permit3;

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        (address pool, address asset) = abi.decode(data, (address, address));

        permit3.transferFrom(onBehalfOf, address(this), asset, uint160(amount));
        IERC20(asset).approve(pool, amount);
        IAaveV3Pool(pool).supply(asset, amount, onBehalfOf, 0);
    }
}

// ──────────────────── Aave v3 repay maker module ────────────────────
//
// Handles interest-accrual over-repay cleanly:
//
//   1. Pulls `amount` (a user-signed buffered value) from the user via Permit3.
//   2. Calls `pool.repay(asset, amount, rateMode, user)`. Aave v3 caps
//      internally at `min(amount, currentDebt)` and only pulls
//      `paybackAmount` from this contract via its own transferFrom.
//   3. Any residual left in this contract is swept back to `user` —
//      never to an attacker-controlled address, because the refund
//      destination is the `user` function argument, not a field of
//      `data`. That closes the "anyone can call this and redirect dust"
//      attack vector without requiring a `msg.sender == permit3` gate.
//
// `nonReentrant` guards against weird-token transfer hooks.
// `data = abi.encode(pool, asset, rateMode)`.
//
contract AaveV3RepayModule is IMakerModule {
    IPermit3 public immutable permit3;

    uint256 private _locked = 1;

    error Reentrancy();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;

        (address pool, address asset, uint256 rateMode) = abi.decode(data, (address, address, uint256));

        permit3.transferFrom(onBehalfOf, address(this), asset, uint160(amount));
        IERC20(asset).approve(pool, amount);
        IAaveV3Pool(pool).repay(asset, amount, rateMode, onBehalfOf);

        // Sweep residual (over-repay dust) back to the user. `balanceOf` avoids
        // depending on the pool's return value and handles protocols that round
        // differently from their own accounting.
        uint256 residual = IERC20(asset).balanceOf(address(this));
        if (residual > 0) IERC20(asset).transfer(onBehalfOf, residual);

        _locked = 1;
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
// `data = abi.encode(pool, asset, aToken)`.
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

        permit3.transferFrom(onBehalfOf, address(this), aToken, uint160(amount));
        IAaveV3Pool(pool).withdraw(asset, amount, receiver);
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
        IERC20(asset).transfer(receiver, amount);
    }
}
