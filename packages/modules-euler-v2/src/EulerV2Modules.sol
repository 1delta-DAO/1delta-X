// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {DustHandler} from "@core/dust/DustHandler.sol";

import {IEulerVault, IEVC} from "./interfaces/IEulerV2.sol";

// ════════════════════════════════════════════════════════════════════════════
//  Euler V2 (EVK + EVC) modules
//
//  Euler vaults are ERC-4626 + a borrowing extension, fronted by the EVC for
//  authentication and batching. Two facts shape these modules:
//
//   1. A vault pulls/credits the *authenticated account*, not raw `msg.sender`.
//      Called directly, the vault's `callThroughEVC` modifier routes the call so
//      the authenticated account is `msg.sender` — i.e. THIS module. So a
//      module-funded `deposit`/`repay` pulls the underlying from the module (it
//      holds it via a Permit3 pull) while crediting the *user's* position.
//
//   2. Value-out (`borrow`, `withdraw`) must be authenticated as the owner
//      account. The module routes those via `EVC.call(vault, user, …)`, which
//      requires the user to have granted the module operator rights once
//      (`EVC.setAccountOperator(user, module, true)`) and enabled the controller
//      / collateral — the Euler analogue of Aave `approveDelegation`.
//
//  Level A = four single-op modules (deposit/repay makers, borrow/withdraw
//  takers). Level B = `EulerV2BatchModule`, which fuses a value-in and a
//  value-out leg into ONE `EVC.batch` so they share a single deferred liquidity
//  check — the payoff of Euler's architecture.
// ════════════════════════════════════════════════════════════════════════════

// ──────────────────── Euler V2 deposit maker module ────────────────────
//
// Single-op module: pulls the vault's `asset()` from the user via Permit3, then
// supplies it into `vault` crediting shares to the user. Called directly, so the
// authenticated (funding) account is this module while the shares land on the
// user. No EVC operator status is needed (value flows *into* the protocol).
// `data = abi.encode(vault)`.
//
contract EulerV2DepositModule is IMakerModule {
    IPermit3 public immutable permit3;

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        address vault = abi.decode(data, (address));
        address asset = IEulerVault(vault).asset();

        permit3.transferFrom(onBehalfOf, address(this), asset, uint160(amount));
        IERC20(asset).approve(vault, amount);
        IEulerVault(vault).deposit(amount, onBehalfOf);
    }
}

// ──────────────────── Euler V2 repay maker module ────────────────────
//
// Closes the user's borrow in `vault`, handling interest-accrual over-repay with
// a pull-exact strategy: read the live debt, repay `min(amount, debt)`. EVK's
// `repay` itself caps at the debt, but pulling only what we need keeps the
// over-repay buffer out of this contract entirely (SweepToUser), removing the
// "stray dust a caller can redirect" vector at the source. On Recycle the module
// takes the full signed ceiling, repays the debt, and re-supplies the surplus as
// a lend balance into the same vault for the user — best-effort, sweep fallback.
//
// Repay is permissionless on behalf of the user, so no EVC operator status is
// needed; the module funds the repay as the authenticated account.
//
// `nonReentrant` guards weird-token transfer hooks.
// `data = abi.encode(vault[, DustHandler.DustAction])` — trailing action
// optional; absent ⇒ SweepToUser.
//
contract EulerV2RepayModule is IMakerModule {
    IPermit3 public immutable permit3;

    uint256 private _locked = 1;

    error Reentrancy();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;

        address vault = abi.decode(data, (address));
        address asset = IEulerVault(vault).asset();
        DustHandler.DustAction action = DustHandler.readAction(data, 32); // base = (address)

        _pullAndRepay(vault, asset, amount, onBehalfOf, action == DustHandler.DustAction.Recycle);
        _disposeResidual(vault, asset, onBehalfOf, action);

        _locked = 1;
    }

    /// @dev Pull the funding token and repay. SweepToUser pulls only `toRepay`, so
    ///      the buffer never enters this contract; Recycle pulls the full signed
    ///      ceiling so the surplus can be redirected into the user's position.
    function _pullAndRepay(address vault, address asset, uint256 amount, address onBehalfOf, bool recycle) private {
        uint256 toRepay;
        {
            uint256 debt = IEulerVault(vault).debtOf(onBehalfOf);
            toRepay = amount < debt ? amount : debt;
        }
        {
            uint256 toPull = recycle ? amount : toRepay;
            if (toPull > 0) permit3.transferFrom(onBehalfOf, address(this), asset, uint160(toPull));
        }
        if (toRepay > 0) {
            IERC20(asset).approve(vault, toRepay);
            IEulerVault(vault).repay(toRepay, onBehalfOf);
        }
    }

    /// @dev Re-supply (opt-in) the residual as a lend balance in the same vault,
    ///      else sweep to the user. Best-effort recycle with a guaranteed sweep.
    function _disposeResidual(address vault, address asset, address onBehalfOf, DustHandler.DustAction action)
        private
    {
        uint256 residual = IERC20(asset).balanceOf(address(this));
        if (residual == 0) return;
        DustHandler.disposeResidual(
            asset,
            residual,
            onBehalfOf,
            action,
            vault,
            abi.encodeCall(IEulerVault.deposit, (residual, onBehalfOf))
        );
    }
}

// ──────────────────── Euler V2 borrow taker module ────────────────────
//
// Single-op taker module. Routes a borrow through the EVC as the user account so
// the vault authenticates the maker as the on-behalf-of account, then sends the
// borrowed asset straight to `receiver`. The user must have enabled `vault` as
// their controller and granted this module operator rights
// (`EVC.setAccountOperator(user, module, true)`); the Permit3 taker allowance
// caps the per-fill size. `data = abi.encode(vault)`.
//
contract EulerV2BorrowModule is ITakerModule {
    IPermit3 public immutable permit3;

    error OnlyPermit3();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        address vault = abi.decode(data, (address));
        IEVC(IEulerVault(vault).EVC()).call(
            vault, onBehalfOf, 0, abi.encodeCall(IEulerVault.borrow, (amount, receiver))
        );
    }
}

// ──────────────────── Euler V2 withdraw taker module ────────────────────
//
// Single-op taker module. Withdraws collateral on the user's behalf, routed via
// the EVC. Optional `BalanceMode.Full`: withdraw the user's entire withdrawable
// balance (`maxWithdraw`) to this module, forward the signed `amount` to
// `receiver`, and sweep the excess back to the user — the TAKE-side mirror of the
// over-repay refund. Fill-or-kill only, and only after debt is cleared.
//
// `data = abi.encode(vault[, DustHandler.BalanceMode])`.
//
contract EulerV2WithdrawModule is ITakerModule {
    IPermit3 public immutable permit3;

    error OnlyPermit3();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        address vault = abi.decode(data, (address));
        IEVC evc = IEVC(IEulerVault(vault).EVC());

        if (DustHandler.readBalanceMode(data, 32) == DustHandler.BalanceMode.Full) {
            // Withdraw the user's entire withdrawable balance to this module, then
            // forward `amount` to the order and sweep the excess back to the user.
            uint256 bal = IEulerVault(vault).maxWithdraw(onBehalfOf);
            evc.call(vault, onBehalfOf, 0, abi.encodeCall(IEulerVault.withdraw, (bal, address(this), onBehalfOf)));
            address asset = IEulerVault(vault).asset();
            IERC20(asset).transfer(receiver, amount);
            if (bal > amount) IERC20(asset).transfer(onBehalfOf, bal - amount);
        } else {
            evc.call(vault, onBehalfOf, 0, abi.encodeCall(IEulerVault.withdraw, (amount, receiver, onBehalfOf)));
        }
    }
}

// ──────────────────── Euler V2 batch taker module (Level B) ────────────────────
//
// Composite module that fuses a value-in and a value-out leg into a SINGLE
// `EVC.batch`, so both share one deferred account/vault status check instead of
// one per leg — the architectural payoff of Euler's design. Two shapes:
//
//   • Open  — deposit `sideAmount` collateral into `collateralVault` (module-
//             funded via Permit3) + borrow `amount` from `borrowVault` to
//             `receiver`. The deposit credits the user's collateral and the
//             borrow draws against it under one check.
//   • Close — repay up to `sideAmount` of the user's `borrowVault` debt (module-
//             funded via Permit3, capped at live debt) + withdraw `amount`
//             collateral from `collateralVault` to `receiver`. The single check
//             sees the debt reduced before validating the collateral withdrawal.
//
// Trade-off vs single-op: one module signs a whole batch (deposit+borrow or
// repay+withdraw) under one `keccak256(data)` taker ref. It is still fully
// maker-signed and amount-gated, but it deliberately gives up the "one module =
// one protocol action" blast-radius invariant the single-op modules hold. The
// user must grant operator rights and enable the controller/collateral once.
//
// `data = abi.encode(BatchMode mode, address collateralVault, address borrowVault, uint256 sideAmount)`.
// `amount`/`receiver` carry the value-out leg (borrow for Open, collateral for Close).
//
contract EulerV2BatchModule is ITakerModule {
    IPermit3 public immutable permit3;

    enum BatchMode {
        Open, // 0 — deposit collateral + borrow
        Close // 1 — repay debt + withdraw collateral

    }

    struct BatchData {
        uint256 mode;
        address collateralVault;
        address borrowVault;
        uint256 sideAmount;
    }

    error OnlyPermit3();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        BatchData memory p = abi.decode(data, (BatchData));

        if (BatchMode(uint8(p.mode)) == BatchMode.Open) {
            _open(p, onBehalfOf, receiver, amount);
        } else {
            _close(p, onBehalfOf, receiver, amount);
        }
    }

    /// @dev deposit `sideAmount` collateral (module-funded) + borrow `borrowAmount`
    ///      in one batch. Item 0 is authenticated as this module (the funder) so
    ///      the collateral is pulled from here; item 1 as the user so the debt and
    ///      the single liquidity check land on the user's account.
    function _open(BatchData memory p, address user, address receiver, uint256 borrowAmount) private {
        address collateralAsset = IEulerVault(p.collateralVault).asset();
        permit3.transferFrom(user, address(this), collateralAsset, uint160(p.sideAmount));
        IERC20(collateralAsset).approve(p.collateralVault, p.sideAmount);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            targetContract: p.collateralVault,
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeCall(IEulerVault.deposit, (p.sideAmount, user))
        });
        items[1] = IEVC.BatchItem({
            targetContract: p.borrowVault,
            onBehalfOfAccount: user,
            value: 0,
            data: abi.encodeCall(IEulerVault.borrow, (borrowAmount, receiver))
        });
        IEVC(IEulerVault(p.borrowVault).EVC()).batch(items);
    }

    /// @dev repay up to `sideAmount` (capped at live debt, module-funded) +
    ///      withdraw `collateralAmount` to `receiver` in one batch.
    function _close(BatchData memory p, address user, address receiver, uint256 collateralAmount) private {
        address borrowAsset = IEulerVault(p.borrowVault).asset();
        uint256 debt = IEulerVault(p.borrowVault).debtOf(user);
        uint256 toRepay = p.sideAmount < debt ? p.sideAmount : debt;

        if (toRepay > 0) {
            permit3.transferFrom(user, address(this), borrowAsset, uint160(toRepay));
            IERC20(borrowAsset).approve(p.borrowVault, toRepay);
        }

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            targetContract: p.borrowVault,
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeCall(IEulerVault.repay, (toRepay, user))
        });
        items[1] = IEVC.BatchItem({
            targetContract: p.collateralVault,
            onBehalfOfAccount: user,
            value: 0,
            data: abi.encodeCall(IEulerVault.withdraw, (collateralAmount, receiver, user))
        });
        IEVC(IEulerVault(p.borrowVault).EVC()).batch(items);
    }
}
