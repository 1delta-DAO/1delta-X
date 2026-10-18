// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {
    AggregatorFillSolver,
    SurplusPolicy,
    PoolVenue,
    ItemFillGuard
} from "@solvers/aggregator/AggregatorFillSolver.sol";

Vm constant AGG_VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

/// @dev Every test deploys its {AggregatorFillSolver} through here. Unset, it is a plain
///      `new` (this profile's legacy build). With `AGG_ARTIFACT=<artifact json>` it is
///      the solver from THAT build instead — `make test-solvers-deployed` points it at
///      the via-IR `solvers-deploy` artifact, so the whole suite runs against the
///      bytecode that ships (the analogue of core's `make test-deployed`). Constructor-
///      revert tests keep a plain `new` (a `deployCode` revert is re-wrapped by forge).
function newAgg(address settlement, address[] memory ops, SurplusPolicy memory policy, PoolVenue[] memory venues)
    returns (AggregatorFillSolver)
{
    return newAggNative(settlement, ops, policy, venues, address(0), address(0));
}

/// @dev {newAgg} with native delivery (task 30) configured: `nativeBalance` / `wnative`
///      as the constructor's last two arguments (both zero = off, what {newAgg} passes).
function newAggNative(
    address settlement,
    address[] memory ops,
    SurplusPolicy memory policy,
    PoolVenue[] memory venues,
    address nativeBalance,
    address wnative
) returns (AggregatorFillSolver) {
    string memory artifact = AGG_VM.envOr("AGG_ARTIFACT", string(""));
    if (bytes(artifact).length == 0) {
        return new AggregatorFillSolver(settlement, ops, policy, venues, nativeBalance, wnative);
    }
    return AggregatorFillSolver(
        payable(AGG_VM.deployCode(artifact, abi.encode(settlement, ops, policy, venues, nativeBalance, wnative)))
    );
}

/// @dev {AggregatorFillSolver.executeItemFill}'s guard with every check off — the
///      pre-2026-10-18 behaviour (no race guard, no listed receipts).
function noGuard() pure returns (ItemFillGuard memory g) {}
