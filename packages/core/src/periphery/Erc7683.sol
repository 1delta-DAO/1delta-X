// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order} from "../settlement/Structs.sol";

/// @notice ERC-7683 output description. `token`/`recipient` are `bytes32` so the
///         standard can address non-EVM chains.
struct Output {
    bytes32 token;
    uint256 amount;
    bytes32 recipient;
    uint256 chainId;
}

/// @notice ERC-7683 fill instruction — where and with what a filler must fill.
struct FillInstruction {
    uint64 destinationChainId;
    bytes32 destinationSettler;
    bytes originData;
}

/// @notice ERC-7683 resolved order — the standard's view of any order, whatever the
///         underlying protocol's native encoding is.
struct ResolvedCrossChainOrder {
    address user;
    uint256 originChainId;
    uint32 openDeadline;
    uint32 fillDeadline;
    bytes32 orderId;
    Output[] maxSpent;
    Output[] minReceived;
    FillInstruction[] fillInstructions;
}

/// @notice ERC-7683 user-signed (gasless) order envelope.
struct GaslessCrossChainOrder {
    address originSettler;
    address user;
    uint256 nonce;
    uint256 originChainId;
    uint32 openDeadline;
    uint32 fillDeadline;
    bytes32 orderDataType;
    bytes orderData;
}

/// @notice ERC-7683 self-opened order envelope.
struct OnchainCrossChainOrder {
    uint32 fillDeadline;
    bytes32 orderDataType;
    bytes orderData;
}

interface IOriginSettler {
    event Open(bytes32 indexed orderId, ResolvedCrossChainOrder resolvedOrder);

    function openFor(GaslessCrossChainOrder calldata order, bytes calldata signature, bytes calldata originFillerData)
        external;
    function open(OnchainCrossChainOrder calldata order) external;
    function resolveFor(GaslessCrossChainOrder calldata order, bytes calldata originFillerData)
        external
        view
        returns (ResolvedCrossChainOrder memory);
    function resolve(OnchainCrossChainOrder calldata order) external view returns (ResolvedCrossChainOrder memory);
}

interface IDestinationSettler {
    function fill(bytes32 orderId, bytes calldata originData, bytes calldata fillerData) external;
}

/// @notice The payload carried in `orderData` / `originData` — a 1delta-x order plus
///         everything a filler needs to execute it. `orderDataType` is
///         {OrderHash.ORDER_TYPEHASH}, so a solver can tell our orders apart from any
///         other protocol's by the type hash alone.
struct OrderPayload {
    Order order;
    bytes signature;
    uint256 fillAmount;
    bytes takerData;
}
