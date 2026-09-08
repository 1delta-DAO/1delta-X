// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC2612} from "@lib/interfaces/IERC2612.sol";

/// @title PermitHelper
/// @notice Library for optional EIP-2612 permit replay appended to module `data`.
///
///  MakerModules that support gasless operation append a permit block to their
///  standard `data` encoding. If the block is present, the permit is replayed
///  before `permit3.transferFrom` so Permit3 can pull the token without the user
///  having sent a prior `approve` transaction.
///
///  Encoding convention (appended after the module's fixed base params):
///    abi.encode(deadline, v, r, s)   — 128 bytes (v is uint8, ABI-padded to 32)
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
///  The front-runner's call leaves the chain in exactly the state the fill wanted
///  (`allowance(owner, spender) >= amount`), so swallowing the revert is not just
///  safe, it is the correct outcome: the permit's *effect* is what matters, not
///  who landed it. The real gate is the `permit3.transferFrom` that follows —
///  which still reverts if the allowance genuinely is not there.
///
///  The permit approves `spender` (always `address(permit3)` in practice) to pull
///  `amount` of `token` from `owner` — it does NOT touch Permit3's own allowance
///  book. The caller's Permit3 module allowance must be set separately (e.g. via
///  `fillWithPermit`).
library PermitHelper {
    /// @notice Replay an EIP-2612 permit if the permit block is present in `data`.
    /// @param data     The full module data blob passed to `makeOnBehalf`.
    /// @param baseLen  Byte length of the fixed base params before the permit block.
    /// @param token    ERC-2612 token to call `permit` on.
    /// @param owner    The token holder whose signature is being replayed.
    /// @param spender  The address being approved (typically `address(permit3)`).
    /// @param amount   The approval value to set.
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
        // Best-effort by design — see the front-run note above. A revert here means
        // the nonce is already spent (someone else landed the same permit), which is
        // the state we wanted anyway; the following `permit3.transferFrom` is the
        // real gate.
        try IERC2612(token).permit(owner, spender, amount, deadline, v, r, s) {} catch {}
    }

    /// @notice Variant carrying an EXPLICIT `value` word in the tail — for permits
    ///         whose approval amount is NOT this fill's `amount` (e.g. a venue's
    ///         ERC-4626 share allowance sized to the whole item, spent across many
    ///         fills). An EIP-2612 signature commits to `value`, so a module that
    ///         cannot derive it from its arguments must carry it alongside the
    ///         signature.
    ///
    ///  Encoding convention (appended after the module's fixed base params):
    ///    abi.encode(value, deadline, v, r, s)   — 160 bytes
    ///
    ///  Shorter data ⇒ no-op (the module falls back to a standing on-chain
    ///  allowance). Same BEST-EFFORT try/catch as {replayIfPresent}, for the same
    ///  reason: a front-run replay of the lifted permit leaves exactly the
    ///  allowance the fill wants, and the venue call that follows is the real gate.
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
        try IERC2612(token).permit(owner, spender, value, deadline, v, r, s) {} catch {}
    }
}
