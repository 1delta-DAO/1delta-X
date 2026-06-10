// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";

import {IGiverPositionManager, ITakerPositionManager} from "./interfaces/IAaveV4.sol";

// These are the Aave v4 counterparts of the v3 adapters in the sibling package
// `@1delta-x/modules-aave-v3`. Same module shape — one Aave action per contract,
// gated by Permit3 — but the action routes through v4's Hub/Spoke position
// managers instead of a pool.
//
// `data = abi.encode(spoke, positionManager, reserveId, asset)` for every module.
// `asset` is the underlying ERC20: a maker module pulls it via Permit3, a taker
// module forwards it to `receiver` (the taker PMs have no receiver parameter, so
// proceeds land here first). It is also part of `keccak256(data)`, the taker
// allowance ref, so the bytes the user authorised pin down the exact position.

// ──────────────────── Aave v4 deposit maker module ────────────────────
//
// Single-op module: pulls `asset` from the user via Permit3, then supplies on
// the user's behalf through the GiverPositionManager. The user must have
// approved the giver PM on the spoke beforehand (`spoke.setUserPositionManager`).
//
contract AaveV4DepositModule is IMakerModule {
    IPermit3 public immutable permit3;

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        (address spoke, address positionManager, uint256 reserveId, address asset) =
            abi.decode(data, (address, address, uint256, address));

        permit3.transferFrom(onBehalfOf, address(this), asset, uint160(amount));
        IERC20(asset).approve(positionManager, amount);
        IGiverPositionManager(positionManager).supplyOnBehalfOf(spoke, reserveId, amount, onBehalfOf);
    }
}

// ──────────────────── Aave v4 repay maker module ────────────────────
//
// Mirrors `AaveV3RepayModule`'s over-repay handling:
//
//   1. Pulls `amount` (a user-signed buffered value) from the user via Permit3.
//   2. Calls `giverPM.repayOnBehalfOf(...)`. Aave v4 caps internally at the
//      user's actual debt and only pulls what it needs from this contract.
//   3. Any residual is swept back to `onBehalfOf` — never to an attacker-
//      controlled address, because the refund destination is the `onBehalfOf`
//      function argument, not a field of `data`.
//
// `nonReentrant` guards against weird-token transfer hooks.
//
contract AaveV4RepayModule is IMakerModule {
    IPermit3 public immutable permit3;

    uint256 private _locked = 1;

    error Reentrancy();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;

        (address spoke, address positionManager, uint256 reserveId, address asset) =
            abi.decode(data, (address, address, uint256, address));

        permit3.transferFrom(onBehalfOf, address(this), asset, uint160(amount));
        IERC20(asset).approve(positionManager, amount);
        IGiverPositionManager(positionManager).repayOnBehalfOf(spoke, reserveId, amount, onBehalfOf);

        // Sweep residual (over-repay dust) back to the user. `balanceOf` avoids
        // depending on the PM's return value and handles rounding differences.
        uint256 residual = IERC20(asset).balanceOf(address(this));
        if (residual > 0) IERC20(asset).transfer(onBehalfOf, residual);

        _locked = 1;
    }
}

// ──────────────────── Aave v4 withdraw taker module ────────────────────
//
// Single-op taker module. Permit3 decrements the taker allowance on
// `keccak256(data)`, then invokes `takeOnBehalf` here. The TakerPositionManager
// has no receiver parameter, so the withdrawn underlying lands in this contract
// and is forwarded to `receiver`. The user must have approved the taker PM on
// the spoke and granted `approveWithdraw(spoke, reserveId, module, cap)`.
//
contract AaveV4WithdrawModule is ITakerModule {
    IPermit3 public immutable permit3;

    error OnlyPermit3();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        (address spoke, address positionManager, uint256 reserveId, address asset) =
            abi.decode(data, (address, address, uint256, address));

        (, uint256 assets) =
            ITakerPositionManager(positionManager).withdrawOnBehalfOf(spoke, reserveId, amount, onBehalfOf);
        IERC20(asset).transfer(receiver, assets);
    }
}

// ──────────────────── Aave v4 borrow taker module ────────────────────
//
// Single-op taker module. Issues a borrow on behalf of the user through the
// TakerPositionManager and forwards proceeds to `receiver`. The user must have
// approved the taker PM on the spoke and granted
// `approveBorrow(spoke, reserveId, module, cap)` so the PM permits the module to
// incur debt on their account.
//
contract AaveV4BorrowModule is ITakerModule {
    IPermit3 public immutable permit3;

    error OnlyPermit3();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        (address spoke, address positionManager, uint256 reserveId, address asset) =
            abi.decode(data, (address, address, uint256, address));

        // Borrow lands `amount` of `asset` at this module (the caller).
        ITakerPositionManager(positionManager).borrowOnBehalfOf(spoke, reserveId, amount, onBehalfOf);
        // Forward to Permit3's requested receiver (Settlement in our flow).
        IERC20(asset).transfer(receiver, amount);
    }
}
