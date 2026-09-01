// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {IFundingSource} from "@core/interfaces/IFundingSource.sol";
import {IProceedsAsset} from "@core/interfaces/IProceedsAsset.sol";
import {FundingPreflight} from "@lib/FundingPreflight.sol";
import {DustHandler} from "@lib/DustHandler.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";
import {PermitHelper} from "@lib/PermitHelper.sol";
import {DelegationHelper} from "@lib/DelegationHelper.sol";

import {IAaveV3Pool} from "./interfaces/IAaveV3.sol";

// ──────────────────── Aave v3 deposit maker module ────────────────────
//
// Single-op module: pulls `asset` from the user via Permit3, then supplies
// on the user's behalf.
//
// Optional EIP-2612 permit replay: if the caller appends permit fields to
// `data`, the module replays them before `permit3.transferFrom` so the user
// never needs a prior on-chain `approve` (gasless deposits for EIP-2612 tokens).
//
// `data = abi.encode(pool, asset[, deadline, v, r, s])`
//
contract AaveV3DepositModule is IMakerModule, IFundingSource {
    IPermit3 public immutable permit3;
    address public immutable settlement;

    error NotSettlement();

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();

        (address pool, address asset) = abi.decode(data, (address, address));

        // Optional permit: approves Permit3 at ERC-20 level. base = (address,address) = 64 bytes.
        PermitHelper.replayIfPresent(data, 64, asset, onBehalfOf, address(permit3), amount);

        permit3.transferFrom(onBehalfOf, address(this), asset, uint160(amount));
        // Scoped approve + CLEAR, not a standing grant. `pool` is decoded from the
        // order's `data` on a SHARED singleton module, so it is attacker-choosable —
        // anyone can author an order naming themselves as maker. A target that
        // consumes less than approved would leave this module holding a permanent
        // third-party claim on any FUTURE balance of `asset`, which is what turns a
        // later residual-stranding bug into a theft. {SafeTransferLib.ensureApproval}'s
        // own note forbids exactly this shape, and every Midnight module already
        // clears. F25 / lead A-3.
        SafeTransferLib.forceApprove(asset, pool, amount);
        IAaveV3Pool(pool).supply(asset, amount, onBehalfOf, 0);
        SafeTransferLib.forceApprove(asset, pool, 0);
    }

    /// @inheritdoc IFundingSource
    /// @dev `asset` is field 1 of this module's layout. The pull is
    ///      `permit3.transferFrom(user, THIS MODULE, asset, …)`, so the grant the lens
    ///      has to report is `(user, module, asset)` — a book neither the order's
    ///      input-leg preflight (spender = the settler) nor the taker book reads.
    function fundingSource(address onBehalfOf, bytes calldata data)
        external
        view
        override
        returns (address asset, uint256 available)
    {
        (, asset) = abi.decode(data, (address, address));
        available = FundingPreflight.pullable(permit3, address(this), onBehalfOf, asset);
    }
}

// ──────────────────── Aave v3 repay maker module ────────────────────
//
// Handles interest-accrual over-repay cleanly with a pull-exact strategy:
//
//   1. Read the user's live debt — `IERC20(debtToken).balanceOf(user)`, where
//      `debtToken` is the variable/stable debt token matching `rateMode` — and
//      compute `toRepay = min(amount, debt)` (`amount` = maker-signed ceiling).
//   2. Pull exactly `toRepay` from the user via Permit3 and
//      `pool.repay(asset, toRepay, rateMode, user)`.
//
// In the default (SweepToUser) mode the over-repay buffer is never pulled, so no
// dust is created and nothing sits in this contract for a caller to redirect —
// the "anyone can call this and redirect dust" vector is removed at the source,
// without a `msg.sender == permit3` gate. When the maker-signed `data` opts into
// Recycle, the module instead takes custody of the full signed ceiling and, after
// repaying, re-supplies the surplus into the user's Aave position (best-effort,
// with a guaranteed sweep fallback if the supply reverts — cap reached, frozen,
// paused). Either way disposal is locked to `onBehalfOf` / the pool, never a
// caller-chosen address, so the redirect vector stays closed. The debt token
// lives in `data` (so it is maker-signed) rather than being derived from a
// version-fragile `getReserveData` layout.
//
// `nonReentrant` guards against weird-token transfer hooks.
// `data = abi.encode(pool, asset, rateMode, debtToken[, DustHandler.DustAction[, deadline, v, r, s]])`
// — the trailing dust action is optional (absent ⇒ SweepToUser);
//   the permit block (128 bytes) is optional after the dust action slot.
//
contract AaveV3RepayModule is IMakerModule, IFundingSource {
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

        // Decode only (pool, asset) here — both are needed for the dust step
        // below. The pull+repay runs in its own frame so its locals don't pile up
        // on the stack (avoids stack-too-deep). The base tuple is all-static, so a
        // prefix decode is sound.
        (address pool, address asset) = abi.decode(data, (address, address));
        // base = (address,address,uint256,address) = 128 bytes; DustAction at 128, permit at 160.
        DustHandler.DustAction action = DustHandler.readAction(data, 128);
        PermitHelper.replayIfPresent(data, 160, asset, onBehalfOf, address(permit3), amount);

        // The balance this module held BEFORE the pull. Everything below disposes of
        // the delta over it, never the whole balance — see {DustHandler.disposeResidual}'s
        // floor overload for why "the module ends empty" is the wrong invariant.
        uint256 floor = IERC20(asset).balanceOf(address(this));

        _pullAndRepay(data, amount, onBehalfOf, asset, pool, action == DustHandler.DustAction.Recycle);

        _disposeResidual(pool, asset, onBehalfOf, action, floor);

        _locked = 1;
    }

    /// @inheritdoc IFundingSource
    /// @dev `asset` is field 1 of this module's layout. The pull is
    ///      `permit3.transferFrom(user, THIS MODULE, asset, …)`, so the grant the lens
    ///      has to report is `(user, module, asset)` — a book neither the order's
    ///      input-leg preflight (spender = the settler) nor the taker book reads.
    function fundingSource(address onBehalfOf, bytes calldata data)
        external
        view
        override
        returns (address asset, uint256 available)
    {
        (, asset) = abi.decode(data, (address, address));
        available = FundingPreflight.pullable(permit3, address(this), onBehalfOf, asset);
    }

    /// @dev Pull the funding token and repay. SweepToUser pulls only what the
    ///      debt needs — the over-repay buffer is never pulled, so the surplus
    ///      stays in the maker's wallet (the solver paid `tokenOut` straight to
    ///      them). Recycle takes custody of the full signed ceiling so the surplus
    ///      can be redirected into the user's position by `_disposeResidual`;
    ///      disposal stays locked to `onBehalfOf` / the pool, never a caller.
    function _pullAndRepay(
        bytes calldata data,
        uint256 amount,
        address onBehalfOf,
        address asset,
        address pool,
        bool recycle
    ) private {
        uint256 rateMode;
        uint256 toRepay;
        {
            // (pool, asset) already decoded by the caller — decode only the tail
            // (rateMode @64, debtToken @96) via a calldata slice instead of
            // re-decoding all four fields.
            address debtToken;
            (rateMode, debtToken) = abi.decode(data[64:], (uint256, address));
            uint256 debt = IERC20(debtToken).balanceOf(onBehalfOf);
            toRepay = amount < debt ? amount : debt;
        }
        {
            uint256 toPull = recycle ? amount : toRepay;
            if (toPull > 0) permit3.transferFrom(onBehalfOf, address(this), asset, uint160(toPull));
        }
        if (toRepay > 0) {
            // Scoped approve + CLEAR, not a standing grant. `pool` is decoded from the
            // order's `data` on a SHARED singleton module, so it is attacker-choosable —
            // anyone can author an order naming themselves as maker. A target that
            // consumes less than approved would leave this module holding a permanent
            // third-party claim on any FUTURE balance of `asset`, which is what turns a
            // later residual-stranding bug into a theft. {SafeTransferLib.ensureApproval}'s
            // own note forbids exactly this shape, and every Midnight module already
            // clears. F25 / lead A-3.
            SafeTransferLib.forceApprove(asset, pool, toRepay);
            IAaveV3Pool(pool).repay(asset, toRepay, rateMode, onBehalfOf);
            SafeTransferLib.forceApprove(asset, pool, 0);
        }
    }

    /// @dev Dispose of any residual THIS call produced: re-supply into the user's
    ///      Aave position (Recycle, best-effort with a guaranteed sweep fallback) or
    ///      sweep to the user (default). In its own frame to keep the stack shallow.
    ///
    ///      `floor` is the module's balance before the pull. Measuring the delta
    ///      rather than reading the whole balance is what stops a stranded or donated
    ///      amount being paid out to whoever fills next — see the floor overload of
    ///      {DustHandler.disposeResidual}. On the normal path the module starts empty
    ///      and `floor` is 0, so this is behaviour-preserving.
    function _disposeResidual(
        address pool,
        address asset,
        address onBehalfOf,
        DustHandler.DustAction action,
        uint256 floor
    ) private {
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
            pool,
            abi.encodeCall(IAaveV3Pool.supply, (asset, residual, onBehalfOf, 0))
        );
    }
}

// ──────────────────── Aave v3 withdraw taker module ────────────────────
//
// Single-op taker module. Permit3 decrements the taker allowance on
// `keccak256(data)`, then invokes `takeOnBehalf` here. The module pulls
// the user's aToken via the Permit3 token allowance (the user infinite-
// approves the aToken to this module), then calls `pool.withdraw` which
// burns the module's aTokens and sends the underlying to `receiver`.
//
// Optional `BalanceMode.Full` (trailing field): withdraw the user's ENTIRE
// (rebasing) aToken balance, forward the signed `amount` to `receiver`, and
// sweep the accrued excess back to `onBehalfOf`. Fill-or-kill only, and only
// after debt is cleared.
//
// Optional EIP-2612 permit replay (EXACT mode only): aTokens implement
// EIP-2612. Appending a permit block to `data` lets Permit3 pull aTokens
// without a prior on-chain `approve`. The BalanceMode slot MUST be encoded
// explicitly (as 0 = Exact) when including the permit block so the offsets
// are unambiguous.
//
// Exact: `abi.encode(pool, asset, aToken[, BalanceMode(0)[, deadline, v, r, s]])`
//   — BalanceMode at 96, permit block at 128 (EXACT mode only).
// Full:  `abi.encode(pool, asset, aToken, BalanceMode(1), totalAmount)`
//   — BalanceMode at 96, `totalAmount` at 128 and MANDATORY.
//   — `totalAmount` is the item's full maker-signed amount; {FullFillGuard} asserts
//     the slice equals it, and FAILS CLOSED when the word is absent
//     (`PartialFillUnsupported(amount, 0)`). It was previously undeclared here, so
//     a maker encoding `Full` from this map signed an order no filler could ever
//     settle. Declared in F25 (lead A-2).
//   — Full mode is incompatible with gasless permit (rebasing balance unknown
//     at signing time); use a standing ERC-20 approval in that case. That is why
//     the permit block and `totalAmount` can share offset 128: the two modes are
//     mutually exclusive branches. (Contrast the Morpho Blue / Comet modules, where
//     the auth block IS needed in both modes and the offsets had to diverge.)
//
contract AaveV3WithdrawModule is ITakerModule, IProceedsAsset, IFundingSource {
    IPermit3 public immutable permit3;

    error OnlyPermit3();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        (address pool, address asset, address aToken) = abi.decode(data, (address, address, address));

        if (DustHandler.readBalanceMode(data, 96) == DustHandler.BalanceMode.Full) {
            // `Full` liquidates the user's ENTIRE live balance, so it cannot be
            // pro-rated — a sliced fill would unwind the whole position and brick
            // the rest of the order. Require the slice to be the whole item.
            FullFillGuard.requireFullFillFromData(data, 128, amount);
            // Full mode: user must have a standing ERC-20 approval on aToken.
            // Pull the user's entire (rebasing) aToken balance and withdraw it all
            // to this module; `withdraw(max)` mops up any 1-wei transfer rounding.
            // aTokens this module ALREADY held are not this user's, and
            // `withdraw(max)` burns the module's whole aToken balance — so without
            // this they would convert into `received` and be swept to `onBehalfOf`
            // below. aTokens are 1:1 with the underlying, so the pre-existing amount
            // subtracts directly. (`beforeBal` already excludes pre-existing
            // UNDERLYING; this is the aToken half of the same measurement.)
            uint256 aBefore = IERC20(aToken).balanceOf(address(this));
            uint256 bal = IERC20(aToken).balanceOf(onBehalfOf);
            permit3.transferFrom(onBehalfOf, address(this), aToken, uint160(bal));
            uint256 beforeBal = IERC20(asset).balanceOf(address(this));
            IAaveV3Pool(pool).withdraw(asset, type(uint256).max, address(this));
            uint256 received = IERC20(asset).balanceOf(address(this)) - beforeBal;
            // Saturating, so a rounding wei can never underflow-panic; the `require`
            // below is the fail-closed gate either way.
            received = received > aBefore ? received - aBefore : 0;
            require(received >= amount, "insufficient withdrawn");
            SafeTransferLib.safeTransfer(asset, receiver, amount);
            if (received > amount) SafeTransferLib.safeTransfer(asset, onBehalfOf, received - amount);
        } else {
            // Exact mode: optional EIP-2612 permit on aToken at offset 128.
            // Approves Permit3 to pull exactly `amount` aTokens from the user.
            PermitHelper.replayIfPresent(data, 128, aToken, onBehalfOf, address(permit3), amount);
            permit3.transferFrom(onBehalfOf, address(this), aToken, uint160(amount));
            IAaveV3Pool(pool).withdraw(asset, amount, receiver);
        }
    }

    /// @inheritdoc IProceedsAsset
    /// @dev The UNDERLYING (field 1), not the aToken: the aToken is what this module
    ///      pulls IN to burn, the underlying is what lands on `receiver` and is what
    ///      an input leg has to be able to consume.
    function proceedsAsset(bytes calldata data) external pure override returns (address asset) {
        (, asset) = abi.decode(data, (address, address));
    }

    /// @inheritdoc IFundingSource
    /// @dev The aToken (field 2) — pulled from the user in BOTH modes, so both need
    ///      the `(user, module, aToken)` grant. In `Full` mode the amount is the
    ///      user's whole live balance rather than the item's slice, which is why
    ///      `available` is min(allowance, balance) rather than the allowance alone.
    function fundingSource(address onBehalfOf, bytes calldata data)
        external
        view
        override
        returns (address asset, uint256 available)
    {
        (,, asset) = abi.decode(data, (address, address, address));
        available = FundingPreflight.pullable(permit3, address(this), onBehalfOf, asset);
    }
}

// ──────────────────── Aave v3 borrow taker module ────────────────────
//
// Single-op taker module. Issues a variable-rate borrow on behalf of the
// user and forwards proceeds to `receiver`.
//
// Optional EIP-712 delegation-with-sig replay: appending a delegation block
// to `data` grants this module credit delegation on-the-fly — no prior
// on-chain `approveDelegation` needed. The user signs a `delegationWithSig`
// on the variable/stable debt token and includes the sig + the debt token
// address in the order data. The delegation cap is set to `amount`.
//
// `data = abi.encode(pool, asset, rateMode[, debtToken, deadline, v, r, s])`
//   — base = 96 bytes (pool, asset, rateMode).
//   — delegation block at 96: (address debtToken, uint256 deadline, uint8 v,
//     bytes32 r, bytes32 s) = 160 bytes.
//   — rateMode: 1 = stable, 2 = variable (must match the debt token passed).
//
contract AaveV3BorrowModule is ITakerModule, IProceedsAsset {
    IPermit3 public immutable permit3;

    error OnlyPermit3();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        (address pool, address asset, uint256 rateMode) = abi.decode(data, (address, address, uint256));

        // Optional delegation-with-sig: grants this module borrow rights on
        // the debt token without a prior on-chain `approveDelegation`.
        // Block at 96: (debtToken, deadline, v, r, s) = 160 bytes.
        DelegationHelper.replayAaveDelegation(data, 96, onBehalfOf, address(this), amount);

        // Measure the delta rather than assuming the requested `amount` arrived: an
        // under-delivering borrow (fee-on-transfer underlying, a capped or
        // partially-filled reserve) would otherwise be topped up from any balance the
        // module happens to hold and paid to the solver, while the user keeps the full
        // debt — the H-3 River shape. Fail closed instead. Matches
        // {AaveV4BorrowModule}, which already carried this guard.
        uint256 balBefore = IERC20(asset).balanceOf(address(this));
        IAaveV3Pool(pool).borrow(asset, amount, rateMode, 0, onBehalfOf);
        uint256 received = IERC20(asset).balanceOf(address(this)) - balBefore;
        require(received >= amount, "insufficient borrowed");
        SafeTransferLib.safeTransfer(asset, receiver, amount);
        if (received > amount) SafeTransferLib.safeTransfer(asset, onBehalfOf, received - amount);
    }

    /// @inheritdoc IProceedsAsset
    /// @dev No {IFundingSource} counterpart: a bare borrow pulls nothing from the
    ///      user, it only issues debt. The value-OUT declaration is the whole of this
    ///      module's asset surface.
    function proceedsAsset(bytes calldata data) external pure override returns (address asset) {
        (, asset) = abi.decode(data, (address, address));
    }
}
