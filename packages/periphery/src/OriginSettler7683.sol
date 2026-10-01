// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order} from "@core/settlement/Structs.sol";
import {OrderHash} from "@core/settlement/OrderHash.sol";
import {PackedArraysMem} from "@core/settlement/PackedArraysMem.sol";
import {SettlementLens} from "./SettlementLens.sol";
import {
    FillBounds,
    FillInstruction,
    FillPayload,
    GaslessCrossChainOrder,
    IOriginSettler,
    OnchainCrossChainOrder,
    Order7683,
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
///    • `resolve` / `resolveFor` QUOTE the order at the current tick, for the address
///      the published instruction fills as — {DESTINATION_SETTLER} — and the quote is
///      also the BOUND that fill enforces: `maxSpent` / `minReceived` travel in the
///      instruction's `originData` as a {FillBounds}, and {DestinationSettler7683}
///      reverts a fill that settles at a worse per-unit price on any leg. So
///      `maxSpent` is the standard's "cap on filler liabilities" for real, and an
///      order whose price moves toward the maker between the quote and the fill (a
///      priority auction priced off the filler's tip, a price module, a curve that
///      moves back up) reverts rather than charging the solver more (audit 2026-09-30
///      PERIPH-1). A solver that moves the price itself — a priority bidder — passes
///      its own bounds in `fillerData`.
///    • Because there is no escrow, there is nothing to refund and no
///      non-performance to punish. A filler that walks away costs the maker nothing.
///
///  ⚠ `openFor` AUTHORISES ONLY THE INNER ORDER (PERIPH-6). ERC-7683 has the user sign
///  the `GaslessCrossChainOrder`; here the maker's signature is over the 1delta-x
///  `Order` — the one thing the settlement verifies — and the envelope's deadlines and
///  the payload's `fillAmount` / `takerData` are the RELAYER's. Anyone may therefore
///  `Open` a live order with its own deadlines and size. What is bound: the envelope
///  must name this settler, this chain, the order's maker and the order's own nonce;
///  a `fillDeadline` already in the past is refused; and the published deadline can
///  only TIGHTEN the order's own expiry. Nothing an `Open` says can move funds, and
///  the bounds a solver fills under are the per-unit price, so a 1-wei or oversized
///  `fillAmount` in somebody's broadcast costs a solver nothing: it can re-size.
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
    ///         Every quote is priced FOR this address: it is the settlement-level
    ///         filler of the only instruction this adapter publishes.
    address public immutable DESTINATION_SETTLER;

    /// @dev `orderDataType` must be the order typehash: it is what tells a solver the
    ///      payload is one of ours, and it changes whenever the order encoding does.
    error UnsupportedOrderType();
    /// @dev The envelope names a different origin settler or a different chain.
    error WrongSettler();
    /// @dev The order cannot be broadcast: its open-envelope deadline, its fill
    ///      deadline or its own expiry has passed, its nonce was cancelled, or its
    ///      nonce sits in the settlement's reserved signer-permit half (every fill
    ///      reverts `OrderNonceReserved`). `reason` names which. (Per-hash
    ///      cancellation, full-fill and the exclusivity gates surface from
    ///      {SettlementLens.previewFill} as their own reverts; maker funding and
    ///      validators are the filler's to check via
    ///      {SettlementLens.getOrderRelevantState} before filling.)
    error OrderNotFillable(string reason);
    /// @dev `openFor`/`resolveFor`'s envelope disagrees with the order it carries —
    ///      a different maker, or a different nonce.
    error UserMismatch();
    /// @dev The lens passed to the constructor serves a different settlement.
    error LensSettlementMismatch();
    /// @dev The order is DELTA-VERIFY (`timing` bit 104): fillable only through
    ///      `Settlement.fillWithCallback` by its named `exclusiveFiller`, never
    ///      through {DestinationSettler7683} — see {_decode}.
    error DeltaVerifyNotSupported();

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
        if (order.openDeadline != 0 && block.timestamp > order.openDeadline) revert OrderNotFillable("open deadline");
        OrderPayload memory p = _decodeEnvelope(order);
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
        _requireLive(p.order, order.fillDeadline);
        ResolvedCrossChainOrder memory r = _resolve(p, orderHash, order.user, order.openDeadline, order.fillDeadline);
        emit Open(r.orderId, r);
    }

    /// @inheritdoc IOriginSettler
    /// @dev The self-opened form. The maker calls this itself, which is also the
    ///      moment it can make an order signature-less: `Settlement.approveOrder`
    ///      keys on `msg.sender`, so a maker that cannot sign calls that first and
    ///      then opens here with an empty signature.
    ///
    ///      ⚠ THE SIGNATURE IS CHECKED HERE TOO, and the signature-less path is
    ///      unaffected. {openFor} states the invariant this pair maintains — `Open` is
    ///      never emitted for an order nobody can fill — and this entry used to be the
    ///      hole in it: `maker == msg.sender` proves who is opening, not that the
    ///      embedded credential is one the settler will accept, and the fill DOES
    ///      require it ({DestinationSettler7683.fill} → `Settlement.fillUpTo`). So an
    ///      `Open` here could advertise an order that reverts at fill time. Bounded to
    ///      wasted solver simulation — the flow is same-chain, atomic and escrow-free,
    ///      so a failed verification unwinds the solver's own pull — but a broadcast
    ///      nobody can act on is exactly what the invariant exists to prevent.
    ///
    ///      Adding it costs the signature-less maker nothing, which is why it is not a
    ///      trade-off: {LENS.checkSignature} routes an EMPTY `sig` to the settler's own
    ///      `orderApproved` record, so the `approveOrder`-then-`open` sequence in the
    ///      paragraph above passes this check by construction. What it rejects is a
    ///      STALE or malformed credential — the case the maker cannot detect and the
    ///      solver pays for.
    function open(OnchainCrossChainOrder calldata order) external override {
        OrderPayload memory p = _decode(order.orderDataType, order.orderData);
        if (p.order.maker != msg.sender) revert UserMismatch();
        _requireLive(p.order, order.fillDeadline);
        bytes32 orderHash = LENS.hashOrder(p.order);
        LENS.checkSignature(orderHash, p.signature, p.order.maker);
        ResolvedCrossChainOrder memory r = _resolve(p, orderHash, msg.sender, 0, order.fillDeadline);
        emit Open(r.orderId, r);
    }

    // ──────────────────── Resolve ────────────────────

    /// @inheritdoc IOriginSettler
    /// @dev Applies {openFor}'s envelope checks, so a resolution is never returned for
    ///      an envelope `openFor` would refuse (PERIPH-6).
    function resolveFor(GaslessCrossChainOrder calldata order, bytes calldata)
        external
        view
        override
        returns (ResolvedCrossChainOrder memory)
    {
        OrderPayload memory p = _decodeEnvelope(order);
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

    /// @dev The gasless envelope's binding to the order it carries: this settler, this
    ///      chain, the order's maker, and the order's own nonce. The nonce is the one
    ///      envelope field the standard has the user sign that maps onto a field the
    ///      maker DID sign here, so it is held to it rather than left free.
    function _decodeEnvelope(GaslessCrossChainOrder calldata order) private view returns (OrderPayload memory p) {
        if (order.originSettler != address(this) || order.originChainId != block.chainid) revert WrongSettler();
        p = _decode(order.orderDataType, order.orderData);
        if (p.order.maker != order.user || p.order.nonce != order.nonce) revert UserMismatch();
    }

    /// @dev Also the one place every entry refuses a shape the published instruction
    ///      cannot execute, before any signature or lens work:
    ///        • DELTA-VERIFY (`timing` bit 104 — memory mirror of
    ///          {DutchAuction.deltaVerifyOutputs}, calldata-only like {_expiry}'s).
    ///          Such an order delivers its outputs only inside a `fillWithCallback` run
    ///          by its named `exclusiveFiller`; the instruction points at
    ///          {DestinationSettler7683}, which fills through `fillUpTo` — no callback,
    ///          so nothing is delivered and the settler reverts {DeltaTooLow} even when
    ///          the order names the adapter itself.
    ///        • a `SETTLE` item ({Order7683.SettleItemUnsupported}): it would pay the
    ///          adapter, in a token neither the adapter nor `minReceived` can name
    ///          (PERIPH-4).
    ///      An `Open` for either would be a dead order to every solver that reads it.
    function _decode(bytes32 orderDataType, bytes calldata orderData) private pure returns (OrderPayload memory p) {
        if (orderDataType != OrderHash.ORDER_TYPEHASH) revert UnsupportedOrderType();
        p = abi.decode(orderData, (OrderPayload));
        if ((p.order.timing >> 104) & 1 == 1) revert DeltaVerifyNotSupported();
        Order7683.requireNoSettleItem(p.order.items);
    }

    /// @dev Refuse to broadcast a dead order. `open`/`openFor` emit the standard
    ///      `Open` event that a solver fleet consumes, so an expired or nonce-cancelled
    ///      order here is wasted solver gas and feed spam. Per-hash cancellation and
    ///      full-fill are already caught inside {SettlementLens.previewFill}; this
    ///      covers the lifecycle gates it does not: the order expiry, the envelope's
    ///      fill deadline, the maker's nonce bitmap, and the reserved nonce half
    ///      (`Base._gateOrderPost` reverts `OrderNonceReserved` on every fill of an
    ///      order whose nonce has bit 255 set — PERIPH-5).
    function _requireLive(Order memory order, uint32 fillDeadline) private view {
        if (block.timestamp > _expiry(order)) revert OrderNotFillable("order expired");
        if (fillDeadline != 0 && fillDeadline <= block.timestamp) revert OrderNotFillable("fill deadline");
        if (order.nonce >> 255 != 0) revert OrderNotFillable("nonce reserved");
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

    /// @dev The standard's view of one of our orders, priced at the CURRENT tick FOR
    ///      {DESTINATION_SETTLER}:
    ///        • `maxSpent`   — what the filler delivers (our output legs);
    ///        • `minReceived`— what the filler collects (our input legs);
    ///        • `orderId`    — the EIP-712 order hash, which is already the protocol's
    ///                         unique, cancellable identifier, so no second id space
    ///                         is invented;
    ///        • `fillInstructions` — one instruction naming this chain and the
    ///                         destination settler, carrying the payload verbatim and
    ///                         the two amount vectors as its {FillBounds}.
    ///
    ///      ⚠ PRICED FOR THE DESTINATION SETTLER, WHOEVER ASKS (PERIPH-2). That
    ///      adapter is the settlement-level filler of the instruction published here —
    ///      it calls `fillUpTo` itself — so an exclusivity window naming anyone else
    ///      makes every fill through it an OUTSIDER's. This used to price for the named
    ///      filler or a set member, quoting a soft window WITHOUT the premium the
    ///      instruction then always paid (up to 2× outputs, or zero inputs at
    ///      `overrideBps = 10_000`) and broadcasting a hard window whose instruction
    ///      reverted for the whole window. Now a soft window is quoted with its premium
    ///      and a hard one — or a soft one with no carrier, or a pre-funded leg under a
    ///      live override — reverts here, exactly as the fill would, so it is never
    ///      broadcast. The window's own filler fills on the settlement directly.
    ///
    ///      `minReceived[i].recipient` is `0`: the standard's "filler", which is
    ///      whoever calls the instruction — this contract cannot know it.
    function _resolve(OrderPayload memory p, bytes32 orderHash, address user, uint32 openDeadline, uint32 fillDeadline)
        private
        view
        returns (ResolvedCrossChainOrder memory r)
    {
        (uint256 delta, uint256[] memory received, uint256[] memory paid) =
            LENS.previewFill(p.order, p.fillAmount, DESTINATION_SETTLER, p.takerData);

        r.user = user;
        r.originChainId = block.chainid;
        r.openDeadline = openDeadline;
        // The order's own expiry is authoritative; the envelope may only tighten it.
        uint32 orderDeadline =
            _expiry(p.order) > type(uint32).max ? type(uint32).max : uint32(_expiry(p.order));
        r.fillDeadline = fillDeadline != 0 && fillDeadline < orderDeadline ? fillDeadline : orderDeadline;
        r.orderId = orderHash;

        uint256 nOut = PackedArraysMem.validateLegsOut(p.order.legsOut);
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

        uint256 nIn = PackedArraysMem.validateLegsIn(p.order.legsIn);
        r.minReceived = new Output[](nIn);
        for (uint256 i; i < nIn; i++) {
            r.minReceived[i] = Output({
                token: bytes32(uint256(uint160(PackedArraysMem.legInToken(p.order.legsIn, i)))),
                amount: received[i],
                recipient: bytes32(0), // the filler — whoever calls the instruction
                chainId: block.chainid
            });
        }

        r.fillInstructions = new FillInstruction[](1);
        r.fillInstructions[0] = FillInstruction({
            destinationChainId: uint64(block.chainid),
            destinationSettler: bytes32(uint256(uint160(DESTINATION_SETTLER))),
            originData: abi.encode(
                FillPayload({payload: p, bounds: FillBounds({quotedDelta: delta, maxPaid: paid, minReceived: received})})
            )
        });
    }
}
