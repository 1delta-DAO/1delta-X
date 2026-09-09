// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {DustHandler} from "@lib/DustHandler.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";
import {PermitHelper} from "@lib/PermitHelper.sol";

import {IAaveV2Pool} from "./interfaces/IAaveV2.sol";

// ──────────────────── Aave V2 deposit maker module ────────────────────
//
// Single-op module: pulls `asset` from the user via Permit3, then deposits
// on the user's behalf via `pool.deposit`. Aave V2 uses `deposit` instead
// of the V3/V4 `supply`; the module shape is otherwise identical.
//
// Optional EIP-2612 permit replay: if the caller appends permit fields to
// `data`, the module replays them before calling `permit3.transferFrom` so
// the user never needs a prior on-chain `approve` (gasless deposits for
// tokens that implement EIP-2612, e.g. DAI, USDC on some networks).
//
// `data = abi.encode(pool, asset[, deadline, v, r, s])`
//
contract AaveV2DepositModule is IMakerModule {
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

        // Optional permit: approves Permit3 at the ERC-20 level so it can pull
        // without a standing allowance. base = (address,address) = 64 bytes.
        PermitHelper.replayIfPresent(data, 64, asset, onBehalfOf, address(permit3), amount);

        permit3.transferFrom(onBehalfOf, address(this), asset, uint160(amount));
        SafeTransferLib.forceApprove(asset, pool, amount);
        IAaveV2Pool(pool).deposit(asset, amount, onBehalfOf, 0);
        // Clear the scoped grant: `pool` is decoded from the order's `data` on a
        // SHARED singleton, so it is attacker-choosable — anyone can author an
        // order naming themselves as maker. A target that consumes less than
        // approved would leave a standing third-party claim on any FUTURE balance
        // of this module, which is what turns a later stranded-balance bug into a
        // theft. {SafeTransferLib.ensureApproval} forbids this shape. F25 / A-3.
        SafeTransferLib.forceApprove(asset, pool, 0);
    }
}

// ──────────────────── Aave V2 repay maker module ────────────────────
//
// Handles interest-accrual over-repay cleanly with a pull-exact strategy
// (same design as `AaveV3RepayModule`):
//
//   1. Read the user's live debt from `debtToken.balanceOf(user)` and compute
//      `toRepay = min(amount, debt)`, where `amount` is the maker-signed ceiling.
//   2. Pull exactly `toRepay` from the user via Permit3 and `pool.repay`.
//
// SweepToUser (default) never pulls the over-repay buffer — nothing sits in
// this module for a caller to redirect. Recycle takes custody of the full
// ceiling and re-deposits the surplus back into the user's Aave V2 position
// (best-effort, guaranteed sweep fallback).
//
// Optional permit replay enables gasless repayments for EIP-2612 tokens.
//
// `data = abi.encode(pool, asset, rateMode, debtToken[, DustAction[, deadline, v, r, s]])`
//
contract AaveV2RepayModule is IMakerModule {
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

        (address pool, address asset) = abi.decode(data, (address, address));
        // base = (address,address,uint256,address) = 128 bytes; DustAction at 128.
        DustHandler.DustAction action = DustHandler.readAction(data, 128);
        // Optional permit at 160 (after base + DustAction slot).
        PermitHelper.replayIfPresent(data, 160, asset, onBehalfOf, address(permit3), amount);

        // The balance this module held BEFORE the pull. Everything below disposes of
        // the DELTA over it, never the whole balance: a module address can be sent
        // tokens by anyone, and "sweep everything to the user" pays that to whoever
        // happens to be filling. See the floor overload of {DustHandler.disposeResidual}.
        uint256 floor = IERC20(asset).balanceOf(address(this));

        _pullAndRepay(data, amount, onBehalfOf, asset, pool, action == DustHandler.DustAction.Recycle);
        _disposeResidual(pool, asset, onBehalfOf, action, floor);

        _locked = 1;
    }

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
            // (rateMode @64, debtToken @96) via a calldata slice.
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
            SafeTransferLib.forceApprove(asset, pool, toRepay);
            IAaveV2Pool(pool).repay(asset, toRepay, rateMode, onBehalfOf);
            // Clear the scoped grant: `pool` is decoded from the order's `data` on a
            // SHARED singleton, so it is attacker-choosable — anyone can author an
            // order naming themselves as maker. A target that consumes less than
            // approved would leave a standing third-party claim on any FUTURE balance
            // of this module, which is what turns a later stranded-balance bug into a
            // theft. {SafeTransferLib.ensureApproval} forbids this shape. F25 / A-3.
            SafeTransferLib.forceApprove(asset, pool, 0);
        }
    }

    function _disposeResidual(
        address pool,
        address asset,
        address onBehalfOf,
        DustHandler.DustAction action,
        uint256 floor
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
            pool,
            abi.encodeCall(IAaveV2Pool.deposit, (asset, residual, onBehalfOf, 0))
        );
    }
}

// ──────────────────── Aave V2 withdraw taker module ────────────────────
//
// Single-op taker module. The user holds aTokens (Aave V2's interest-bearing
// receipt token) and pre-approves this module at the ERC-20 level. Permit3
// decrements the taker allowance, then invokes `takeOnBehalf` here. The module
// pulls aTokens from the user via the Permit3 token allowance, calls
// `pool.withdraw` (which burns the module's aTokens and sends underlying to
// `receiver`).
//
// Optional `BalanceMode.Full`: withdraw the user's full rebasing aToken
// balance, forward the signed `amount` to `receiver`, sweep accrued excess
// back to `onBehalfOf`.
//
// `data = abi.encode(pool, asset, aToken[, DustHandler.BalanceMode])`.
//
contract AaveV2WithdrawModule is ITakerModule {
    IPermit3 public immutable permit3;

    error OnlyPermit3();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        (address pool, address asset, address aToken) = abi.decode(data, (address, address, address));

        // base = (address,address,address) = 96 bytes; BalanceMode at 96.
        if (DustHandler.readBalanceMode(data, 96) == DustHandler.BalanceMode.Full) {
            // `Full` liquidates the user's ENTIRE live balance, so it cannot be
            // pro-rated — a sliced fill would unwind the whole position and brick
            // the rest of the order. Require the slice to be the whole item.
            FullFillGuard.requireFullFillFromData(data, 128, amount);
            // Resolve "full" to the USER's live aToken balance, pull exactly that,
            // and withdraw EXACT amounts straight to their destinations.
            //
                        // ONE venue withdraw, then an ERC-20 SPLIT. The venue pays this module the
            // whole position; the signed `amount` goes on to `receiver` and the rest back
            // to `onBehalfOf`. Cheaper than paying each destination from its own venue
            // call — a second withdraw re-does the venue's burn and accounting, an ERC-20
            // transfer does not. (Measured on an aave-v3 loop close: 536,396 -> 525,457.)
            //
            // ⚠ STILL NEVER `withdraw(max)`. `max` burns every receipt THIS MODULE holds,
            // conflating the user's position with the module's own. "Full" is resolved
            // from the USER's position and that exact amount is withdrawn.
            //
            // ⚠ AND THE CAP IS WHAT MAKES THE CUSTODY SAFE — it is not optional here. The
            // module holds the underlying between the withdraw and the split, so the
            // payout MUST be bounded by what THIS withdraw produced: `floor` excludes any
            // balance already sitting here, and `min(received, amount)` makes it
            // structurally impossible for a short or fake-venue delivery to be topped up
            // out of it. A nominal `safeTransfer(receiver, amount)` here would be the H-3
            // drain. Direct-to-destination needed neither, which is why it was the shape
            // until the split measured cheaper.
            uint256 floor = IERC20(asset).balanceOf(address(this));
            uint256 bal = IERC20(aToken).balanceOf(onBehalfOf);
            SafeTransferLib.safeTransferFrom(aToken, onBehalfOf, address(this), bal);
            IAaveV2Pool(pool).withdraw(asset, bal, address(this));
            uint256 received = IERC20(asset).balanceOf(address(this)) - floor;
            SafeTransferLib.safeTransfer(asset, receiver, received < amount ? received : amount);
            if (received > amount) SafeTransferLib.safeTransfer(asset, onBehalfOf, received - amount);
        } else {
            // Direct ERC-20 pull on the module's own allowance (not Permit3).
            SafeTransferLib.safeTransferFrom(aToken, onBehalfOf, address(this), amount);
            IAaveV2Pool(pool).withdraw(asset, amount, receiver);
        }
    }
}

// ──────────────────── Aave V2 borrow taker module ────────────────────
//
// Single-op taker module. Issues a variable or stable-rate borrow on behalf of
// the user and forwards proceeds to `receiver`. The user must have called
// `approveDelegation(module, cap)` on the relevant Aave V2 debt token so Aave
// permits the module to incur debt on their account.
//
// `data = abi.encode(pool, asset, rateMode)`  (rateMode: 1 = stable, 2 = variable)
//
contract AaveV2BorrowModule is ITakerModule {
    IPermit3 public immutable permit3;

    error OnlyPermit3();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        (address pool, address asset, uint256 rateMode) = abi.decode(data, (address, address, uint256));

        // Measure the delta rather than assuming the requested `amount` arrived: an
        // under-delivering borrow (fee-on-transfer underlying, a capped or
        // partially-filled reserve) would otherwise be topped up from any balance the
        // module happens to hold and paid to the solver, while the user keeps the full
        // debt — the H-3 River shape. Fail closed instead. Matches AaveV3/V4.
        uint256 balBefore = IERC20(asset).balanceOf(address(this));
        IAaveV2Pool(pool).borrow(asset, amount, rateMode, 0, onBehalfOf);
        uint256 received = IERC20(asset).balanceOf(address(this)) - balBefore;
        // Deliver the measured proceeds, capped at the signed amount; any excess
        // goes to the maker below. Never exceeds `received`, so a short delivery
        // (a fake/under-delivering venue) can never be topped up from a stray
        // balance the module holds — it simply delivers less and the fill's
        // output check fails downstream. Replaces a `received >= amount` gate.
        SafeTransferLib.safeTransfer(asset, receiver, received < amount ? received : amount);
        if (received > amount) SafeTransferLib.safeTransfer(asset, onBehalfOf, received - amount);
    }
}
