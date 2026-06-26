// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICreditDelegationToken} from "@core/interfaces/ICreditDelegationToken.sol";
import {ICometAllow} from "@core/interfaces/ICometAllow.sol";
import {IMorphoAuth} from "@core/interfaces/IMorphoAuth.sol";

// ──────────────────── DelegationHelper ────────────────────
//
// Shared library for optional EIP-712 delegation-sig replay in taker modules.
// Each protocol has its own delegation mechanism; the library exposes one
// helper per protocol. All delegation blocks are exactly 160 bytes (5 ABI-
// padded words) appended after the module's base `data`.
//
// The caller passes `data`, the byte offset at which the delegation block
// starts, plus the protocol-specific context. If `data` is too short (block
// absent), the call is a no-op — the module falls back to requiring a prior
// on-chain delegation from the user.
//
// Offset accounting for modules that have an optional DustAction / BalanceMode
// slot between the fixed base and the delegation block:
//
//   • If delegation is present, that intermediate slot MUST be encoded
//     explicitly (even as 0 / Exact) so the block starts at a fixed offset.
//   • Example: `abi.encode(comet, asset, uint8(0 /*BalanceMode*/), nonce, expiry, v, r, s)`
//     gives base=64, BalanceMode@64, delegation@96 = check 96+160=256 bytes total.
//
library DelegationHelper {
    // ── Aave V3 variable/stable debt token ────────────────────────────────────
    //
    // Block at `baseLen`:
    //   abi.encode(address debtToken, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
    //   = 5 × 32 = 160 bytes
    //
    // Grants `delegatee` (the borrow module) the right to borrow up to `value`
    // tokens of the underlying on `delegator`'s behalf — without a prior
    // on-chain `approveDelegation` call.
    //
    function replayAaveDelegation(
        bytes calldata data,
        uint256 baseLen,
        address delegator,
        address delegatee,
        uint256 value
    ) internal {
        if (data.length < baseLen + 160) return;
        (address debtToken, uint256 deadline, uint8 v, bytes32 r, bytes32 s) =
            abi.decode(data[baseLen:baseLen + 160], (address, uint256, uint8, bytes32, bytes32));
        ICreditDelegationToken(debtToken).delegationWithSig(delegator, delegatee, value, deadline, v, r, s);
    }

    // ── Compound V3 (Comet) ───────────────────────────────────────────────────
    //
    // Block at `baseLen`:
    //   abi.encode(uint256 nonce, uint256 expiry, uint8 v, bytes32 r, bytes32 s)
    //   = 5 × 32 = 160 bytes
    //
    // Grants `manager` (the withdraw/borrow module) permission to call
    // `withdrawFrom` on `owner`'s Comet position — without a prior on-chain
    // `allow(manager, true)` call.
    //
    function replayCometAllow(
        bytes calldata data,
        uint256 baseLen,
        address comet,
        address owner,
        address manager
    ) internal {
        if (data.length < baseLen + 160) return;
        (uint256 nonce, uint256 expiry, uint8 v, bytes32 r, bytes32 s) =
            abi.decode(data[baseLen:baseLen + 160], (uint256, uint256, uint8, bytes32, bytes32));
        ICometAllow(comet).allowBySig(owner, manager, true, nonce, expiry, v, r, s);
    }

    // ── Morpho Blue ───────────────────────────────────────────────────────────
    //
    // Block at `baseLen`:
    //   abi.encode(uint256 nonce, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
    //   = 5 × 32 = 160 bytes
    //
    // Grants `authorized` (the borrow/withdraw-collateral module) permission to
    // manage `authorizer`'s Morpho positions — without a prior on-chain
    // `setAuthorization(module, true)` call. Authorization is coarse (all
    // markets); the Permit3 taker allowance caps the per-fill amount.
    //
    function replayMorphoAuth(
        bytes calldata data,
        uint256 baseLen,
        address morpho,
        address authorizer,
        address authorized
    ) internal {
        if (data.length < baseLen + 160) return;
        (uint256 nonce, uint256 deadline, uint8 v, bytes32 r, bytes32 s) =
            abi.decode(data[baseLen:baseLen + 160], (uint256, uint256, uint8, bytes32, bytes32));
        IMorphoAuth(morpho).setAuthorizationWithSig(
            IMorphoAuth.Authorization({
                authorizer: authorizer,
                authorized: authorized,
                isAuthorized: true,
                nonce: nonce,
                deadline: deadline
            }),
            IMorphoAuth.Signature({v: v, r: r, s: s})
        );
    }
}
