// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ITakerModule
/// @notice Uniform "pull value from a user's position" adapter.
///
///  A taker module performs exactly one operation that removes value from a
///  user's position in some external protocol and forwards it to a receiver.
///  Examples (each a separate module):
///
///    - AaveV3BorrowModule         — borrow-on-behalf
///    - AaveV3WithdrawModule       — withdraw collateral on-behalf
///    - MorphoBlueBorrowModule     — borrow from a specific market
///    - CometWithdrawModule        — withdrawFrom(src=user)
///    - LidoUnstakeModule          — initiate stETH unstake
///    - LidoClaimModule            — claim a matured unstake NFT
///
///  Single-op modules keep the blast radius small: a user approving
///  `AaveV3BorrowModule` for 1000 USDC only authorises borrows — never
///  withdrawals — and the operation is legible from the module address
///  alone.
///
///  Trust model
///  ───────────
///  Users authorise a module via two independent primitives:
///
///    1. A one-time protocol-native delegation permitting the module to act:
///       - Aave v3:  `variableDebtToken.approveDelegation(module, max)` for
///                   borrow modules; aToken pulls for withdraw modules.
///       - Comet:    `allow(module, true)`
///       - Morpho:   `setAuthorization(module, true)`
///
///    2. An amount-gated allowance held by Permit3:
///       - `permit3.approveTaker(module, takerKey(asset, data), amount, expiry)`
///       - `permit3.approveToken(module, token, amount, expiry)` — if the module
///         also pulls ERC20s from the user mid-op (fees, collateral legs, etc.)
///
///  Permit3 enforces the allowance gate inside its `take` entrypoint, so the
///  module does not need to call `spend` itself. The module only has to:
///  implement the protocol-native call and, if needed, use
///  `permit3.transferFrom` to pull ERC20s.
interface ITakerModule {
    /// @notice Perform the protocol-native call that removes `amount` of
    ///         value from `onBehalfOf`'s position and sends it to `receiver`.
    ///         The asset being moved is whatever the position's `data`
    ///         implies (often fixed by the position itself, e.g. Morpho
    ///         market loan token, Comet base asset, Lido withdrawal NFT).
    /// @dev    Called ONLY by Permit3 after the allowance gate has been
    ///         decremented. The allowance ref is `keccak256(data)`, so the
    ///         bytes the module decodes here are the same bytes the user
    ///         authorised.
    ///
    ///         Modules MUST enforce `msg.sender == permit3` as their first
    ///         statement. This is load-bearing: without it, a direct
    ///         `takeOnBehalf(victim, amount, attacker, data)` call bypasses
    ///         the Permit3 taker-allowance gate entirely and, combined with
    ///         the victim's (usually infinite) token allowance on the
    ///         position's receipt token, lets any caller drain the victim
    ///         into the `receiver` address they control.
    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external;
}
