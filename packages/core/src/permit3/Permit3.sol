// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SignedPermits} from "./SignedPermits.sol";
import {SignatureTransfer} from "./SignatureTransfer.sol";

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
///      Permit2-equivalent. See {AllowanceTransfer}.
///
///    • taker book — keyed (user → spender → bytes32 ref). An approved
///      spender invokes `take(module, user, amount, receiver, data)`;
///      Permit3 computes `ref = keccak256(data)`, decrements the user's
///      allowance on (spender, ref), then invokes the module's
///      `takeOnBehalf`. The module performs the protocol-native call.
///      See {TakerAllowance}.
///
///  Permit3 knows nothing about lending/staking/vault protocols. Protocol
///  heterogeneity stays in modules. Single-operation modules keep blast
///  radius small: approvals on a borrow module cannot be used to withdraw,
///  and vice versa.
///
///  Authority can be granted three ways, and this contract is nothing but the
///  point where those three layers meet:
///
///    • on-chain — `approveToken` / `approveTaker`
///    • signed allowance — {SignedPermits}: `permitBatch`, and
///      `permitBatchWithWitness` to bind the grant to an order hash so one
///      signature covers both the allowances and the order consuming them
///    • signed one-shot — {SignatureTransfer}: `permitTransferFrom` moves
///      tokens once and leaves no allowance behind
///
///  A fourth, signature-free path lives OUTSIDE this contract: {AllowanceHolder}
///  grants an allowance that exists only for the duration of one call. It is
///  deliberately a separate, unprivileged contract — see the note there.
///
///  PROVENANCE
///  ──────────
///  Permit3 is Permit2 (Uniswap, MIT) plus a second allowance book. Every file
///  in this directory carries a `PROVENANCE` block saying exactly what came from
///  Permit2, what changed, and what is new; `README.md` has the same thing as a
///  table. In short:
///
///    from Permit2, ported   {AllowanceTransfer} {SignatureTransfer}
///                           {UnorderedNonces} {EIP712} {SignatureVerification}
///                           {Allowance} {Permit3Hash} (signature-transfer half)
///    reworked               {SignedPermits} — Permit2's `permit()`, but one
///                           batch spanning both books, bitmap nonces, witness
///    new in Permit3         {TakerAllowance} {Permit3Base} {Permit3Hash}
///                           (allowance-permit half)
///    not Permit2 at all     {AllowanceHolder} — ported from 0x
///
///  This file mirrors Permit2's own `Permit2.sol`, which is likewise nothing but
///  `contract Permit2 is SignatureTransfer, AllowanceTransfer {}`.
///
/// @dev  This file is an assembly point on purpose. Every behaviour lives in the
///       base it belongs to, so a reviewer reading `AllowanceTransfer` sees the
///       whole token book and nothing else. Adding logic HERE is almost always
///       the wrong move: put it in the layer that owns the state it touches.
///
///       Base order is load-bearing for storage layout — see the linearisation
///       note in `README.md` before reordering.
contract Permit3 is SignedPermits, SignatureTransfer {}
