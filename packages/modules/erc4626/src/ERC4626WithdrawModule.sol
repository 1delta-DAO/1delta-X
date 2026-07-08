// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";

import {ITimelockERC4626} from "./interfaces/ITimelockERC4626.sol";

// ──────────────────── ERC-4626 two-phase withdraw module ────────────────────
//
// Handles time-locked ERC-4626 vault withdrawals in two separate limit-order
// executions:
//
//   Phase 1 — Request  (MakerModule, Settlement-gated)
//   ─────────────────────────────────────────────────
//   Settlement calls `makeOnBehalf(user, shares, data)`.
//   The module pulls vault shares from the user via the Permit3 token allowance,
//   approves the vault, submits `vault.requestRedeem(shares)`, and stores the
//   resulting `requestId` alongside who initiated it and when the lock expires.
//
//   `data = abi.encode(vault, shareToken)`
//
//   Phase 2 — Claim  (TakerModule, Permit3-gated)
//   ──────────────────────────────────────────────
//   After the vault's lock duration, Permit3 calls
//   `takeOnBehalf(user, minAssets, receiver, data)`.
//   The module verifies the caller is the original requester, checks the
//   module-level unlock timestamp (fast early-exit), then delegates to
//   `vault.claimRedeem` — which enforces the lock on-chain as the final gate.
//   Received assets are forwarded to `receiver`; `minAssets` acts as a
//   slippage / minimum-output guard.
//
//   `data = abi.encode(vault, asset, requestId)`
//
// Trust model
// ───────────
//  • Phase 1 is gated by `msg.sender == settlement` (same as all MakerModules).
//  • Phase 2 is gated by `msg.sender == permit3` (same as all TakerModules).
//  • The two phases are bound through `pendingWithdrawals[vault][requestId]`,
//    which records the beneficiary and unlock time at request submission.
//  • The module is the vault's registered requester for every pending entry,
//    so only this contract can call `vault.claimRedeem` for those requests.
//
// The reentrancy guard is shared across both entry points — a nested call into
// either phase during execution of the other will revert.
//
contract ERC4626WithdrawModule is IMakerModule, ITakerModule {
    // ── Immutables ────────────────────────────────────────────────────────────

    IPermit3 public immutable permit3;
    address public immutable settlement;

    // ── Storage ───────────────────────────────────────────────────────────────

    struct PendingWithdrawal {
        address beneficiary; // user on whose behalf the request was made
        uint256 unlocksAt; // block.timestamp at request + vault.lockDuration()
    }

    // vault address → vault-issued requestId → pending withdrawal details
    mapping(address => mapping(uint256 => PendingWithdrawal)) public pendingWithdrawals;

    uint256 private _locked = 1;

    // ── Events ────────────────────────────────────────────────────────────────

    event WithdrawRequested(
        address indexed vault, uint256 indexed requestId, address indexed beneficiary, uint256 shares, uint256 unlocksAt
    );

    event WithdrawClaimed(
        address indexed vault, uint256 indexed requestId, address indexed beneficiary, uint256 assets, address receiver
    );

    // ── Errors ────────────────────────────────────────────────────────────────

    error NotSettlement();
    error OnlyPermit3();
    error Reentrancy();
    error NoPendingWithdrawal();
    error NotBeneficiary();
    error TimelockActive(uint256 unlocksAt, uint256 currentTime);
    error InsufficientAssets(uint256 received, uint256 minAssets);

    // ── Constructor ───────────────────────────────────────────────────────────

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    // ── Phase 1: Request (IMakerModule) ───────────────────────────────────────

    /// @notice Initiate a time-locked vault withdrawal on behalf of a user.
    /// @param onBehalfOf User whose shares are being redeemed.
    /// @param amount     Number of vault shares to submit for redemption.
    /// @param data       `abi.encode(vault, shareToken)`
    ///                   • vault      — ITimelockERC4626 vault address
    ///                   • shareToken — ERC-20 address of the vault's share token
    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();
        if (_locked != 1) revert Reentrancy();
        _locked = 2;

        (address vault, address shareToken) = abi.decode(data, (address, address));

        // Pull shares from the user via Permit3 token allowance.
        permit3.transferFrom(onBehalfOf, address(this), shareToken, uint160(amount));

        // Approve the vault to pull the shares from this module.
        SafeTransferLib.forceApprove(shareToken, vault, amount);

        // Submit the redeem request. The vault pulls shares from this module
        // and records this module as the authorized claimer for the returned requestId.
        uint256 requestId = ITimelockERC4626(vault).requestRedeem(amount);

        // Record the beneficiary and the earliest valid claim time.
        // The vault's claimRedeem is the authoritative lock enforcer; this
        // timestamp gives a cheaper early-exit path and a descriptive error.
        uint256 unlocksAt = block.timestamp + ITimelockERC4626(vault).lockDuration();
        pendingWithdrawals[vault][requestId] = PendingWithdrawal({beneficiary: onBehalfOf, unlocksAt: unlocksAt});

        emit WithdrawRequested(vault, requestId, onBehalfOf, amount, unlocksAt);

        _locked = 1;
    }

    // ── Phase 2: Claim (ITakerModule) ─────────────────────────────────────────

    /// @notice Claim a matured vault withdrawal and forward assets to `receiver`.
    ///         Called by Permit3 after the user's taker allowance gate is checked.
    /// @param onBehalfOf User who initiated the withdrawal (must match the stored beneficiary).
    /// @param amount     Minimum underlying assets to accept (slippage guard).
    /// @param receiver   Destination for the claimed assets.
    /// @param data       `abi.encode(vault, asset, requestId)`
    ///                   • vault     — ITimelockERC4626 vault address
    ///                   • asset     — ERC-20 address of the vault's underlying asset
    ///                   • requestId — ID returned by the vault during Phase 1
    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();
        if (_locked != 1) revert Reentrancy();
        _locked = 2;

        (address vault, address asset, uint256 requestId) = abi.decode(data, (address, address, uint256));

        PendingWithdrawal storage pw = pendingWithdrawals[vault][requestId];

        if (pw.beneficiary == address(0)) revert NoPendingWithdrawal();
        if (pw.beneficiary != onBehalfOf) revert NotBeneficiary();
        if (block.timestamp < pw.unlocksAt) revert TimelockActive(pw.unlocksAt, block.timestamp);

        // Clear before the external call (checks-effects-interactions).
        delete pendingWithdrawals[vault][requestId];

        // Claim from the vault. The vault sends assets to this module;
        // it will revert if the lock has not elapsed on-chain.
        uint256 received = ITimelockERC4626(vault).claimRedeem(requestId, address(this));

        if (received < amount) revert InsufficientAssets(received, amount);

        SafeTransferLib.safeTransfer(asset, receiver, received);

        emit WithdrawClaimed(vault, requestId, onBehalfOf, received, receiver);

        _locked = 1;
    }
}
