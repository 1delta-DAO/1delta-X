// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICreditDelegationToken} from "@lib/interfaces/ICreditDelegationToken.sol";
import {ICometAllow} from "@lib/interfaces/ICometAllow.sol";
import {IMorphoAuth} from "@lib/interfaces/IMorphoAuth.sol";

// The one slice of the Ethereum Vault Connector's surface the EVC permit replay
// needs. Declared here (not under the shared interfaces dir) because this lib
// must not depend on the euler-v2 package's fuller `IEVC`, and no other lib
// consumer needs it. `permit` executes `data` as an EVC self-call authenticated
// as `signer`; `sender == address(0)` lets anyone submit.
interface IEVCPermit {
    function permit(
        address signer,
        address sender,
        uint256 nonceNamespace,
        uint256 nonce,
        uint256 deadline,
        uint256 value,
        bytes calldata data,
        bytes calldata signature
    ) external payable;
}

// ──────────────────── DelegationHelper ────────────────────
//
// Shared library for optional EIP-712 delegation-sig replay in taker modules.
// Each protocol has its own delegation mechanism; the library exposes one
// helper per protocol. The delegation block is appended after the module's base
// `data` — exactly 160 bytes (5 ABI-padded words) for the fixed-shape protocols
// below; the EVC block alone is dynamic (it carries the signed self-call bytes).
//
// The caller passes `data`, the byte offset at which the delegation block
// starts, plus the protocol-specific context. If `data` is too short (block
// absent), the call is a no-op — the module falls back to requiring a prior
// on-chain delegation from the user.
//
// ⚠ EVERY REPLAY IS BEST-EFFORT AND MUST NOT REVERT THE FILL.
// All three mechanisms below are nonce-based and revert once their nonce is
// spent. The signature bytes live inside the module's `data`, which is part of
// the order hash AND of `ref = keccak256(data)`, so they are frozen into the
// maker's authorization. A hard call would therefore hand anyone a cheap,
// repeatable kill switch on gasless orders: pull `(nonce, deadline, v, r, s)`
// from the pending calldata, land the delegation directly, and the victim's fill
// reverts forever with no way to re-encode it. Swallowing the revert is correct —
// the front-runner leaves exactly the delegation the fill wanted, and the real
// gate is the protocol call that follows, which still fails if the delegation is
// genuinely absent. Same reasoning as {PermitHelper.replayIfPresent}.
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
        // Best-effort — see the front-run note in the header.
        try ICreditDelegationToken(debtToken).delegationWithSig(delegator, delegatee, value, deadline, v, r, s) {}
            catch {}
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
    function replayCometAllow(bytes calldata data, uint256 baseLen, address comet, address owner, address manager)
        internal
    {
        if (data.length < baseLen + 160) return;
        (uint256 nonce, uint256 expiry, uint8 v, bytes32 r, bytes32 s) =
            abi.decode(data[baseLen:baseLen + 160], (uint256, uint256, uint8, bytes32, bytes32));
        // Best-effort — see the front-run note in the header.
        try ICometAllow(comet).allowBySig(owner, manager, true, nonce, expiry, v, r, s) {} catch {}
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
        // Best-effort — see the front-run note in the header.
        try IMorphoAuth(morpho)
            .setAuthorizationWithSig(
                IMorphoAuth.Authorization({
                    authorizer: authorizer, authorized: authorized, isAuthorized: true, nonce: nonce, deadline: deadline
                }),
                IMorphoAuth.Signature({v: v, r: r, s: s})
            ) {}
            catch {}
    }

    // ── Euler V2 (Ethereum Vault Connector) ───────────────────────────────────
    //
    // Block at `baseLen` — DYNAMIC, unlike the fixed 160-byte blocks above,
    // because it carries the signed self-call bytes:
    //   abi.encode(uint256 nonceNamespace, uint256 nonce, uint256 deadline,
    //              bytes evcData, bytes sig)
    //
    // `evcData` is an EVC self-call the maker signed under the EVC's own EIP-712
    // `Permit` — typically `abi.encodeCall(IEVC.batch, (items))` whose items
    // target the EVC itself: `setAccountOperator(signer, module, true)`,
    // `enableController(signer, borrowVault)`, `enableCollateral(signer,
    // collateralVault)`. Replaying it in-fill makes the maker's ENTIRE Euler
    // auth surface signature-only — the EVC analogue of Aave's
    // `delegationWithSig`, covering operator, controller AND collateral in one
    // sealed blob (the EVC has no per-grant sig entrypoints, only `permit`).
    //
    // `sender = address(0)` is DELIBERATE: the EVC only lets the named `sender`
    // submit a permit, and the maker cannot know which filler wins the order, so
    // the maker signs an any-sender permit. That is safe here for the same
    // reason it is best-effort: the permit is nonce-bound and grants exactly
    // what the fill needs — whoever lands it first (this fill or a front-runner)
    // leaves the same state behind. `value = 0` always: the replayed grants move
    // no ETH.
    //
    // Best-effort per the header: the EVC burns the nonce on use AND
    // `setAccountOperator` reverts when the status is already set, so a
    // front-runner lifting `(nonce, deadline, evcData, sig)` from pending
    // calldata and landing the permit directly would otherwise brick the fill
    // forever (the bytes are frozen into the order hash and the taker ref). The
    // real gate stays the EVC-routed call that follows, which still fails if the
    // grants are genuinely absent.
    //
    // A malformed tail (maker-authored — it is under the order signature)
    // reverts the decode and thus the fill: fail closed, nothing granted.
    //
    function replayEvcPermit(bytes calldata data, uint256 baseLen, address evc, address signer) internal {
        if (data.length <= baseLen) return;
        (uint256 nonceNamespace, uint256 nonce, uint256 deadline, bytes memory evcData, bytes memory sig) =
            abi.decode(data[baseLen:], (uint256, uint256, uint256, bytes, bytes));
        // Best-effort — see the front-run note in the header.
        try IEVCPermit(evc).permit(signer, address(0), nonceNamespace, nonce, deadline, 0, evcData, sig) {} catch {}
    }
}
