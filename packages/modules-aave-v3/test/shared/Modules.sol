// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOrderValidator} from "@core/interfaces/IOrderValidator.sol";
import {LimitOrder} from "@core/settlement/LimitOrderSettlement.sol";

// The Aave v3 maker/taker modules and their interfaces now live in the package
// `src/` tree (`src/AaveV3Modules.sol`, `src/interfaces/IAaveV3.sol`). Only the
// test-only invariant validators below remain here as shared test fixtures.

// ──────────────────── Test-only validators for invariant checks ────────────────────

contract TrueInvariant is IOrderValidator {
    function validate(LimitOrder calldata, bytes calldata) external pure returns (bool) {
        return true;
    }
}

contract FalseInvariant is IOrderValidator {
    function validate(LimitOrder calldata, bytes calldata) external pure returns (bool) {
        return false;
    }
}
