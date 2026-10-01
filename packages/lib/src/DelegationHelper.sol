// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICreditDelegationToken} from "@lib/interfaces/ICreditDelegationToken.sol";
import {ICometAllow} from "@lib/interfaces/ICometAllow.sol";
import {IMorphoAuth} from "@lib/interfaces/IMorphoAuth.sol";

// The one slice of the Ethereum Vault Connector's surface the EVC permit replay
// needs. Declared here (not under the shared interfaces dir) because this lib
// must not depend on the euler-v2 package's fuller `IEVC`, and no other lib
// consumer needs it. `permit` executes `data` as an EVC self-call authenticated
// as `signer`; `sender == address(0)` lets anyone submit, which is exactly why
// {DelegationHelper.replayEvcPermit} always names ITSELF as `sender`.
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
// below (192 for Aave when the optional signed value is appended); the EVC tail
// alone is dynamic (it carries the signed self-call bytes).
//
// The caller passes `data`, the byte offset at which the delegation block
// starts, plus the protocol-specific context. If `data` is too short (block
// absent), the call is a no-op — the module falls back to requiring a prior
// on-chain delegation from the user.
//
// ⚠ EVERY REPLAY IS BEST-EFFORT AND MUST NOT REVERT THE FILL.
// All four mechanisms below are nonce-based and revert once their nonce is
// spent. The signature bytes live inside the module's `data`, which is part of
// the order hash AND of `ref = keccak256(data)`, so they are frozen into the
// maker's authorization. A hard call would therefore hand anyone a cheap,
// repeatable kill switch on gasless orders: pull `(nonce, deadline, v, r, s)`
// from the pending calldata, land the delegation directly, and the victim's fill
// reverts forever with no way to re-encode it. Swallowing the revert is correct
// for the PENDING fill — the front-runner leaves the delegation the fill wanted,
// and the real gate is the protocol call that follows, which still fails if the
// delegation is genuinely absent. Same reasoning as {PermitHelper.replayIfPresent}.
//
// ⚠ WHAT "BEST-EFFORT" DOES NOT COVER: CANCELLATION AND REVOCATION (2026-09-30
// audit, L-CMT-3 / L-ED-1). The signature is PUBLISHED with the order. Cancelling
// the order in Settlement, letting it expire, or revoking the grant directly on
// the venue does NOT consume the venue nonce, so wherever the venue lets anyone
// submit the signature, the lifted bytes stay landable until the venue-side
// deadline — after the maker withdrew consent:
//
//   • Aave `delegationWithSig`, Comet `allowBySig`, Morpho/Lista
//     `setAuthorizationWithSig`: ANY submitter (these venues have no sender
//     binding). A direct `approveDelegation(m, 0)`, `allow(m, false)` or
//     `setAuthorization(m, false)` does NOT advance the venue nonce, so a stale
//     signature at the current nonce re-installs the grant. A DURABLE revoke must
//     CONSUME the nonce: submit `allowBySig(owner, m, false, nonce, …)` /
//     `setAuthorizationWithSig({isAuthorized: false, nonce: current, …})` /
//     `delegationWithSig(…, value: 0, …)` signed at the current nonce. Sign the
//     venue deadline no later than the order deadline so the exposure ends with
//     the order. No value moves through such a re-grant on its own — every module
//     using these helpers is gated by Permit3's taker book or by Settlement — but
//     the maker's revoke is undone.
//   • EVC `permit`: CLOSED at the root. {replayEvcPermit} submits with
//     `sender = address(this)`, so the maker signs a permit bound to THIS module
//     and only a live fill of the maker's own order can land it.
//
// ⚠ SET, NOT RAISE (L-LIB-4). `delegationWithSig` SETS the borrow allowance to
// the signed value. Replaying it over a maker's standing max delegation would
// overwrite that grant with this fill's value (and the borrow then spends it
// down), silently breaking the maker's other resting orders. {replayAaveDelegation}
// therefore SKIPS the replay when the standing allowance already covers this
// fill. A third party can still land the published signature directly (the venue
// makes it any-sender); the maker's remedy is a re-grant. The boolean grants
// (Comet, Morpho, EVC) are permanent and unscoped once installed — they outlive
// the order until the maker revokes them.
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
    //   abi.encode(address debtToken, uint256 deadline, uint8 v, bytes32 r, bytes32 s
    //              [, uint256 signedValue])
    //   = 5 × 32 = 160 bytes, or 192 with the optional trailing `signedValue`.
    //   The block must be the LAST thing in `data` (it is, in every caller).
    //
    // Grants `delegatee` (the borrow module) the right to borrow on `delegator`'s
    // behalf — without a prior on-chain `approveDelegation` call.
    //
    // ⚠ THE SIGNED VALUE (L-AAVE-2). The EIP-712 `DelegationWithSig` digest
    // commits to `value`. Without the trailing word the replay uses `amount` —
    // THIS fill's pro-rated slice — so the signature verifies only on a fill whose
    // slice equals what the maker signed: in practice one full fill. A maker who
    // wants partial fills appends `signedValue` (normally the item's total): the
    // first fill lands a delegation of the total, and every later slice finds the
    // remaining allowance sufficient and skips the replay.
    //
    // ⚠ SKIPPED WHEN THE STANDING ALLOWANCE ALREADY COVERS `amount` (L-LIB-4):
    // `delegationWithSig` SETS rather than raises, so replaying over a standing
    // max delegation would shrink it to `value` and the borrow would spend it down.
    //
    function replayAaveDelegation(
        bytes calldata data,
        uint256 baseLen,
        address delegator,
        address delegatee,
        uint256 amount
    ) internal {
        if (data.length < baseLen + 160) return;
        (address debtToken, uint256 deadline, uint8 v, bytes32 r, bytes32 s) =
            abi.decode(data[baseLen:baseLen + 160], (address, uint256, uint8, bytes32, bytes32));
        if (_borrowAllowanceCovers(debtToken, delegator, delegatee, amount)) return;
        uint256 value = data.length >= baseLen + 192 ? uint256(bytes32(data[baseLen + 160:baseLen + 192])) : amount;
        // Best-effort — see the front-run note in the header.
        try ICreditDelegationToken(debtToken).delegationWithSig(delegator, delegatee, value, deadline, v, r, s) {}
            catch {}
    }

    /// @dev `borrowAllowance(delegator, delegatee) >= amount`, read defensively: a
    ///      failed or malformed read answers "no", so the replay is attempted.
    function _borrowAllowanceCovers(address debtToken, address delegator, address delegatee, uint256 amount)
        private
        view
        returns (bool)
    {
        (bool ok, bytes memory ret) =
            debtToken.staticcall(abi.encodeCall(ICreditDelegationToken.borrowAllowance, (delegator, delegatee)));
        return ok && ret.length >= 32 && abi.decode(ret, (uint256)) >= amount;
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
    // Replayed even when `isAllowed` is already true, ON PURPOSE: landing the
    // signature in-fill CONSUMES Comet's `userNonce`, which is what retires it.
    // Skipping would leave a published, any-sender signature live after the fill,
    // able to re-grant the module once the maker later revokes with
    // `allow(manager, false)` (L-CMT-3; see the header for the durable revoke).
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
    // Replayed even when already authorized, ON PURPOSE: Morpho's
    // `setAuthorizationWithSig` deliberately does not check the current status,
    // so landing it in-fill always CONSUMES `nonce[authorizer]` and retires the
    // published signature (L-CMT-3; see the header for the durable revoke).
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
    // Tail at `baseLen` — DYNAMIC, unlike the fixed blocks above, because each
    // permit carries signed self-call bytes:
    //   abi.encode(EvcPermit[] permits)
    // with EvcPermit = (uint256 nonceNamespace, uint256 nonce, uint256 deadline,
    //                   bytes evcData, bytes sig).
    //
    // Each `evcData` is an EVC self-call the maker signed under the EVC's own
    // EIP-712 `Permit` — e.g. `abi.encodeCall(IEVC.batch, (items))` whose items
    // target the EVC itself: `setAccountOperator(signer, module, true)`,
    // `enableController(signer, borrowVault)`, `enableCollateral(signer,
    // collateralVault)`. Replaying them in-fill makes the maker's ENTIRE Euler
    // auth surface signature-only — the EVC analogue of Aave's
    // `delegationWithSig` (the EVC has no per-grant sig entrypoints, only `permit`).
    //
    // ⚠ `sender = address(this)`: THE MAKER SIGNS A PERMIT BOUND TO THIS MODULE
    // (2026-09-30 audit, L-ED-1). This used to submit `sender = address(0)` on the
    // false premise that "the maker cannot know which filler wins the order". The
    // filler is irrelevant: this is an internal library, so `msg.sender` of
    // `EVC.permit` is always the module itself — a fixed address the order's item
    // names. An any-sender permit, published with the order, could be landed by
    // ANYONE directly on the EVC until its deadline: after the maker cancelled the
    // order, and after the maker revoked the operator flag (it even outlived a
    // FILLED order whose in-fill replay reverted because the operator was already
    // set). Bound to the module, the permit can be landed only through this
    // module's own call, which runs only inside a live Settlement fill of the
    // maker's own signed order (`signer == onBehalfOf`); cancelling the order
    // retires it. The EVC digest commits to `sender`, so a permit signed for
    // `address(0)` does NOT replay here any more — makers must sign
    // `sender = <this module>`.
    //
    // ⚠ SEVERAL INDEPENDENT PERMITS, NOT ONE SEALED BATCH (L-LIB-3). The EVC
    // reverts `setAccountOperator` when the flag would not change, and a revert
    // inside a batch reverts the whole permit. One sealed blob bundling the
    // operator grant with this order's controller/collateral enables therefore
    // failed ATOMICALLY — dropping the enables — whenever the operator was already
    // set by any other means (an earlier order, a manual grant). Each permit here
    // is replayed in its OWN try/catch: sign the operator grant apart from the
    // per-order enables (which are idempotent on the EVC), and the enables land
    // regardless of the operator's prior state.
    //
    // ⚠ NONCE NAMESPACES. EVC nonces are SEQUENTIAL per (account prefix,
    // namespace), and a permit that reverts does NOT burn its nonce. Two permits
    // in ONE namespace therefore chain: if the first fails, the second can never
    // land. Sign the operator permit and each order's enables permit in DISTINCT
    // namespaces (e.g. a fixed namespace for the operator grant and a per-order
    // namespace for the enables). A maker can invalidate an already-signed permit
    // with `EVC.setNonce(prefix, namespace, nonce + 1)`, or stop all permits with
    // `EVC.setPermitDisabledMode`.
    //
    // Best-effort per the header: the EVC burns the nonce on use AND
    // `setAccountOperator` reverts when the status is already set. The real gate
    // stays the EVC-routed call that follows, which still fails if the grants are
    // genuinely absent. `value = 0` always: the replayed grants move no ETH.
    //
    // A malformed tail (maker-authored — it is under the order signature)
    // reverts the decode and thus the fill: fail closed, nothing granted.
    //
    struct EvcPermit {
        uint256 nonceNamespace;
        uint256 nonce;
        uint256 deadline;
        bytes evcData;
        bytes sig;
    }

    function replayEvcPermit(bytes calldata data, uint256 baseLen, address evc, address signer) internal {
        if (data.length <= baseLen) return;
        EvcPermit[] memory permits = abi.decode(data[baseLen:], (EvcPermit[]));
        for (uint256 i; i < permits.length; ++i) {
            EvcPermit memory p = permits[i];
            // Best-effort — see the front-run note in the header. `sender` is THIS
            // module, never `address(0)`: see L-ED-1 above.
            try IEVCPermit(evc).permit(signer, address(this), p.nonceNamespace, p.nonce, p.deadline, 0, p.evcData, p.sig) {}
                catch {}
        }
    }
}
