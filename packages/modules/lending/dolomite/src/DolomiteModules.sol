// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {ITakerForModule} from "@core/interfaces/ITakerForModule.sol";
import {DustHandler} from "@lib/DustHandler.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";

import {
    IDolomiteMargin,
    AccountInfo,
    AssetAmount,
    AssetDenomination,
    AssetReference,
    WeiBalance,
    ActionType,
    ActionArgs
} from "./interfaces/IDolomite.sol";

// ════════════════════════════════════════════════════════════════════════════
//  Dolomite (DolomiteMargin) modules
//
//  Every Dolomite state change flows through `operate(accounts, actions)`, which
//  applies a batch of actions and runs ONE collateralisation check at the end.
//  The single-op modules each submit a one-action `operate`; the Level B
//  `DolomiteOperateModule` submits a two-action `operate` (deposit+borrow or
//  repay+withdraw) so the legs share that single check — the payoff of
//  Dolomite's architecture.
//
//  Authorisation: `operate` requires `msg.sender` to be a local operator of each
//  referenced account, so the user must `setOperators([{module, true}])` once for
//  EVERY module here (deposit included) — Dolomite has no permissionless
//  value-in path. The Permit3 token/taker allowance bounds the per-fill amount.
//
//  `data` (single-op) = abi.encode(address dolomite, uint256 marketId,
//  address token, uint256 accountNumber[, DustAction|BalanceMode]) — baseLen 128.
//  `marketId`/`token` are maker-signed (pinned into the order hash / taker ref)
//  rather than looked up, so the position the user authorised is fixed.
// ════════════════════════════════════════════════════════════════════════════

/// @dev Shared helpers for building and submitting `operate` calls.
abstract contract DolomiteBase {
    IPermit3 public immutable permit3;

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    /// @dev A positive (supply) delta in `marketId`, funded from `otherAddress`.
    function _depositAction(uint256 marketId, uint256 amount, address from) internal pure returns (ActionArgs memory) {
        return ActionArgs({
            actionType: ActionType.Deposit,
            accountId: 0,
            amount: AssetAmount(true, AssetDenomination.Wei, AssetReference.Delta, amount),
            primaryMarketId: marketId,
            secondaryMarketId: 0,
            otherAddress: from,
            otherAccountId: 0,
            data: ""
        });
    }

    /// @dev A negative (withdraw/borrow) delta in `marketId`, sent to `to`.
    function _withdrawAction(uint256 marketId, uint256 amount, address to) internal pure returns (ActionArgs memory) {
        return ActionArgs({
            actionType: ActionType.Withdraw,
            accountId: 0,
            amount: AssetAmount(false, AssetDenomination.Wei, AssetReference.Delta, amount),
            primaryMarketId: marketId,
            secondaryMarketId: 0,
            otherAddress: to,
            otherAccountId: 0,
            data: ""
        });
    }

    function _operate(address dolomite, address user, uint256 accountNumber, ActionArgs memory action) internal {
        AccountInfo[] memory accounts = new AccountInfo[](1);
        accounts[0] = AccountInfo(user, accountNumber);
        ActionArgs[] memory actions = new ActionArgs[](1);
        actions[0] = action;
        IDolomiteMargin(dolomite).operate(accounts, actions);
    }

    /// @dev The account's debt in `marketId` (0 if the balance is non-negative).
    function _debtOf(address dolomite, address user, uint256 accountNumber, uint256 marketId)
        internal
        view
        returns (uint256)
    {
        WeiBalance memory w = IDolomiteMargin(dolomite).getAccountWei(AccountInfo(user, accountNumber), marketId);
        return w.sign ? 0 : w.value;
    }
}

// ──────────────────── Dolomite deposit maker module ────────────────────
//
// Single-op module: pulls `token` from the user via Permit3 and supplies it into
// the user's Dolomite account as a one-action `operate`. The module is the
// Deposit action's funding source (`otherAddress`), so it must be a local
// operator of the user. `data = abi.encode(dolomite, marketId, token, accountNumber)`.
//
contract DolomiteDepositModule is DolomiteBase, IMakerModule {
    error NotSettlement();

    address public immutable settlement;

    constructor(address _permit3, address _settlement) DolomiteBase(_permit3) {
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();

        (address dolomite, uint256 marketId, address token, uint256 accountNumber) =
            abi.decode(data, (address, uint256, address, uint256));

        permit3.transferFrom(onBehalfOf, address(this), token, uint160(amount));
        SafeTransferLib.forceApprove(token, dolomite, amount);
        _operate(dolomite, onBehalfOf, accountNumber, _depositAction(marketId, amount, address(this)));
    }
}

// ──────────────────── Dolomite repay maker module ────────────────────
//
// Closes the user's borrow in `marketId`, handling interest-accrual over-repay
// with a pull-exact strategy: read the live debt and repay `min(amount, debt)`.
// In SweepToUser the over-repay buffer is never pulled, so nothing sits in this
// module for a caller to redirect. On Recycle the module takes the full signed
// ceiling, repays, and re-supplies the surplus into the user's Dolomite account
// (best-effort, sweep fallback). The module is the Deposit funding source, so it
// must be a local operator of the user.
//
// `nonReentrant` guards weird-token transfer hooks.
// `data = abi.encode(dolomite, marketId, token, accountNumber[, DustHandler.DustAction])`.
//
contract DolomiteRepayModule is DolomiteBase, IMakerModule {
    uint256 private _locked = 1;

    error Reentrancy();
    error NotSettlement();

    address public immutable settlement;

    constructor(address _permit3, address _settlement) DolomiteBase(_permit3) {
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();
        if (_locked != 1) revert Reentrancy();
        _locked = 2;

        (address dolomite, uint256 marketId, address token, uint256 accountNumber) =
            abi.decode(data, (address, uint256, address, uint256));
        DustHandler.DustAction action = DustHandler.readAction(data, 128); // base = (address,uint256,address,uint256)

        _pullAndRepay(dolomite, marketId, token, accountNumber, amount, onBehalfOf, action);
        _disposeResidual(dolomite, marketId, token, accountNumber, onBehalfOf, action);

        _locked = 1;
    }

    function _pullAndRepay(
        address dolomite,
        uint256 marketId,
        address token,
        uint256 accountNumber,
        uint256 amount,
        address onBehalfOf,
        DustHandler.DustAction action
    ) private {
        uint256 debt = _debtOf(dolomite, onBehalfOf, accountNumber, marketId);
        uint256 toRepay = amount < debt ? amount : debt;

        uint256 toPull = action == DustHandler.DustAction.Recycle ? amount : toRepay;
        if (toPull > 0) permit3.transferFrom(onBehalfOf, address(this), token, uint160(toPull));

        if (toRepay > 0) {
            SafeTransferLib.forceApprove(token, dolomite, toRepay);
            _operate(dolomite, onBehalfOf, accountNumber, _depositAction(marketId, toRepay, address(this)));
        }
    }

    /// @dev Re-supply (opt-in) the residual into the user's Dolomite account via a
    ///      one-action deposit `operate`, else sweep to the user.
    function _disposeResidual(
        address dolomite,
        uint256 marketId,
        address token,
        uint256 accountNumber,
        address onBehalfOf,
        DustHandler.DustAction action
    ) private {
        uint256 residual = IERC20(token).balanceOf(address(this));
        if (residual == 0) return;

        AccountInfo[] memory accounts = new AccountInfo[](1);
        accounts[0] = AccountInfo(onBehalfOf, accountNumber);
        ActionArgs[] memory actions = new ActionArgs[](1);
        actions[0] = _depositAction(marketId, residual, address(this));

        DustHandler.disposeResidual(
            token, residual, onBehalfOf, action, dolomite, abi.encodeCall(IDolomiteMargin.operate, (accounts, actions))
        );
    }
}

// ──────────────────── Dolomite combined taker module ────────────────────
//
// Fuses the borrow and withdraw taker legs into a SINGLE contract. A leading
// `op` flag in `data` selects the leg, so a user who runs the full leverage
// round-trip authorizes ONE module address instead of two — a single
// `setOperators([{module, true}])` covers both borrow and withdraw, and the
// Dolomite operator surface shrinks accordingly.
//
// Withdrawing collateral and borrowing are the SAME `operate` Withdraw action
// (a negative delta sent to `otherAddress`); a borrow simply drives the balance
// past zero, which Dolomite permits and checks at the end of `operate`. So op 0
// (Borrow) and op-1-Exact (Withdraw) share the same `_withdrawAction(marketId,
// amount, receiver)` path; only op-1-Full takes the custody+sweep branch.
//
// Safety is unchanged from the split modules: the Permit3 taker allowance is
// keyed by `ref = keccak256(data)`, and `op` is the first word of `data`, so
// borrow-data and withdraw-data hash to DIFFERENT refs. The user therefore still
// grants a separate amount-gated allowance per leg — the flag cannot be flipped
// to spend a borrow allowance on a withdraw (or vice-versa). The only thing
// shared is the coarse Dolomite operator boolean, which is per-address by
// construction.
//
//   byte map (base — op first; all old offsets shift +32):
//     op            @ 0    (uint8)
//     dolomite      @ 32   (address)
//     marketId      @ 64   (uint256)
//     token         @ 96   (address)
//     accountNumber @ 128  (uint256)   → base length 160
//
//   op = 0 (Borrow):
//     data = abi.encode(uint8(0), dolomite, marketId, token, accountNumber)
//
//   op = 1 (Withdraw):
//     data = abi.encode(uint8(1), dolomite, marketId, token, accountNumber[, BalanceMode])
//       — BalanceMode slot at offset 160. `Full` ⇒ custody+sweep branch.
//
contract DolomiteTakerModule is DolomiteBase, ITakerModule {
    enum Op {
        Borrow, // 0
        Withdraw // 1
    }

    error OnlyPermit3();
    error BadOp(uint8 op);

    constructor(address _permit3) DolomiteBase(_permit3) {}

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        (uint8 op, address dolomite, uint256 marketId, address token, uint256 accountNumber) =
            abi.decode(data, (uint8, address, uint256, address, uint256));

        if (op == uint8(Op.Withdraw) && DustHandler.readBalanceMode(data, 160) == DustHandler.BalanceMode.Full) {
            // `Full` liquidates the user's ENTIRE live balance, so it cannot be
            // pro-rated — a sliced fill would unwind the whole position and brick
            // the rest of the order. Require the slice to be the whole item.
            FullFillGuard.requireFullFillFromData(data, 192, amount);
            WeiBalance memory w =
                IDolomiteMargin(dolomite).getAccountWei(AccountInfo(onBehalfOf, accountNumber), marketId);
            uint256 bal = w.sign ? w.value : 0;

            // Measure the token actually received from the withdraw (fee-on-transfer
            // / rebasing safe) and never forward more than that.
            uint256 snapshot = IERC20(token).balanceOf(address(this));
            _operate(dolomite, onBehalfOf, accountNumber, _withdrawAction(marketId, bal, address(this)));
            uint256 received = IERC20(token).balanceOf(address(this)) - snapshot;

            require(received >= amount, "insufficient withdrawn");
            SafeTransferLib.safeTransfer(token, receiver, amount);
            if (received > amount) SafeTransferLib.safeTransfer(token, onBehalfOf, received - amount);
        } else if (op == uint8(Op.Borrow) || op == uint8(Op.Withdraw)) {
            // Borrow == exact withdraw: a single negative delta sent to `receiver`.
            _operate(dolomite, onBehalfOf, accountNumber, _withdrawAction(marketId, amount, receiver));
        } else {
            revert BadOp(op);
        }
    }
}

// ──────────────────── Dolomite operate module (Level B) ────────────────────
//
// Composite module that fuses a value-in and a value-out leg into ONE `operate`
// so they share Dolomite's single end-of-call collateralisation check. Two
// shapes:
//
//   • Open  — deposit `sideAmount` collateral (module-funded via Permit3) +
//             withdraw/borrow `amount` to `receiver`, drawn against the freshly
//             deposited collateral under one check.
//   • Close — repay up to `sideAmount` of the user's borrow (module-funded,
//             capped at live debt) + withdraw `amount` collateral to `receiver`,
//             the check seeing the debt reduced before the collateral leaves.
//
// Trade-off vs single-op: one module signs a whole batch under one
// `keccak256(data)` taker ref — still fully maker-signed and amount-gated, but it
// gives up the one-action-per-module blast-radius invariant. The user must
// `setOperators([{module, true}])` once.
//
// `data = abi.encode(BatchData)` (see struct); `amount`/`receiver` carry the
// value-out leg.
//
contract DolomiteOperateModule is DolomiteBase, ITakerModule {
    enum BatchMode {
        Open, // 0 — deposit collateral + borrow
        Close // 1 — repay debt + withdraw collateral
    }

    struct BatchData {
        uint256 mode;
        address dolomite;
        uint256 collMarketId;
        address collToken;
        uint256 borrowMarketId;
        address borrowToken;
        uint256 accountNumber;
        uint256 sideAmount;
        /// @dev The item's FULL maker-signed amount. Composite ops are full-fill
        ///      only — see {FullFillGuard}.
        uint256 totalAmount;
    }

    error OnlyPermit3();

    constructor(address _permit3) DolomiteBase(_permit3) {}

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        BatchData memory p = abi.decode(data, (BatchData));

        // Composite items execute a multi-leg position op whose side leg lives in
        // `data` and does NOT pro-rate. Reject a sliced fill outright — see {FullFillGuard}.
        FullFillGuard.requireFullFill(amount, p.totalAmount);

        ActionArgs[] memory actions = new ActionArgs[](2);
        if (BatchMode(uint8(p.mode)) == BatchMode.Open) {
            // Pull collateral to fund the deposit leg, then deposit + borrow.
            permit3.transferFrom(onBehalfOf, address(this), p.collToken, uint160(p.sideAmount));
            SafeTransferLib.forceApprove(p.collToken, p.dolomite, p.sideAmount);
            actions[0] = _depositAction(p.collMarketId, p.sideAmount, address(this));
            actions[1] = _withdrawAction(p.borrowMarketId, amount, receiver);
        } else {
            // Pull the (capped) repay funding, then repay + withdraw collateral.
            uint256 debt = _debtOf(p.dolomite, onBehalfOf, p.accountNumber, p.borrowMarketId);
            uint256 toRepay = p.sideAmount < debt ? p.sideAmount : debt;
            if (toRepay > 0) {
                permit3.transferFrom(onBehalfOf, address(this), p.borrowToken, uint160(toRepay));
                SafeTransferLib.forceApprove(p.borrowToken, p.dolomite, toRepay);
            }
            actions[0] = _depositAction(p.borrowMarketId, toRepay, address(this));
            actions[1] = _withdrawAction(p.collMarketId, amount, receiver);
        }

        AccountInfo[] memory accounts = new AccountInfo[](1);
        accounts[0] = AccountInfo(onBehalfOf, p.accountNumber);
        IDolomiteMargin(p.dolomite).operate(accounts, actions);
    }
}

// ──────────── Dolomite TAKE_FOR open module (core-funded collateral) ────────────
//
// The same two-action `operate` (deposit + borrow under ONE collateralisation
// check) as {DolomiteOperateModule}'s Open path, with the collateral sized by the
// settler instead of pinned in `data`.
//
// Like Euler, Dolomite has no position identity object: a position IS the balance
// set of the maker-signed `(owner, accountNumber)` sub-account, and `operate` may
// be applied to it repeatedly. So {DolomiteOperateModule}'s {FullFillGuard} was
// never protecting a protocol constraint — only the fact that a constant
// `sideAmount` cannot pro-rate. It is GONE here: every slice is its own two-action
// `operate` sharing one check.
//
// `data = abi.encode(OpenData{forDesc, forCap, dolomite, collMarketId, collToken,
//                             borrowMarketId, accountNumber})`.
//
// Auth is unchanged: `setOperators([{module, true}])` once, and debt must live in a
// NON-ZERO sub-account (account 0 is lend-only on this deployment).
//
contract DolomiteTakeForModule is DolomiteBase, ITakerForModule {
    struct OpenData {
        uint256 forDesc; // word 0 — the funding descriptor
        uint256 forCap; //  word 1 — the balance form's mandatory cap
        address dolomite;
        uint256 collMarketId;
        address collToken;
        uint256 borrowMarketId;
        uint256 accountNumber;
    }

    error OnlyPermit3();

    constructor(address _permit3) DolomiteBase(_permit3) {}

    function takeForOnBehalf(
        address onBehalfOf,
        uint256 amount,
        uint256 forAmount,
        address receiver,
        bytes calldata data
    ) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        OpenData memory p = abi.decode(data, (OpenData));

        ActionArgs[] memory actions = new ActionArgs[](forAmount == 0 ? 1 : 2);
        uint256 k;
        if (forAmount != 0) {
            permit3.transferFrom(onBehalfOf, address(this), p.collToken, uint160(forAmount));
            SafeTransferLib.forceApprove(p.collToken, p.dolomite, forAmount);
            actions[k++] = _depositAction(p.collMarketId, forAmount, address(this));
        }
        actions[k] = _withdrawAction(p.borrowMarketId, amount, receiver);

        AccountInfo[] memory accounts = new AccountInfo[](1);
        accounts[0] = AccountInfo(onBehalfOf, p.accountNumber);
        IDolomiteMargin(p.dolomite).operate(accounts, actions);
    }
}
