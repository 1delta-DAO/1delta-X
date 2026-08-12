// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ICctpTokenMessenger
/// @notice The minimal Circle CCTP v1 surface this package needs (vendored rather
///         than imported, matching {IAcrossSpokePool} — one function beats pulling
///         a large tree in).
///
/// @dev    CCTP is burn-and-mint, not a liquidity network: the source `burnToken`
///         is destroyed and Circle's attestation service authorises an equal mint
///         on the destination. Three consequences shape the calling module:
///
///           • **no relayer, no LP, no fee** on v1 — the minted amount equals the
///             burned amount exactly, so the guaranteed-delivery floor is the
///             amount itself rather than an amount-minus-slippage estimate. That
///             is the strongest floor of any path in this package.
///           • **no liquidity risk** — nothing can be under-filled because there is
///             no counterparty fronting capital.
///           • **no message payload.** `depositForBurn` carries tokens only. See
///             the note in {CctpBridgeOutModule} for what that rules out.
///
///         ⚠ ABI RISK — pin before mainnet, exactly as {IAcrossSpokePool} warns.
///         Circle ships v1 and v2 TokenMessengers with different signatures (v2
///         adds `maxFee`/`minFinalityThreshold` and hook variants). This is the v1
///         `depositForBurn`. Verify against the target deployment.
interface ICctpTokenMessenger {
    /// @notice Burn `amount` of `burnToken` for minting on `destinationDomain`.
    /// @param  amount            Burned on this chain, minted 1:1 on the destination.
    /// @param  destinationDomain Circle's own DOMAIN id — **not** a chain id. They
    ///                           are unrelated numbering schemes (Ethereum is
    ///                           domain 0, Avalanche 1, Optimism 2, Arbitrum 3 …),
    ///                           which is why the calling module carries both.
    /// @param  mintRecipient     Destination recipient, left-padded into a
    ///                           `bytes32` because CCTP addresses non-EVM chains
    ///                           through the same field.
    /// @param  burnToken         The source-chain token (USDC).
    /// @return nonce             Circle's message nonce for this burn.
    function depositForBurn(uint256 amount, uint32 destinationDomain, bytes32 mintRecipient, address burnToken)
        external
        returns (uint64 nonce);
}
