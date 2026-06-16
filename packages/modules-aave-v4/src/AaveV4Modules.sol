// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {DustHandler} from "@core/dust/DustHandler.sol";

import {IGiverPositionManager, ITakerPositionManager, ISpokeV4} from "./interfaces/IAaveV4.sol";

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
// Mirrors `AaveV3RepayModule`'s pull-exact over-repay handling:
//
//   1. Read the user's live debt from the spoke and compute
//      `toRepay = min(amount, debt)`, where `amount` is the maker-signed ceiling.
//   2. Pull exactly `toRepay` from the user via Permit3 and `repayOnBehalfOf`.
//
// In the default (SweepToUser) mode the over-repay buffer is never pulled, so
// nothing sits in this module for a caller to redirect — removing the redirect
// vector at the source. When `data` opts into Recycle, the module takes custody
// of the full signed ceiling and, after repaying, re-supplies the surplus into
// the user's v4 position (same reserve), best-effort with a guaranteed sweep
// fallback that gracefully degrades when the spoke does not list the asset for
// supply (or the cap is reached). Either way disposal is locked to `onBehalfOf` /
// the PM, never a caller-chosen address.
//
// `nonReentrant` guards against weird-token transfer hooks.
// `data = abi.encode(spoke, positionManager, reserveId, asset[, DustHandler.DustAction])`
// — the trailing dust action is optional; absent ⇒ SweepToUser.
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
        DustHandler.DustAction action = DustHandler.readAction(data, 128); // base = (address,address,uint256,address)

        _pullAndRepay(spoke, positionManager, reserveId, asset, amount, onBehalfOf, action == DustHandler.DustAction.Recycle);

        // Dispose of any residual: re-supplied into the user's position (Recycle,
        // best-effort with sweep fallback) or swept to the user (default), never
        // to a caller. In its own frame to keep the decoded locals off the stack.
        _disposeResidual(spoke, positionManager, reserveId, asset, onBehalfOf, action);

        _locked = 1;
    }

    /// @dev Pull the funding token and repay. SweepToUser pulls only what the
    ///      debt needs — the buffer is never pulled and the surplus stays in the
    ///      maker's wallet. Recycle takes custody of the full signed ceiling so
    ///      the surplus can be redirected into the user's v4 position by
    ///      `_disposeResidual`; disposal stays locked to `onBehalfOf` / the PM.
    function _pullAndRepay(
        address spoke,
        address positionManager,
        uint256 reserveId,
        address asset,
        uint256 amount,
        address onBehalfOf,
        bool recycle
    ) private {
        uint256 toRepay;
        {
            uint256 debt = ISpokeV4(spoke).getUserTotalDebt(reserveId, onBehalfOf);
            toRepay = amount < debt ? amount : debt;
        }
        {
            uint256 toPull = recycle ? amount : toRepay;
            if (toPull > 0) permit3.transferFrom(onBehalfOf, address(this), asset, uint160(toPull));
        }
        if (toRepay > 0) {
            IERC20(asset).approve(positionManager, toRepay);
            IGiverPositionManager(positionManager).repayOnBehalfOf(spoke, reserveId, toRepay, onBehalfOf);
        }
    }

    /// @dev Re-supply (opt-in) into the same v4 reserve, else sweep to the user.
    ///      `base = (address,address,uint256,address)` ⇒ trailing action at 128.
    function _disposeResidual(
        address spoke,
        address positionManager,
        uint256 reserveId,
        address asset,
        address onBehalfOf,
        DustHandler.DustAction action
    ) private {
        uint256 residual = IERC20(asset).balanceOf(address(this));
        if (residual == 0) return;
        DustHandler.disposeResidual(
            asset,
            residual,
            onBehalfOf,
            action,
            positionManager,
            abi.encodeCall(IGiverPositionManager.supplyOnBehalfOf, (spoke, reserveId, residual, onBehalfOf))
        );
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
// Optional `BalanceMode.Full` (trailing field): withdraw the user's ENTIRE
// supplied balance (`getUserSuppliedAssets`), forward the signed `amount` to
// `receiver`, and sweep the accrued excess back to `onBehalfOf`. Fill-or-kill
// only, and only after debt is cleared.
//
// `data = abi.encode(spoke, positionManager, reserveId, asset[, DustHandler.BalanceMode])`.
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

        if (DustHandler.readBalanceMode(data, 128) == DustHandler.BalanceMode.Full) {
            // Withdraw the user's entire supplied balance to this module; forward
            // the signed `amount` to the order, sweep the accrued excess to user.
            uint256 supplied = ISpokeV4(spoke).getUserSuppliedAssets(reserveId, onBehalfOf);
            (, uint256 withdrawn) =
                ITakerPositionManager(positionManager).withdrawOnBehalfOf(spoke, reserveId, supplied, onBehalfOf);
            IERC20(asset).transfer(receiver, amount);
            if (withdrawn > amount) IERC20(asset).transfer(onBehalfOf, withdrawn - amount);
        } else {
            (, uint256 assets) =
                ITakerPositionManager(positionManager).withdrawOnBehalfOf(spoke, reserveId, amount, onBehalfOf);
            IERC20(asset).transfer(receiver, assets);
        }
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
