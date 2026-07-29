// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {DustHandler} from "@core/dust/DustHandler.sol";
import {FullFillGuard} from "@core/utils/FullFillGuard.sol";
import {PermitHelper} from "@core/utils/PermitHelper.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {IExactlyMarket} from "./interfaces/IExactly.sol";

// ════════════════════════════════════════════════════════════════════════════
//  Exactly (ERC-4626 fixed/floating pool) modules
//
//  One Market per asset. `maturity == 0` ⇒ floating pool; a non-zero unix
//  timestamp ⇒ that fixed pool. Because `borrow`/`withdraw` carry a `receiver`,
//  the value-out legs forward straight to the order's `receiver` — the clean
//  case. Cross-margin: collateral counts only once the maker has
//  `Auditor.enterMarket(market)` (a maker-side permission, not a module call).
//
//  Authorisation:
//    • deposit / repay — permissionless value-in; no grant.
//    • borrow / withdraw — the maker signs one `market.approve(module, max)`
//      (ERC-4626 share allowance); Exactly consumes it when principal != caller.
//      The Permit3 taker allowance bounds the per-fill amount.
// ════════════════════════════════════════════════════════════════════════════

// ──────────────────── Exactly deposit maker module ────────────────────
//
// Pulls `asset` via Permit3 and supplies it into `market` crediting the user.
// `maturity == 0` ⇒ floating `deposit`; else `depositAtMaturity` with the
// maker-signed `minAssetsRequired` floor. Optional EIP-2612 permit replay.
//
// `data = abi.encode(market, asset, maturity, minAssetsRequired[, deadline, v, r, s])`
//   — base = 128 bytes.
//
contract ExactlyDepositModule is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;

    error NotSettlement();

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();

        (address market, address asset, uint256 maturity, uint256 minAssetsRequired) =
            abi.decode(data, (address, address, uint256, uint256));

        PermitHelper.replayIfPresent(data, 128, asset, onBehalfOf, address(permit3), amount);

        permit3.transferFrom(onBehalfOf, address(this), asset, uint160(amount));
        SafeTransferLib.forceApprove(asset, market, amount);

        if (maturity == 0) {
            IExactlyMarket(market).deposit(amount, onBehalfOf);
        } else {
            IExactlyMarket(market).depositAtMaturity(maturity, amount, minAssetsRequired, onBehalfOf);
        }
    }
}

// ──────────────────── Exactly repay maker module ────────────────────
//
// Closes the user's borrow in `market`. Floating: read the live debt
// (`previewDebt`) and repay `min(amount, debt)` — SweepToUser never pulls the
// over-repay buffer. Fixed: repay `amount` face at `maturity`, bounded by the
// maker-signed `maxAssets`; any unspent buffer is disposed to the user (or
// recycled). Either way disposal is locked to `onBehalfOf` / the market.
//
// `nonReentrant` guards weird-token transfer hooks.
// `data = abi.encode(market, asset, maturity, maxAssets[, DustAction[, deadline, v, r, s]])`
//   — base = 128; DustAction@128; permit@160.
//
contract ExactlyRepayModule is IMakerModule {
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

        (address market, address asset, uint256 maturity, uint256 maxAssets) =
            abi.decode(data, (address, address, uint256, uint256));
        DustHandler.DustAction action = DustHandler.readAction(data, 128);
        PermitHelper.replayIfPresent(data, 160, asset, onBehalfOf, address(permit3), amount);

        _pullAndRepay(market, asset, maturity, amount, maxAssets, onBehalfOf, action == DustHandler.DustAction.Recycle);
        _disposeResidual(market, asset, onBehalfOf, action);

        _locked = 1;
    }

    function _pullAndRepay(
        address market,
        address asset,
        uint256 maturity,
        uint256 amount,
        uint256 maxAssets,
        address onBehalfOf,
        bool recycle
    ) private {
        if (maturity == 0) {
            // Floating: pull-exact against the live debt.
            uint256 debt = IExactlyMarket(market).previewDebt(onBehalfOf);
            uint256 toRepay = amount < debt ? amount : debt;
            uint256 toPull = recycle ? amount : toRepay;
            if (toPull > 0) permit3.transferFrom(onBehalfOf, address(this), asset, uint160(toPull));
            if (toRepay > 0) {
                SafeTransferLib.forceApprove(asset, market, toRepay);
                IExactlyMarket(market).repay(toRepay, onBehalfOf);
            }
        } else {
            // Fixed: `amount` = face to repay; `maxAssets` bounds the transfer.
            // Pull the bound, let the Market take only what it needs; the surplus
            // is disposed below.
            if (maxAssets > 0) {
                permit3.transferFrom(onBehalfOf, address(this), asset, uint160(maxAssets));
                SafeTransferLib.forceApprove(asset, market, maxAssets);
            }
            IExactlyMarket(market).repayAtMaturity(maturity, amount, maxAssets, onBehalfOf);
        }
    }

    /// @dev Re-supply (opt-in) the residual into the user's floating position,
    ///      else sweep to the user. Best-effort recycle with a guaranteed sweep.
    function _disposeResidual(address market, address asset, address onBehalfOf, DustHandler.DustAction action)
        private
    {
        uint256 residual = IERC20(asset).balanceOf(address(this));
        if (residual == 0) return;
        SafeTransferLib.forceApprove(asset, market, 0); // clear the repay approval first
        DustHandler.disposeResidual(
            asset,
            residual,
            onBehalfOf,
            action,
            market,
            abi.encodeWithSignature("deposit(uint256,address)", residual, onBehalfOf)
        );
    }
}

// ──────────────────── Exactly combined taker module ────────────────────
//
// Fuses borrow and withdraw behind a leading `op` flag. Borrow-data and
// withdraw-data hash to different `keccak256(data)` refs, so the maker grants a
// separate amount-gated taker allowance per leg; the shared ERC-4626 share
// allowance (`market.approve(module, max)`) is per-address by construction.
//
//   base: op@0, market@32, asset@64, maturity@96, bound@128 (base length 160)
//     — `bound` = maxAssets (borrow-at-maturity) / minAssetsRequired (withdraw-at-maturity).
//   op = 0 (Borrow):    data = abi.encode(uint8(0), market, asset, maturity, maxAssets)
//   op = 1 (Withdraw):  data = abi.encode(uint8(1), market, asset, maturity, minAssets[, BalanceMode])
//     — BalanceMode@160 (floating only). `Full` withdraws the whole floating
//       position and sweeps the excess to the user.
//
contract ExactlyTakerModule is ITakerModule {
    IPermit3 public immutable permit3;

    enum Op {
        Borrow, // 0
        Withdraw // 1
    }

    error OnlyPermit3();
    error BadOp(uint8 op);

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        (uint8 op, address market, address asset, uint256 maturity, uint256 bound) =
            abi.decode(data, (uint8, address, address, uint256, uint256));

        if (op == uint8(Op.Borrow)) {
            if (maturity == 0) {
                IExactlyMarket(market).borrow(amount, receiver, onBehalfOf);
            } else {
                IExactlyMarket(market).borrowAtMaturity(maturity, amount, bound, receiver, onBehalfOf);
            }
        } else if (op == uint8(Op.Withdraw)) {
            if (maturity != 0) {
                IExactlyMarket(market).withdrawAtMaturity(maturity, amount, bound, receiver, onBehalfOf);
            } else if (DustHandler.readBalanceMode(data, 160) == DustHandler.BalanceMode.Full) {
                // `Full` liquidates the user's ENTIRE live balance, so it cannot be
                // pro-rated — a sliced fill would unwind the whole position and brick
                // the rest of the order. Require the slice to be the whole item.
                FullFillGuard.requireFullFillFromData(data, 192, amount);
                _withdrawFull(market, asset, onBehalfOf, amount, receiver);
            } else {
                IExactlyMarket(market).withdraw(amount, receiver, onBehalfOf);
            }
        } else {
            revert BadOp(op);
        }
    }

    /// @dev Full mode (floating): withdraw the user's entire position to this
    ///      module, forward the signed `amount` to `receiver`, sweep the excess
    ///      back to the user — always to `onBehalfOf`, never a caller.
    function _withdrawFull(address market, address asset, address onBehalfOf, uint256 amount, address receiver) private {
        uint256 max = IExactlyMarket(market).maxWithdraw(onBehalfOf);
        uint256 before = IERC20(asset).balanceOf(address(this));
        IExactlyMarket(market).withdraw(max, address(this), onBehalfOf);
        uint256 received = IERC20(asset).balanceOf(address(this)) - before;
        require(received >= amount, "insufficient withdrawn");
        SafeTransferLib.safeTransfer(asset, receiver, amount);
        if (received > amount) SafeTransferLib.safeTransfer(asset, onBehalfOf, received - amount);
    }
}
