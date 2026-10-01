// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order} from "@core/settlement/Structs.sol";

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

/// @notice The payload carried in `orderData` — a 1delta-x order plus everything a
///         filler needs to execute it. `orderDataType` is {OrderHash.ORDER_TYPEHASH},
///         so a solver can tell our orders apart from any other protocol's by the type
///         hash alone.
/// @dev    ⚠ ONLY `order` IS SIGNED BY THE MAKER — its EIP-712 hash is the `orderId`.
///         `signature`, `fillAmount` and `takerData`, and the whole 7683 envelope
///         around them, are chosen by whoever opens the order, so a solver must read
///         them as a proposal. What protects it is the {FillBounds} the origin
///         publishes beside them ({FillPayload}), which the destination enforces.
struct OrderPayload {
    Order order;
    bytes signature;
    uint256 fillAmount;
    bytes takerData;
}

/// @notice The filler's price bound for a fill through {DestinationSettler7683}: the
///         ERC-7683 `maxSpent` / `minReceived` of a resolved order, made ENFORCEABLE.
///
///         ERC-7683 defines `maxSpent` as "a cap on filler liabilities" and
///         `minReceived` as "a floor on filler receipts". A 1delta-x order's price can
///         move between the quote and the fill — a priority auction prices off the
///         filler's own tip, a maker-chosen price module may answer differently per
///         caller, a curve can have a segment that moves toward the maker — so a quote
///         is only a cap if the fill CHECKS it. {DestinationSettler7683} does, after
///         the settlement has run, against the amounts the settlement itself returns.
///
///         The bounds are a PRICE, not absolute amounts: they were quoted for
///         `quotedDelta` anchor units, and a fill of a different size (a clamp to a
///         partially-filled order's remainder, a {Proportional} anchor resolved
///         against a balance that changed since, a solver that re-sized `fillAmount`)
///         is held to the same per-unit terms, per leg:
///
///             paid[j]     · quotedDelta  <  maxPaid[j]     · delta + quotedDelta
///             received[i] · quotedDelta  >  minReceived[i] · delta − quotedDelta
///
///         i.e. the quote scaled to `delta`, within one unit of rounding. At
///         `delta == quotedDelta` it is exactly `paid ≤ maxPaid` and
///         `received ≥ minReceived`. `maxPaid[j] == type(uint256).max` and
///         `minReceived[i] == 0` switch one leg's check off — the filler's own call.
struct FillBounds {
    uint256 quotedDelta;
    uint256[] maxPaid; //     one per `legsOut`
    uint256[] minReceived; // one per `legsIn`
}

/// @notice The `originData` of the fill instruction {OriginSettler7683} publishes, and
///         what {DestinationSettler7683.fill} decodes: the payload VERBATIM plus the
///         bounds the origin quoted it at — the very numbers the same resolved order
///         reports as `maxSpent` / `minReceived`, priced for the destination settler,
///         the address the fill actually runs as.
/// @dev    The bounds are not part of the `orderId` and need not be: they protect the
///         CALLER of `fill`, which is the party choosing what `originData` to submit. A
///         solver replaying the published instruction is held to the published quote
///         by construction; one that wants other terms passes its own ({FillerData}).
struct FillPayload {
    OrderPayload payload;
    FillBounds bounds;
}

/// @notice The long form of {DestinationSettler7683.fill}'s `fillerData`. Empty
///         `fillerData` means "proceeds to the caller, published bounds"; one 32-byte
///         word is a bare `abi.encode(address payTo)`; anything longer decodes as this.
/// @param payTo      where input-leg proceeds and refunds are swept; 0 = the caller.
/// @param minBumpBps forwarded to `Settlement.fillUpTo` as its price floor — quote it
///                   with `SettlementLens.previewBump`. 0 = none.
/// @param bounds     the filler's OWN bounds. They REPLACE the published ones, so a
///                   solver can tighten them, or widen them for an order whose price
///                   it moves itself (a priority auction priced off its own tip).
///                   `quotedDelta == 0` keeps the published bounds.
struct FillerData {
    address payTo;
    uint256 minBumpBps;
    FillBounds bounds;
}

/// @notice Shape rules both 7683 adapters apply to the order they carry.
library Order7683 {
    /// @dev `uint8(ItemOp.SETTLE)`.
    uint256 private constant SETTLE = 2;

    /// @dev The order carries a `SETTLE` item. Such an item pays the maker's asset to
    ///      the FILLER — which, through {DestinationSettler7683}, is the adapter, not
    ///      the solver — in a token the adapter cannot know to sweep (it is named only
    ///      inside the module's own `data`), and an ERC-721/1155 one reverts on an
    ///      adapter without receiver hooks. ERC-7683's `minReceived` cannot describe
    ///      the receipt either. So neither adapter announces or fills one.
    error SettleItemUnsupported();
    /// @dev The `items` blob does not parse — the settlement would revert on it too.
    error MalformedItems();

    /// @notice Revert {SettleItemUnsupported} if `items` holds a `SETTLE` record.
    /// @dev    A memory twin of `PackedArrays.validateRecords` + `itemAt`: one count
    ///         byte, then records of `op(1) | module(20) | amount(32) | recipient(20) |
    ///         len(2) | data(len)`. Bounds-checked per record, so a malformed blob
    ///         reverts {MalformedItems} instead of reading past its end.
    function requireNoSettleItem(bytes memory items) internal pure {
        uint256 len = items.length;
        if (len == 0) return;
        uint256 count = uint8(items[0]);
        uint256 cursor = 1;
        for (uint256 i; i < count; i++) {
            if (cursor + 75 > len) revert MalformedItems();
            if (uint8(items[cursor]) == SETTLE) revert SettleItemUnsupported();
            cursor += 75 + ((uint256(uint8(items[cursor + 73])) << 8) | uint8(items[cursor + 74]));
            if (cursor > len) revert MalformedItems();
        }
    }
}
