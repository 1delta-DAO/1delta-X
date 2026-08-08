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
        PermitHelper.replayIfPresent(data, 160, marketParams.collateralToken, onBehalfOf, address(permit3), amount);

        permit3.transferFrom(onBehalfOf, address(this), marketParams.collateralToken, uint160(amount));
        // `morpho` is an immutable, trusted target → a standing max approval is safe
        // and skips the approve SSTORE on repeat supplies.
        SafeTransferLib.ensureApproval(marketParams.collateralToken, address(morpho), amount);
        morpho.supplyCollateral(marketParams, amount, onBehalfOf, "");
    }
}

// ──────────────────── Morpho Blue supply (earn) maker module ────────────────────
//
// The EARN-side sibling of the collateral module: pulls `loanToken` from the
// user via Permit3 and supplies it as a LEND balance (`morpho.supply`, exact
// assets, shares = 0) on the user's behalf — the deposit leg that pairs with the
// taker module's `Op.Withdraw` (op 2), closing the earn round-trip that
// previously only had its exit half. Interest accrues to the position; a later
// Full-mode withdraw redeems by shares and sweeps the accrual back to the user.
//
// Optional EIP-2612 permit replay for gasless deposits.
// `data = abi.encode(MarketParams[, deadline, v, r, s])` — base = 160 bytes.
//
contract MorphoBlueSupplyModule is IMakerModule {
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
        PermitHelper.replayIfPresent(data, 160, marketParams.loanToken, onBehalfOf, address(permit3), amount);

        permit3.transferFrom(onBehalfOf, address(this), marketParams.loanToken, uint160(amount));
        // `morpho` is an immutable, trusted target → standing max approval is safe.
        SafeTransferLib.ensureApproval(marketParams.loanToken, address(morpho), amount);
        morpho.supply(marketParams, amount, 0, onBehalfOf, "");
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
                // be recycled below. `morpho` is immutable/trusted, so we leave the
                // standing max approval (no reset) to skip the SSTORE churn.
                permit3.transferFrom(onBehalfOf, address(this), loanToken, uint160(amount));
                SafeTransferLib.ensureApproval(loanToken, address(morpho), amount);
                morpho.repay(marketParams, 0, borrowShares, onBehalfOf, "");
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
        SafeTransferLib.ensureApproval(loanToken, address(morpho), assets);
    }
}

// ──────────────────── Morpho Blue combined taker module ────────────────────
//
// Fuses the borrow and withdraw-collateral taker legs into a SINGLE contract. A
// leading `op` flag in `data` selects the leg, so a user who
// runs the full leverage round-trip authorizes ONE module address instead of two
// — a single `setAuthorization(this, true)` (or one auth-with-sig) covers both
// borrow and withdraw, and the EVC/Morpho operator surface shrinks accordingly.
//
// Safety is unchanged from the split modules: the Permit3 taker allowance is
// keyed by `ref = keccak256(data)`, and `op` is the first word of `data`, so
// borrow-data and withdraw-data hash to DIFFERENT refs. The user therefore still
// grants a separate amount-gated allowance per leg — the flag cannot be flipped
// to spend a borrow allowance on a withdraw (or vice-versa). The only thing
// shared is the coarse Morpho authorization boolean, which is per-address by
// construction.
//
//   op = 0 (Borrow):
//     data = abi.encode(uint8(0), MarketParams[, nonce, deadline, v, r, s])
//       — op@0, MarketParams@32 (base = 192); auth block (160B) optional at 192.
//
//   op = 1 (WithdrawCollateral):
//     data = abi.encode(uint8(1), MarketParams[, BalanceMode[, nonce, deadline, v, r, s]])
//       — op@0, MarketParams@32 (base = 192); BalanceMode@192; auth@224.
//       The BalanceMode slot MUST be encoded explicitly (as 0 = Exact) when an
//       auth block follows, so the block starts at a fixed offset.
//
//   op = 2 (Withdraw — loan asset):
//     data = abi.encode(uint8(2), MarketParams[, BalanceMode[, nonce, deadline, v, r, s]])
//       — same byte map as op 1; unwinds the maker's supplied LOAN token (the
//       earn position) via `morpho.withdraw` instead of collateral. Full mode
//       redeems by shares, so the accrued-interest excess sweeps back in-kind.
//
contract MorphoBlueTakerModule is ITakerModule {
    using MarketParamsLib for MarketParams;

    IPermit3 public immutable permit3;
    IMorphoBlue public immutable morpho;

    enum Op {
        Borrow, // 0
        WithdrawCollateral, // 1
        Withdraw // 2 — supplied loan asset (earn position)
    }

    error OnlyPermit3();
    error BadOp(uint8 op);

    constructor(address _permit3, address _morpho) {
        permit3 = IPermit3(_permit3);
        morpho = IMorphoBlue(_morpho);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        // op@0, MarketParams@32 — both static, so a prefix decode is sound even
        // when op-specific trailing fields follow. An out-of-range enum reverts.
        (uint8 op, MarketParams memory marketParams) = abi.decode(data, (uint8, MarketParams));

        if (op == uint8(Op.Borrow)) {
            // Optional auth-with-sig at offset 192 (op@0 + MarketParams@32 = 192).
            DelegationHelper.replayMorphoAuth(data, 192, address(morpho), onBehalfOf, address(this));
            morpho.borrow(marketParams, amount, 0, onBehalfOf, receiver);
        } else if (op == uint8(Op.WithdrawCollateral)) {
            // Optional auth-with-sig at offset 224 (after BalanceMode slot at 192).
            DelegationHelper.replayMorphoAuth(data, 224, address(morpho), onBehalfOf, address(this));

            if (DustHandler.readBalanceMode(data, 192) == DustHandler.BalanceMode.Full) {
                // `Full` liquidates the user's ENTIRE live balance, so it cannot be
                // pro-rated — a sliced fill would unwind the whole position and brick
                // the rest of the order. Require the slice to be the whole item.
                FullFillGuard.requireFullFillFromData(data, 224, amount);
                _withdrawFull(marketParams, onBehalfOf, amount, receiver);
            } else {
                morpho.withdrawCollateral(marketParams, amount, onBehalfOf, receiver);
            }
        } else if (op == uint8(Op.Withdraw)) {
            // Same byte map as WithdrawCollateral: BalanceMode@192, auth@224.
            DelegationHelper.replayMorphoAuth(data, 224, address(morpho), onBehalfOf, address(this));

            if (DustHandler.readBalanceMode(data, 192) == DustHandler.BalanceMode.Full) {
                // `Full` liquidates the user's ENTIRE live balance, so it cannot be
                // pro-rated — a sliced fill would unwind the whole position and brick
                // the rest of the order. Require the slice to be the whole item.
                FullFillGuard.requireFullFillFromData(data, 224, amount);
                _withdrawLoanFull(marketParams, onBehalfOf, amount, receiver);
            } else {
                // Exact-assets withdrawal of the supplied loan token (shares = 0).
                morpho.withdraw(marketParams, amount, 0, onBehalfOf, receiver);
            }
        } else {
            revert BadOp(op);
        }
    }

    /// @dev Full mode: withdraw the user's entire collateral to this module,
    ///      forward the signed `amount` to `receiver`, and sweep the excess back
    ///      to the user — always to `onBehalfOf`, never a caller-chosen address.
    ///      Measures what actually landed rather than trusting the static `amount`.
    function _withdrawFull(MarketParams memory marketParams, address onBehalfOf, uint256 amount, address receiver)
        private
    {
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
    }

    /// @dev Full mode for the loan leg: redeem the user's ENTIRE supply by
    ///      shares (assets drift upward as interest accrues, shares don't),
    ///      forward the signed `amount` to `receiver`, and sweep the accrued
    ///      excess back to the user — always to `onBehalfOf`, never a
    ///      caller-chosen address.
    function _withdrawLoanFull(MarketParams memory marketParams, address onBehalfOf, uint256 amount, address receiver)
        private
    {
        address loanToken = marketParams.loanToken;
        uint256 shares = morpho.position(marketParams.id(), onBehalfOf).supplyShares;
        uint256 before = IERC20(loanToken).balanceOf(address(this));
        morpho.withdraw(marketParams, 0, shares, onBehalfOf, address(this));
        uint256 received = IERC20(loanToken).balanceOf(address(this)) - before;
        require(received >= amount, "insufficient withdrawn");
        SafeTransferLib.safeTransfer(loanToken, receiver, amount);
        if (received > amount) {
            SafeTransferLib.safeTransfer(loanToken, onBehalfOf, received - amount);
        }
    }
}
