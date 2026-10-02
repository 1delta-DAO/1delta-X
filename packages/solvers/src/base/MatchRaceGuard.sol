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
///  For an ordinary order the losing condition is knowable from ONE storage slot,
///  and the solver already knows every order hash off-chain. So check that first,
///  from a parameter list small enough to be nearly free, and bail before touching
///  the plan:
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
///  the state on chain" is the right one for the `filled` AXIS — and only that
///  axis: the counter is all this check reads. It does NOT see a {Proportional}
///  order's anchor, which resolves from the maker's LIVE token balance (audit
///  2026-09-30 X-DIFF-CORE-1.v1). A maker that drains its balance between the
///  simulation and inclusion shrinks that anchor with `filled` untouched; under
///  the `type(uint256).max` sentinel the netted path then settles the shrunk size,
///  and a plan that fronts a residual from inventory (a CALL step) pays FULL
///  outputs for it. Guard such plans with {_requireAnchors} (the maker still holds
///  the quoted anchor) and/or {_requireSwept} (the settlement swept at least what
///  the plan was priced for), or name the exact resolved anchor instead of `max`.
///
///  A solver running INDEPENDENT single-order fills (not a netted plan) has looser
///  requirements and should write its own predicate — this guard is for plans
///  whose amounts are jointly balanced.
///
///  ⚠ WHAT `filled` CANNOT SEE (audit 2026-09-30 FLASH-5 / CORE-MATCH-5)
///  ──────────────────────────────────────────────────────────────────
///  Two ways an order leaves the market never touch its `filled` slot:
///    • a FILL-ONCE order ({DutchAuction.useNonceInvalidator}, `timing` bit 100 —
///      the shape OCO brackets use) records its one fill by burning its NONCE, and
///      `filled[hash]` stays 0 forever; a sibling sharing the nonce dies the same way;
///    • NONCE cancellation (`cancelOrders`, `invalidateNonceWord`, `rollbackNonces`)
///      cancels by `(maker, nonce)`; only the per-hash `cancelOrder` writes the
///      `type(uint256).max` sentinel into `filled`.
///  For those orders pass the `(maker, nonce)` pair to {_requireNoncesLive} as well
///  — one or two more `SLOAD`s (`minValidNonce` plus one bitmap word). Without it the
///  `filled` check passes with `expected = 0` after a competitor already won, and
///  the loser pays the full approach run the guard exists to avoid.
abstract contract MatchRaceGuard {
    /// @notice The settler whose `filled` book the guard reads.
    Settlement public immutable SETTLEMENT;

    /// @dev Order `index` moved between simulation and inclusion — almost always a
    ///      competing solver landing first. Carried as a typed error (rather than a
    ///      bare revert) so a searcher's infrastructure can separate "lost the
    ///      race", which is routine and needs no investigation, from a genuine
    ///      failure, which does — without re-simulating.
    error OrderTaken(uint256 index, uint256 expected, uint256 actual);

    /// @dev `orderHashes` and `expectedFilled` (or `makers` and `nonces`) are not
    ///      the same length.
    error GuardLengthMismatch();

    /// @dev The nonce of nonce-guarded order `index` is spent or cancelled — a
    ///      competitor filled the fill-once order (or its OCO sibling), or the maker
    ///      cancelled by nonce. Same race-loss classification as {OrderTaken}.
    error NonceTaken(uint256 index, address maker, uint256 nonce);

    /// @notice One {Proportional} order's quoted anchor: `maker` must still hold at
    ///         least `minBalance` of `token` (the anchor token, `legsIn[0].token`).
    struct AnchorCheck {
        address maker;
        address token;
        uint256 minBalance;
    }

    /// @notice A floor on what `matchSettle` sweeps to the plan's recipient in `token`.
    struct SweptFloor {
        address token;
        uint256 min;
    }

    /// @dev Anchor check `index` failed: the maker's balance shrank below the
    ///      anchor the plan was priced for (X-DIFF-CORE-1.v1).
    error AnchorShrunk(uint256 index, uint256 expected, uint256 actual);
    /// @dev The settlement swept less of `token` than the plan's floor.
    error SweptShort(address token, uint256 expected, uint256 actual);

    constructor(address settlement) {
        SETTLEMENT = Settlement(settlement);
    }

    /// @notice Revert unless every {Proportional} maker still holds the anchor the
    ///         plan was priced for. One `balanceOf` per entry, before the plan is
    ///         touched — a drained anchor is a lost race, not a loss.
    function _requireAnchors(AnchorCheck[] calldata anchors) internal view {
        for (uint256 i; i < anchors.length;) {
            AnchorCheck calldata a = anchors[i];
            (bool ok, bytes memory ret) =
                a.token.staticcall(abi.encodeWithSignature("balanceOf(address)", a.maker));
            uint256 bal = ok && ret.length >= 32 ? abi.decode(ret, (uint256)) : 0;
            if (bal < a.minBalance) revert AnchorShrunk(i, a.minBalance, bal);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Revert unless `matchSettle`'s returned sweep meets every floor. A
    ///         floored token the settlement did not sweep at all reads 0.
    function _requireSwept(address[] memory tokens, uint256[] memory swept, SweptFloor[] calldata floors)
        internal
        pure
    {
        for (uint256 f; f < floors.length; f++) {
            uint256 got;
            for (uint256 t; t < tokens.length; t++) {
                if (tokens[t] == floors[f].token) {
                    got = swept[t];
                    break;
                }
            }
            if (got < floors[f].min) revert SweptShort(floors[f].token, floors[f].min, got);
        }
    }

    /// @notice Revert unless every listed order's `filled` counter is EXACTLY the
    ///         value the plan was built against. One `SLOAD` per order, no hashing,
    ///         no signature work, no plan access.
    /// @param  orderHashes   EIP-712 order hashes, computed off-chain (or read from
    ///         `SettlementLens.hashOrder`) — never recomputed here, which is the
    ///         whole point.
    /// @param  expectedFilled `filled[orderHashes[i]]` as observed when the plan was
    ///         built. A fresh order is 0; a partially-filled one is its cumulative
    ///         progress. An order cancelled BY HASH (`cancelOrder`) reads
    ///         `type(uint256).max`, so passing a stale non-max value also catches
    ///         that cancellation — but NOT a nonce cancellation, and not a fill-once
    ///         order's fill: see the ⚠ above and {_requireNoncesLive}.
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

    /// @notice Revert unless every listed `(maker, nonce)` is still live — the
    ///         guard for FILL-ONCE orders and nonce cancellation, which the `filled`
    ///         counter cannot see (see the ⚠ on the contract).
    /// @param  makers the maker of each nonce-guarded order.
    /// @param  nonces that order's signed `nonce`, aligned with `makers`.
    function _requireNoncesLive(address[] calldata makers, uint256[] calldata nonces) internal view {
        uint256 n = makers.length;
        if (nonces.length != n) revert GuardLengthMismatch();
        for (uint256 i; i < n;) {
            if (SETTLEMENT.isNonceCancelled(makers[i], nonces[i])) revert NonceTaken(i, makers[i], nonces[i]);
            unchecked {
                ++i;
            }
        }
    }
}
