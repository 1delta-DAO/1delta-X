// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {DustHandler} from "@core/dust/DustHandler.sol";
import {FullFillGuard} from "@core/utils/FullFillGuard.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {PermitHelper} from "@core/utils/PermitHelper.sol";

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
// Optional EIP-2612 permit replay: if the caller appends permit fields to `data`,
// the module replays them before `permit3.transferFrom` (gasless deposits).
//
// `data = abi.encode(spoke, positionManager, reserveId, asset[, deadline, v, r, s])`
contract AaveV4DepositModule is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;

    error NotSettlement();

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();

        (address spoke, address positionManager, uint256 reserveId, address asset) =
            abi.decode(data, (address, address, uint256, address));

        // Optional permit. base = (address,address,uint256,address) = 128 bytes.
        PermitHelper.replayIfPresent(data, 128, asset, onBehalfOf, address(permit3), amount);

        permit3.transferFrom(onBehalfOf, address(this), asset, uint160(amount));
        SafeTransferLib.forceApprove(asset, positionManager, amount);
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
// `data = abi.encode(spoke, positionManager, reserveId, asset[, DustHandler.DustAction[, deadline, v, r, s]])`
// — the trailing dust action is optional (absent ⇒ SweepToUser);
//   the permit block (128 bytes) is optional after the dust action slot.
//
contract AaveV4RepayModule is IMakerModule {
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

        (address spoke, address positionManager, uint256 reserveId, address asset) =
            abi.decode(data, (address, address, uint256, address));
        // base = (address,address,uint256,address) = 128 bytes; DustAction at 128, permit at 160.
        DustHandler.DustAction action = DustHandler.readAction(data, 128);
        PermitHelper.replayIfPresent(data, 160, asset, onBehalfOf, address(permit3), amount);

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
            SafeTransferLib.forceApprove(asset, positionManager, toRepay);
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
            // `Full` liquidates the user's ENTIRE live balance, so it cannot be
            // pro-rated — a sliced fill would unwind the whole position and brick
            // the rest of the order. Require the slice to be the whole item.
            FullFillGuard.requireFullFillFromData(data, 160, amount);
            // Withdraw the user's entire supplied balance to this module; forward
            // the signed `amount` to the order, sweep the accrued excess to user.
            // Measure the actually-received underlying via a balanceOf snapshot
            // rather than trusting the PM's reported amount.
            uint256 supplied = ISpokeV4(spoke).getUserSuppliedAssets(reserveId, onBehalfOf);
            uint256 balBefore = IERC20(asset).balanceOf(address(this));
            ITakerPositionManager(positionManager).withdrawOnBehalfOf(spoke, reserveId, supplied, onBehalfOf);
            uint256 received = IERC20(asset).balanceOf(address(this)) - balBefore;
            require(received >= amount, "insufficient withdrawn");
            SafeTransferLib.safeTransfer(asset, receiver, amount);
            if (received > amount) SafeTransferLib.safeTransfer(asset, onBehalfOf, received - amount);
        } else {
            (, uint256 assets) =
                ITakerPositionManager(positionManager).withdrawOnBehalfOf(spoke, reserveId, amount, onBehalfOf);
            SafeTransferLib.safeTransfer(asset, receiver, assets);
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
        SafeTransferLib.safeTransfer(asset, receiver, amount);
    }
}
