// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {IPositionSource} from "@core/interfaces/IPositionSource.sol";
import {IProceedsAsset} from "@core/interfaces/IProceedsAsset.sol";
import {DustHandler} from "@lib/DustHandler.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {PermitHelper} from "@lib/PermitHelper.sol";

import {IGiverPositionManager, ITakerPositionManager, ISpokeV4} from "./interfaces/IAaveV4.sol";

// These are the Aave v4 counterparts of the v3 adapters in the sibling package
// `@1delta-x/modules-aave-v3`. Same module shape — one Aave action per contract,
// gated by Permit3 — but the action routes through v4's Hub/Spoke position
// managers instead of a pool.
//
// `data = abi.encode(spoke, positionManager, reserveId, asset)` for every module.
// `asset` is the underlying ERC20: a maker module pulls it via Permit3, a taker
// module forwards it to `receiver` (the taker PMs have no receiver parameter, so
// proceeds land here first). It is also part of `keccak256(data)`, the taker
// allowance ref, so the bytes the user authorised pin down the exact position.
//
// The TAKER modules additionally BIND `asset` to the spoke's reserve underlying
// (`spoke.getReserve(reserveId)`, word 0) — 2026-09-30 audit, L-CV2-4. Proceeds are
// measured as a balance delta of the SIGNED `asset`; a mis-encoded one read 0,
// forwarded 0, stranded the real withdrawn/borrowed underlying on this shared
// singleton forever and left the core to bill the whole input leg to the maker's
// wallet. The maker modules fail closed on the same mistake unaided (the PM pulls
// the real underlying, which the module never approved).

// ──────────────────── Aave v4 deposit maker module ────────────────────
//
// Single-op module: pulls `asset` from the user via Permit3, then supplies on
// the user's behalf through the GiverPositionManager. The user must have
// approved the giver PM on the spoke beforehand (`spoke.setUserPositionManager`).
//
// Optional EIP-2612 permit replay: if the caller appends permit fields to `data`,
// the module replays them before `permit3.transferFrom` (gasless deposits).
//
// `data = abi.encode(spoke, positionManager, reserveId, asset[, deadline, v, r, s])`
//   — base = 128; permit@128.
// EIP-2612 permit block @128 (+ signedValue@256): `(deadline, v, r, s)` = 128 bytes, plus an OPTIONAL
// trailing `signedValue` word. Without it the signature commits to THIS fill's slice
// and verifies only on a full fill; sign `signedValue = item total` for partial fills
// ({PermitHelper}, audit 2026-09-30 L-AAVE-2).
contract AaveV4DepositModule is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;

    error NotSettlement();

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();

        (address spoke, address positionManager, uint256 reserveId, address asset) =
            abi.decode(data, (address, address, uint256, address));

        // Optional permit. base = (address,address,uint256,address) = 128 bytes.
        PermitHelper.replayIfPresent(data, 128, asset, onBehalfOf, address(permit3), amount);

        permit3.transferFrom(onBehalfOf, address(this), asset, uint160(amount));
        // Scoped approve + CLEAR, not a standing grant. `positionManager` is decoded from the
        // order's `data` on a SHARED singleton module, so it is attacker-choosable —
        // anyone can author an order naming themselves as maker. A target that
        // consumes less than approved would leave this module holding a permanent
        // third-party claim on any FUTURE balance of `asset`, which is what turns a
        // later residual-stranding bug into a theft. {SafeTransferLib.ensureApproval}'s
        // own note forbids exactly this shape, and every Midnight module already
        // clears. F25 / lead A-3.
        SafeTransferLib.forceApprove(asset, positionManager, amount);
        IGiverPositionManager(positionManager).supplyOnBehalfOf(spoke, reserveId, amount, onBehalfOf);
        SafeTransferLib.forceApprove(asset, positionManager, 0);
    }
}

// ──────────────────── Aave v4 repay maker module ────────────────────
//
// Mirrors `AaveV3RepayModule`'s pull-exact over-repay handling:
//
//   1. Read the user's live debt from the spoke and compute
//      `toRepay = min(amount, debt)`, where `amount` is the maker-signed ceiling.
//   2. Pull exactly `toRepay` from the user via Permit3 and `repayOnBehalfOf`.
//
// In the default (SweepToUser) mode the over-repay buffer is never pulled, so
// nothing sits in this module for a caller to redirect — removing the redirect
// vector at the source. When `data` opts into Recycle, the module takes custody
// of the full signed ceiling and, after repaying, re-supplies the surplus into
// the user's v4 position (same reserve), best-effort with a guaranteed sweep
// fallback that gracefully degrades when the spoke does not list the asset for
// supply (or the cap is reached). Either way disposal is locked to `onBehalfOf` /
// the PM, never a caller-chosen address.
//
// `nonReentrant` guards against weird-token transfer hooks.
// `data = abi.encode(spoke, positionManager, reserveId, asset[, DustHandler.DustAction[, deadline, v, r, s]])`
// — the trailing dust action is optional (absent ⇒ SweepToUser);
//   the permit block (128 bytes) is optional after the dust action slot.
//
//   — base = 128; DustAction@128; permit@160.
// EIP-2612 permit block @160 (+ signedValue@288): `(deadline, v, r, s)` = 128 bytes, plus an OPTIONAL
// trailing `signedValue` word. Without it the signature commits to THIS fill's slice
// and verifies only on a full fill; sign `signedValue = item total` for partial fills
// ({PermitHelper}, audit 2026-09-30 L-AAVE-2).
contract AaveV4RepayModule is IMakerModule {
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

        (address spoke, address positionManager, uint256 reserveId, address asset) =
            abi.decode(data, (address, address, uint256, address));
        // base = (address,address,uint256,address) = 128 bytes; DustAction at 128, permit at 160.
        DustHandler.DustAction action = DustHandler.readAction(data, 128);
        // The balance this module held BEFORE the pull. Everything below disposes of
        // the DELTA over it, never the whole balance: a module address can be sent
        // tokens by anyone, and "sweep everything to the user" pays that to whoever
        // happens to be filling. See the floor overload of {DustHandler.disposeResidual}.
        uint256 floor = IERC20(asset).balanceOf(address(this));

        PermitHelper.replayIfPresent(data, 160, asset, onBehalfOf, address(permit3), amount);

        _pullAndRepay(
            spoke, positionManager, reserveId, asset, amount, onBehalfOf, action == DustHandler.DustAction.Recycle
        );

        // Dispose of any residual: re-supplied into the user's position (Recycle,
        // best-effort with sweep fallback) or swept to the user (default), never
        // to a caller. In its own frame to keep the decoded locals off the stack.
        _disposeResidual(spoke, positionManager, reserveId, asset, onBehalfOf, action, floor);

        _locked = 1;
    }

    /// @dev Pull the funding token and repay. SweepToUser pulls only what the
    ///      debt needs — the buffer is never pulled and the surplus stays in the
    ///      maker's wallet. Recycle takes custody of the full signed ceiling so
    ///      the surplus can be redirected into the user's v4 position by
    ///      `_disposeResidual`; disposal stays locked to `onBehalfOf` / the PM.
    function _pullAndRepay(
        address spoke,
        address positionManager,
        uint256 reserveId,
        address asset,
        uint256 amount,
        address onBehalfOf,
        bool recycle
    ) private {
        uint256 toRepay;
        {
            uint256 debt = ISpokeV4(spoke).getUserTotalDebt(reserveId, onBehalfOf);
            toRepay = amount < debt ? amount : debt;
        }
        {
            uint256 toPull = recycle ? amount : toRepay;
            if (toPull > 0) permit3.transferFrom(onBehalfOf, address(this), asset, uint160(toPull));
        }
        if (toRepay > 0) {
            // Scoped approve + CLEAR, not a standing grant. `positionManager` is decoded from the
            // order's `data` on a SHARED singleton module, so it is attacker-choosable —
            // anyone can author an order naming themselves as maker. A target that
            // consumes less than approved would leave this module holding a permanent
            // third-party claim on any FUTURE balance of `asset`, which is what turns a
            // later residual-stranding bug into a theft. {SafeTransferLib.ensureApproval}'s
            // own note forbids exactly this shape, and every Midnight module already
            // clears. F25 / lead A-3.
            SafeTransferLib.forceApprove(asset, positionManager, toRepay);
            IGiverPositionManager(positionManager).repayOnBehalfOf(spoke, reserveId, toRepay, onBehalfOf);
            SafeTransferLib.forceApprove(asset, positionManager, 0);
        }
    }

    /// @dev Re-supply (opt-in) into the same v4 reserve, else sweep to the user.
    ///      `base = (address,address,uint256,address)` ⇒ trailing action at 128.
    function _disposeResidual(
        address spoke,
        address positionManager,
        uint256 reserveId,
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
            positionManager,
            abi.encodeCall(IGiverPositionManager.supplyOnBehalfOf, (spoke, reserveId, residual, onBehalfOf))
        );
    }
}

// ──────────────────── Aave v4 withdraw taker module ────────────────────
//
// Single-op taker module. Permit3 decrements the taker allowance on
// `keccak256(data)`, then invokes `takeOnBehalf` here. The TakerPositionManager
// has no receiver parameter, so the withdrawn underlying lands in this contract
// and is forwarded to `receiver`. The user must have approved the taker PM on
// the spoke and granted `approveWithdraw(spoke, reserveId, module, cap)`.
//
// Optional `BalanceMode.Full` (trailing field): withdraw the user's ENTIRE
// supplied balance (`getUserSuppliedAssets`), forward the signed `amount` to
// `receiver`, and sweep the accrued excess back to `onBehalfOf`. Fill-or-kill
// only, and only after debt is cleared.
//
// ⚠ `Full` NEEDS A TakerPM GRANT COVERING THE WHOLE LIVE POSITION (L-CV2-3). It
// asks the PM to withdraw `getUserSuppliedAssets(...)` — not the signed `amount` —
// and the PM checks `approveWithdraw` allowance >= the REQUESTED amount before the
// spoke call. A grant sized to the item (or to the position at signing time: it
// keeps accruing) reverts `InsufficientWithdrawAllowance`. Grant
// `type(uint256).max` (infinite, not decremented) or a padded cap. The extra grant
// gives no filler more: only this module can spend it, only through Permit3's
// taker book, and everything above `amount` goes back to `onBehalfOf`.
//
// ⚠ THE VENUE CLAMPS, SO `Exact` CARRIES THE DELIVERY BOUND TOO (L-CV2-1). The v4
// `Spoke.withdraw` computes `withdrawnAmount = min(amount, suppliedAssets)` and does
// NOT revert on a short position, and the TakerPM forwards whatever it got. A
// short position therefore under-delivered silently and {Core._payInputsToSolver}
// pulled `owed - proceeds` from the MAKER'S WALLET — wallet funds sold under an
// order signed as a position exit, at a moment the filler picks. Both branches now
// `requireDelivered`; on `Exact` the PM call is sized at this fill's slice, so an
// honest position returns exactly `amount` and the bound cannot misfire. (An
// `Exact` withdraw of the ENTIRE position can come back 1 wei short from the
// spoke's share rounding — use `Full` to close a position.)
//
// Exact: `abi.encode(spoke, positionManager, reserveId, asset[, BalanceMode(0)])`
//   — BalanceMode at 128.
// Full:  `abi.encode(spoke, positionManager, reserveId, asset, 0xB0DE0001, totalAmount)`
//   — BalanceMode at 128 as the TAGGED word `DustHandler.encodeMode(Full)` (a bare
//     `1` reverts `InvalidModeWord`), `totalAmount` at 160 and MANDATORY.
//   — `totalAmount` is the item's full maker-signed amount; {FullFillGuard} asserts
//     the slice equals it and FAILS CLOSED when the word is absent
//     (`PartialFillUnsupported(amount, 0)`). It was previously undeclared here, so
//     a maker encoding `Full` from this map signed an order no filler could ever
//     settle. Declared in F25 (lead A-2).
//
contract AaveV4WithdrawModule is ITakerModule, IProceedsAsset, IPositionSource {
    IPermit3 public immutable permit3;

    error OnlyPermit3();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        (address spoke, address positionManager, uint256 reserveId, address asset) =
            abi.decode(data, (address, address, uint256, address));
        AaveV4ReserveBinding.requireUnderlying(spoke, reserveId, asset);

        if (DustHandler.readBalanceMode(data, 128) == DustHandler.BalanceMode.Full) {
            // `Full` liquidates the user's ENTIRE live balance, so it cannot be
            // pro-rated — a sliced fill would unwind the whole position and brick
            // the rest of the order. Require the slice to be the whole item.
            FullFillGuard.requireFullFillFromData(data, 160, amount);
            // Withdraw the user's entire supplied balance to this module; forward
            // the signed `amount` to the order, sweep the accrued excess to user.
            // Measure the actually-received underlying via a balanceOf snapshot
            // rather than trusting the PM's reported amount.
            // Through {positionOf} — the number a position-sized fill is priced
            // against and the number withdrawn are the same function (L-LIB-8).
            (, uint256 supplied) = positionOf(onBehalfOf, data);
            uint256 balBefore = IERC20(asset).balanceOf(address(this));
            ITakerPositionManager(positionManager).withdrawOnBehalfOf(spoke, reserveId, supplied, onBehalfOf);
            uint256 received = IERC20(asset).balanceOf(address(this)) - balBefore;
            // The lower bound the venue used to enforce (I-8). Before the split rewrite
            // the venue call was sized at `amount`, so a short position reverted inside
            // it; now nothing does, and {Core._payInputsToSolver} would bill the
            // shortfall to the MAKER'S WALLET. Safe here and only here: `Full` is
            // full-fill, so `amount` is the signed TOTAL, never a pro-rated slice.
            // (2026-09-12 audit: the sibling the 2026-09-10 restoration missed.)
            FullFillGuard.requireDelivered(received, amount);
            // Deliver the measured proceeds, capped at the signed amount; any excess
            // goes to the maker below. Never exceeds `received`, so a short delivery
            // (a fake/under-delivering venue) can never be topped up from a stray
            // balance the module holds.
            SafeTransferLib.safeTransfer(asset, receiver, received < amount ? received : amount);
            if (received > amount) SafeTransferLib.safeTransfer(asset, onBehalfOf, received - amount);
        } else {
            // Measure what actually landed rather than forwarding the PM's
            // REPORTED `assets`. The two can differ (fee-on-transfer underlying,
            // share→asset rounding, a spoke that partially fills), and the
            // reported figure is not a claim about this module's balance: on a
            // short delivery a nominal transfer silently covers the gap from
            // whatever else the module happens to hold, paying the order out of a
            // stray balance. Same rule as the `Full` branch above and the M-4 fix
            // applied to the other packages — forward a measured delta, fail
            // closed below it.
            uint256 balBefore = IERC20(asset).balanceOf(address(this));
            ITakerPositionManager(positionManager).withdrawOnBehalfOf(spoke, reserveId, amount, onBehalfOf);
            uint256 received = IERC20(asset).balanceOf(address(this)) - balBefore;
            // The v4 spoke CLAMPS a withdraw to the supplied balance instead of
            // reverting, so a short position delivers less here — and the core then
            // bills `owed - proceeds` to the MAKER'S WALLET (no "output check" catches
            // it: a withdraw item funds an INPUT leg). Fail closed. Sized at this
            // fill's slice, so it cannot misfire on a partial fill. (2026-09-30
            // audit, L-CV2-1: the `Exact` sibling of the F28 #4 `Full` fix.)
            FullFillGuard.requireDelivered(received, amount);
            // Deliver the measured proceeds, capped at the signed amount; any excess
            // goes to the maker below. Never exceeds `received`, so a stray balance
            // the module holds is never paid out.
            SafeTransferLib.safeTransfer(asset, receiver, received < amount ? received : amount);
            // A withdraw that over-delivers (rounding in the user's favour) must
            // not leave the surplus parked in the module for the next fill to
            // sweep — it belongs to the position owner.
            if (received > amount) SafeTransferLib.safeTransfer(asset, onBehalfOf, received - amount);
        }
    }

    /// @inheritdoc IProceedsAsset
    /// @dev The underlying `asset` (word 3) — what lands on `receiver` (L-CMT-6).
    function proceedsAsset(bytes calldata data) external pure override returns (address asset) {
        (,,, asset) = abi.decode(data, (address, address, uint256, address));
    }

    /// @inheritdoc IPositionSource
    /// @dev The spoke's `getUserSuppliedAssets` — the RAW supplied position in
    ///      `asset` units, accrued by the spoke's own view, NOT bounded by the
    ///      TakerPM's withdraw approval (a short approval must revert the fill, not
    ///      quietly sell a fraction). `asset` is bound to the reserve's underlying
    ///      first, as `takeOnBehalf` does (audit 2026-09-30 L-LIB-8).
    function positionOf(address user, bytes calldata data)
        public
        view
        override
        returns (address asset, uint256 amount)
    {
        address spoke;
        uint256 reserveId;
        (spoke,, reserveId, asset) = abi.decode(data, (address, address, uint256, address));
        AaveV4ReserveBinding.requireUnderlying(spoke, reserveId, asset);
        amount = ISpokeV4(spoke).getUserSuppliedAssets(reserveId, user);
    }
}

// ──────────────────── Aave v4 borrow taker module ────────────────────
//
// Single-op taker module. Issues a borrow on behalf of the user through the
// TakerPositionManager and forwards proceeds to `receiver`. The user must have
// approved the taker PM on the spoke and granted
// `approveBorrow(spoke, reserveId, module, cap)` so the PM permits the module to
// incur debt on their account.
//
// `data = abi.encode(spoke, positionManager, reserveId, asset)`; `asset` is bound to
// the spoke's reserve underlying (L-CV2-4, see the file header).
//
contract AaveV4BorrowModule is ITakerModule, IProceedsAsset {
    IPermit3 public immutable permit3;

    error OnlyPermit3();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        (address spoke, address positionManager, uint256 reserveId, address asset) =
            abi.decode(data, (address, address, uint256, address));
        AaveV4ReserveBinding.requireUnderlying(spoke, reserveId, asset);

        // Borrow lands the proceeds of `asset` at this module (the caller). Measure
        // the delta rather than assuming the requested `amount` arrived: an
        // under-delivering borrow (fee-on-transfer underlying, a capped or
        // partially-filled spoke) would otherwise be topped up from any balance
        // the module happens to hold and paid to the solver, while the user keeps
        // the full debt — the H-3 River shape. Fail closed instead.
        uint256 balBefore = IERC20(asset).balanceOf(address(this));
        ITakerPositionManager(positionManager).borrowOnBehalfOf(spoke, reserveId, amount, onBehalfOf);
        uint256 received = IERC20(asset).balanceOf(address(this)) - balBefore;
        // Forward to Permit3's requested receiver (Settlement in our flow) the
        // measured proceeds, capped at the signed amount; excess to the user below.
        SafeTransferLib.safeTransfer(asset, receiver, received < amount ? received : amount);
        // Any excess is the user's, not the next fill's.
        if (received > amount) SafeTransferLib.safeTransfer(asset, onBehalfOf, received - amount);
    }

    /// @inheritdoc IProceedsAsset
    /// @dev The underlying `asset` (word 3) — what lands on `receiver` (L-CMT-6).
    function proceedsAsset(bytes calldata data) external pure override returns (address asset) {
        (,,, asset) = abi.decode(data, (address, address, uint256, address));
    }
}

/// @title AaveV4ReserveBinding
/// @notice Binds a taker module's signed `asset` to the spoke reserve's underlying
///         (2026-09-30 audit, L-CV2-4). See the file header.
/// @dev `Spoke.getReserve(reserveId)` returns a STATIC struct whose word 0 is the
///      `underlying` (verified on the live Main Spoke; the remaining fields vary by
///      spoke version and are deliberately not decoded). A spoke that does not answer
///      — or answers short — fails closed: the module cannot prove which token the
///      PM will pay in, and the delta measurement depends on it.
library AaveV4ReserveBinding {
    error UnderlyingMismatch(address signed, address actual);

    function requireUnderlying(address spoke, uint256 reserveId, address asset) internal view {
        (bool ok, bytes memory ret) = spoke.staticcall(abi.encodeWithSelector(ISpokeV4.getReserve.selector, reserveId));
        address actual;
        if (ok && ret.length >= 32) actual = abi.decode(ret, (address));
        if (actual != asset) revert UnderlyingMismatch(asset, actual);
    }
}
