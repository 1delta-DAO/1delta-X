// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPermit3} from "../interfaces/IPermit3.sol";
import {ITakerModule} from "../interfaces/ITakerModule.sol";

/// @title Permit3
/// @notice Unified allowance hub for ERC20 transfers *and* protocol taker ops
///         (borrow, withdraw, unstake, claim, …).
///
///  Design
///  ──────
///  Permit3 holds two allowance books:
///
///    • token book — keyed (user → spender → token). A spender calls
///      `transferFrom(user, to, token, amount)`; Permit3 decrements the
///      spender's allowance and calls the token's ERC20 transferFrom.
///      Permit2-equivalent.
///
///    • taker book — keyed (user → module → bytes32 ref). An arbitrary
///      caller invokes `take(module, user, asset, amount, receiver, data)`;
///      Permit3 asks the module for `takerKey(asset, data)`, decrements the
///      user's allowance on (module, ref), then invokes the module's
///      `takeOnBehalf`. The module performs the protocol-native call.
///
///  Permit3 knows nothing about lending/staking/vault protocols. Protocol
///  heterogeneity stays in modules. Single-operation modules keep blast
///  radius small: approvals on a borrow module cannot be used to withdraw,
///  and vice versa.
///
///  This cut exposes only on-chain `approveX` flows (no EIP-712 signed
///  permits). Signed permits with order-hash witnesses are a straight
///  extension.
contract Permit3 is IPermit3 {
    /// @dev user → spender → token → (amount, expiration, nonce)
    mapping(address => mapping(address => mapping(address => PackedAllowance))) private _tokenAllowance;

    /// @dev user → module → ref → (amount, expiration, nonce).
    ///      `ref` is opaque to Permit3 — a module-specific position key
    ///      (Morpho marketId, Comet address, Aave (asset, rateMode), LST
    ///      withdrawal NFT id, …).
    mapping(address => mapping(address => mapping(bytes32 => PackedAllowance))) private _takerAllowance;

    uint256 private _locked = 1;

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    // ──────────────────── Token side ────────────────────

    function approveToken(address spender, address token, uint160 amount, uint48 expiration) external override {
        PackedAllowance storage a = _tokenAllowance[msg.sender][spender][token];
        a.amount = amount;
        a.expiration = expiration;
        emit TokenApproval(msg.sender, spender, token, amount, expiration);
    }

    function transferFrom(address user, address to, address token, uint160 amount) external override {
        PackedAllowance storage a = _tokenAllowance[user][msg.sender][token];
        _spend(a, amount);
        IERC20(token).transferFrom(user, to, amount);
    }

    function tokenAllowance(address user, address spender, address token)
        external
        view
        override
        returns (uint160 amount, uint48 expiration, uint48 nonce)
    {
        PackedAllowance storage a = _tokenAllowance[user][spender][token];
        return (a.amount, a.expiration, a.nonce);
    }

    // ──────────────────── Taker side ────────────────────

    function approveTaker(address module, bytes32 ref, uint160 amount, uint48 expiration) external override {
        PackedAllowance storage a = _takerAllowance[msg.sender][module][ref];
        a.amount = amount;
        a.expiration = expiration;
        emit TakerApproval(msg.sender, module, ref, amount, expiration);
    }

    function take(address module, address user, uint160 amount, address receiver, bytes calldata data)
        external
        override
        nonReentrant
    {
        bytes32 ref = keccak256(data);
        _spend(_takerAllowance[user][module][ref], amount);
        ITakerModule(module).takeOnBehalf(user, amount, receiver, data);
    }

    function takerAllowance(address user, address module, bytes32 ref)
        external
        view
        override
        returns (uint160 amount, uint48 expiration, uint48 nonce)
    {
        PackedAllowance storage a = _takerAllowance[user][module][ref];
        return (a.amount, a.expiration, a.nonce);
    }

    // ──────────────────── Revocation ────────────────────

    function revokeToken(address spender, address token) external override {
        delete _tokenAllowance[msg.sender][spender][token];
        emit TokenApproval(msg.sender, spender, token, 0, 0);
    }

    function revokeTaker(address module, bytes32 ref) external override {
        delete _takerAllowance[msg.sender][module][ref];
        emit TakerApproval(msg.sender, module, ref, 0, 0);
    }

    function lockdown(address spender) external override {
        // Intent-only signal; callers sweep specific (asset, ref) pairs via
        // revokeToken / revokeTaker using their off-chain-indexed asset list.
        emit Lockdown(msg.sender, spender);
    }

    // ──────────────────── Internal ────────────────────

    function _spend(PackedAllowance storage a, uint160 amount) private {
        uint48 exp = a.expiration;
        // expiration == 0 means "no expiration" — matches Permit2 ergonomics
        if (exp != 0 && block.timestamp > exp) revert AllowanceExpired(exp);

        uint160 cur = a.amount;
        // type(uint160).max == "infinite, do not decrement"
        if (cur != type(uint160).max) {
            if (cur < amount) revert InsufficientAllowance(cur);
            unchecked {
                a.amount = cur - amount;
            }
        }
    }
}
