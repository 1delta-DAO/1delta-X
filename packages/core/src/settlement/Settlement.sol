// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.sol";
import {Batch} from "./Batch.sol";

// Re-exported so downstream files can keep importing the order types from here.
import {Order, Item, ItemOp, Validator, OrderSide, CurvePoint, CallbackMode, ItemsBatch, FillCtx} from "./Structs.sol";

/// @title Settlement
/// @notice Signed limit-order settler with partial fills, optional dutch decay,
///         and pro-rata module-dispatched lending legs. All token and taker
///         authority flows through Permit3 — there is no module whitelist, no admin
///         role. A module's authority comes entirely from the maker's signature +
///         their per-module Permit3 allowances.
///
///  Structure — the inheritance chain, most-base → most-derived, each a small
///  single-responsibility layer an auditor can read in isolation:
///    • {NonceManager}         — nonce-bitmap cancellation state.
///    • {OrderState}           — the `filled` counter + on-chain approvals +
///                               per-hash cancellation + the `_openFill` counter
///                               transition (all order STATE, one place).
///    • {Signatures} — the EIP-712 domain + `_verifySignature` (order
///                               AUTHORIZATION — signed or on-chain-approved).
///    • {Base}       — execution infra: Permit3 hub + callback executor,
///                               reentrancy lock, validators, `_executeItems`.
///    • {Core}       — the single-order hot path.
///    • {Batch}      — the netted coincidence-of-wants modes.
///    • order types in {Structs}, EIP-712 hashing in {OrderHash}, auction
///      pricing in {DutchAuction}, per-leg slice math in {Pricing}.
///  This contract only assembles them and wires the constructor.
contract Settlement is Batch {
    constructor(address permit3) Base(permit3) {}
}
