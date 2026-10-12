// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {AggregatorFillSolver, SurplusPolicy, PoolVenue} from "@solvers/aggregator/AggregatorFillSolver.sol";

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
    string memory artifact = AGG_VM.envOr("AGG_ARTIFACT", string(""));
    if (bytes(artifact).length == 0) return new AggregatorFillSolver(settlement, ops, policy, venues);
    return AggregatorFillSolver(AGG_VM.deployCode(artifact, abi.encode(settlement, ops, policy, venues)));
}
