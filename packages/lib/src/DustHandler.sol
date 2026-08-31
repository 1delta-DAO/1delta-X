// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

/// @title DustHandler
/// @notice Shared residual-disposal logic for maker modules (repay, etc.).
///
///  After a pull-exact repay, a module may hold a tiny residual (rounding, or a
///  partially-consumed buffer). There are two sensible destinations:
///
///    • SweepToUser — send it straight to the user's wallet. The safe floor:
///      a plain ERC20 transfer that cannot revert for protocol-state reasons.
///
///    • Recycle — push it back into the user's position (e.g. re-supply the
///      leftover loan token as a lend balance) so capital stays productive.
///      This is the CoW × Aave "leftover back into the position" pattern.
///
///  Recycle is best-effort: a re-supply can revert for reasons unrelated to the
///  user's intent — Aave v3 `SUPPLY_CAP_EXCEEDED` / frozen / paused reserves,
///  an Aave v4 spoke that does not list the asset for supply, a Comet supply
///  pause, isolation-mode rules. So a failed recycle MUST NOT revert the
///  surrounding repay; it falls back to the sweep floor. The off-chain order-prep
///  API picks the action from live reserve state, and this on-chain fallback
///  catches the state drift between signing and execution.
///
///  The action travels as an OPTIONAL trailing field appended to a module's
///  `data` blob, so existing encodings (which omit it) default to SweepToUser
///  and behave exactly as before. `readAction` extracts it past a module's
///  fixed-layout base length.
library DustHandler {
    enum DustAction {
        SweepToUser, // 0 — default & safe floor
        Recycle // 1 — best-effort re-supply into the position
    }

    /// @notice Balance mode for taker (withdraw) items — the TAKE-side mirror of
    ///         the maker-side over-repay refund. Appended as an optional trailing
    ///         field after a module's fixed base layout, same encoding as
    ///         `DustAction`. Absent ⇒ Exact (withdraw exactly `amount`).
    ///
    ///  `Full` withdraws the user's entire live (accruing) balance, forwards the
    ///  signed `amount` to the order's receiver, and sweeps the excess
    ///  (`balance − amount`) back to the user — just like the repay residual,
    ///  always to `onBehalfOf`, never a caller-chosen address. It MUST be paired
    ///  with a fill-or-kill order (a dynamic full balance can't be pro-rata'd
    ///  across partial fills) and is only safe once debt is cleared (else the
    ///  withdraw breaks the position's health factor) — i.e. the close-flow leg
    ///  `[repay (cap at debt) → withdraw-full collateral]`.
    enum BalanceMode {
        Exact, // 0 — withdraw exactly `amount` (default, current behavior)
        Full // 1 — withdraw the full live balance, sweep the excess to the user
    }

    /// @dev A trailing mode word carries a value outside its enum's range. Raised
    ///      instead of letting the `uint8` narrowing silently discard the high
    ///      248 bits: `uint256(256)` would otherwise truncate to `0` and read as a
    ///      well-formed `SweepToUser` / `Exact`, so a malformed (or
    ///      differently-encoded) blob would be accepted as the DEFAULT mode rather
    ///      than rejected. The value is part of `ref = keccak256(data)`, so this is
    ///      a maker-authored encoding error, not a filler-reachable one — but the
    ///      whole point of the trailing field is that its meaning is unambiguous.
    error InvalidModeWord(uint256 word);

    /// @notice Decode the optional trailing `DustAction` appended after a
    ///         module's `baseLen`-byte fixed base layout. Absent ⇒ SweepToUser.
    /// @dev    Only valid when the base layout is fully static (all the repay
    ///         modules are: addresses / uint256 / a static MarketParams struct),
    ///         so a trailing 32-byte word is unambiguous. An out-of-range value
    ///         reverts {InvalidModeWord} — the check is on the FULL word, before
    ///         any narrowing.
    function readAction(bytes calldata data, uint256 baseLen) internal pure returns (DustAction) {
        if (data.length < baseLen + 32) return DustAction.SweepToUser;
        uint256 word = uint256(bytes32(data[baseLen:baseLen + 32]));
        if (word > uint256(type(DustAction).max)) revert InvalidModeWord(word);
        return DustAction(uint8(word));
    }

    /// @notice Decode the optional trailing `BalanceMode` appended after a taker
    ///         module's `baseLen`-byte fixed base layout. Absent ⇒ Exact.
    /// @dev    Since a taker item's allowance ref is `keccak256(data)`, the mode
    ///         is part of the maker-approved bytes — authorized by construction.
    ///         Out-of-range reverts {InvalidModeWord}; see `readAction`. Silently
    ///         truncating to `Exact` would be the more dangerous default here — a
    ///         maker who encoded `Full` in a wider word would get an exact
    ///         withdraw, and the `FullFillGuard` total they appended after the
    ///         mode slot would go unread.
    function readBalanceMode(bytes calldata data, uint256 baseLen) internal pure returns (BalanceMode) {
        if (data.length < baseLen + 32) return BalanceMode.Exact;
        uint256 word = uint256(bytes32(data[baseLen:baseLen + 32]));
        if (word > uint256(type(BalanceMode).max)) revert InvalidModeWord(word);
        return BalanceMode(uint8(word));
    }

    /// @notice Dispose of a module's `residual` balance of `token`.
    /// @param token        the residual token
    /// @param residual     amount held by `address(this)` (read by the caller)
    /// @param onBehalfOf    the user — sole sweep destination, never caller-chosen
    /// @param action        SweepToUser or Recycle
    /// @param recycleTarget contract to re-supply into (pool / PM / comet / morpho)
    /// @param recycleCall    typed calldata for the re-supply, sized to `residual`
    function disposeResidual(
        address token,
        uint256 residual,
        address onBehalfOf,
        DustAction action,
        address recycleTarget,
        bytes memory recycleCall
    ) internal {
        disposeResidual(token, residual, 0, onBehalfOf, action, recycleTarget, recycleCall);
    }

    /// @notice {disposeResidual} with an explicit FLOOR — the balance of `token` this
    ///         module already held when the operation began, which is NOT this
    ///         operation's residual and must not be paid to `onBehalfOf`.
    ///
    ///  ⚠ WHY A FLOOR, AND WHY `0` IS THE WRONG DEFAULT FOR NEW CALLERS.
    ///  The overload above reads a caller-supplied `residual` that every module in
    ///  this repo computes as `IERC20(token).balanceOf(address(this))` — the module's
    ///  WHOLE balance, not the delta this call produced. Modules are pull-exact and
    ///  should never carry a balance between calls, so the two are normally equal.
    ///  When they are not, "sweep everything" pays the difference to whoever happens
    ///  to be filling: anyone can transfer tokens to a module address, and anyone can
    ///  be the maker of a one-unit order against that module and asset, so a stranded
    ///  balance is claimable by the next filler rather than merely lost.
    ///
    ///  Nothing is being stolen from a live position — the destination is still
    ///  `onBehalfOf`, never a caller-chosen address — but "the module ends empty" is
    ///  the wrong invariant to enforce with a transfer. The right one is "the module
    ///  ends where it started", and that needs the floor.
    ///
    ///  The recycle branch needs it too, and that is easy to miss: after a partial
    ///  re-supply it re-reads the balance, so without the floor it would sweep the
    ///  pre-existing amount even when the caller measured its own residual correctly.
    ///
    /// @param floor balance of `token` held before this operation; retained, not swept.
    function disposeResidual(
        address token,
        uint256 residual,
        uint256 floor,
        address onBehalfOf,
        DustAction action,
        address recycleTarget,
        bytes memory recycleCall
    ) internal {
        if (residual == 0) return;

        if (action == DustAction.Recycle && recycleTarget.code.length != 0) {
            SafeTransferLib.forceApprove(token, recycleTarget, residual);
            (bool ok,) = recycleTarget.call(recycleCall);
            SafeTransferLib.forceApprove(token, recycleTarget, 0); // never leave a dangling allowance

            if (ok) {
                // Recycle may consume all or part of the residual; sweep whatever
                // remains ABOVE the floor, so the module ends where it started rather
                // than empty.
                uint256 bal = IERC20(token).balanceOf(address(this));
                uint256 left = bal > floor ? bal - floor : 0;
                if (left != 0) SafeTransferLib.safeTransfer(token, onBehalfOf, left);
                return;
            }
            // Recycle reverted (cap / frozen / paused / non-depositable / pause) —
            // fall through to the sweep floor.
        }

        SafeTransferLib.safeTransfer(token, onBehalfOf, residual);
    }
}
