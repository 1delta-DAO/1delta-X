// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {DustHandler} from "@lib/DustHandler.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {IEulerVault} from "./interfaces/IEulerV2.sol";

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
//  This file now holds ONLY the two makers, because only they need no EVC
//  operator status: value flowing INTO the protocol is authenticated as the module
//  itself. Every op that acts AS the maker's account — borrow, withdraw, the fused
//  `EVC.batch` opens and closes, and the core-funded `TAKE_FOR` open in both
//  funding shapes — lives in {EulerV2OperatorModule}, merged there because they all
//  require the same unscoped `setAccountOperator` boolean.
// ════════════════════════════════════════════════════════════════════════════

/// @dev The maker's EVC sub-account named by an OPTIONAL trailing `subId` word.
library EulerSubAccount {
    /// @dev `subId` is not a valid EVC sub-account id (must be < 256).
    error BadSubAccount(uint256 subId);

    /// @notice `owner ^ subId` for the word at `offset`, or `owner` when absent.
    ///         The XOR stays inside `owner`'s own 256-account EVC group, so it can
    ///         never name another principal. 2026-09-30 audit L-ED-6.
    function account(address owner, bytes calldata data, uint256 offset) internal pure returns (address) {
        if (data.length < offset + 32) return owner;
        uint256 subId = uint256(bytes32(data[offset:offset + 32]));
        if (subId > 0xff) revert BadSubAccount(subId);
        return address(uint160(owner) ^ uint160(subId));
    }
}

// ──────────────────── Euler V2 deposit maker module ────────────────────
//
// Single-op module: pulls the vault's `asset()` from the user via Permit3, then
// supplies it into `vault` crediting shares to the user. Called directly, so the
// authenticated (funding) account is this module while the shares land on the
// user. No EVC operator status is needed (value flows *into* the protocol).
// `data = abi.encode(vault[, subId])` — base 32; optional `subId@32` (< 256)
// credits the maker's EVC SUB-ACCOUNT `maker ^ subId` instead of the primary
// account (see {EulerV2OperatorModule._plainAccount}); absent ⇒ 0 ⇒ primary.
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
        address account = EulerSubAccount.account(onBehalfOf, data, 32); // validated before any pull
        address asset = IEulerVault(vault).asset();

        permit3.transferFrom(onBehalfOf, address(this), asset, uint160(amount));
        SafeTransferLib.forceApprove(asset, vault, amount);
        IEulerVault(vault).deposit(amount, account);
        // Clear the scoped grant: `vault` is decoded from the order's `data` on a
        // SHARED singleton, so it is attacker-choosable — anyone can author an
        // order naming themselves as maker. A target that consumes less than
        // approved would leave a standing third-party claim on any FUTURE balance
        // of this module, which is what turns a later stranded-balance bug into a
        // theft. {SafeTransferLib.ensureApproval} forbids this shape. F25 / A-3.
        SafeTransferLib.forceApprove(asset, vault, 0);
    }
}

// ──────────────────── Euler V2 repay maker module ────────────────────
//
// Closes the user's borrow in `vault`, handling interest-accrual over-repay with
// a pull-exact strategy: read the live debt, repay `min(amount, debt)`. The clamp
// is LOAD-BEARING: EVK's `repay` does NOT cap at the debt — any finite amount
// above it reverts `E_RepayTooMuch` (only the `type(uint256).max` sentinel
// resolves to the full debt) — and `debtOf` is the same `toAssetsUp` figure
// `repay` checks in the same block, so the clamp is exact. Pulling only what is
// needed also keeps the over-repay buffer out of this contract entirely
// (SweepToUser), removing the "stray dust a caller can redirect" vector at the
// source. On Recycle the module takes the full signed ceiling, repays the debt,
// and re-supplies the surplus as a lend balance into the same vault for the
// user — best-effort, sweep fallback.
//
// Repay is permissionless on behalf of the user, so no EVC operator status is
// needed; the module funds the repay as the authenticated account.
//
// `nonReentrant` guards weird-token transfer hooks.
// `data = abi.encode(vault[, DustHandler.DustAction[, subId]])` — base 32;
// DustAction@32 optional (absent ⇒ SweepToUser); `subId@64` optional (< 256):
// repay (and Recycle into) the maker's EVC SUB-ACCOUNT `maker ^ subId`. The
// residual is always swept to the maker's own wallet, never to a sub-account
// address (which cannot move an ERC-20 it holds).
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

        // The balance this module held BEFORE the pull. Everything below disposes of
        // the DELTA over it, never the whole balance: a module address can be sent
        // tokens by anyone, and "sweep everything to the user" pays that to whoever
        // happens to be filling. See the floor overload of {DustHandler.disposeResidual}.
        uint256 floor = IERC20(asset).balanceOf(address(this));

        _pullAndRepay(vault, asset, amount, onBehalfOf, action == DustHandler.DustAction.Recycle, data);
        _disposeResidual(vault, asset, onBehalfOf, action, floor, data);

        _locked = 1;
    }

    /// @dev Pull the funding token and repay. SweepToUser pulls only `toRepay`, so
    ///      the buffer never enters this contract; Recycle pulls the full signed
    ///      ceiling so the surplus can be redirected into the user's position.
    function _pullAndRepay(
        address vault,
        address asset,
        uint256 amount,
        address onBehalfOf,
        bool recycle,
        bytes calldata data
    ) private {
        address account = EulerSubAccount.account(onBehalfOf, data, 64);
        uint256 toRepay;
        {
            // Load-bearing: EVK `repay` reverts `E_RepayTooMuch` above the debt.
            uint256 debt = IEulerVault(vault).debtOf(account);
            toRepay = amount < debt ? amount : debt;
        }
        {
            uint256 toPull = recycle ? amount : toRepay;
            if (toPull > 0) permit3.transferFrom(onBehalfOf, address(this), asset, uint160(toPull));
        }
        if (toRepay > 0) {
            SafeTransferLib.forceApprove(asset, vault, toRepay);
            IEulerVault(vault).repay(toRepay, account);
            // Clear the scoped grant: `vault` is decoded from the order's `data` on a
            // SHARED singleton, so it is attacker-choosable — anyone can author an
            // order naming themselves as maker. A target that consumes less than
            // approved would leave a standing third-party claim on any FUTURE balance
            // of this module, which is what turns a later stranded-balance bug into a
            // theft. {SafeTransferLib.ensureApproval} forbids this shape. F25 / A-3.
            SafeTransferLib.forceApprove(asset, vault, 0);
        }
    }

    /// @dev Re-supply (opt-in) the residual as a lend balance in the same vault,
    ///      else sweep to the user. Best-effort recycle with a guaranteed sweep.
    function _disposeResidual(
        address vault,
        address asset,
        address onBehalfOf,
        DustHandler.DustAction action,
        uint256 floor,
        bytes calldata data
    ) private {
        // The delta THIS call produced, not the module's whole balance — `floor` is
        // what it already held. On the normal path a module is pull-exact and starts
        // empty, so `floor` is 0 and this is behaviour-preserving.
        uint256 bal = IERC20(asset).balanceOf(address(this));
        if (bal <= floor) return;
        uint256 residual;
        unchecked {
            residual = bal - floor; // bal > floor
        }
        DustHandler.disposeResidual(
            asset,
            residual,
            floor,
            onBehalfOf,
            action,
            vault,
            abi.encodeCall(IEulerVault.deposit, (residual, EulerSubAccount.account(onBehalfOf, data, 64)))
        );
    }
}

// ──────────── Euler V2 value-out taker modules — MOVED ────────────
//
// `EulerV2TakerModule`, `EulerV2BatchModule`, `EulerV2TakeForModule` and
// `EulerV2PreFundTakeForModule` lived here. All four now live in
// {EulerV2OperatorModule} as ops of one contract.
//
// The merge is by GRANT. Every one of them authenticated value-out through
// `EVC.call` / `EVC.batch` as the maker's account, which Euler admits only for an
// ACCOUNT OPERATOR — an unscoped, uncapped, non-expiring boolean. Four addresses
// meant four independent total-control grants over the same account; splitting
// them divided no authority and multiplied the approvals. One address, one
// `EVC.setAccountOperator`.
//
// The two makers ABOVE stay here on purpose: value flowing INTO the protocol is
// authenticated as the module itself, so they need no operator status at all.
// They are a different grant class (a Permit3 token allowance) and a merged
// contract redeploys as a unit — folding them in would let a fix to a value-out
// op force re-approval of a grant it never touched.
//
// Wire: `Op.Borrow` (0) and `Op.Withdraw` (1) keep their values, so those blobs are
// unchanged. `EulerV2BatchModule`'s `BatchMode.Open`/`Close` become `Op.BatchOpen`
// (2) / `Op.BatchClose` (3), and the `TAKE_FOR` seam gains `Op.Open` (4) in its
// descriptor's op bits [244,252).
