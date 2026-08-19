// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order} from "../settlement/Structs.sol";
import {OrderHash} from "../settlement/OrderHash.sol";
import {PackedArraysMem} from "../settlement/PackedArraysMem.sol";
import {SettlementLens} from "./SettlementLens.sol";
import {
    FillInstruction,
    GaslessCrossChainOrder,
    IOriginSettler,
    OnchainCrossChainOrder,
    OrderPayload,
    Output,
    ResolvedCrossChainOrder
} from "./Erc7683.sol";

/// @dev The two settlement views this adapter needs to refuse broadcasting a dead
///      order — the nonce-cancellation bitmap (per-hash cancellation and full-fill are
///      already caught by {SettlementLens.previewFill}).
interface ISettlementNonce {
    function isNonceCancelled(address maker, uint256 nonce) external view returns (bool);
}

/// @title OriginSettler7683
/// @notice The ERC-7683 face of a 1delta-x order. By 2026 the intent networks
///         (Across, UniswapX, Eco, CoW) all expose 7683 endpoints and the bulk of
///         Across's flow arrives that way, so this exists for DISTRIBUTION: an
///         existing solver fleet can discover, resolve and fill our orders through
///         the interface it already speaks, with no bespoke integration.
///
///  ⚠ THIS IS ESCROW-FREE, AND THAT IS THE ONE DEVIATION FROM THE STANDARD'S USUAL
///  SHAPE. ERC-7683 was written around settlers that ESCROW the user's funds when an
///  order is opened and repay the filler afterwards. Nothing here can do that, by
///  design: a maker's funds move only at fill time, pulled through Permit3 under the
///  maker's own allowances, which is exactly what lets the protocol have no admin, no
///  custody and no upgrade key. So:
///
///    • `open` / `openFor` do not take custody. They VERIFY the order is live and
///      authorized and emit the standard `Open` event, which is what a solver network
///      actually consumes. An order is fillable before, during and after, by anyone.
///    • `resolve` / `resolveFor` are exact: `minReceived` / `maxSpent` come from the
///      same {SettlementLens.previewFill} a filler would quote with, at the current
///      tick.
///    • Because there is no escrow, there is nothing to refund and no
///      non-performance to punish. A filler that walks away costs the maker nothing.
///
///  A solver that requires the standard's escrow ordering can wrap this in one of the
///  bridge package's inboxes; that is an opt-in module, never a core requirement.
///
///  This contract holds no funds, has no owner, and can move nothing: every function
///  is a view or an event emitter.
contract OriginSettler7683 is IOriginSettler {
    /// @notice The settlement this adapter describes orders for. Bound to {LENS} at
    ///         construction (see the constructor) and exposed so an integrator or an
    ///         indexer can tell which deployment an `Open` event belongs to.
    address public immutable SETTLEMENT;
    /// @notice The lens used for pricing and liveness (same math as the settler).
    SettlementLens public immutable LENS;
    /// @notice The destination settler solvers should call — see {DestinationSettler7683}.
    address public immutable DESTINATION_SETTLER;

    /// @dev `orderDataType` must be the order typehash: it is what tells a solver the
    ///      payload is one of ours, and it changes whenever the order encoding does.
    error UnsupportedOrderType();
    /// @dev The envelope names a different origin settler or a different chain.
    error WrongSettler();
    /// @dev The order cannot be broadcast: its open-envelope deadline or its own
    ///      expiry has passed, or its nonce was cancelled. `reason` names which.
    ///      (Per-hash cancellation and full-fill surface from {SettlementLens.previewFill}
    ///      as their own reverts; maker funding and validators are the filler's to
    ///      check via {SettlementLens.getOrderRelevantState} before filling.)
    error OrderNotFillable(string reason);
    /// @dev `openFor`'s envelope disagrees with the order it carries.
    error UserMismatch();
    /// @dev The lens passed to the constructor serves a different settlement.
    error LensSettlementMismatch();

    /// @dev The `settlement` argument is not decoration: every quote this contract
    ///      publishes is produced by `lens`, so a lens built against a DIFFERENT
    ///      deployment would have it resolving orders — and emitting `Open` for them —
    ///      against a settlement nobody is going to fill on. Bind the two at
    ///      construction and the pair can never be mismatched afterwards (both are
    ///      immutable).
    constructor(address settlement, address lens, address destinationSettler) {
        if (address(SettlementLens(lens).SETTLEMENT()) != settlement) revert LensSettlementMismatch();
        SETTLEMENT = settlement;
        LENS = SettlementLens(lens);
        DESTINATION_SETTLER = destinationSettler;
    }

    // ──────────────────── Open (broadcast, not escrow) ────────────────────

    /// @inheritdoc IOriginSettler
    function openFor(GaslessCrossChainOrder calldata order, bytes calldata signature, bytes calldata)
        external
        override
    {
        if (order.originSettler != address(this) || order.originChainId != block.chainid) revert WrongSettler();
        if (order.openDeadline != 0 && block.timestamp > order.openDeadline) revert OrderNotFillable("open deadline");
        OrderPayload memory p = _decode(order.orderDataType, order.orderData);
        if (p.order.maker != order.user) revert UserMismatch();
        // Broadcast the signature we actually verify. An override supplied in
        // `signature` REPLACES the payload's own (the standard's sponsor-signature
        // parameter), so the `Open` event and every solver fill carry exactly the
        // credential that passed here — never a stale/empty embedded one that would
        // then revert at fill time.
        if (signature.length != 0) p.signature = signature;
        // The signature travels with the payload for the filler's own `fill` call; we
        // check it here so `Open` is never emitted for an order nobody can fill.
        // `checkSignature` reverts with the settler's own precise reason, which is
        // more useful to a relayer than a boolean would be.
        bytes32 orderHash = LENS.hashOrder(p.order);
        LENS.checkSignature(orderHash, p.signature, p.order.maker);
        _requireLive(p.order);
        ResolvedCrossChainOrder memory r = _resolve(p, orderHash, order.user, order.openDeadline, order.fillDeadline);
        emit Open(r.orderId, r);
    }

    /// @inheritdoc IOriginSettler
    /// @dev The self-opened form. The maker calls this itself, which is also the
    ///      moment it can make an order signature-less: `Settlement.approveOrder`
    ///      keys on `msg.sender`, so a maker that cannot sign calls that first and
    ///      then opens here with an empty signature.
    function open(OnchainCrossChainOrder calldata order) external override {
        OrderPayload memory p = _decode(order.orderDataType, order.orderData);
        if (p.order.maker != msg.sender) revert UserMismatch();
        _requireLive(p.order);
        bytes32 orderHash = LENS.hashOrder(p.order);
        ResolvedCrossChainOrder memory r = _resolve(p, orderHash, msg.sender, 0, order.fillDeadline);
        emit Open(r.orderId, r);
    }

    // ──────────────────── Resolve ────────────────────

    /// @inheritdoc IOriginSettler
    function resolveFor(GaslessCrossChainOrder calldata order, bytes calldata)
        external
        view
        override
        returns (ResolvedCrossChainOrder memory)
    {
        OrderPayload memory p = _decode(order.orderDataType, order.orderData);
        return _resolve(p, LENS.hashOrder(p.order), order.user, order.openDeadline, order.fillDeadline);
    }

    /// @inheritdoc IOriginSettler
    function resolve(OnchainCrossChainOrder calldata order)
        external
        view
        override
        returns (ResolvedCrossChainOrder memory)
    {
        OrderPayload memory p = _decode(order.orderDataType, order.orderData);
        return _resolve(p, LENS.hashOrder(p.order), p.order.maker, 0, order.fillDeadline);
    }

    // ──────────────────── Internals ────────────────────

    function _decode(bytes32 orderDataType, bytes calldata orderData) private pure returns (OrderPayload memory) {
        if (orderDataType != OrderHash.ORDER_TYPEHASH) revert UnsupportedOrderType();
        return abi.decode(orderData, (OrderPayload));
    }

    /// @dev Refuse to broadcast a dead order. `open`/`openFor` emit the standard
    ///      `Open` event that a solver fleet consumes, so an expired or nonce-cancelled
    ///      order here is wasted solver gas and feed spam. Per-hash cancellation and
    ///      full-fill are already caught inside {SettlementLens.previewFill}; this
    ///      covers the two lifecycle gates it does not: the order expiry and the
    ///      maker's nonce bitmap.
    function _requireLive(Order memory order) private view {
        if (block.timestamp > _expiry(order)) revert OrderNotFillable("order expired");
        if (ISettlementNonce(SETTLEMENT).isNonceCancelled(order.maker, order.nonce)) {
            revert OrderNotFillable("nonce cancelled");
        }
    }

    /// @dev Memory mirror of {DutchAuction.expiry} (which is calldata-only, and
    ///      Solidity cannot overload it on data location). The expiry rides in
    ///      `timing` bits [160:208) since it stopped being an `Order` field of its own.
    function _expiry(Order memory order) private pure returns (uint256) {
        return uint48(order.timing >> 160);
    }

    /// @dev The standard's view of one of our orders, priced at the CURRENT tick:
    ///        • `maxSpent`   — what the filler delivers (our output legs);
    ///        • `minReceived`— what the filler collects (our input legs);
    ///        • `orderId`    — the EIP-712 order hash, which is already the protocol's
    ///                         unique, cancellable identifier, so no second id space
    ///                         is invented;
    ///        • `fillInstructions` — one instruction naming this chain and the
    ///                         destination settler, carrying the payload verbatim.
    ///
    ///      Both amount vectors come from {SettlementLens.previewFill}, i.e. the same
    ///      arithmetic the fill will run — a resolve that disagreed with the fill is
    ///      the failure mode this adapter exists to avoid.
    function _resolve(OrderPayload memory p, bytes32 orderHash, address user, uint32 openDeadline, uint32 fillDeadline)
        private
        view
        returns (ResolvedCrossChainOrder memory r)
    {
        // A HARD-exclusive order previews as {NotExclusiveFiller} for anyone but the
        // exclusive filler, which would make even a broadcast (`open`/`openFor`) revert
        // during the window — the maker cannot open its own order, and a relayer cannot
        // announce an RFQ winner. Quote the broadcast at the exclusive filler's terms
        // (the party who WILL fill in the window); outside exclusivity this is just the
        // caller.
        address previewFiller = p.order.exclusiveFiller != address(0) ? p.order.exclusiveFiller : msg.sender;
        (, uint256[] memory received, uint256[] memory paid) =
            LENS.previewFill(p.order, p.fillAmount, previewFiller, p.takerData);

        r.user = user;
        r.originChainId = block.chainid;
        r.openDeadline = openDeadline;
        // The order's own expiry is authoritative; the envelope may only tighten it.
        uint32 orderDeadline =
            _expiry(p.order) > type(uint32).max ? type(uint32).max : uint32(_expiry(p.order));
        r.fillDeadline = fillDeadline != 0 && fillDeadline < orderDeadline ? fillDeadline : orderDeadline;
        r.orderId = orderHash;

        uint256 nOut = PackedArraysMem.count(p.order.legsOut);
        r.maxSpent = new Output[](nOut);
        for (uint256 j; j < nOut; j++) {
            address recipient = PackedArraysMem.legOutRecipient(p.order.legsOut, j);
            r.maxSpent[j] = Output({
                token: bytes32(uint256(uint160(PackedArraysMem.legOutToken(p.order.legsOut, j)))),
                amount: paid[j],
                recipient: bytes32(uint256(uint160(recipient == address(0) ? p.order.maker : recipient))),
                chainId: block.chainid
            });
        }

        uint256 nIn = PackedArraysMem.count(p.order.legsIn);
        r.minReceived = new Output[](nIn);
        for (uint256 i; i < nIn; i++) {
            r.minReceived[i] = Output({
                token: bytes32(uint256(uint160(PackedArraysMem.legInToken(p.order.legsIn, i)))),
                amount: received[i],
                // The filler is whoever fills; the standard wants an address, and this
                // is the filler the quote was priced for (the exclusive filler in an
                // exclusivity window, else the caller asking).
                recipient: bytes32(uint256(uint160(previewFiller))),
                chainId: block.chainid
            });
        }

        r.fillInstructions = new FillInstruction[](1);
        r.fillInstructions[0] = FillInstruction({
            destinationChainId: uint64(block.chainid),
            destinationSettler: bytes32(uint256(uint160(DESTINATION_SETTLER))),
            originData: abi.encode(p)
        });
    }
}
