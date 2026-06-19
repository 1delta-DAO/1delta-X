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

import {
    IMorphoBlue,
    IMorphoRepayCallback,
    MarketParams,
    Position,
    Id,
    MarketParamsLib
} from "./interfaces/IMorphoBlue.sol";

// ──────────────────── Morpho Blue supply-collateral maker module ────────────────────
//
// Single-op module: pulls `collateralToken` from the user via Permit3, then
// supplies it as collateral into the market on the user's behalf. Morpho's
// `supplyCollateral` has no shares variant and never accrues interest, so the
// pulled amount maps 1:1 to deposited collateral.
//
// Optional EIP-2612 permit replay for gasless collateral deposits.
// `data = abi.encode(MarketParams[, deadline, v, r, s])` — base = 160 bytes.
//
contract MorphoBlueSupplyCollateralModule is IMakerModule {
    IPermit3 public immutable permit3;
    IMorphoBlue public immutable morpho;
    address public immutable settlement;

    error NotSettlement();

    constructor(address _permit3, address _morpho, address _settlement) {
        permit3 = IPermit3(_permit3);
        morpho = IMorphoBlue(_morpho);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();

        MarketParams memory marketParams = abi.decode(data, (MarketParams));

        // Optional permit. MarketParams = 5 addresses = 160 bytes.
        PermitHelper.replayIfPresent(
            data, 160, marketParams.collateralToken, onBehalfOf, address(permit3), amount
        );

        permit3.transferFrom(onBehalfOf, address(this), marketParams.collateralToken, uint160(amount));
        SafeTransferLib.forceApprove(marketParams.collateralToken, address(morpho), amount);
        morpho.supplyCollateral(marketParams, amount, onBehalfOf, "");
    }
}

// ──────────────────── Morpho Blue repay maker module ────────────────────
//
// Closes the user's borrow in a market, handling interest-accrual over-repay
// cleanly with a pull-exact strategy. Unlike Aave, Morpho's `repay(assets=…)`
// does NOT cap at the live debt — overshooting by assets reverts (share
// underflow). So a full close repays by *shares*, and the exact asset amount is
// only known after Morpho accrues interest. We use Morpho's repay callback to
// pull precisely that amount:
//
//   1. Read the live `borrowShares` and `repay(shares = borrowShares, data≠"")`.
//   2. Morpho accrues, converts shares→assets (rounding up), then calls back
//      `onMorphoRepay(assets, …)`. There we pull exactly `assets` from the user
//      via Permit3 (capped by the maker-signed `amount`) and approve Morpho.
//   3. Morpho pulls exactly `assets` from this contract.
//
// In the default (SweepToUser) mode the over-repay buffer is never pulled (the
// callback funds exactly what Morpho needs), so nothing sits in this contract for
// a caller to redirect — removing that vector at the source without a `msg.sender
// == permit3` gate. When `data` opts into Recycle, the module instead takes
// custody of the full signed ceiling, repays with empty callback data (Morpho
// pulls the exact accrued assets from the module), and re-supplies the surplus as
// a lend balance into the same market — best-effort with a guaranteed sweep
// fallback. Either way disposal is locked to `onBehalfOf` / morpho, never a
// caller-chosen address.
//
// `nonReentrant` guards against weird-token transfer hooks.
// `data = abi.encode(MarketParams[, DustHandler.DustAction[, deadline, v, r, s]])` —
// dust action optional (absent ⇒ SweepToUser); permit block optional after it.
//
contract MorphoBlueRepayModule is IMakerModule, IMorphoRepayCallback {
    using MarketParamsLib for MarketParams;

    IPermit3 public immutable permit3;
    IMorphoBlue public immutable morpho;
    address public immutable settlement;

    uint256 private _locked = 1;

    error Reentrancy();
    error OnlyMorpho();
    error BufferTooSmall();
    error NotSettlement();

    constructor(address _permit3, address _morpho, address _settlement) {
        permit3 = IPermit3(_permit3);
        morpho = IMorphoBlue(_morpho);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();
        if (_locked != 1) revert Reentrancy();
        _locked = 2;

        MarketParams memory marketParams = abi.decode(data, (MarketParams));
        address loanToken = marketParams.loanToken;
        // base = MarketParams (5 addresses) = 160 bytes; DustAction at 160, permit at 192.
        DustHandler.DustAction action = DustHandler.readAction(data, 160);
        PermitHelper.replayIfPresent(data, 192, loanToken, onBehalfOf, address(permit3), amount);

        // Repay the entire debt by shares. The exact asset amount is only known
        // after Morpho accrues interest.
        Id id = marketParams.id();
        uint256 borrowShares = morpho.position(id, onBehalfOf).borrowShares;
        if (borrowShares > 0) {
            if (action == DustHandler.DustAction.Recycle) {
                // Take custody of the full signed ceiling, then repay with empty
                // callback data so Morpho pulls the exact accrued assets straight
                // from this module. The unpulled surplus stays here as residual to
                // be recycled below. Reset the leftover allowance afterwards.
                permit3.transferFrom(onBehalfOf, address(this), loanToken, uint160(amount));
                SafeTransferLib.forceApprove(loanToken, address(morpho), amount);
                morpho.repay(marketParams, 0, borrowShares, onBehalfOf, "");
                SafeTransferLib.forceApprove(loanToken, address(morpho), 0);
            } else {
                // Pull-exact via `onMorphoRepay`: no buffer is pre-pulled, so the
                // surplus stays in the maker's wallet and nothing sits here.
                morpho.repay(marketParams, 0, borrowShares, onBehalfOf, abi.encode(onBehalfOf, amount, loanToken));
            }
        }

        // Dispose of any residual: re-supplied as a lend balance into the same
        // market (Recycle, best-effort with sweep fallback) or swept to the user
        // (default), never to a caller. In its own frame to keep the decoded
        // locals from overflowing the stack.
        _disposeResidual(marketParams, loanToken, onBehalfOf, action);

        _locked = 1;
    }

    /// @dev Re-supply (opt-in) the residual loan token as a lend balance in the
    ///      same market, else sweep to the user. `base = MarketParams` (5 static
    ///      fields) ⇒ trailing action at byte 160.
    function _disposeResidual(
        MarketParams memory marketParams,
        address loanToken,
        address onBehalfOf,
        DustHandler.DustAction action
    ) private {
        uint256 residual = IERC20(loanToken).balanceOf(address(this));
        if (residual == 0) return;
        DustHandler.disposeResidual(
            loanToken,
            residual,
            onBehalfOf,
            action,
            address(morpho),
            abi.encodeCall(IMorphoBlue.supply, (marketParams, residual, 0, onBehalfOf, ""))
        );
    }

    /// @notice Morpho repay callback. Pulls exactly `assets` (capped by the
    ///         maker-signed ceiling) from the user and approves Morpho to take
    ///         it. Only Morpho may invoke this; the funds it can move are bounded
    ///         by the user's Permit3 allowance, so a stray call cannot do harm.
    function onMorphoRepay(uint256 assets, bytes calldata data) external override {
        if (msg.sender != address(morpho)) revert OnlyMorpho();

        (address user, uint256 cap, address loanToken) = abi.decode(data, (address, uint256, address));
        if (assets > cap) revert BufferTooSmall();

        permit3.transferFrom(user, address(this), loanToken, uint160(assets));
        SafeTransferLib.forceApprove(loanToken, address(morpho), assets);
    }
}

// ──────────────────── Morpho Blue withdraw-collateral taker module ────────────────────
//
// Single-op taker module. Permit3 decrements the taker allowance on
// `keccak256(data)`, then invokes `takeOnBehalf` here. Morpho collateral is not
// tokenised — the module calls `withdrawCollateral` directly and Morpho sends
// collateral straight to `receiver` (or this module in Full mode).
//
// Optional `BalanceMode.Full` (trailing field): withdraw the user's ENTIRE
// collateral balance, forward the signed `amount` to `receiver`, and sweep the
// excess back to `onBehalfOf`. Fill-or-kill only, after debt is cleared.
//
// Optional EIP-712 authorization-with-sig: appending an auth block grants this
// module Morpho authorization on-the-fly — no prior `setAuthorization` call.
// The BalanceMode slot MUST be encoded explicitly (as 0 = Exact) when including
// the auth block so offsets are unambiguous.
//
// `data = abi.encode(MarketParams[, BalanceMode[, nonce, deadline, v, r, s]])`
//   — BalanceMode at 160, auth block at 192 (5 × 32 = 160 bytes).
//
contract MorphoBlueWithdrawCollateralModule is ITakerModule {
    using MarketParamsLib for MarketParams;

    IPermit3 public immutable permit3;
    IMorphoBlue public immutable morpho;

    error OnlyPermit3();

    constructor(address _permit3, address _morpho) {
        permit3 = IPermit3(_permit3);
        morpho = IMorphoBlue(_morpho);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        MarketParams memory marketParams = abi.decode(data, (MarketParams));

        // Optional auth-with-sig at offset 192 (after BalanceMode slot at 160).
        DelegationHelper.replayMorphoAuth(data, 192, address(morpho), onBehalfOf, address(this));

        if (DustHandler.readBalanceMode(data, 160) == DustHandler.BalanceMode.Full) {
            address collateralToken = marketParams.collateralToken;
            uint256 bal = morpho.position(marketParams.id(), onBehalfOf).collateral;
            uint256 before = IERC20(collateralToken).balanceOf(address(this));
            morpho.withdrawCollateral(marketParams, bal, onBehalfOf, address(this));
            uint256 received = IERC20(collateralToken).balanceOf(address(this)) - before;
            require(received >= amount, "insufficient withdrawn");
            SafeTransferLib.safeTransfer(collateralToken, receiver, amount);
            if (received > amount) {
                SafeTransferLib.safeTransfer(collateralToken, onBehalfOf, received - amount);
            }
        } else {
            morpho.withdrawCollateral(marketParams, amount, onBehalfOf, receiver);
        }
    }
}

// ──────────────────── Morpho Blue borrow taker module ────────────────────
//
// Single-op taker module. Issues a borrow on behalf of the user and Morpho
// sends the loan token straight to `receiver`.
//
// Optional EIP-712 authorization-with-sig: appending an auth block grants this
// module Morpho authorization on-the-fly — no prior `setAuthorization` call.
// Authorization is coarse (all markets); the Permit3 taker allowance caps the
// per-fill amount.
//
// `data = abi.encode(MarketParams[, nonce, deadline, v, r, s])`
//   — base = 160 bytes (MarketParams), auth block at 160 (5 × 32 = 160 bytes).
//
contract MorphoBlueBorrowModule is ITakerModule {
    IPermit3 public immutable permit3;
    IMorphoBlue public immutable morpho;

    error OnlyPermit3();

    constructor(address _permit3, address _morpho) {
        permit3 = IPermit3(_permit3);
        morpho = IMorphoBlue(_morpho);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        MarketParams memory marketParams = abi.decode(data, (MarketParams));

        // Optional auth-with-sig at offset 160 (base = MarketParams = 160 bytes).
        DelegationHelper.replayMorphoAuth(data, 160, address(morpho), onBehalfOf, address(this));

        morpho.borrow(marketParams, amount, 0, onBehalfOf, receiver);
    }
}
