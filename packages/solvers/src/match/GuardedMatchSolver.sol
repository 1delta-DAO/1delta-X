// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MatchPlan} from "@core/settlement/Settlement.sol";
import {MatchRaceGuard} from "@solvers/base/MatchRaceGuard.sol";

/// @title GuardedMatchSolver
/// @notice A minimal `matchSettle` front-end that loses races cheaply:
///
///           1. check every order's `filled` counter against what the plan was
///              simulated against — one `SLOAD` each, and the plan is still
///              untouched calldata if this fails;
///           2. run the settlement.
///
///  There is no step 3. The settlement's residual goes straight to the plan's
///  `profitRecipient`, so this contract never receives it and never needs to
///  forward it — which removes both a transfer per token and the only way it could
///  ever hold a balance. `_requireForwarded` enforces that the recipient is set, so
///  a plan that would strand its own profit here fails before anything moves.
///
///  Trust model, matching the rest of `packages/solvers`: no owner, no funds at
///  rest, no approvals granted, never a Permit3 spender. The security boundary is
///  entirely the makers' signed orders and their own Permit3 allowances, exactly as
///  when a searcher calls `matchSettle` directly. This is a calldata shape, not a
///  privilege.
///
///  Plans needing a `CALL` step (a residual to front, a DEX hop) point that step at
///  a contract of the solver's choosing; this one deliberately exposes no callback
///  surface, so there is nothing to authenticate. Note `PRESEND` still pays
///  `msg.sender` — this contract — because that is working capital a `CALL` step is
///  meant to spend; only the final sweep is redirected.
contract GuardedMatchSolver is MatchRaceGuard {
    /// @dev The plan would leave its residual in this contract, where the next
    ///      caller would sweep it. Set `MatchPlan.profitRecipient` to a real
    ///      destination.
    error ProfitStranded();

    constructor(address settlement) MatchRaceGuard(settlement) {}

    /// @notice Guarded `matchSettle`. Reverts {OrderTaken} — cheaply — if any order
    ///         moved since the plan was built.
    /// @param  orderHashes    per-order EIP-712 hashes, computed off-chain.
    /// @param  expectedFilled per-order `filled` at simulation time (see
    ///         {MatchRaceGuard._requireUntouched} for why this is an exact match).
    /// @param  plan           the settlement itself. LAST and `calldata` on purpose:
    ///         when the guard reverts this is never copied to memory or walked. Its
    ///         `profitRecipient` must name a destination other than this contract.
    function settleMatch(bytes32[] calldata orderHashes, uint256[] calldata expectedFilled, MatchPlan calldata plan)
        external
        returns (uint256[][] memory outs, address[] memory tokens, uint256[] memory swept)
    {
        _requireUntouched(orderHashes, expectedFilled);
        // Checked AFTER the race guard so a loser still pays only the SLOADs.
        address to = plan.profitRecipient;
        if (to == address(0) || to == address(this)) revert ProfitStranded();
        return SETTLEMENT.matchSettle(plan);
    }
}
