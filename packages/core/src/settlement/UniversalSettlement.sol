// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SettlementBase} from "./SettlementBase.sol";
import {SettlementBatch} from "./SettlementBatch.sol";

// Re-exported so downstream files can keep importing the order types from here.
import {Order, Item, ItemOp, Validator, OrderSide, CurvePoint, CallbackMode, ItemsBatch, FillCtx} from "./SettlementStructs.sol";

/// @title UniversalSettlement
/// @notice Signed limit-order settler with partial fills, optional dutch decay,
///         and pro-rata module-dispatched lending legs. All token and taker
///         authority flows through Permit3 — there is no module whitelist, no admin
///         role. A module's authority comes entirely from the maker's signature +
///         their per-module Permit3 allowances.
///
///  Structure (read in this order):
///    • {SettlementBase}  — storage, domain, reentrancy, signature/approval,
///                          validators, and the shared fill primitives.
///    • {SettlementCore}  — the single-order hot path.
///    • {SettlementBatch} — the netted coincidence-of-wants modes.
///    • order types in {SettlementStructs}, EIP-712 hashing in {OrderHash}, auction
///      pricing in {DutchAuction}, per-leg slice math in {SettlementPricing},
///      cancellation in {NonceManager}.
///  This contract only assembles them and wires the constructor.
contract UniversalSettlement is SettlementBatch {
    constructor(address permit3) SettlementBase(permit3) {}
}
