// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {MatchRaceGuard} from "@solvers/base/MatchRaceGuard.sol";

/// @title GuardedMatchSolver
/// @notice A minimal `matchSettle` front-end that loses races cheaply:
///
///           1. check every order's `filled` counter (and, for fill-once or
///              nonce-gated orders, its nonce) against what the plan was simulated
///              against — one or two `SLOAD`s each, and the plan is still untouched
///              calldata if this fails;
///           2. run the settlement.
///
///  There is no step 3. The settlement's residual goes straight to the plan's
///  `profitRecipient`, so this contract never receives it and never needs to
///  forward it — which removes both a transfer per token and the only way it could
///  ever hold a balance. {ProfitStranded} enforces that the recipient is a real
///  destination, so a plan that would strand its own profit fails before anything
///  moves.
///
///  Trust model, matching the rest of `packages/solvers`: no owner, no funds at
///  rest, no approvals granted, never a Permit3 spender. The security boundary is
///  entirely the makers' signed orders and their own Permit3 allowances, exactly as
///  when a searcher calls `matchSettle` directly.
///
///  ⚠ NO `PRESEND` THROUGH THIS WRAPPER (audit 2026-09-30 CORE-MATCH-1). `PRESEND`
///  pays `msg.sender` of `matchSettle` — this contract — and this contract has no
///  function that can move a token: it exposes no callback, grants no approvals,
///  and `matchSettle` never pulls from its caller. A pre-sent balance would be
///  locked here forever (this NatSpec used to call it "working capital a CALL step
///  is meant to spend"; a CALL runs from the EXECUTOR, which has no allowance over
///  this contract). Plans containing a `PRESEND` step are refused
///  ({PresendUnsupported}); a plan that needs one must call `matchSettle` from the
///  solver's OWN contract (inheriting {MatchRaceGuard}), which can then spend what
///  it is pre-sent. Plans needing a `CALL` step (a residual to front, a DEX hop)
///  point that step at a contract of the solver's choosing — authenticate it
///  against more than `msg.sender == EXECUTOR` (see {SolverCallbackExecutor}).
///
///  ⚠ THIS CONTRACT'S ADDRESS IS NOT A FILLER IDENTITY on an open instance (audit
///  2026-09-30 CORE-MATCH-3). `matchSettle` keys every filler-conditional gate —
///  `exclusiveFiller`, a {OrderGates.FILLER_SET}, a filler-aware validator or price
///  module, an invariant — on its `msg.sender`, which is THIS contract whoever
///  called it. An order naming a permissionless instance in any of them has named
///  everyone. Never put an open instance there. A solver that wants an identity of
///  its own deploys a GATED instance: the optional, immutable operator set below
///  (fixed at construction, no setter — the {AggregatorFillSolver} model) makes
///  "only these callers" literally true, and only then may an order name it.
contract GuardedMatchSolver is MatchRaceGuard {
    /// @dev The plan would leave its residual where the next caller could take it:
    ///      in this contract (`0` = `msg.sender` = this contract), in Settlement
    ///      (a self-transfer the next snapshot floors and nobody can ever claim), or
    ///      on the shared EXECUTOR (takeable by anyone's next CALL step). Set
    ///      `MatchPlan.profitRecipient` to a real destination.
    error ProfitStranded();
    /// @dev The plan contains a `PRESEND` step — see the contract note.
    error PresendUnsupported();
    /// @dev A gated instance was called by someone outside its operator set.
    error NotOperator(address caller);
    /// @dev The operator set holds `address(0)` or more than {MAX_OPERATORS} entries.
    error BadOperatorSet();

    /// @notice Settlement's callback trampoline, refused as a profit recipient.
    address public immutable EXECUTOR;

    /// @notice Whether {settleMatch} is restricted to {isOperator}. Immutable:
    ///         `true` iff the constructor was given a non-empty operator set.
    bool public immutable GATED;

    uint256 public constant MAX_OPERATORS = 4;
    address private immutable OPERATOR0;
    address private immutable OPERATOR1;
    address private immutable OPERATOR2;
    address private immutable OPERATOR3;

    /// @param operators who may call {settleMatch}; empty = anyone. See the ⚠ on
    ///        filler identity for when a solver needs a gated instance.
    constructor(address settlement, address[] memory operators) MatchRaceGuard(settlement) {
        EXECUTOR = address(SETTLEMENT.EXECUTOR());
        uint256 n = operators.length;
        if (n > MAX_OPERATORS) revert BadOperatorSet();
        for (uint256 i; i < n; i++) {
            if (operators[i] == address(0)) revert BadOperatorSet();
        }
        GATED = n != 0;
        OPERATOR0 = n > 0 ? operators[0] : address(0);
        OPERATOR1 = n > 1 ? operators[1] : OPERATOR0;
        OPERATOR2 = n > 2 ? operators[2] : OPERATOR0;
        OPERATOR3 = n > 3 ? operators[3] : OPERATOR0;
    }

    /// @notice Whether `who` may call {settleMatch} on a {GATED} instance. Always
    ///         `false` on an open one.
    function isOperator(address who) public view returns (bool) {
        return GATED && (who == OPERATOR0 || who == OPERATOR1 || who == OPERATOR2 || who == OPERATOR3);
    }

    /// @notice Guarded `matchSettle`. Reverts {OrderTaken} — cheaply — if any order
    ///         moved since the plan was built.
    /// @param  orderHashes    per-order EIP-712 hashes, computed off-chain.
    /// @param  expectedFilled per-order `filled` at simulation time (see
    ///         {MatchRaceGuard._requireUntouched} for why this is an exact match).
    /// @param  plan           the settlement itself. LAST and `calldata` on purpose:
    ///         when the guard reverts this is never copied to memory or walked. Its
    ///         `profitRecipient` must be a real destination (see {ProfitStranded}).
    function settleMatch(bytes32[] calldata orderHashes, uint256[] calldata expectedFilled, MatchPlan calldata plan)
        external
        returns (uint256[][] memory outs, address[] memory tokens, uint256[] memory swept)
    {
        _requireOperator();
        _requireUntouched(orderHashes, expectedFilled);
        return _settle(plan);
    }

    /// @notice {settleMatch} that also guards FILL-ONCE and nonce-gated orders,
    ///         whose progress the `filled` counter cannot show (a fill-once order
    ///         burns its nonce and never writes `filled`; `cancelOrders`,
    ///         `invalidateNonceWord` and `rollbackNonces` cancel by nonce). See
    ///         {MatchRaceGuard._requireNoncesLive}.
    /// @param  nonceMakers maker of each nonce-guarded order (parallel to `nonces`).
    /// @param  nonces      the order's signed nonce.
    function settleMatchWithNonces(
        bytes32[] calldata orderHashes,
        uint256[] calldata expectedFilled,
        address[] calldata nonceMakers,
        uint256[] calldata nonces,
        MatchPlan calldata plan
    ) external returns (uint256[][] memory outs, address[] memory tokens, uint256[] memory swept) {
        _requireOperator();
        _requireUntouched(orderHashes, expectedFilled);
        _requireNoncesLive(nonceMakers, nonces);
        return _settle(plan);
    }

    /// @notice {settleMatch} with the two checks the `filled` guard cannot make
    ///         (audit 2026-09-30 X-DIFF-CORE-1.v1): every listed {Proportional}
    ///         maker still holds its quoted anchor (before the plan is touched),
    ///         and the settlement swept at least `minSwept` of each listed token
    ///         (after it returns). Use it for any plan that names the
    ///         `type(uint256).max` sentinel on a proportional order, and for every
    ///         plan that fronts a residual from inventory through a CALL step —
    ///         there a shrunk anchor would otherwise be paid in full.
    /// @param  g    the race guard plus the two extra checks — bundled for the
    ///         legacy profile's stack limit.
    function settleMatchChecked(CheckedGuard calldata g, MatchPlan calldata plan)
        external
        returns (uint256[][] memory outs, address[] memory tokens, uint256[] memory swept)
    {
        _requireOperator();
        _requireUntouched(g.orderHashes, g.expectedFilled);
        _requireAnchors(g.anchors);
        (outs, tokens, swept) = _settle(plan);
        _requireSwept(tokens, swept, g.minSwept);
    }

    /// @notice {settleMatchChecked}'s guard bundle.
    struct CheckedGuard {
        bytes32[] orderHashes;
        uint256[] expectedFilled;
        AnchorCheck[] anchors;
        SweptFloor[] minSwept;
    }

    function _requireOperator() private view {
        if (GATED && !isOperator(msg.sender)) revert NotOperator(msg.sender);
    }

    /// @dev The plan checks — AFTER the race guard so a loser still pays only the
    ///      SLOADs — then the settlement.
    function _settle(MatchPlan calldata plan)
        private
        returns (uint256[][] memory, address[] memory, uint256[] memory)
    {
        address to = plan.profitRecipient;
        if (to == address(0) || to == address(this) || to == address(SETTLEMENT) || to == EXECUTOR) {
            revert ProfitStranded();
        }
        uint256[] calldata schedule = plan.schedule;
        for (uint256 i; i < schedule.length;) {
            if (schedule[i] & 0xff == MatchStep.PRESEND) revert PresendUnsupported();
            unchecked {
                ++i;
            }
        }
        return SETTLEMENT.matchSettle(plan);
    }
}
