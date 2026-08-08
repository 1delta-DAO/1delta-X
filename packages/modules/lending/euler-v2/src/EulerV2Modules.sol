// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {DustHandler} from "@core/dust/DustHandler.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {FullFillGuard} from "@core/utils/FullFillGuard.sol";

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
//  Level A = deposit/repay makers + a single combined `EulerV2TakerModule` that
//  multiplexes the two value-out legs (borrow/withdraw) behind a leading `op`
//  flag. Level B = `EulerV2BatchModule`, which fuses a value-in and a value-out
//  leg into ONE `EVC.batch` so they share a single deferred liquidity check — the
//  payoff of Euler's architecture.
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
    address public immutable settlement;

    error NotSettlement();

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();
        address vault = abi.decode(data, (address));
        address asset = IEulerVault(vault).asset();

        permit3.transferFrom(onBehalfOf, address(this), asset, uint160(amount));
        SafeTransferLib.forceApprove(asset, vault, amount);
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
            SafeTransferLib.forceApprove(asset, vault, toRepay);
            IEulerVault(vault).repay(toRepay, onBehalfOf);
        }
    }

    /// @dev Re-supply (opt-in) the residual as a lend balance in the same vault,
    ///      else sweep to the user. Best-effort recycle with a guaranteed sweep.
    function _disposeResidual(address vault, address asset, address onBehalfOf, DustHandler.DustAction action) private {
        uint256 residual = IERC20(asset).balanceOf(address(this));
        if (residual == 0) return;
        DustHandler.disposeResidual(
            asset, residual, onBehalfOf, action, vault, abi.encodeCall(IEulerVault.deposit, (residual, onBehalfOf))
        );
    }
}

// ──────────────────── Euler V2 combined taker module ────────────────────
//
// Fuses the borrow and withdraw value-out legs into a SINGLE contract. A leading
// `op` flag in `data` selects the leg, so a user who runs the full leverage
// round-trip authorizes ONE module address instead of two — a single
// `EVC.setAccountOperator(user, module, true)` covers both borrow and withdraw,
// and the EVC operator surface shrinks accordingly.
//
// Safety is unchanged from the split modules: the Permit3 taker allowance is
// keyed by `ref = keccak256(data)`, and `op` is the first word of `data`, so
// borrow-data and withdraw-data hash to DIFFERENT refs. The user therefore still
// grants a separate amount-gated allowance per leg — the flag cannot be flipped
// to spend a borrow allowance on a withdraw (or vice-versa). The only thing
// shared is the coarse EVC operator grant, which is per-address by construction.
//
// Both legs route value-out through the EVC as the user account; the user must
// have enabled the borrow vault as their controller / the collateral vault in
// their set, and granted this module operator rights once.
//
// Byte map (op first; old single-op offsets shift +32):
//   base:           op@0, vault@32                     (base length 64)
//   op = 0 (Borrow):
//     data = abi.encode(uint8(0), vault)
//   op = 1 (Withdraw):
//     data = abi.encode(uint8(1), vault[, BalanceMode]) — BalanceMode@64
//
contract EulerV2TakerModule is ITakerModule {
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

        // op@0, vault@32 — both static, so a prefix decode is sound even when
        // op-specific trailing fields follow.
        (uint8 op, address vault) = abi.decode(data, (uint8, address));

        if (op == uint8(Op.Borrow)) {
            IEVC(IEulerVault(vault).EVC())
                .call(vault, onBehalfOf, 0, abi.encodeCall(IEulerVault.borrow, (amount, receiver)));
        } else if (op == uint8(Op.Withdraw)) {
            // BalanceMode slot at offset 64 (op@0 + vault@32).
            if (DustHandler.readBalanceMode(data, 64) == DustHandler.BalanceMode.Full) {
                // `Full` liquidates the user's ENTIRE live balance, so it cannot be
                // pro-rated — a sliced fill would unwind the whole position and brick
                // the rest of the order. Require the slice to be the whole item.
                FullFillGuard.requireFullFillFromData(data, 96, amount);
                _withdrawFull(vault, onBehalfOf, amount, receiver);
            } else {
                IEVC(IEulerVault(vault).EVC())
                    .call(vault, onBehalfOf, 0, abi.encodeCall(IEulerVault.withdraw, (amount, receiver, onBehalfOf)));
            }
        } else {
            revert BadOp(op);
        }
    }

    /// @dev Full mode: withdraw the user's entire withdrawable balance to this
    ///      module, forward the signed `amount` to `receiver`, and sweep the
    ///      excess back to the user. Measures what actually landed (the vault may
    ///      credit less than the pre-call `maxWithdraw` estimate) and requires it
    ///      to cover the order. Its own frame keeps the stack shallow.
    function _withdrawFull(address vault, address onBehalfOf, uint256 amount, address receiver) private {
        address asset = IEulerVault(vault).asset();
        uint256 bal = IEulerVault(vault).maxWithdraw(onBehalfOf);
        uint256 balBefore = IERC20(asset).balanceOf(address(this));
        IEVC(IEulerVault(vault).EVC())
            .call(vault, onBehalfOf, 0, abi.encodeCall(IEulerVault.withdraw, (bal, address(this), onBehalfOf)));
        uint256 received = IERC20(asset).balanceOf(address(this)) - balBefore;
        require(received >= amount, "insufficient withdrawn");
        SafeTransferLib.safeTransfer(asset, receiver, amount);
        if (received > amount) SafeTransferLib.safeTransfer(asset, onBehalfOf, received - amount);
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
        /// @dev The item's FULL maker-signed amount. Composite ops are full-fill
        ///      only — see {FullFillGuard}.
        uint256 totalAmount;
    }

    error OnlyPermit3();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        BatchData memory p = abi.decode(data, (BatchData));

        // Composite items execute a multi-leg position op whose side leg lives in
        // `data` and does NOT pro-rate. Reject a sliced fill outright — see {FullFillGuard}.
        FullFillGuard.requireFullFill(amount, p.totalAmount);

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
        SafeTransferLib.forceApprove(collateralAsset, p.collateralVault, p.sideAmount);

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
            SafeTransferLib.forceApprove(borrowAsset, p.borrowVault, toRepay);
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
