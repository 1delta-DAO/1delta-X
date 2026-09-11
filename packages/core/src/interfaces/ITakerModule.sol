// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ITakerModule
/// @notice Uniform "pull value from a user's position" adapter.
///
///  A taker module performs exactly one operation that removes value from a
///  user's position in some external protocol and forwards it to a receiver.
///  Examples (each a separate module):
///
///    - AaveV3CreditModule         — borrow-on-behalf (and fused leverage)
///    - AaveV3WithdrawModule       — withdraw collateral on-behalf
///    - MorphoBlueBorrowModule     — borrow from a specific market
///    - CometWithdrawModule        — withdrawFrom(src=user)
///    - LidoUnstakeModule          — initiate stETH unstake
///    - LidoClaimModule            — claim a matured unstake NFT
///
///  Blast radius is bounded by the GRANT, not by the contract. A taker allowance
///  is keyed `(user, spender, module, ref = keccak256(data))`, so approving
///  1000 USDC against a borrow `ref` authorises borrows at those parameters —
///  never withdrawals — whether or not the withdraw op happens to live at the
///  same address.
///
///  That is what lets a module host several ops: put the op INSIDE `data` and it
///  is inside `ref`, so a grant signed for one op cannot be replayed as another.
///  {AaveV3CreditModule} does this deliberately, and for a reason the per-`ref`
///  keying does not cover: Aave's credit delegation is a STANDING,
///  protocol-native authorisation outside Permit3 entirely. Split across one
///  contract per borrow-shaped op, it becomes one permanent liability per
///  contract for the maker to audit and revoke. Merged by grant class, it is one.
///
///  ⚠ MERGE BY GRANT, NOT BY VENUE. A merged contract redeploys as a unit, so ops
///  that consume DIFFERENT standing grants must stay at different addresses —
///  otherwise a bugfix in one op forces a re-approval of a grant it never
///  touched. Aave v3 keeps three: the credit line, the aToken, the wallet
///  allowance.
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
///    2. An amount-gated allowance held by Permit3, keyed by the SPENDER that
///       will call `take` (the Settlement contract) — exactly like the token
///       book is keyed by spender:
///       - `permit3.approveTaker(settlement, keccak256(data), amount, expiry)`
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
    ///
    ///         Note this gate is necessary but not sufficient on its own: it
    ///         funnels all calls through `Permit3.take`, whose own safety comes
    ///         from the taker book being keyed by SPENDER (only an approved
    ///         spender — Settlement — can consume an allowance and choose
    ///         `receiver`). See `Permit3.take` / `IPermit3`.
    ///
    ///         ⚠ `Permit3.take` is `nonReentrant`, so a module CANNOT call back
    ///         into it from inside `takeOnBehalf` — a composite op spanning two
    ///         protocols must be expressed as two items, not one nested take.
    ///         (`Permit3.transferFrom` is NOT locked and stays available, which is
    ///         how a module pulls the ERC20s it needs mid-op.) Stated here because
    ///         it is a constraint on writing a module, discoverable otherwise only
    ///         by reading Permit3.
    ///
    ///         The allowance `ref` is `keccak256(data)` — the position key — but the
    ///         taker book is keyed `(user, spender, MODULE, ref)`, so the module is
    ///         part of the allowance identity. Two modules that decode the same
    ///         `data` layout (`AaveV2BorrowModule` / `AaveV3CreditModule`, both
    ///         reading `(address pool, address asset, uint256 rateMode)` after their
    ///         leading word) therefore have SEPARATE allowance buckets: approving one
    ///         can never be consumed dispatching the other, whatever the data.
    ///
    ///         The same keying is what makes several OPS on one module safe, and by
    ///         the same argument one level down: put the op inside `data` and it is
    ///         inside `ref`, so the buckets separate per op exactly as they separate
    ///         per module. Blast radius is bounded by the allowance, not by the
    ///         address.
    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external;
}

/// @notice OPTIONAL companion a module MAY implement so a wallet or the settlement
///         lens can render a taker authorisation in words — turning an opaque
///         `ref = keccak256(data)` into "Borrow 1,000 USDC from Aave v3". Purely
///         informational and off-chain; Permit3 never calls it. A module that does
///         not implement it is unaffected (the call simply reverts, and callers
///         treat a revert as "no description available").
interface ITakerModuleDescribe {
    /// @param data The exact `data` bytes the allowance is keyed to.
    /// @return A human-readable description of the operation `data` encodes.
    function describe(bytes calldata data) external view returns (string memory);
}
