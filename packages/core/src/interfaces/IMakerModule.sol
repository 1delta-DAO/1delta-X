// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IMakerModule
/// @notice Uniform "make (push) value into a user's position" adapter — the
///         inverse of `ITakerModule`. Used for deposit and repay ops.
///
///         Naming mirrors limit-order parlance: takers draw value out, makers
///         put value in. (Unrelated to the `maker` field on a `LimitOrder`,
///         which names the order's signer.)
///
///  A maker module performs exactly one operation that moves value from the
///  user into some external protocol on the user's behalf. Examples (each a
///  separate module):
///
///    - AaveV3DepositModule        — supply to Aave v3
///    - AaveV3RepayModule          — repay Aave v3 debt
///    - MorphoBlueSupplyModule     — supply to a specific Morpho market
///    - CometSupplyModule          — supply base or collateral to Comet
///    - CompoundV2MintModule       — mint cTokens
///
///  Trust model
///  ───────────
///  Maker modules need only an ERC20 allowance from the user (no "on-behalf"
///  delegation at the protocol layer, because tokens flow *to* the protocol).
///  The user:
///
///    1. Approves Permit3 once per token at the ERC20 level.
///    2. Grants the module a Permit3 token allowance:
///       `permit3.approveToken(module, token, amount, expiration)`
///
///  Inside `makeOnBehalf` the module pulls the token via
///  `permit3.transferFrom(user, address(this), token, amount)` and forwards
///  it to the protocol.
interface IMakerModule {
    /// @notice Push `amount` of value from `onBehalfOf` into the protocol
    ///         position identified by `data`.
    /// @dev    Called by Settlement. Module MUST pull the funding token
    ///         from `onBehalfOf` via `permit3.transferFrom(...)` — the
    ///         token allowance is the gate.
    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external;
}
