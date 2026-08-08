// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFillModule} from "../interfaces/IFillModule.sol";
import {Order, OrderSide, FillCtx} from "./Structs.sol";
import {OrderHash} from "./OrderHash.sol";
import {DutchAuction} from "./DutchAuction.sol";
import {PackedArrays} from "./PackedArrays.sol";
import {NonceManager} from "./NonceManager.sol";

/// @title OrderState
/// @notice ALL order-lifecycle STATE and its mutation, in one auditable place — no
///         token movement, no signatures, no settlement logic, only the
///         who-can-fill-what-and-how-much bookkeeping:
///           • the per-order `filled` counter (with the cancellation sentinel),
///           • the on-chain `orderApproved` records (the signature-less path),
///           • per-order-HASH cancellation ({cancelOrder}),
///           • nonce cancellation (inherited from {NonceManager}),
///           • the `_openFill` state transition — resolve this fill's delta, apply
///             the over-fill cap, and advance the counter.
///
///         All mutable storage lives in this layer + {NonceManager}, so the slot
///         layout is fixed here: `nonceBitmap`(0), `minValidNonce`(1) from
///         NonceManager, then `filled`(2), `orderApproved`(3).
abstract contract OrderState is NonceManager {
    using OrderHash for Order;
    using DutchAuction for Order;

    /// @notice orderHash → cumulative filled amount, in the order's ANCHOR units
    ///         (`tokenIn[0]` for SELL, `tokenOut[0]` for BUY). The
    ///         `type(uint256).max` value is the CANCELLED sentinel (see {cancelOrder}).
    mapping(bytes32 => uint256) public filled;

    /// @notice maker → orderHash → on-chain order authorization. The signature-less
    ///         alternative to signing: a maker that cannot produce a verifiable
    ///         signature at all — a classic multisig with no EIP-1271
    ///         `isValidSignature`, for which neither the ECDSA nor the 1271 branch
    ///         of the verifier can ever succeed — instead records intent on-chain via
    ///         {approveOrder}. Fillers then pass an EMPTY `sig` and the fill
    ///         authorizes against this mapping (see {Signatures}). Funding
    ///         still flows through the maker's standing Permit3 allowances, and the
    ///         fill is still gated by the shared nonce/deadline/validator machinery —
    ///         this only replaces the signature check, nothing else.
    mapping(address => mapping(bytes32 => bool)) public orderApproved;

    /// @notice A maker authorized an order on-chain via {approveOrder} — the
    ///         signature-less order path — or withdrew it via {revokeOrderApproval}.
    event OrderApproved(address indexed maker, bytes32 indexed orderHash);
    event OrderApprovalRevoked(address indexed maker, bytes32 indexed orderHash);

    /// @notice A maker cancelled a SPECIFIC order by hash via {cancelOrder} — the
    ///         per-order-hash cancellation, complementing {NonceManager}'s bulk
    ///         nonce cancellation. Permanent; the order can never fill again.
    event OrderCancelledByHash(address indexed maker, bytes32 indexed orderHash);

    error ZeroFill();
    error OverFill();
    error FillTooSmall();
    error NonceCancelled();
    /// @dev {approveOrder}/{cancelOrder} called with an order whose `maker` is not
    ///      the caller.
    error NotOrderMaker();
    /// @dev The order was cancelled by hash via {cancelOrder} (`filled` sentinel).
    error OrderCancelled();
    /// @dev A fill-once order (see {DutchAuction.useNonceInvalidator}) was offered a
    ///      partial fill. Such an order keeps no per-order counter — its progress IS
    ///      the consumed nonce — so anything short of a full fill would burn the nonce
    ///      and make the remainder permanently unfillable. Rejected outright.
    error FillOnceMustBeFull();
    /// @dev The order derives its fill denominator from leg 0 of the fixed side, but
    ///      that side is empty. Such an order must carry an explicit `fillTotal`.
    error NoAnchorLeg();

    // ──────────────────── On-chain order authorization ────────────────────

    /// @notice Signature-less order authorization. Instead of signing the order
    ///         off-chain, the maker (`msg.sender`) records approval on-chain here;
    ///         fillers then fill with an EMPTY `sig`. This is the path for makers
    ///         that cannot produce a verifiable signature at all — a classic
    ///         multisig with no EIP-1271 `isValidSignature`, for which neither the
    ///         ECDSA nor the 1271 branch of the verifier can succeed. (Signers that
    ///         CAN produce a signature — EOA, EIP-1271 wallet, Safe, EIP-7702
    ///         account — should just sign; they need no on-chain write.)
    ///
    ///         The mapping is keyed by `msg.sender` and checked at fill time against
    ///         `order.maker`, so a caller can only ever authorize an order that names
    ///         itself as maker — no one can approve on another maker's behalf. The
    ///         `order.maker == msg.sender` guard makes that explicit and fails fast.
    ///
    ///         Nothing else about the fill changes: the maker must still hold the
    ///         standing Permit3 allowances the fill consumes, and every fill remains
    ///         gated by the order's deadline, nonce, validators, and invariants.
    ///         Approval authorizes the order for partial fills up to its size, not a
    ///         single use.
    /// @return orderHash The EIP-712 order hash now authorized (handy for indexing).
    function approveOrder(Order calldata order) external returns (bytes32 orderHash) {
        if (order.maker != msg.sender) revert NotOrderMaker();
        orderHash = order.hash();
        orderApproved[msg.sender][orderHash] = true;
        emit OrderApproved(msg.sender, orderHash);
    }

    /// @notice Withdraw a prior {approveOrder}. Keyed by `msg.sender`, so a maker can
    ///         only clear its own approval. Binds on EVERY fill, including the
    ///         remainder of an already partially-filled order: {Signatures} re-reads
    ///         this record each time precisely because, unlike a signature, it is
    ///         revocable. Cancelling the order's nonce ({cancelOrders}/{rollbackNonces})
    ///         also blocks the fill — the nonce gate runs on every fill regardless —
    ///         but leaves this flag set; use this to un-approve without burning the
    ///         nonce, or to reclaim the storage.
    function revokeOrderApproval(bytes32 orderHash) external {
        orderApproved[msg.sender][orderHash] = false;
        emit OrderApprovalRevoked(msg.sender, orderHash);
    }

    /// @notice Cancel ONE specific order by hash — the per-order-hash cancellation
    ///         primitive (the 0x-orderbook model: nonce OR hash). {NonceManager}'s
    ///         nonce cancellation is BULK (a nonce may be shared by several orders,
    ///         so cancelling it drops them all); this cancels exactly the one order,
    ///         leaving any others that share its nonce fillable.
    ///
    ///         Implementation is GAS-FREE on the fill hot path: it parks the
    ///         `filled[hash]` counter at the `type(uint256).max` sentinel, which
    ///         `_openFill` already SLOADs on every fill — so the cancel check is a
    ///         single added compare, no extra storage read. The sentinel is
    ///         unambiguous: a real order's `filled` never exceeds `total` (a token
    ///         amount, always ≪ 2^256-1), so it can never collide with `max`.
    ///
    ///         Only the maker can cancel: the caller must equal `order.maker`, and
    ///         the order hash is maker-bound (maker is a signed field), so no one
    ///         can cancel another maker's order. Permanent and irreversible (mirrors
    ///         nonce cancellation). A PARTIALLY-filled order is cancellable too — its
    ///         remaining size becomes unfillable.
    /// @return orderHash The EIP-712 order hash now cancelled (handy for indexing).
    function cancelOrder(Order calldata order) external returns (bytes32 orderHash) {
        if (order.maker != msg.sender) revert NotOrderMaker();
        orderHash = order.hash();
        filled[orderHash] = type(uint256).max;
        emit OrderCancelledByHash(msg.sender, orderHash);
    }

    // ──────────────────── The fill state transition ────────────────────

    /// @dev Reserve this fill's slice: resolve the denominator + this fill's
    ///      delta, check over-fill, bump the cumulative counter, and package the
    ///      context. The denominator (`ctx.anchor`) is the fixed-side leg 0
    ///      (`tokenIn[0]` for SELL, `tokenOut[0]` for BUY) for a plain fungible
    ///      order, or the maker-signed `fillTotal` when set. The delta is the
    ///      requested `fillAmount` for the identity case, or a fill module's
    ///      accepted amount when `order.fillModule` is set — see {IFillModule}.
    ///
    ///      Security: the module may only choose the DELTA; the over-fill cap
    ///      (`newFilled <= total`) and the uniform per-leg scaling stay here, so
    ///      a buggy/hostile module can only mis-size the fraction (which scales
    ///      both sides of the order proportionally), never over-extract.
    function _openFill(
        Order calldata order,
        bytes32 orderHash,
        uint256 fillAmount,
        uint256 overrideBps,
        address filler,
        bytes memory takerData
    ) internal returns (FillCtx memory ctx) {
        // Denominator: maker-signed `fillTotal` when set, else the leg anchor.
        // The `!= 0` branch reads a single calldata word — no leg access, so a
        // pure non-fungible order (empty legs) still has a valid denominator.
        uint256 total = order.fillTotal != 0 ? order.fillTotal : _anchorTotal(order);
        uint256 prevFilled = filled[orderHash];
        // Per-order-hash cancellation ({cancelOrder}) parks `filled` at max — reuse
        // the SLOAD we just did, so the check is free. (An uncancelled order's
        // `filled` never reaches max, so no false positive.)
        if (prevFilled == type(uint256).max) revert OrderCancelled();
        // Delta: identity (zero overhead — a calldata compare, no call) or a
        // fill-module resolve. The module validates the filler's proposal
        // (`takerData`) against this order and returns the accepted delta.
        uint256 delta;
        if (order.fillModule == address(0)) {
            delta = fillAmount; // identity — already checked != 0 in _fillCore
        } else {
            delta = IFillModule(order.fillModule).resolveFill(order, prevFilled, fillAmount, takerData);
            if (delta == 0) revert ZeroFill(); // a module can return 0; identity can't
        }
        // Anti-dust floor on the ACTUAL progress (delta), identity + module alike.
        if (delta < order.minFillAnchor) revert FillTooSmall();
        uint256 newFilled = prevFilled + delta;
        if (newFilled > total) revert OverFill();
        // Progress is recorded EITHER in this order's own counter (the default) OR, for
        // a maker who opted into fill-once, by consuming the nonce — a warm, shared,
        // usually-already-non-zero slot instead of a fresh 22,100-gas one. See
        // {DutchAuction.useNonceInvalidator} for the full trade and its consequences.
        if (order.useNonceInvalidator()) {
            // A partial fill would burn the nonce and strand the remainder, so the
            // opt-in only accepts a fill that closes the order outright.
            if (newFilled != total) revert FillOnceMustBeFull();
            _cancelNonce(order.maker, order.nonce); // blocks every later fill via the
            // nonce gate `_fillCore` already runs
        } else {
            filled[orderHash] = newFilled;
        }
        // `payTo` defaults to the filler; the aggregator entry may redirect it
        // after this returns (payment destination only — never authority).
        // Assigned field-by-field rather than as a struct literal: a literal would
        // have to name `receipts`, and the only way to name it is `new uint256[](0)`
        // — a real allocation on EVERY fill, for an array only `fillUpTo` ever sizes
        // and only it ever reads. Zero-initialisation points it at the canonical
        // empty-array slot for free, so the ordinary paths pay nothing.
        ctx.orderHash = orderHash;
        ctx.anchor = total;
        ctx.prevFilled = prevFilled;
        ctx.newFilled = newFilled;
        ctx.overrideBps = overrideBps;
        // `payTo` defaults to the filler; the aggregator entry may redirect it
        // after this returns (payment destination only — never authority).
        ctx.filler = filler;
        ctx.payTo = filler;
        ctx.fullFill = prevFilled == 0 && newFilled == total;
    }

    /// @dev The fill denominator in anchor units: the FIXED side's leg 0 —
    ///      `startAmountIn[0]` (SELL) or `startAmountOut[0]` (BUY).
    ///      The empty-blob check is NOT optional. `LegIn[]` used to give us an
    ///      out-of-bounds revert for free when leg 0 did not exist; a packed blob just
    ///      reads zeroes (`calldataload` pads past calldata), which would silently
    ///      yield a zero denominator. An order with no legs must set `fillTotal`.
    function _anchorTotal(Order calldata order) internal pure returns (uint256) {
        if (order.side() == OrderSide.BUY) {
            if (PackedArrays.validateFixed(order.legsOut, PackedArrays.LEG_OUT_STRIDE) == 0) revert NoAnchorLeg();
            (, uint256 start,,) = PackedArrays.legOut(order.legsOut, 0);
            return start;
        }
        if (PackedArrays.validateFixed(order.legsIn, PackedArrays.LEG_IN_STRIDE) == 0) revert NoAnchorLeg();
        (, uint256 startIn,) = PackedArrays.legIn(order.legsIn, 0);
        return startIn;
    }
}
