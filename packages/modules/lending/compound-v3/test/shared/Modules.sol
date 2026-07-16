// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOrderValidator} from "@core/interfaces/IOrderValidator.sol";
import {Order} from "@core/settlement/UniversalSettlement.sol";

// The Comet maker/taker modules and their interfaces live in the package `src/`
// tree (`src/CompoundV3Modules.sol`, `src/interfaces/ICompoundV3.sol`). Only the
// test-only invariant validators below remain here as shared test fixtures.

// ──────────────────── Test-only validators for invariant checks ────────────────────

contract TrueInvariant is IOrderValidator {
    function validate(Order calldata, address, bytes calldata, bytes calldata) external pure returns (bool) {
        return true;
    }
}

contract FalseInvariant is IOrderValidator {
    function validate(Order calldata, address, bytes calldata, bytes calldata) external pure returns (bool) {
        return false;
    }
}
