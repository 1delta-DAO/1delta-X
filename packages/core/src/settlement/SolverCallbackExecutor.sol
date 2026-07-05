// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title SolverCallbackExecutor
/// @notice Privilege-less trampoline for {UniversalSettlement}.fillWithCallback.
///         Settlement routes a solver-supplied `(target, data)` call THROUGH this
///         contract instead of making it itself, so the arbitrary call executes
///         from an identity that holds no Permit3 allowances and is an approved
///         spender for nobody.
///
///  Why it exists
///  ─────────────
///  Settlement is an approved Permit3 spender in every maker's token/taker book.
///  If Settlement made the solver's arbitrary call directly, a solver could pass
///  `target = Permit3, data = transferFrom(victim, attacker, token, amount)` and
///  drain any maker who had ever approved Settlement. Executing from this
///  allowance-less contract removes that authority: the very same call reverts,
///  because the executor is not an approved spender for anyone.
///
///  It is stateless and holds no funds or approvals between calls, so it can only
///  ever act with its own (empty) authority. `execute` is nonetheless pinned to
///  the deploying Settlement to keep it a dedicated, single-purpose component
///  rather than a public trampoline.
contract SolverCallbackExecutor {
    /// @dev The Settlement that deployed this executor (constructor caller).
    address public immutable SETTLEMENT;

    error OnlySettlement();
    error CallbackFailed(bytes ret);

    constructor() {
        SETTLEMENT = msg.sender;
    }

    /// @notice Execute `target.call(data)` from this allowance-less context,
    ///         bubbling any revert so a failed callback aborts the surrounding
    ///         fill.
    function execute(address target, bytes calldata data) external {
        if (msg.sender != SETTLEMENT) revert OnlySettlement();
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) revert CallbackFailed(ret);
    }
}
