// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

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

    /// @notice Decode the optional trailing `DustAction` appended after a
    ///         module's `baseLen`-byte fixed base layout. Absent ⇒ SweepToUser.
    /// @dev    Only valid when the base layout is fully static (all the repay
    ///         modules are: addresses / uint256 / a static MarketParams struct),
    ///         so a trailing 32-byte word is unambiguous. An out-of-range value
    ///         reverts on the enum conversion — acceptable for a malformed blob.
    function readAction(bytes calldata data, uint256 baseLen) internal pure returns (DustAction) {
        if (data.length < baseLen + 32) return DustAction.SweepToUser;
        uint256 word = uint256(bytes32(data[baseLen:baseLen + 32]));
        return DustAction(uint8(word));
    }

    /// @notice Decode the optional trailing `BalanceMode` appended after a taker
    ///         module's `baseLen`-byte fixed base layout. Absent ⇒ Exact.
    /// @dev    Since a taker item's allowance ref is `keccak256(data)`, the mode
    ///         is part of the maker-approved bytes — authorized by construction.
    function readBalanceMode(bytes calldata data, uint256 baseLen) internal pure returns (BalanceMode) {
        if (data.length < baseLen + 32) return BalanceMode.Exact;
        uint256 word = uint256(bytes32(data[baseLen:baseLen + 32]));
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
        if (residual == 0) return;

        if (action == DustAction.Recycle && recycleTarget.code.length != 0) {
            IERC20(token).approve(recycleTarget, residual);
            (bool ok,) = recycleTarget.call(recycleCall);
            IERC20(token).approve(recycleTarget, 0); // never leave a dangling allowance

            if (ok) {
                // Recycle may consume all or part of the residual; sweep whatever
                // remains so the module always ends empty.
                uint256 left = IERC20(token).balanceOf(address(this));
                if (left != 0) IERC20(token).transfer(onBehalfOf, left);
                return;
            }
            // Recycle reverted (cap / frozen / paused / non-depositable / pause) —
            // fall through to the sweep floor.
        }

        IERC20(token).transfer(onBehalfOf, residual);
    }
}
