// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @title SafeTransferLib
/// @notice Minimal safe ERC20 wrappers for tokens that (a) return no boolean
///         (USDT, BNB), (b) return `false` instead of reverting, or (c) require
///         the allowance to be reset to zero before a non-zero re-approval (USDT).
///
///         The repo only vendors `forge-std`, so this stands in for OpenZeppelin
///         `SafeERC20` — same guarantees: a transfer/approve that does not
///         succeed reverts, and `forceApprove` tolerates approve-race tokens.
library SafeTransferLib {
    error TransferFailed();
    error TransferFromFailed();
    error ApproveFailed();

    function safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transferFrom, (from, to, amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFromFailed();
    }

    /// @dev Set the allowance to exactly `amount`. Handles tokens that revert on a
    ///      non-zero→non-zero approve by first zeroing, and tokens that return no
    ///      boolean. Use before pulling and (optionally) reset to 0 after.
    function forceApprove(address token, address spender, uint256 amount) internal {
        if (!_tryApprove(token, spender, amount)) {
            // Reset to zero, then retry (USDT-style approve-race tokens).
            if (!_tryApprove(token, spender, 0)) revert ApproveFailed();
            if (!_tryApprove(token, spender, amount)) revert ApproveFailed();
        }
    }

    function _tryApprove(address token, address spender, uint256 amount) private returns (bool) {
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.approve, (spender, amount)));
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }

    /// @dev Idempotent max-approval: if the current allowance already covers
    ///      `amount`, do nothing (skips the SSTORE on repeat calls); otherwise set
    ///      an infinite allowance once. Saves the per-call approve churn.
    ///
    ///      SECURITY: only safe when `spender` is a TRUSTED, PINNED address (e.g. an
    ///      immutable protocol). Do NOT use with a spender decoded from caller/order
    ///      data on a shared contract — a standing max allowance to an
    ///      attacker-chosen spender lets it drain any future balance of `token`.
    function ensureApproval(address token, address spender, uint256 amount) internal {
        if (IERC20(token).allowance(address(this), spender) < amount) {
            forceApprove(token, spender, type(uint256).max);
        }
    }
}
