// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IAllowanceHolder
/// @notice A signature-free allowance path: the owner approves this contract once
///         on the ERC20, then grants an allowance that exists ONLY for the duration
///         of a single call and is zeroed before that call returns.
///
///         Modelled on 0x's `AllowanceHolder`. It is the third point on the
///         approve/permit spectrum:
///
///           standing allowance  — durable, revocable, must be revoked
///           signed permit       — bounded, but needs a signature per use
///           ephemeral allowance — no signature, and nothing survives the call
///
/// @dev    Deliberately NOT part of Permit3 and deliberately unprivileged. `exec`
///         makes an arbitrary call to an arbitrary target, so the holder's own
///         address must never be granted authority anywhere — not as a Permit3
///         spender, not as a module's authorised caller, not as a settlement
///         operator. Anything it is trusted to do, anyone can make it do.
interface IAllowanceHolder {
    /// @notice Thrown when `target` is the holder itself — that would let a caller
    ///         re-enter `transferFrom` with the holder as the operator.
    error InvalidTarget();
    /// @notice Thrown when `target` looks like an ERC20. Calling a token DIRECTLY
    ///         from the holder would spend the holder's own standing approvals —
    ///         every user's, not just the caller's. See {AllowanceHolder}.
    error ConfusedDeputy();
    /// @notice Thrown when an ephemeral allowance for the same
    ///         (operator, owner, token) is already live in an enclosing `exec`.
    error AllowanceInFlight();
    /// @notice Thrown when an operator pulls more than its live allowance.
    error InsufficientEphemeralAllowance(uint256 allowed);

    /// @notice Grant `operator` a one-call allowance of `amount` on `token`, then
    ///         call `target` with `data`.
    ///
    ///         The allowance is keyed to `msg.sender` as the owner — you can only
    ///         ever put your OWN tokens at risk — and is zeroed when `target`
    ///         returns. `msg.sender` is appended to `data` as 20 trailing bytes
    ///         (ERC-2771 style) so a target that cares can recover the real caller;
    ///         targets that don't simply ignore the extra calldata.
    ///
    /// @param operator the only address allowed to call `transferFrom` during this call
    /// @param token    the ERC20 the allowance covers
    /// @param amount   the maximum the operator may pull
    /// @param target   the contract to call (must not be this contract)
    /// @param data     calldata for `target`; `msg.sender` is appended
    /// @return result  `target`'s raw return data; a revert is bubbled verbatim
    function exec(address operator, address token, uint256 amount, address payable target, bytes calldata data)
        external
        payable
        returns (bytes memory result);

    /// @notice Pull `amount` of `token` from `owner` to `recipient` against a live
    ///         ephemeral allowance. Callable only by the `operator` of an `exec`
    ///         currently in flight — outside one, the allowance reads zero and this
    ///         reverts.
    function transferFrom(address token, address owner, address recipient, uint256 amount) external returns (bool);

    /// @notice The live ephemeral allowance for a triple. Zero outside an `exec`.
    function ephemeralAllowance(address operator, address owner, address token) external view returns (uint256);
}
