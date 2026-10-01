// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC2612} from "@lib/interfaces/IERC2612.sol";

/// @title PermitHelper
/// @notice Library for optional EIP-2612 permit replay appended to module `data`.
///
///  MakerModules that support gasless operation append a permit block to their
///  standard `data` encoding. If the block is present, the permit is replayed
///  before `permit3.transferFrom` so Permit3 can pull the token without the user
///  having sent a prior `approve` transaction.
///
///  Encoding convention (appended after the module's fixed base params, and the
///  LAST thing in `data`):
///    abi.encode(deadline, v, r, s [, signedValue])
///      — 128 bytes (v is uint8, ABI-padded to 32), or 160 with the optional
///        trailing `signedValue`.
///
///  If the data is shorter than `baseLen + 128` the function is a no-op; the
///  module falls back to whatever ERC-20 allowance already exists.
///
///  ⚠ THE REPLAY MUST NOT REVERT THE FILL — it is BEST-EFFORT.
///  ERC-2612 `permit` consumes a per-owner nonce and reverts once that nonce is
///  used. The permit block lives inside the module's `data`, which is part of the
///  order hash AND of `ref = keccak256(data)` for a TAKE item, so the signature
///  bytes are frozen into the maker's authorization. If a hard call reverted on an
///  already-used nonce, anyone could permanently kill a gasless order for ~50k gas:
///  watch the mempool, pull `(deadline, v, r, s)` out of the pending calldata, and
///  submit `token.permit(...)` directly. The victim's fill then reverts forever and
///  the order cannot be re-encoded without changing `ref` and the order hash — so
///  the whole artifact has to be re-signed, repeatably, by an attacker paying
///  almost nothing.
///
///  For the PENDING fill the front-runner's call leaves the chain in the state the
///  fill wanted (`allowance(owner, spender) >= amount`), so swallowing the revert is
///  correct: the permit's *effect* is what matters, not who landed it. The real
///  gate is the `permit3.transferFrom` that follows — which still reverts if the
///  allowance genuinely is not there.
///
///  ⚠ SET, NOT RAISE (2026-09-30 audit, L-LIB-4). ERC-2612 `permit` OVERWRITES the
///  allowance with the signed value. Two consequences:
///    • Replayed over a maker's standing `approve(spender, max)`, the permit would
///      shrink that grant to this fill's value and the pull would spend it down —
///      silently breaking the maker's other resting orders in the token. Both
///      replays below therefore SKIP when the standing allowance already covers
///      what this fill needs. (Skipping leaves the signature unconsumed; it was
///      published with the order either way.)
///    • The signature is public and any-sender: a third party can land it
///      DIRECTLY at any time before its deadline — including after the maker
///      cancelled the order — and so reset a standing allowance to the signed
///      value. No value moves (Permit3's books still gate every pull), but the
///      maker must re-approve. Sign the permit deadline no later than the order
///      deadline, and do not append a permit when a sufficient standing grant
///      already exists.
///
///  ⚠ THE SIGNED VALUE (L-AAVE-2). An EIP-2612 signature commits to `value`.
///  Without the optional trailing word, `value = amount` — THIS fill's pro-rated
///  slice — so the signature verifies only on a fill whose slice equals what the
///  maker signed: in practice one full fill; on any other slice the replay fails
///  silently and the pull falls back to a standing allowance. A maker who wants
///  partial fills appends `signedValue` (normally the item's total): the first
///  fill lands the allowance for the total and every later slice finds it
///  sufficient and skips the replay.
///
///  The permit approves `spender` (always `address(permit3)` or the module itself
///  in practice) — it does NOT touch Permit3's own allowance book. The caller's
///  Permit3 module allowance must be set separately (e.g. via `fillWithPermit`).
library PermitHelper {
    /// @notice Replay an EIP-2612 permit if the permit block is present in `data`.
    /// @param data     The full module data blob passed to `makeOnBehalf`.
    /// @param baseLen  Byte length of the fixed base params before the permit block.
    /// @param token    ERC-2612 token to call `permit` on.
    /// @param owner    The token holder whose signature is being replayed.
    /// @param spender  The address being approved (typically `address(permit3)`).
    /// @param amount   This fill's slice: the allowance the pull that follows needs,
    ///                 and the signed value when the block carries no `signedValue`.
    function replayIfPresent(
        bytes calldata data,
        uint256 baseLen,
        address token,
        address owner,
        address spender,
        uint256 amount
    ) internal {
        if (data.length < baseLen + 128) return;
        (uint256 deadline, uint8 v, bytes32 r, bytes32 s) =
            abi.decode(data[baseLen:baseLen + 128], (uint256, uint8, bytes32, bytes32));
        // Set-not-raise: never shrink a standing grant that already covers this fill.
        if (_allowanceCovers(token, owner, spender, amount)) return;
        uint256 value = data.length >= baseLen + 160 ? uint256(bytes32(data[baseLen + 128:baseLen + 160])) : amount;
        // Best-effort by design — see the front-run note above. A revert here means
        // the nonce is already spent (someone else landed the same permit), which is
        // the state we wanted anyway; the following `permit3.transferFrom` is the
        // real gate.
        try IERC2612(token).permit(owner, spender, value, deadline, v, r, s) {} catch {}
    }

    /// @notice Variant carrying an EXPLICIT `value` word at the HEAD of the tail —
    ///         for permits whose approval amount is NOT this fill's `amount` (e.g. a
    ///         venue's ERC-4626 share allowance sized to the whole item, spent
    ///         across many fills). An EIP-2612 signature commits to `value`, so a
    ///         module that cannot derive it from its arguments must carry it
    ///         alongside the signature.
    ///
    ///  Encoding convention (appended after the module's fixed base params):
    ///    abi.encode(value, deadline, v, r, s)   — 160 bytes
    ///
    ///  Shorter data ⇒ no-op (the module falls back to a standing on-chain
    ///  allowance). Same BEST-EFFORT try/catch as {replayIfPresent}, for the same
    ///  reason, and the same set-not-raise skip: a standing allowance that already
    ///  covers `value` is left untouched rather than overwritten.
    ///
    /// @param data     The full module data blob.
    /// @param baseLen  Byte length of the fixed base params before the permit block.
    /// @param token    ERC-2612 token to call `permit` on.
    /// @param owner    The token holder whose signature is being replayed.
    /// @param spender  The address being approved (here typically the module itself).
    function replayValueIfPresent(bytes calldata data, uint256 baseLen, address token, address owner, address spender)
        internal
    {
        if (data.length < baseLen + 160) return;
        (uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) =
            abi.decode(data[baseLen:baseLen + 160], (uint256, uint256, uint8, bytes32, bytes32));
        if (_allowanceCovers(token, owner, spender, value)) return;
        try IERC2612(token).permit(owner, spender, value, deadline, v, r, s) {} catch {}
    }

    /// @dev `allowance(owner, spender) >= need`, read defensively: a failed or
    ///      malformed read answers "no", so the replay is attempted as before.
    function _allowanceCovers(address token, address owner, address spender, uint256 need)
        private
        view
        returns (bool)
    {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeCall(IERC20.allowance, (owner, spender)));
        return ok && ret.length >= 32 && abi.decode(ret, (uint256)) >= need;
    }
}
