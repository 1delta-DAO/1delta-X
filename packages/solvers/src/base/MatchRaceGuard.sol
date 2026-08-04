// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Settlement} from "@core/settlement/Settlement.sol";

/// @title MatchRaceGuard
/// @notice The cheap-loss primitive for solvers competing on the same orders.
///
///  The problem
///  ───────────
///  A profitable match is visible to everyone at once, so several solvers land a
///  transaction for it in the same block. Exactly one wins; every other one
///  reverts — and reverting is not free. An unguarded loser pays for the whole
///  approach run before anything tells it the race is over: `matchSettle` derives
///  the token universe, snapshots a `balanceOf` per token, hashes the first order
///  (keccak over the full struct plus every dynamic sub-array), `ecrecover`s its
///  signature, and only THEN reads `filled` and reverts {OverFill}. With
///  validators on the order — an oracle read, an attestation recovery — the wasted
///  work grows without bound, and it grows with the size of the plan.
///
///  The fix
///  ───────
///  The losing condition is knowable from ONE storage slot per order, and the
///  solver already knows every order hash off-chain. So check that first, from a
///  parameter list small enough to be nearly free, and bail before touching the
///  plan:
///
///  ```solidity
///  function settleMatch(
///      bytes32[] calldata orderHashes,
///      uint256[] calldata expectedFilled,
///      MatchPlan calldata plan            // ← still untouched when the guard fires
///  ) external {
///      _requireUntouched(orderHashes, expectedFilled);
///      SETTLEMENT.matchSettle(plan);
///  }
///  ```
///
///  `plan` stays in CALLDATA: it is never copied to memory and its nested arrays
///  are never walked, so a losing call pays its calldata cost (unavoidable — the
///  EVM charges for calldata whether or not it is read) plus one `SLOAD` per
///  order, and nothing else.
///
///  Why EXACT equality, not "is there room left"
///  ────────────────────────────────────────────
///  A netted plan is balanced against a specific chain state. `Pricing.inputOwed`
///  computes a fixed leg as `amt·newFilled/anchor − amt·prevFilled/anchor`, so
///  `prevFilled` moving changes the owed amount by a rounding unit even when
///  plenty of room remains — and a plan that is off by one wei no longer nets:
///  the pool comes up short and the settlement reverts {BatchNotWhole}, or a
///  sliver is swept that the solver's economics did not account for. "Still has
///  room" is therefore the wrong question; "is the state I simulated against still
///  the state on chain" is the right one, and it is also the cheaper check.
///
///  A solver running INDEPENDENT single-order fills (not a netted plan) has looser
///  requirements and should write its own predicate — this guard is for plans
///  whose amounts are jointly balanced.
abstract contract MatchRaceGuard {
    /// @notice The settler whose `filled` book the guard reads.
    Settlement public immutable SETTLEMENT;

    /// @dev Order `index` moved between simulation and inclusion — almost always a
    ///      competing solver landing first. Carried as a typed error (rather than a
    ///      bare revert) so a searcher's infrastructure can separate "lost the
    ///      race", which is routine and needs no investigation, from a genuine
    ///      failure, which does — without re-simulating.
    error OrderTaken(uint256 index, uint256 expected, uint256 actual);

    /// @dev `orderHashes` and `expectedFilled` are not the same length.
    error GuardLengthMismatch();

    constructor(address settlement) {
        SETTLEMENT = Settlement(settlement);
    }

    /// @notice Revert unless every listed order's `filled` counter is EXACTLY the
    ///         value the plan was built against. One `SLOAD` per order, no hashing,
    ///         no signature work, no plan access.
    /// @param  orderHashes   EIP-712 order hashes, computed off-chain (or read from
    ///         `SettlementLens.hashOrder`) — never recomputed here, which is the
    ///         whole point.
    /// @param  expectedFilled `filled[orderHashes[i]]` as observed when the plan was
    ///         built. A fresh order is 0; a partially-filled one is its cumulative
    ///         progress. A cancelled order reads `type(uint256).max`, so passing a
    ///         stale non-max value also catches cancellation.
    function _requireUntouched(bytes32[] calldata orderHashes, uint256[] calldata expectedFilled) internal view {
        uint256 n = orderHashes.length;
        if (expectedFilled.length != n) revert GuardLengthMismatch();
        for (uint256 i; i < n;) {
            uint256 actual = SETTLEMENT.filled(orderHashes[i]);
            if (actual != expectedFilled[i]) revert OrderTaken(i, expectedFilled[i], actual);
            unchecked {
                ++i;
            }
        }
    }
}
