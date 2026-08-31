// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFillModule} from "../interfaces/IFillModule.sol";
import {Order, OrderSide, FillCtx} from "./Structs.sol";
import {OrderHash} from "./OrderHash.sol";
import {DutchAuction} from "./DutchAuction.sol";
import {PackedArrays} from "./PackedArrays.sol";
import {NonceManager} from "./NonceManager.sol";
import {OrderGates} from "./OrderGates.sol";

/// @title OrderState
/// @notice ALL order-lifecycle STATE and its mutation, in one auditable place — no
///         token movement, no signatures, no settlement logic, only the
///         who-can-fill-what-and-how-much bookkeeping:
///           • the per-order `filled` counter (with the cancellation sentinel),
///           • the on-chain `orderApproved` records (the signature-less path),
///           • per-order-HASH cancellation ({cancelOrder}),
///           • the maker-keyed delegated-signer registry ({setOrderSigner}),
///           • nonce cancellation (inherited from {NonceManager}),
///           • the `_openFill` state transition — resolve this fill's delta, apply
///             the over-fill cap, and advance the counter.
///
///         All mutable storage lives in this layer + {NonceManager}, so the slot
///         layout is fixed here: `nonceBitmap`(0), `minValidNonce`(1) from
///         NonceManager, then `filled`(2), `orderApproved`(3),
///         `orderSignerExpiry`(4).
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
    ///         fill is still gated by the shared nonce/expiry/validator machinery —
    ///         this only replaces the signature check, nothing else.
    mapping(address => mapping(bytes32 => bool)) public orderApproved;

    /// @notice maker → delegate → the unix time until which that delegate may sign
    ///         orders on the maker's behalf. `0` means NOT a signer.
    ///
    ///         The session-key / trading-desk primitive: an EOA maker nominates
    ///         another key to produce order signatures for them, without handing
    ///         over custody and without deploying a smart account. Modelled on 0x
    ///         v4's `registerAllowedOrderSigner`, with an expiry added so a
    ///         delegation can lapse on its own.
    ///
    ///  ⚠ WHY THIS IS NOT AN "OPERATOR"
    ///  ───────────────────────────────
    ///  Delegated order signing is only safe when the DELEGATOR chooses the
    ///  delegate. This mapping is keyed by `msg.sender` on write and by the ORDER'S
    ///  OWN MAKER on read, which pins both halves:
    ///
    ///    • nobody can nominate a signer for someone else — the key is the caller;
    ///    • a delegate's reach is exactly "orders naming this maker", because the
    ///      order hash commits to `maker` and the lookup is
    ///      `orderSignerExpiry[order.maker][recovered]`. A delegate can therefore
    ///      author nothing the maker could not have authored themselves, and
    ///      nothing at all for any other maker.
    ///
    ///  Contrast the protocol-set operator in OpenOcean's LOP fork, where an
    ///  admin-nominated address signs the ORDER hash while the user signs only a
    ///  constant, order-independent message — one signature there is unbounded,
    ///  non-expiring, replayable delegation over everything the user has approved.
    ///  Nothing here can express that: there is no protocol-level signer, and every
    ///  other gate (expiry, nonce, validators, and above all the maker's Permit3
    ///  allowances with their own caps and expiries) binds a delegated order exactly
    ///  as it binds a self-signed one.
    ///
    ///  ⚠ REVOCATION AND THE FIRST-FILL SKIP. {Signatures._verifySignature} only
    ///  re-checks a SIGNATURE on an order's first fill, so revoking a delegate does
    ///  NOT stop the remainder of an order it already part-filled — the same
    ///  documented caveat EIP-1271 makers live with. The kill switches that DO bind
    ///  mid-order are unchanged: {cancelOrder}, nonce cancellation, the expiry,
    ///  and revoking the Permit3 allowances that fund the fill.
    ///
    /// @dev `0` means "not a signer" because that is the value of an unset mapping,
    ///      so it CANNOT also mean "never expires" the way Permit3's `expiration`
    ///      field does. A perpetual delegation is `type(uint256).max`. The
    ///      divergence is deliberate and is called out here because the two
    ///      conventions sit one contract apart.
    mapping(address => mapping(address => uint256)) public orderSignerExpiry;

    /// @notice A maker authorized an order on-chain via {approveOrder} — the
    ///         signature-less order path — or withdrew it via {revokeOrderApproval}.
    event OrderApproved(address indexed maker, bytes32 indexed orderHash);
    event OrderApprovalRevoked(address indexed maker, bytes32 indexed orderHash);

    /// @notice A maker nominated (`expiry != 0`) or revoked (`expiry == 0`) a
    ///         delegate permitted to sign orders on their behalf.
    event OrderSignerSet(address indexed maker, address indexed signer, uint256 expiry);

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
    /// @dev {setOrderSigner} was given `address(0)`. `ecrecover` yields the zero
    ///      address for any malformed signature, so authorizing it would promote
    ///      every unrecoverable signature to a valid delegated one.
    error InvalidOrderSigner();
    /// @dev The order was cancelled by hash via {cancelOrder} (`filled` sentinel).
    error OrderCancelled();
    /// @dev A fill-once order (see {DutchAuction.useNonceInvalidator}) was offered a
    ///      partial fill. Such an order keeps no per-order counter — its progress IS
    ///      the consumed nonce — so anything short of a full fill would burn the nonce
    ///      and make the remainder permanently unfillable. Rejected outright.
    error FillOnceMustBeFull();

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
    ///         gated by the order's expiry, nonce, validators, and invariants.
    ///         Approval authorizes the order for partial fills up to its size, not a
    ///         single use.
    /// @return orderHash The EIP-712 order hash now authorized (handy for indexing).
    function approveOrder(Order calldata order) external returns (bytes32 orderHash) {
        if (order.maker != msg.sender) revert NotOrderMaker();
        orderHash = order.hash();
        orderApproved[msg.sender][orderHash] = true;
        emit OrderApproved(msg.sender, orderHash);
    }

    /// @notice Batch {approveOrder}: authorize several orders in one transaction.
    ///         This is the shape the signature-less makers this path exists for
    ///         actually need — a multisig queues ONE action approving its whole
    ///         ladder of orders, not one proposal per order. Semantics are exactly
    ///         N sequential {approveOrder} calls: every order must name the caller
    ///         as maker (the whole call reverts {NotOrderMaker} otherwise — a
    ///         multisig must not half-approve a ladder), and each order emits its
    ///         own {OrderApproved}, so indexers see no new event shape.
    /// @return orderHashes The EIP-712 hashes now authorized, aligned with `orders`.
    function approveOrders(Order[] calldata orders) external returns (bytes32[] memory orderHashes) {
        uint256 n = orders.length;
        orderHashes = new bytes32[](n);
        for (uint256 i; i < n;) {
            Order calldata order = orders[i];
            if (order.maker != msg.sender) revert NotOrderMaker();
            bytes32 orderHash = order.hash();
            orderApproved[msg.sender][orderHash] = true;
            emit OrderApproved(msg.sender, orderHash);
            orderHashes[i] = orderHash;
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Nominate `signer` to produce order signatures on the caller's behalf
    ///         until `expiry`, or revoke it with `expiry == 0`. See
    ///         {orderSignerExpiry} for the trust model and its limits.
    /// @param  signer the delegate. Nominating `address(0)` is rejected: `ecrecover`
    ///         returns `address(0)` on a malformed signature, so an authorized zero
    ///         address would turn every unrecoverable signature into a valid one.
    /// @param  expiry unix time the delegation lapses at. `0` revokes;
    ///         `type(uint256).max` never lapses. A past value is accepted and is
    ///         simply already-expired — it reads identically to a revocation and
    ///         needs no special case.
    function setOrderSigner(address signer, uint256 expiry) external {
        _setOrderSigner(msg.sender, signer, expiry);
    }

    /// @dev The write itself, shared with the relayed variant
    ///      ({Signatures.setOrderSignerWithSig}) so the storage mutation and its
    ///      event exist ONCE. `maker` is the delegator: `msg.sender` above, or the
    ///      recovered signer of an EIP-712 permit there. Callers own the
    ///      authorization; this owns the write.
    ///
    ///  ⚠ REVOCATION ALSO BURNS THE DELEGATE'S WHOLE PERMIT WORD, AND THAT SINGLE
    ///  `SSTORE` IS WHAT MAKES REVOCATION FINAL. Clearing the registry alone is not
    ///  enough: a nomination permit consumes its bitmap coordinate only when
    ///  RELAYED, so a maker who signs one, never has it landed, and then revokes is
    ///  still exposed — whoever holds the message can relay it up to its `deadline`
    ///  and the delegate is live again. That used to be a documented two-call
    ///  discipline (`setOrderSigner(d, 0)` then `cancelOrders([coordinate])`), which
    ///  the SDK emitted correctly and every other client — a wallet, a block
    ///  explorer, a hand-rolled script — did not. A safety property that depends on
    ///  the caller making a second call is not a safety property.
    ///
    ///  It costs one word because the permit coordinate is DERIVED FROM THE
    ///  DELEGATE, not drawn from a counter: a permit's nonce is
    ///  `(signer << 8) | seq` with `seq` one byte, so every permit for `signer`
    ///  shares the bitmap word `SIGNER_NONCE_NS >> 8 | signer` and one write
    ///  retires all 256 of them. The `signer << 8` never reaches bit 247, so the
    ///  word can collide with no other delegate's and with no order's.
    ///
    ///  THE PRICE, AND IT IS DELIBERATE: gasless RE-nomination of the same delegate
    ///  is afterwards impossible — every coordinate it could use is spent. Direct
    ///  {setOrderSigner} still works, and a maker who cannot pay gas can nominate a
    ///  DIFFERENT key, which is what you should be doing with a delegate you just
    ///  revoked. Buying re-nomination back would take a per-delegate epoch in the
    ///  permit typehash; it is not worth a storage slot and a breaking permit type
    ///  to make a compromised key reusable.
    function _setOrderSigner(address maker, address signer, uint256 expiry) internal {
        if (signer == address(0)) revert InvalidOrderSigner();
        orderSignerExpiry[maker][signer] = expiry;
        // Revocation only. A nomination must NOT burn the word — it is the very
        // word the permit being relayed right now is spending its own coordinate in.
        if (expiry == 0) {
            nonceBitmap[maker][(SIGNER_NONCE_NS >> 8) | uint256(uint160(signer))] = type(uint256).max;
        }
        emit OrderSignerSet(maker, signer, expiry);
    }

    /// @notice Withdraw a prior {approveOrder}. Keyed by `msg.sender`, so a maker can
    ///         only clear its own approval. Binds on EVERY fill, including the
    ///         remainder of an already partially-filled order. Cancelling the order's
    ///         nonce ({cancelOrders}/{rollbackNonces}) also blocks the fill — the
    ///         nonce gate runs on every fill regardless — but leaves this flag set;
    ///         use this to un-approve without burning the nonce, or to reclaim the
    ///         storage.
    ///
    /// @dev    ⚠ ON A PARTIALLY FILLED ORDER THIS ESCALATES TO A FULL CANCEL, and it
    ///         has to. {Signatures._verifySignature} skips re-verification once
    ///         `filled != 0` — a signature over a fixed digest cannot be withdrawn,
    ///         so re-checking it is pure cost — and that skip is reached by ANY
    ///         non-empty `sig`. It does not know the earlier fill was authorised by
    ///         this record rather than by a signature, because nothing records which.
    ///         So clearing the flag alone left a hole: after one approval-authorised
    ///         partial fill, a filler passing 65 arbitrary bytes took the signature
    ///         branch, hit the skip, and settled the remainder of a revoked order —
    ///         even for a maker with no EIP-1271 at all, for whom no signature can
    ///         ever be valid.
    ///
    ///         Parking the {cancelOrder} sentinel closes it at ZERO hot-path cost:
    ///         `filled` is already read by every fill, so no new SLOAD is added to
    ///         settle for it. The alternative — reading `orderApproved` on the
    ///         signature path too — would put a cold SLOAD (~2,100 gas) on EVERY
    ///         fill of EVERY order to protect the rare sigless one, which is the
    ///         exact cost that skip exists to avoid.
    ///
    ///         Two consequences, both deliberate:
    ///           • revocation of a TOUCHED order is one-way. Re-approving the same
    ///             hash will not revive it; sign a fresh order. An UNTOUCHED order
    ///             (`filled == 0`) is unaffected — approve/revoke/re-approve still
    ///             round-trips, because with no fill recorded the skip is not
    ///             reached and the signature branch verifies for real.
    ///           • a maker that both signed AND approved the same order cancels it
    ///             here. That is maker-initiated and safe; it cannot be triggered by
    ///             anyone else.
    ///
    ///         The `wasApproved` guard is load-bearing, NOT an optimisation: this
    ///         takes a bare hash, so without it any caller could park the sentinel on
    ///         any partially filled order and cancel a stranger's order outright.
    ///         {approveOrder} enforces `order.maker == msg.sender`, so a set flag is
    ///         proof the caller is that order's maker.
    function revokeOrderApproval(bytes32 orderHash) external {
        // Nested rather than `wasApproved && …`: Settlement runs on a ~100-byte
        // EIP-170 margin and the flat form measured 98 bytes against it. No second
        // event either — {OrderApprovalRevoked} plus a non-zero `filled` is the same
        // information for an indexer, at no bytecode cost.
        if (orderApproved[msg.sender][orderHash]) {
            orderApproved[msg.sender][orderHash] = false;
            if (filled[orderHash] != 0) filled[orderHash] = type(uint256).max;
        }
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
    /// @dev THE FILL-STATE GATE — the cheapest question a fill can ask, asked FIRST.
    ///      Seeds `ctx` with the order hash, the denominator and the progress so far,
    ///      and rejects an order that is cancelled or already complete.
    ///
    ///      Ordering is the point, not the arithmetic. A PRIORITY-fee auction
    ///      ({DutchAuction.priorityAuction}) is a gas auction: every solver sends the
    ///      SAME fill, the sequencer's fee ordering picks one, and every other bidder
    ///      lands and reverts — paying its own bid on whatever gas it burned before
    ///      the revert. That loss is the tax the whole mechanism charges solvers, and
    ///      it is proportional to how deep into the fill the loser gets before it
    ///      learns it lost. `filled[orderHash] >= total` IS the "you lost" signal, so
    ///      it runs before the maker's nonce word, the exclusivity read, and the
    ///      validator STATICCALLs — none of which can change the answer.
    ///
    ///      Costs the winner nothing: the same SLOAD and the same denominator resolve
    ///      that {_openFill} used to do, moved up and handed over in `ctx` rather than
    ///      recomputed.
    function _gateFillState(Order calldata order, bytes32 orderHash, FillCtx memory ctx) internal view {
        // Denominator: maker-signed `fillTotal` when set, else the leg anchor.
        // The `!= 0` branch reads a single calldata word — no leg access, so a
        // pure non-fungible order (empty legs) still has a valid denominator.
        //
        // A {Proportional} anchor is resolved inside `anchorTotal` and needs
        // NOTHING from this function — deliberately. Threading a "was it
        // proportional" flag back here to force `delta = total` was measured at
        // +253 gas on EVERY plain fill (2026-08-10), which is an order of magnitude
        // more than this codebase accepts for a feature most orders never use. The
        // whole-fill rule is instead enforced where the marker is CONSUMED, by
        // {Pricing.inputOwed}'s `ctx.fullFill` assert, and the solver's size bound
        // falls out of machinery that already exists: `fillUpTo` clamps to the
        // remaining size, so asking for less than the resolved anchor — including
        // because the maker's balance grew past the amount the solver quoted —
        // arrives here as a partial fill and is rejected.
        // ORDER IS LOAD-BEARING. `anchorTotal` STATICCALLs `balanceOf` on a
        // maker-chosen token for a {Proportional} anchor, and this gate runs BEFORE the
        // reentrancy guard on the hand-armed entries (see {Base._enter}). Resolving the
        // denominator first and reading `filled` second means the counter this gate
        // hands to {_openFill} is read after that call, never before it — so it cannot
        // be stale. Do not flip these two lines.
        uint256 total = order.fillTotal != 0 ? order.fillTotal : OrderGates.anchorTotal(order);
        uint256 prevFilled = filled[orderHash];
        // Per-order-hash cancellation ({cancelOrder}) parks `filled` at max — reuse
        // the SLOAD we just did, so the check is free. (An uncancelled order's
        // `filled` never reaches max, so no false positive.)
        if (prevFilled == type(uint256).max) revert OrderCancelled();
        // Nothing is left to fill. {_openFill}'s `newFilled > total` cap still stands
        // as the universal backstop — this is the same rule, asked early enough that
        // a losing bidder pays for it and not for the rest of the fill.
        if (prevFilled >= total) revert OverFill();
        ctx.orderHash = orderHash;
        ctx.anchor = total;
        ctx.prevFilled = prevFilled;
    }

    function _openFill(
        Order calldata order,
        uint256 fillAmount,
        address filler,
        bytes memory takerData,
        FillCtx memory ctx
    ) internal {
        // Seeded by {_gateFillState}, which every caller runs first: `ctx.anchor` is
        // the resolved denominator and `ctx.prevFilled` the progress so far, both
        // already checked against cancellation and completion.
        uint256 total = ctx.anchor;
        uint256 prevFilled = ctx.prevFilled;
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
            filled[ctx.orderHash] = newFilled;
        }
        // `payTo` defaults to the filler; the custom-fill entry may redirect it
        // after this returns (payment destination only — never authority).
        // Assigned field-by-field rather than as a struct literal: a literal would
        // have to name `receipts`, and the only way to name it is `new uint256[](0)`
        // — a real allocation on EVERY fill, for an array only `fillUpTo` ever sizes
        // and only it ever reads. Zero-initialisation points it at the canonical
        // empty-array slot for free, so the ordinary paths pay nothing.
        ctx.newFilled = newFilled;
        // `payTo` defaults to the filler; the custom-fill entry may redirect it
        // after this returns (payment destination only — never authority).
        ctx.filler = filler;
        ctx.payTo = filler;
        ctx.fullFill = prevFilled == 0 && newFilled == total;
        // A PRICE MODULE or a PRIORITY auction is resolved HERE, once, and pinned —
        // this is the only point in a fill where the filler, the fill progress and the
        // taker blob are all in scope. Pinning keeps a multi-leg module order to ONE
        // staticcall, and keeping both cold modes behind this single call site is what
        // holds Settlement under EIP-170 (see the size note on {DutchAuction.bumpBps}).
        // A clock-priced order gets 0 back and resolves lazily per decaying leg, which
        // is the measured-cheapest shape for the dominant case.
        ctx.bump = DutchAuction.resolveBump(order, ctx.orderHash, total, filler, prevFilled, takerData);
    }

}
