// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order} from "../settlement/Structs.sol";

/// @title IFillModule
/// @notice A pluggable fill *matcher* — the generalization of the fungible fill
///         denominator. An order that sets `Order.fillModule` delegates the
///         "how much of this order does this fill advance?" question to the
///         module, so the fill unit can be a fungible amount, one indivisible
///         item (an NFT), an ERC-1155 quantity, a signed quote, or an auction
///         lot — without the maker having to borrow a nominal fungible anchor.
///
///  Responsibility split (deliberate, security-critical):
///    • The MODULE turns the solver's proposal — the requested `fillAmount` plus
///      the shared filler-supplied `takerData` blob — into a scalar `delta` in
///      the maker's unit, and MUST REVERT if the solver's counterparty side does
///      not match the maker's order. This is the taker↔maker match.
///    • The CORE keeps everything money-critical: the denominator (`fillTotal`,
///      maker-signed), the over-fill cap (`filled + delta <= total`), and the
///      UNIFORM scaling of every leg/item by `delta / total`. So the module may
///      choose the *fraction* but never the *per-leg amounts* and never the
///      *cap* — a buggy module can only mis-size the fraction, which scales both
///      sides proportionally; the only extraction risk (past 100%) is caught by
///      the core cap.
///
///  Trust model: `fillModule` is consensus-critical (it gates every fill's
///  progress) and is maker-signed per order, exactly like a validator. It MUST
///  be `view` — no side effects, no fund movement. `takerData` is the same
///  adversarial, unsigned, filler-supplied blob the validators/invariants see,
///  so a module that reads it MUST independently verify it against the order.
///
///  Clamping: the core's race-tolerant entry (`fillUpTo`) clamps IDENTITY
///  orders to the remaining size but passes a module order's proposal through
///  UNTOUCHED — only the module knows what a partial acceptance of its unit
///  means. A module SHOULD therefore clamp itself where partial acceptance is
///  meaningful (`delta = min(resolved, order.fillTotal - prevFilled)`), and
///  simply resolve past the cap where it is not (an indivisible lot) — the
///  core's `filled + delta <= fillTotal` check then rejects the fill.
interface IFillModule {
    /// @param order      the full signed order (the module reads the maker's side)
    /// @param prevFilled cumulative filled so far, in `fillTotal` units
    /// @param fillAmount the solver's requested delta (identity unit)
    /// @param takerData  the shared filler-supplied proposal blob (adversarial)
    /// @return delta     how much of `fillTotal` this fill advances; revert on mismatch
    function resolveFill(Order calldata order, uint256 prevFilled, uint256 fillAmount, bytes calldata takerData)
        external
        view
        returns (uint256 delta);
}
