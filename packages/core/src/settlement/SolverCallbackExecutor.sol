// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title SolverCallbackExecutor
/// @notice Privilege-less trampoline for {Settlement}.fillWithCallback.
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
///  It is an approved SPENDER for nobody, so it can only ever act with its own
///  authority. `execute` is pinned to the deploying Settlement, but that does NOT
///  make it private (audit 2026-09-30 CORE-FILLER-4 / CENSUS-A-4 — this used to say
///  it "holds no funds or approvals" and is not "a public trampoline"; both were
///  wrong):
///    • IT IS A PUBLIC TRAMPOLINE. Anyone can make it call any target with any data:
///      a `matchSettle` plan with ZERO orders and one CALL step, or a
///      `fillWithCallback` on a self-signed order. So `msg.sender == EXECUTOR`
///      authenticates NOTHING. A callback / CALL target that releases funds must also
///      check a flag its OWN entrypoint armed around its Settlement call (and must
///      authenticate that entrypoint's caller — arming from a permissionless entry
///      authorises nothing).
///    • ANYONE CAN MAKE IT A GRANTOR. Through the trampoline it can be made to
///      `approve` ERC-20s, grant Permit3 allowances, `approveOrder` or
///      `setOrderSigner` for itself, and those grants persist. NEVER GRANT THIS
///      ADDRESS AUTHORITY, and never leave value on it across steps where
///      third-party code (another maker's ITEM, a maker-chosen token) runs — whatever
///      lands here belongs to whoever drives it next. Settlement itself refuses an
///      output leg (netted path) or a TAKE proceeds recipient (every path) that
///      names it.
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
