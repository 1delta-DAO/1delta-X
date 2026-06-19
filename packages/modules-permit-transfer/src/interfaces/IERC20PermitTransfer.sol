// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal interface documenting the data encoding for ERC20PermitTransferModule.
///
/// Phase — Transfer (TakerModule, Permit3-gated):
///   data = abi.encode(token, recipient, transferAmount[, deadline, v, r, s])
///
///   token          — ERC-20 token being transferred
///   recipient      — ultimate destination for `transferAmount`
///   transferAmount — tokens delivered to `recipient`; must be ≤ `amount` (gross)
///   deadline/v/r/s — optional EIP-2612 permit block (128 bytes); if omitted,
///                    caller must have a standing ERC-20 allowance to Permit3
///
/// The solver fee = amount - transferAmount flows to Settlement via `receiver`,
/// and Settlement pays it to the solver through its normal _payTokenInToSolver path.
///
/// Matching LimitOrder shape:
///   tokenIn  = token,  amountIn  = fee            (what solver earns)
///   tokenOut = token,  amountOut = 0              (solver provides nothing)
///   items    = [{ TAKE, ERC20PermitTransferModule, fee + transferAmount, 0, data }]
interface IERC20PermitTransfer {}
