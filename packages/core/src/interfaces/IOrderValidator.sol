// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order} from "../settlement/UniversalSettlement.sol";

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
    /// @param  order  The full signed order (the validator may inspect any field).
    /// @param  filler The address executing this fill (msg.sender of the fill, or
    ///                the threaded filler for batchFill); lets validators express
    ///                filler-conditional policies (whitelists, reputation gates).
    ///                Validators that don't care simply ignore it.
    /// @param  data   Maker-signed per-validator config (from the signed order,
    ///                part of the order's EIP-712 typehash). A solver cannot swap
    ///                the validator or rewrite `data`.
    /// @param  takerData  Filler-supplied, shared-per-fill blob threaded from the
    ///                fill entrypoint. It is NOT part of the signed order and NOT
    ///                signed by the maker — it is ADVERSARIAL: any filler can put
    ///                anything here. A validator MUST independently verify anything
    ///                it reads from `takerData` before trusting it (e.g. recover a
    ///                maker-chosen trusted signer over an EIP-712 digest that binds
    ///                to the on-chain `filler` + this validator's domain). It lets a
    ///                maker-signed validator consume filler-supplied proofs at fill
    ///                time (off-chain attestations, oracle updates, ZK proofs).
    ///                Validators that don't need it ignore it. The SAME `takerData`
    ///                is passed to every validator and every invariant of the fill.
    function validate(Order calldata order, address filler, bytes calldata data, bytes calldata takerData)
        external
        view
        returns (bool);
}
