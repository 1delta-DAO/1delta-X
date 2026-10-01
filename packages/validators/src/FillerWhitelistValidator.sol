// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOrderValidator} from "@core/interfaces/IOrderValidator.sol";
import {Order} from "@core/settlement/Settlement.sol";

/// @title FillerWhitelistValidator
/// @notice Combined filler registry + order validator: gate an order so only
///         fillers on a chosen curator's list may execute it, optionally opening
///         to everyone after a signed timestamp.
///
///  Compliance use-case
///  ───────────────────
///  A maker who needs its counterparties vetted (KYC'd solver set, sanctioned-
///  address screening, institutional desk policy) signs this validator into the
///  order with the address of a curator it trusts. The whitelist is per-order
///  and maker-opted — the maker chooses whether to gate at all and whose list to
///  trust — not protocol-imposed: the settlement itself stays permissionless,
///  and orders without this validator remain fillable by anyone.
///
///  Trust model
///  ───────────
///  • This contract has no owner or admin. Anyone can curate a list under their
///    own address; a curator can only ever edit `isListed[curator][*]` for
///    `curator == msg.sender`. Lists are isolated — signing curator A's address
///    into the order means only A's list gates it.
///  • The `(curator, openAfter)` parameters live in the order's signed
///    `Validator.data`, so a solver can neither swap the curator nor shorten
///    the open-up time. The gate is evaluated via `staticcall` at fill time
///    against the curator's CURRENT list (curators can list/delist between
///    signing and filling — that live-ness is the point).
///
///  ⚠ The gated identity is an ADDRESS (audit 2026-09-30 VAL-5)
///  ───────────────────────────────────────────────────────────
///  `filler` is Settlement's IMMEDIATE `msg.sender` (the batch / match caller on
///  the netted paths) — nothing further up the call chain. Listing a CONTRACT that
///  fills as itself on behalf of arbitrary callers — an open (non-GATED)
///  `AggregatorFillSolver`, the `BaseFlashSolver` family (`executeFill` is
///  permissionless), `GuardedMatchSolver.settleMatch`,
///  `DestinationSettler7683.fill`, any permissionless executor — admits EVERY
///  caller of that contract, vetted or not. A compliance list (KYC, sanctions
///  screening) is therefore only as strong as the access control of each contract
///  on it: list EOAs, or contracts whose fill entrypoint is restricted to the
///  vetted party (an operator-GATED solver instance). The maker's signed amounts
///  still bind either way — this widens WHO may fill, never at what price.
///
///  Liveness fallback (Fusion-style)
///  ────────────────────────────────
///  `openAfter == 0` — hard whitelist: only listed fillers, forever.
///  `openAfter != 0` — whitelisted solvers get exclusivity first; once
///  `block.timestamp >= openAfter` the order opens to every filler, so a stalled
///  or abandoned curator list cannot strand the order.
///
/// @dev `data = abi.encode(address curator, uint256 openAfter)`.
contract FillerWhitelistValidator is IOrderValidator {
    /// @notice `isListed[curator][filler]` — whether `filler` is on `curator`'s list.
    mapping(address curator => mapping(address filler => bool)) public isListed;

    /// @notice `curator` set (or cleared) `fillers` on its list.
    event FillersSet(address indexed curator, address[] fillers, bool allowed);

    /// @notice List (`allowed = true`) or delist (`allowed = false`) `fillers`
    ///         under the caller's curator address. Permissionless by design:
    ///         msg.sender can only ever edit its own list.
    function setFillers(address[] calldata fillers, bool allowed) external {
        for (uint256 i; i < fillers.length; i++) {
            isListed[msg.sender][fillers[i]] = allowed;
        }
        emit FillersSet(msg.sender, fillers, allowed);
    }

    /// @inheritdoc IOrderValidator
    /// @dev Passes iff `filler` is on the signed curator's list, OR the signed
    ///      `openAfter` is non-zero and has elapsed (open-to-everyone fallback).
    ///      Uses only the maker-signed `data`; the filler-supplied `takerData` is
    ///      ignored (the whitelist is keyed by the on-chain `filler` address).
    function validate(Order calldata, address filler, bytes calldata data, bytes calldata)
        external
        view
        override
        returns (bool)
    {
        (address curator, uint256 openAfter) = abi.decode(data, (address, uint256));
        return isListed[curator][filler] || (openAfter != 0 && block.timestamp >= openAfter);
    }
}
