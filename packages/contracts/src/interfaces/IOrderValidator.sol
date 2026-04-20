// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LimitOrder} from "../settlement/LimitOrderSettlement.sol";

/// @title IOrderValidator
/// @notice Read-only trigger for limit orders. Settlement calls `validate`
///         via `staticcall` before executing any item, and reverts the
///         fill if any validator returns false.
///
///  Safety properties
///  ─────────────────
///  • `staticcall` forbids state mutation, logs, and reentrancy into
///    Settlement — a malicious validator can do nothing beyond returning
///    a bad boolean (which only harms the user that signed it).
///  • `target` and `data` are part of the order's EIP-712 typehash, so
///    the solver cannot swap validators or rewrite parameters.
///  • Validators are AND-composed in `_runValidators`; any single `false`
///    aborts the fill.
interface IOrderValidator {
    /// @notice Return `true` iff the order is allowed to execute now.
    /// @param  order The full signed order (the validator may inspect any field).
    /// @param  data  Opaque validator-specific parameters, signed with the order.
    function validate(LimitOrder calldata order, bytes calldata data)
        external
        view
        returns (bool);
}
