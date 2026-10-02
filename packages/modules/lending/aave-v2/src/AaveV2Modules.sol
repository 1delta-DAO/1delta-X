// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {IProceedsAsset} from "@core/interfaces/IProceedsAsset.sol";
import {IPositionSource} from "@core/interfaces/IPositionSource.sol";
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
//   — base = 64; permit@64.
// EIP-2612 permit block @64 (+ signedValue@192): `(deadline, v, r, s)` = 128 bytes, plus an OPTIONAL
// trailing `signedValue` word. Without it the signature commits to THIS fill's slice
// and verifies only on a full fill; sign `signedValue = item total` for partial fills
// ({PermitHelper}, audit 2026-09-30 L-AAVE-2).
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
//   — pool@0, asset@32, rateMode@64, debtToken@96 (base = 128); DustAction@128; permit@160.
// EIP-2612 permit block @160 (+ signedValue@288): `(deadline, v, r, s)` = 128 bytes, plus an OPTIONAL
// trailing `signedValue` word. Without it the signature commits to THIS fill's slice
// and verifies only on a full fill; sign `signedValue = item total` for partial fills
// ({PermitHelper}, audit 2026-09-30 L-AAVE-2).
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
// pulls aTokens from the user via a DIRECT ERC-20 allowance to this module (NOT Permit3), calls
// `pool.withdraw` (which burns the module's aTokens and sends underlying to
// `receiver`).
//
// Optional `BalanceMode.Full`: withdraw the user's full rebasing aToken
// balance, forward the signed `amount` to `receiver`, sweep accrued excess
// back to `onBehalfOf`.
//
// `data = abi.encode(pool, asset, aToken[, DustHandler.BalanceMode[, total]])`
//   — mode@96, and `total`@128 is MANDATORY whenever the mode is `Full`: it is
//     the maker-signed full item amount {FullFillGuard.requireFullFillFromData}
//     compares the slice against, and it FAILS CLOSED when absent — so a `Full`
//     order encoded from a map that omits it is one no filler can ever settle.
//     (Was undeclared here; the same F25/A-2 drift already corrected on aave-v3.)
//   — `Full` is the TAGGED word `0xB0DE0001` (`DustHandler.encodeMode(Full)`); a
//     bare `1` reverts `InvalidModeWord`.
//
// ⚠ AAVE V2 ROUNDS aToken TRANSFERS HALF-UP (2026-09-30 audit, L-AAVE-1). A
// transfer moves `rayDiv(amount, index)` scaled units and `withdraw` then checks
// `amount <= rayMul(scaled, index)`; for ~(1 - RAY/index)/2 of all amounts (8.7 %
// at a 1.21 index) that round trip is `amount - 1`, so pulling exactly `amount`
// and withdrawing `amount` reverted `VL_NOT_ENOUGH_AVAILABLE_USER_BALANCE`. The
// `Exact` branch measures what it received, tops up the minimal shortfall from the
// maker when short, withdraws exactly `amount`, and returns any aToken surplus.
//
// Implements {IProceedsAsset} (the underlying) and {IPositionSource} (the maker's
// aToken balance — 1:1 with the underlying), so the lens can preflight it and a
// {PositionFillModule} can size a v2 exit (L-AAVE-5).
//
contract AaveV2WithdrawModule is ITakerModule, IProceedsAsset, IPositionSource {
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
            (, uint256 bal) = positionOf(onBehalfOf, data);
            SafeTransferLib.safeTransferFrom(aToken, onBehalfOf, address(this), bal);
            IAaveV2Pool(pool).withdraw(asset, bal, address(this));
            uint256 received = IERC20(asset).balanceOf(address(this)) - floor;
            // The lower bound the venue used to enforce. Before the split rewrite the
            // venue call was sized at `amount`, so a short position reverted inside it;
            // now nothing does, and {Core._payInputsToSolver} would bill the shortfall to
            // the MAKER'S WALLET. Safe here and only here: `Full` is full-fill, so
            // `amount` is the signed TOTAL, never a pro-rated slice.
            FullFillGuard.requireDelivered(received, amount);
            SafeTransferLib.safeTransfer(asset, receiver, received < amount ? received : amount);
            if (received > amount) SafeTransferLib.safeTransfer(asset, onBehalfOf, received - amount);
        } else {
            // Direct ERC-20 pull on the module's own allowance (not Permit3), sized so
            // the venue's half-up rounding can never leave it 1 wei short (L-AAVE-1).
            AaveV2ATokenExactPull.withdrawExact(pool, asset, aToken, onBehalfOf, amount, receiver);
        }
    }

    /// @inheritdoc IProceedsAsset
    /// @dev The UNDERLYING (word 1) — what lands on `receiver`.
    function proceedsAsset(bytes calldata data) external pure override returns (address asset) {
        (, asset) = abi.decode(data, (address, address));
    }

    /// @inheritdoc IPositionSource
    /// @dev v2 aTokens rebase 1:1 with the underlying, so the aToken balance is
    ///      already in `asset` units — the raw position, NOT bounded by this
    ///      module's allowance (a short approval must make the fill revert, not
    ///      quietly sell a fraction; same rationale as the v3 module).
    function positionOf(address user, bytes calldata data)
        public
        view
        override
        returns (address asset, uint256 amount)
    {
        address aToken;
        (, asset, aToken) = abi.decode(data, (address, address, address));
        amount = IERC20(aToken).balanceOf(user);
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
contract AaveV2BorrowModule is ITakerModule, IProceedsAsset {
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
        // balance the module holds.
        // ⚠ A short is NOT caught downstream (corrected 2026-09-30, L-CV2-1.v3): the
        // proceeds fund an INPUT leg and {Core._payInputsToSolver} bills `owed -
        // proceeds` to the MAKER'S WALLET. Cap-only is right here only because the
        // Aave v2 `borrow` is exact-or-revert for the reserves this targets.
        SafeTransferLib.safeTransfer(asset, receiver, received < amount ? received : amount);
        if (received > amount) SafeTransferLib.safeTransfer(asset, onBehalfOf, received - amount);
    }

    /// @inheritdoc IProceedsAsset
    /// @dev The borrowed `asset` (word 1) — what lands on `receiver`.
    function proceedsAsset(bytes calldata data) external pure override returns (address asset) {
        (, asset) = abi.decode(data, (address, address));
    }
}

/// @title AaveV2ATokenExactPull
/// @notice The `Exact` aToken withdraw, correct under Aave v2's half-up aToken
///         rounding (2026-09-30 audit, L-AAVE-1). See the {AaveV2WithdrawModule}
///         header. Internal library (inlined; no DELEGATECALL); the aave-v3 package
///         carries the same body for pre-v3.5 forks.
library AaveV2ATokenExactPull {
    function withdrawExact(
        address pool,
        address asset,
        address aToken,
        address onBehalfOf,
        uint256 amount,
        address receiver
    ) internal {
        // Pre-pull aToken floor: a stray (donated) balance is neither counted toward
        // this pull nor returned to this maker.
        uint256 aFloor = IERC20(aToken).balanceOf(address(this));
        SafeTransferLib.safeTransferFrom(aToken, onBehalfOf, address(this), amount);
        uint256 have = IERC20(aToken).balanceOf(address(this)) - aFloor;
        bool toppedUp;
        if (have < amount) {
            // Half-up rounding credited `amount - 1`. One more SCALED unit always
            // suffices (rayMul(q + 1, I) >= amount whenever rayMul(q, I) == amount - 1
            // and I >= RAY), and a transfer of `t` moves at least one scaled unit once
            // `t > I / (2 * RAY)` — hence `index / 2e27` on top of the nominal gap.
            uint256 topUp = amount - have + IAaveV2Pool(pool).getReserveNormalizedIncome(asset) / 2e27;
            SafeTransferLib.safeTransferFrom(aToken, onBehalfOf, address(this), topUp);
            toppedUp = true;
        }
        IAaveV2Pool(pool).withdraw(asset, amount, receiver);
        if (toppedUp) {
            uint256 left = IERC20(aToken).balanceOf(address(this));
            if (left > aFloor) SafeTransferLib.safeTransfer(aToken, onBehalfOf, left - aFloor);
        }
    }
}
