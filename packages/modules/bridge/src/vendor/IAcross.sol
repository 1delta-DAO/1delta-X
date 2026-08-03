// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IAcrossSpokePool
/// @notice The single Across V3 SpokePool entrypoint this package uses, vendored
///         rather than pulled in as a dependency (the upstream package drags a
///         large tree in for one function).
///
/// @dev    ABI RISK — pin before mainnet. Across has shipped more than one
///         deposit entrypoint: the `address`-typed `depositV3` declared here and
///         a newer `bytes32`-typed `deposit` (widened for non-EVM destinations).
///         Which one a given SpokePool exposes depends on its deployed version.
///         Verify against the target deployment and, if it only exposes the
///         `bytes32` variant, add an overload — the calling module's logic is
///         unchanged either way.
interface IAcrossSpokePool {
    /// @param depositor        Refund recipient on THIS chain if the deposit
    ///                         expires unfilled. Must be the order maker, never
    ///                         the calling module — a module-addressed refund
    ///                         would need its own claim path.
    /// @param recipient        Destination-chain receiver. For this package that
    ///                         is always the {BridgedOrderInbox}.
    /// @param outputAmount     What the relayer must deliver on the destination.
    ///                         Exact and enforced, so it doubles as the
    ///                         guaranteed-delivery floor the destination order is
    ///                         authored against.
    /// @param message          Arbitrary payload handed to `recipient` via
    ///                         {IAcrossMessageHandler} in the relayer's fill tx.
    function depositV3(
        address depositor,
        address recipient,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes calldata message
    ) external payable;
}

/// @title IAcrossMessageHandler
/// @notice Destination-side callback. The relayer transfers `amount` of
///         `tokenSent` to the recipient and then calls this in the SAME
///         transaction, so tokens and message arrive atomically.
///
/// @dev    Reverting here is SAFE and intended: the relayer's fill reverts, so
///         they simply do not fill, and the deposit refunds to the depositor on
///         the origin chain after `fillDeadline`. No funds are ever stranded on
///         the destination. This posture is INVERTED for LayerZero — see
///         {BridgedOrderInbox.lzCompose}.
///      `message` is declared `calldata` where upstream says `memory`. The
///      external ABI and selector are identical; calldata is what lets
///      {CommitmentCodec} read the payload by slicing.
interface IAcrossMessageHandler {
    function handleV3AcrossMessage(address tokenSent, uint256 amount, address relayer, bytes calldata message)
        external;
}
