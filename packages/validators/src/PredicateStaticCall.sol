// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOrderValidator} from "@core/interfaces/IOrderValidator.sol";
import {Order} from "@core/settlement/Settlement.sol";

/// @title PredicateStaticCall
/// @notice Escape-hatch validator for arbitrary read-only predicates.
///         Staticcalls `(target, data)` and passes iff the returned
///         first 32 bytes decode to a non-zero uint256.
///
/// @dev    `data = abi.encode(address target, bytes calldata)`
///
///         ⚠ A FAILING PREDICATE REVERTS, IT DOES NOT READ AS `false` (audit
///         2026-09-30 VAL-2). This used to fold a reverting, codeless or
///         short-returning target into a clean `false`. At the top level that is
///         equivalent ({OrderGates.gatePasses} folds a revert into `false` anyway),
///         but inside a {ConditionTreeValidator} it is not: the tree treats a
///         reverting leaf as an ERROR precisely so NEGATE can only ever invert a
///         clean boolean, and a leaf that launders its own failure into `false`
///         defeated that — `NOT(predicate)` passed exactly when the predicate was
///         broken. Now:
///           • target reverted / has no code / returned < 32 bytes ⇒ {PredicateFailed};
///           • the target ran out of gas ⇒ this call exhausts ITS gas too
///             (`invalid()`), so the out-of-gas is visible to the caller as an
///             out-of-gas — a filler cannot pick a gas limit that starves the
///             predicate into a value. (OpenZeppelin `ERC2771Forwarder` pattern.)
contract PredicateStaticCall is IOrderValidator {
    /// @dev The predicate target reverted, has no code, or returned fewer than 32
    ///      bytes. A broken predicate is an error, never an answer.
    error PredicateFailed();

    function validate(Order calldata, address, bytes calldata data, bytes calldata)
        external
        view
        override
        returns (bool)
    {
        (address target, bytes memory call) = abi.decode(data, (address, bytes));
        uint256 gasBefore = gasleft();
        (bool ok, bytes memory ret) = target.staticcall(call);
        if (!ok) {
            // The target received 63/64 of `gasBefore`; if it ran dry we are left with
            // at most ~1/64. Propagate it as out-of-gas rather than as a revert
            // reason a caller could mistake for a judgement.
            if (gasleft() < gasBefore / 63) {
                assembly {
                    invalid()
                }
            }
            revert PredicateFailed();
        }
        // A codeless target "succeeds" with empty returndata — caught here.
        if (ret.length < 32) revert PredicateFailed();
        return abi.decode(ret, (uint256)) != 0;
    }
}
