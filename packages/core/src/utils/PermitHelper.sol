// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC2612} from "../interfaces/IERC2612.sol";

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
        IERC2612(token).permit(owner, spender, amount, deadline, v, r, s);
    }
}
