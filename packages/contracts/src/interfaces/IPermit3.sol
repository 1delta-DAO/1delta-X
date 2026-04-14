// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IPermit3
/// @notice Dual-allowance hub:
///         • token book — Permit2-equivalent. Spender pulls ERC20 via transferFrom.
///         • taker book — Taker module pulls value from a user's position
///           (borrow, withdraw, unstake, claim, …) via Permit3.take(…).
///
///         Users approve Permit3 once per asset/module and tune caps per order.
interface IPermit3 {
    struct PackedAllowance {
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    // ──────────────────── Events ────────────────────

    event TokenApproval(
        address indexed user, address indexed spender, address indexed token, uint160 amount, uint48 expiration
    );
    event TakerApproval(
        address indexed user, address indexed module, bytes32 indexed ref, uint160 amount, uint48 expiration
    );
    event Lockdown(address indexed user, address spender);

    // ──────────────────── Errors ────────────────────

    error AllowanceExpired(uint48 expiration);
    error InsufficientAllowance(uint160 amount);
    error Reentrancy();

    // ──────────────────── Token side ────────────────────

    function approveToken(address spender, address token, uint160 amount, uint48 expiration) external;

    function transferFrom(address user, address to, address token, uint160 amount) external;

    function tokenAllowance(address user, address spender, address token)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);

    // ──────────────────── Taker side ────────────────────
    //
    // `ref` is a module-defined opaque key identifying the position the
    // operation touches. The op itself is identified by the module's address
    // (single-operation modules). Refs are computed by
    // `ITakerModule.takerKey(asset, data)` so they are reproducible off-chain.

    function approveTaker(address module, bytes32 ref, uint160 amount, uint48 expiration) external;

    /// @notice Amount-gated dispatch: decrements the user's allowance on
    ///         (user, module, ref) where `ref = keccak256(data)`, then
    ///         invokes `module.takeOnBehalf(user, amount, receiver, data)`.
    ///         Any address may call — the security boundary is the maker's
    ///         per-module allowance. Asset identity is encoded inside `data`.
    function take(address module, address user, uint160 amount, address receiver, bytes calldata data) external;

    function takerAllowance(address user, address module, bytes32 ref)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);

    // ──────────────────── Revocation ────────────────────

    function revokeToken(address spender, address token) external;

    function revokeTaker(address module, bytes32 ref) external;

    function lockdown(address spender) external;
}
