// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ICctpTokenMessengerV2
/// @notice The minimal Circle CCTP **V2** surface this package needs (vendored
///         rather than imported, matching {IAcrossSpokePool} — one function beats
///         pulling a large tree in).
///
/// @dev    WHY V2 (audit 2026-09-30 BRIDGE-B-6 / G-VENUE_A-1). This package used to
///         call the V1 four-argument `depositForBurn` (selector 0x6fd3504e). Circle
///         phases CCTP V1 out: V1 burn limits fall from 2026-10-31 and the V1
///         contracts are halted on 2026-12-01, and V2 is NOT backward compatible —
///         the V2 TokenMessenger exposes only the seven-argument entrypoint below
///         (selector 0x8e0250ee). A V1 module would first revert on shrinking
///         per-message limits and then on every fill.
///
///         CCTP is burn-and-mint, not a liquidity network: the source `burnToken` is
///         destroyed and Circle's attestation authorises a mint on the destination.
///         V2 changes the delivery arithmetic V1 had:
///
///           • **a fee.** V2 charges the burn amount a fee of at most `maxFee`,
///             withheld from the mint (Fast Transfers cost a few bps; Standard
///             Transfers are currently free). The minted amount is therefore
///             `amount - fee >= amount - maxFee`, and `amount - maxFee` — not
///             `amount` — is the guaranteed-delivery floor. `maxFee` must be
///             strictly below `amount` or the messenger reverts.
///           • **finality is a parameter.** `minFinalityThreshold` selects Fast
///             (`<= 1000`, soft finality, fee) or Standard (`2000`, hard finality).
///           • **no relayer, no LP** — still nothing fronting capital, so nothing
///             can under-fill.
///           • **no message payload** on `depositForBurn` — see
///             {CctpBridgeOutModule} for what that rules out.
///           • **no nonce return.** V2 assigns the message nonce off-chain at
///             attestation, so the burn is correlated by source transaction hash
///             (Circle's `/v2/messages/{sourceDomain}?transactionHash=` API), not
///             by an on-chain nonce.
///
///         ⚠ ABI RISK — pin against the target deployment before mainnet, exactly
///         as {IAcrossSpokePool} warns.
interface ICctpTokenMessenger {
    /// @notice Burn `amount` of `burnToken` for minting on `destinationDomain`.
    /// @param  amount               Burned on this chain.
    /// @param  destinationDomain    Circle's own DOMAIN id — **not** a chain id.
    ///                              They are unrelated numbering schemes (Ethereum
    ///                              is domain 0, Avalanche 1, Optimism 2, Arbitrum
    ///                              3 …), which is why the calling module carries
    ///                              both.
    /// @param  mintRecipient        Destination recipient, left-padded into a
    ///                              `bytes32` because CCTP addresses non-EVM chains
    ///                              through the same field.
    /// @param  burnToken            The source-chain token (USDC).
    /// @param  destinationCaller    Who may call `receiveMessage` on the
    ///                              destination; zero = anyone (a solver).
    /// @param  maxFee               Most of `amount` the transfer may be charged;
    ///                              must be `< amount`.
    /// @param  minFinalityThreshold `<= 1000` Fast, `2000` Standard.
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;
}
