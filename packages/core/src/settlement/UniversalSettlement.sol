// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPermit3} from "../interfaces/IPermit3.sol";
import {IMakerModule} from "../interfaces/IMakerModule.sol";
import {IFillModule} from "../interfaces/IFillModule.sol";
import {ISettlementModule} from "../interfaces/ISettlementModule.sol";
import {IOrderValidator} from "../interfaces/IOrderValidator.sol";
import {SignatureVerification} from "../permit3/SignatureVerification.sol";
import {SafeTransferLib} from "../utils/SafeTransferLib.sol";
import {Permit3TransferLib} from "../utils/Permit3TransferLib.sol";

// Re-exported so downstream files can keep importing the order types from here.
import {Order, Item, ItemOp, Validator, OrderSide, CurvePoint} from "./SettlementStructs.sol";
import {OrderHash} from "./OrderHash.sol";
import {DutchAuction} from "./DutchAuction.sol";
import {NonceManager} from "./NonceManager.sol";
import {SolverCallbackExecutor} from "./SolverCallbackExecutor.sol";

/// @title UniversalSettlement
/// @notice Signed limit-order settler with partial fills, optional dutch
///         decay, and pro-rata module-dispatched lending legs. All token
///         and taker authority flows through Permit3 — there is no module
///         whitelist, no admin role. A module's authority comes entirely
///         from the maker's signature + their per-module Permit3 allowances.
///
///  Structure: order types live in {SettlementStructs}, EIP-712 hashing in
///  {OrderHash}, auction pricing in {DutchAuction}, and cancellation in
///  {NonceManager} (inherited). This contract owns the fill flow, the
///  validator/invariant gates, and settlement accounting.
contract UniversalSettlement is NonceManager {
    using OrderHash for Order;
    using DutchAuction for Order;

    // ──────────────────── Storage ────────────────────

    IPermit3 public immutable PERMIT3;

    /// @dev EIP-712 domain, cached at deploy but recomputed if `block.chainid`
    ///      changes (chain fork) so an order signature can never be replayed
    ///      against the wrong domain after a split. Mirrors Permit3's EIP712
    ///      base; exposed via the `DOMAIN_SEPARATOR()` view below.
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;
    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _HASHED_NAME = keccak256("UniversalSettlement");
    bytes32 private constant _HASHED_VERSION = keccak256("1");

    /// @notice Allowance-less trampoline for `fillWithCallback` (see the contract
    ///         for the security rationale). Deployed here so it is dedicated to
    ///         this Settlement and can never be an approved Permit3 spender.
    SolverCallbackExecutor public immutable EXECUTOR;

    /// @notice orderHash → cumulative filled amount, in the order's ANCHOR units
    ///         (`tokenIn[0]` for SELL, `tokenOut[0]` for BUY).
    mapping(bytes32 => uint256) public filled;

    /// @notice maker → orderHash → on-chain order authorization. The signature-less
    ///         alternative to signing: a maker that cannot produce a verifiable
    ///         signature at all — a classic multisig with no EIP-1271
    ///         `isValidSignature`, for which neither the ECDSA nor the 1271 branch
    ///         of the verifier can ever succeed — instead records intent on-chain via
    ///         {approveOrder}. Fillers then pass an EMPTY `sig` and the fill
    ///         authorizes against this mapping. Funding still flows through the
    ///         maker's standing Permit3 allowances, and the fill is still gated by
    ///         the shared nonce/deadline/validator machinery — this only replaces the
    ///         signature check, nothing else.
    mapping(address => mapping(bytes32 => bool)) public orderApproved;

    uint256 private _locked = 1;

    // ──────────────────── Events ────────────────────

    /// @notice A fill occurred. Intentionally data-less: every amount is
    ///         recoverable from the ERC20 `Transfer` / protocol events in the same
    ///         tx (`tokenOut` legs are solver→maker transfers; the anchor
    ///         `fillAmountIn` is the `tokenIn[0]`/`tokenOut[0]` leg), and on-chain
    ///         callers get the per-leg outputs from the function return value. The
    ///         event exists only to bind those transfers to an `orderHash` (which
    ///         Transfer events don't carry) and to make fills filterable by
    ///         maker/solver — so it emits just those three topics, no log data.
    event OrderFilled(bytes32 indexed orderHash, address indexed maker, address indexed solver);

    /// @notice A maker authorized an order on-chain via {approveOrder} — the
    ///         signature-less order path — or withdrew it via {revokeOrderApproval}.
    event OrderApproved(address indexed maker, bytes32 indexed orderHash);
    event OrderApprovalRevoked(address indexed maker, bytes32 indexed orderHash);

    // ──────────────────── Errors ────────────────────

    error OrderExpired();
    error NonceCancelled();
    error ZeroFill();
    error OverFill();
    error Reentrancy();
    error ValidationFailed(uint256 index);
    error InvariantFailed(uint256 index);
    error NotExclusiveFiller();
    error FillTooSmall();
    error OnlySelf();
    error BatchFillIncomplete(uint256 index);
    /// @dev `batchFill`'s `takerDatas` array is not aligned 1:1 with `orders`.
    error LengthMismatch();
    error ReverseModeRequiresNoItems();
    /// @dev An empty `sig` was supplied for a fill, but the maker has no matching
    ///      on-chain {approveOrder} record for this order.
    error OrderNotApproved();
    /// @dev {approveOrder} called with an order whose `maker` is not the caller.
    error NotOrderMaker();

    /// @notice Where the solver callback runs relative to settlement, chosen by
    ///         the filler in `fillWithCallback`.
    enum CallbackMode {
        PreDelivery, // callback → deliver outputs → items → pay inputs (works for any order)
        PostInputs // pay inputs → callback → deliver outputs (item-free only; JIT-from-proceeds)
    }

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(address permit3) {
        PERMIT3 = IPermit3(permit3);
        EXECUTOR = new SolverCallbackExecutor();
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator();
    }

    /// @notice EIP-712 domain separator for the current chain. Returns the cached
    ///         value unless `block.chainid` has changed since deployment (fork),
    ///         in which case it is rebuilt so signatures stay domain-bound.
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return block.chainid == _CACHED_CHAIN_ID ? _CACHED_DOMAIN_SEPARATOR : _buildDomainSeparator();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(_DOMAIN_TYPEHASH, _HASHED_NAME, _HASHED_VERSION, block.chainid, address(this)));
    }

    // ──────────────────── Fill ────────────────────

    /// @notice Fill (up to) `fillAmount` of an order — in `tokenIn[0]` units for a
    ///         SELL, `tokenOut[0]` units for a BUY. Partial fills allowed.
    ///         Lending items are executed pro-rata for this fill's slice.
    /// @dev    Thin wrapper over the {takerData} overload with an empty blob, so
    ///         existing 3-arg call sites (solvers, SDK) keep working unchanged.
    function fill(Order calldata order, bytes calldata sig, uint256 fillAmount)
        external
        nonReentrant
        returns (uint256[] memory fillAmountsOut)
    {
        bytes32 orderHash = order.hash();
        _verifySignature(orderHash, sig, order.maker);
        return _fillCore(order, orderHash, fillAmount, msg.sender, address(0), "", CallbackMode.PreDelivery, "");
    }

    /// @notice Fill overload that carries a filler-supplied `takerData` blob into
    ///         the order's validators and invariants.
    /// @param  takerData  Adversarial, UNSIGNED, shared-per-fill data (see
    ///         {IOrderValidator}). It reaches every validator and invariant of this
    ///         fill but can only be *consumed by a validator* — a read-only gate —
    ///         so it can never alter the maker's signed outcome (amounts, tokens,
    ///         recipients). A validator that reads it MUST independently verify it
    ///         (e.g. recover a maker-trusted attester over a digest bound to
    ///         `msg.sender`). Lets a maker gate a fill on a proof only the filler
    ///         can produce (off-chain attestation, oracle update, ZK proof).
    function fill(Order calldata order, bytes calldata sig, uint256 fillAmount, bytes calldata takerData)
        external
        nonReentrant
        returns (uint256[] memory fillAmountsOut)
    {
        bytes32 orderHash = order.hash();
        _verifySignature(orderHash, sig, order.maker);
        return _fillCore(order, orderHash, fillAmount, msg.sender, address(0), "", CallbackMode.PreDelivery, takerData);
    }

    /// @notice Fill with a solver-supplied callback that runs just before output
    ///         delivery — the taker-interaction analogue. Lets a zero-inventory
    ///         solver source `tokenOut` just-in-time (flash / swap / route)
    ///         without a bespoke solver contract: the callback runs while the
    ///         fill's reentrancy guard is held, then Settlement pulls the outputs
    ///         the solver just acquired.
    ///
    ///  Safety: the `(callbackTarget, callbackData)` call is made by
    ///  {SolverCallbackExecutor} — an allowance-less trampoline — NOT by
    ///  Settlement, so it cannot abuse Settlement's Permit3 spender status to
    ///  move a maker's funds (e.g. `callbackTarget = PERMIT3` gains nothing). The
    ///  callback is filler-supplied and NOT part of the maker's signed order, so
    ///  it can only act with its own authority; the maker's funds stay gated by
    ///  their signature + Permit3 allowances exactly as in a plain `fill`.
    ///  Reentrancy into any fill is blocked by `nonReentrant`.
    ///
    ///  `mode` (filler-chosen) picks where the callback runs:
    ///    • PreDelivery — callback → deliver outputs → items → pay inputs. Works
    ///      for any order; the solver must source `tokenOut` from something that
    ///      does NOT depend on this fill's proceeds (flash / credit / inventory).
    ///    • PostInputs  — pay inputs → callback → deliver outputs. Item-free
    ///      orders only. The solver is paid its `tokenIn` FIRST, converts it in
    ///      the callback, then delivers `tokenOut` — a genuinely zero-inventory,
    ///      zero-flash plain-swap fill (the Fusion `takerInteraction` ordering).
    ///
    ///  The `mode` flag only permutes solver-side transfer order; it cannot change
    ///  the maker's signed outcome. In both modes the tx can only succeed if the
    ///  maker pays exactly the signed input and receives the signed output (a
    ///  mandatory, reverting delivery) and every invariant passes — so it is safe
    ///  for the filler, not the maker, to choose it.
    function fillWithCallback(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmount,
        address callbackTarget,
        bytes calldata callbackData,
        CallbackMode mode
    ) external nonReentrant returns (uint256[] memory fillAmountsOut) {
        bytes32 orderHash = order.hash();
        _verifySignature(orderHash, sig, order.maker);
        return _fillCore(order, orderHash, fillAmount, msg.sender, callbackTarget, callbackData, mode, "");
    }

    /// @notice {fillWithCallback} overload carrying a filler-supplied `takerData`
    ///         blob into the order's validators and invariants. See {fill}'s
    ///         takerData overload for the adversarial/validator-verified rule.
    function fillWithCallback(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmount,
        address callbackTarget,
        bytes calldata callbackData,
        CallbackMode mode,
        bytes calldata takerData
    ) external nonReentrant returns (uint256[] memory fillAmountsOut) {
        bytes32 orderHash = order.hash();
        _verifySignature(orderHash, sig, order.maker);
        return _fillCore(order, orderHash, fillAmount, msg.sender, callbackTarget, callbackData, mode, takerData);
    }

    /// @notice Single-signature fill: the maker's `sig` is over a Permit3
    ///         `PermitBatch` bound to this order's hash as a witness, so
    ///         one signature simultaneously authorises the order *and*
    ///         every Permit3 token + taker allowance the fill needs.
    ///         No standing approvals required.
    function fillWithPermit(
        Order calldata order,
        IPermit3.PermitBatch calldata batch,
        bytes calldata sig,
        uint256 fillAmount
    ) external nonReentrant returns (uint256[] memory fillAmountsOut) {
        bytes32 orderHash = order.hash();
        // Permit3 verifies the sig against (PermitBatchWitness + orderHash) and
        // applies all allowances. The order itself doesn't need a separate sig
        // — the witness binding makes the permit endorse this exact order.
        PERMIT3.permitBatchWithWitness(order.maker, batch, orderHash, OrderHash.WITNESS_TYPESTRING, sig);
        return _fillCore(order, orderHash, fillAmount, msg.sender, address(0), "", CallbackMode.PreDelivery, "");
    }

    /// @notice {fillWithPermit} overload carrying a filler-supplied `takerData`
    ///         blob into the order's validators and invariants. See {fill}'s
    ///         takerData overload for the adversarial/validator-verified rule.
    function fillWithPermit(
        Order calldata order,
        IPermit3.PermitBatch calldata batch,
        bytes calldata sig,
        uint256 fillAmount,
        bytes calldata takerData
    ) external nonReentrant returns (uint256[] memory fillAmountsOut) {
        bytes32 orderHash = order.hash();
        PERMIT3.permitBatchWithWitness(order.maker, batch, orderHash, OrderHash.WITNESS_TYPESTRING, sig);
        return _fillCore(order, orderHash, fillAmount, msg.sender, address(0), "", CallbackMode.PreDelivery, takerData);
    }

    /// @notice Fill a batch of orders in one transaction. Each order is attempted
    ///         independently; an order that reverts (expired, cancelled,
    ///         under-funded, over-fill, …) is SKIPPED and its `success[i]` is
    ///         false — unless `revertIfIncomplete`, in which case the first
    ///         failure reverts the whole batch. Mirrors 0x's `batchFill*` with
    ///         the `revertIfIncomplete` flag.
    /// @dev    Each fill runs via a `this.fillSelf` self-call so a revert unwinds
    ///         only that order, not the batch. The real filler (`msg.sender`) is
    ///         threaded through, so a skipped order costs the caller nothing and a
    ///         filled one settles against the caller exactly as a direct `fill`.
    function batchFill(
        Order[] calldata orders,
        bytes[] calldata sigs,
        uint256[] calldata fillAmounts,
        bool revertIfIncomplete
    ) external nonReentrant returns (uint256[][] memory fillAmountsOut, bool[] memory success) {
        uint256 n = orders.length;
        fillAmountsOut = new uint256[][](n);
        success = new bool[](n);
        address filler = msg.sender;
        for (uint256 i; i < n;) {
            // Empty takerData — the no-taker-blob path.
            try this.fillSelf(orders[i], sigs[i], fillAmounts[i], filler, "") returns (uint256[] memory outs) {
                fillAmountsOut[i] = outs;
                success[i] = true;
            } catch {
                if (revertIfIncomplete) revert BatchFillIncomplete(i);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice {batchFill} overload carrying a per-order filler-supplied `takerData`
    ///         blob, aligned 1:1 with `orders` (`takerDatas[i]` threads into order
    ///         `i`'s validators + invariants). See {fill}'s takerData overload for
    ///         the adversarial/validator-verified rule.
    /// @dev    Reverts {LengthMismatch} if `takerDatas.length != orders.length`.
    ///         The loop is inlined (not shared with the 4-arg overload) to stay
    ///         under the EVM stack limit without via-IR.
    function batchFill(
        Order[] calldata orders,
        bytes[] calldata sigs,
        uint256[] calldata fillAmounts,
        bool revertIfIncomplete,
        bytes[] calldata takerDatas
    ) external nonReentrant returns (uint256[][] memory fillAmountsOut, bool[] memory success) {
        uint256 n = orders.length;
        if (takerDatas.length != n) revert LengthMismatch();
        fillAmountsOut = new uint256[][](n);
        success = new bool[](n);
        address filler = msg.sender;
        for (uint256 i; i < n;) {
            try this.fillSelf(orders[i], sigs[i], fillAmounts[i], filler, takerDatas[i]) returns (uint256[] memory outs)
            {
                fillAmountsOut[i] = outs;
                success[i] = true;
            } catch {
                if (revertIfIncomplete) revert BatchFillIncomplete(i);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Self-call fill target for {batchFill}. Verifies the maker signature
    ///         and runs the fill for an explicit `filler`, carrying this order's
    ///         `takerData`. `onlySelf` — external callers must use `fill`.
    function fillSelf(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmount,
        address filler,
        bytes calldata takerData
    ) external returns (uint256[] memory) {
        if (msg.sender != address(this)) revert OnlySelf();
        bytes32 orderHash = order.hash();
        _verifySignature(orderHash, sig, order.maker);
        return _fillCore(order, orderHash, fillAmount, filler, address(0), "", CallbackMode.PreDelivery, takerData);
    }

    // ──────────────────── On-chain order authorization ────────────────────

    /// @notice Signature-less order authorization. Instead of signing the order
    ///         off-chain, the maker (`msg.sender`) records approval on-chain here;
    ///         fillers then fill with an EMPTY `sig`. This is the path for makers
    ///         that cannot produce a verifiable signature at all — a classic
    ///         multisig with no EIP-1271 `isValidSignature`, for which neither the
    ///         ECDSA nor the 1271 branch of {SignatureVerification} can succeed.
    ///         (Signers that CAN produce a signature — EOA, EIP-1271 wallet, Safe,
    ///         EIP-7702 account — should just sign; they need no on-chain write.)
    ///
    ///         The mapping is keyed by `msg.sender` and checked at fill time against
    ///         `order.maker`, so a caller can only ever authorize an order that names
    ///         itself as maker — no one can approve on another maker's behalf. The
    ///         `order.maker == msg.sender` guard makes that explicit and fails fast.
    ///
    ///         Nothing else about the fill changes: the maker must still hold the
    ///         standing Permit3 allowances the fill consumes, and every fill remains
    ///         gated by the order's deadline, nonce (see {NonceManager}), validators,
    ///         and invariants. Approval is the exact analogue of a signature — it
    ///         authorizes the order for partial fills up to its size, not a single use.
    /// @return orderHash The EIP-712 order hash now authorized (handy for indexing).
    function approveOrder(Order calldata order) external returns (bytes32 orderHash) {
        if (order.maker != msg.sender) revert NotOrderMaker();
        orderHash = order.hash();
        orderApproved[msg.sender][orderHash] = true;
        emit OrderApproved(msg.sender, orderHash);
    }

    /// @notice Withdraw a prior {approveOrder}. Keyed by `msg.sender`, so a maker can
    ///         only clear its own approval. Cancelling the order's nonce
    ///         ({cancelOrders}/{rollbackNonces}) also blocks the fill — the nonce gate
    ///         runs on every fill regardless — but leaves this flag set; use this to
    ///         un-approve without burning the nonce, or to reclaim the storage.
    function revokeOrderApproval(bytes32 orderHash) external {
        orderApproved[msg.sender][orderHash] = false;
        emit OrderApprovalRevoked(msg.sender, orderHash);
    }

    /// @dev Per-fill context, bundled so the settlement helpers take one memory
    ///      pointer and each settle flow runs in its own stack frame (keeps the
    ///      fill under the EVM stack limit).
    struct FillCtx {
        bytes32 orderHash;
        uint256 anchor; //       fill denominator (fixed-side leg 0)
        uint256 prevFilled; //   cumulative filled before this fill
        uint256 newFilled; //    cumulative filled after this fill
        uint256 overrideBps; //  soft-exclusivity improvement (0 = none)
        address filler; //       who is paid / delivers
        bool fullFill; //        prevFilled == 0 && newFilled == anchor: the whole
        //                       order in one shot ⇒ every pro-rata slice is the
        //                       leg's full amount, skipping the mul/div.
    }

    function _fillCore(
        Order calldata order,
        bytes32 orderHash,
        uint256 fillAmount,
        address filler,
        address callbackTarget,
        bytes memory callbackData,
        CallbackMode mode,
        bytes memory takerData
    ) internal returns (uint256[] memory) {
        if (fillAmount == 0) revert ZeroFill();
        // Note: the anti-dust floor is checked in _openFill against the resolved
        // `delta` (the actual progress), not the requested `fillAmount` — for a
        // fill-module order the two can differ, and minFillAnchor must gate the
        // real advance. For an identity order delta == fillAmount, so behavior is
        // unchanged.
        if (block.timestamp > order.deadline) revert OrderExpired();

        uint256 overrideBps = _exclusivity(order, filler);
        if (_isNonceCancelled(order.maker, order.nonce)) revert NonceCancelled();
        _runValidators(order, filler, takerData);

        // `takerData` doubles as the filler's fill proposal for a fill-module
        // order (see {IFillModule}); a plain fungible order ignores it here.
        FillCtx memory ctx = _openFill(order, orderHash, fillAmount, overrideBps, filler, takerData);

        // The SAME takerData feeds the post-execution invariants (via the settle
        // helper), so a validator and an invariant see an identical filler blob.
        return mode == CallbackMode.PostInputs
            ? _settlePostInputs(order, ctx, callbackTarget, callbackData, takerData)
            : _settleForward(order, ctx, callbackTarget, callbackData, takerData);
    }

    /// @dev Exclusivity gate. Inside the window only the nominated filler fills
    ///      for free; a non-exclusive filler is blocked (hard exclusivity) or
    ///      allowed against an `exclusivityOverrideBps` price improvement it must
    ///      pay the maker (soft exclusivity). Returns the override, 0 otherwise.
    function _exclusivity(Order calldata order, address filler) internal view returns (uint256 overrideBps) {
        if (
            order.exclusiveFiller != address(0) && block.timestamp < order.exclusivityEndTime
                && filler != order.exclusiveFiller
        ) {
            if (order.exclusivityOverrideBps == 0) revert NotExclusiveFiller();
            overrideBps = order.exclusivityOverrideBps;
        }
    }

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
        filled[orderHash] = newFilled;
        ctx = FillCtx(orderHash, total, prevFilled, newFilled, overrideBps, filler, prevFilled == 0 && newFilled == total);
    }

    /// @dev Forward flow: optional callback → deliver outputs → items → pay
    ///      inputs → invariants. The callback runs BEFORE any funds move, routed
    ///      through the allowance-less EXECUTOR (cannot leverage Settlement's
    ///      Permit3 spender status) and under `nonReentrant`.
    function _settleForward(
        Order calldata order,
        FillCtx memory ctx,
        address callbackTarget,
        bytes memory callbackData,
        bytes memory takerData
    ) internal returns (uint256[] memory outs) {
        if (callbackTarget != address(0)) EXECUTOR.execute(callbackTarget, callbackData);

        outs = _deliverOutputs(order, ctx);

        // Snapshot each tokenIn before items so the payout uses ONLY this fill's
        // TAKE proceeds — never a pre-existing/donated Settlement balance. Skipped
        // for item-free orders: with no TAKE legs there are no proceeds, so the
        // snapshot + the balanceOf re-read in `_payInputsToSolver` would just burn
        // two STATICCALLs per input leg on every plain swap.
        bool hasItems = order.items.length != 0;
        uint256[] memory tokenInBefore = hasItems ? _snapshotInputs(order.tokenIn) : new uint256[](0);
        _executeItems(order, ctx);
        _payInputsToSolver(order, ctx, tokenInBefore, hasItems);
        _runInvariants(order, ctx.filler, takerData);
        emit OrderFilled(ctx.orderHash, order.maker, ctx.filler);
    }

    /// @dev Reverse (PostInputs) flow: pay the solver its tokenIn FIRST, let the
    ///      callback convert it, THEN deliver tokenOut — a zero-inventory /
    ///      zero-flash swap (the Fusion takerInteraction order). Item-free only:
    ///      item flows have deposit→borrow dependencies that assume the forward
    ///      order. Delivery + invariants stay mandatory and reverting, so the
    ///      maker is made whole or the whole tx unwinds.
    function _settlePostInputs(
        Order calldata order,
        FillCtx memory ctx,
        address callbackTarget,
        bytes memory callbackData,
        bytes memory takerData
    ) internal returns (uint256[] memory outs) {
        if (order.items.length != 0) revert ReverseModeRequiresNoItems();
        // No items ⇒ no TAKE proceeds ⇒ proceeds are 0 by construction, so
        // `_payInputsToSolver` (hasItems=false) pulls exactly `owed` from the
        // maker → solver with no balance snapshot needed.
        _payInputsToSolver(order, ctx, new uint256[](0), false);
        if (callbackTarget != address(0)) EXECUTOR.execute(callbackTarget, callbackData);
        outs = _deliverOutputs(order, ctx);
        _runInvariants(order, ctx.filler, takerData);
        emit OrderFilled(ctx.orderHash, order.maker, ctx.filler);
    }

    /// @dev The fill denominator in anchor units: the FIXED side's leg 0 —
    ///      `startAmountIn[0]` (SELL) or `startAmountOut[0]` (BUY).
    function _anchorTotal(Order calldata order) internal pure returns (uint256) {
        return order.side == OrderSide.BUY ? order.startAmountOut[0] : order.startAmountIn[0];
    }

    /// @dev ceil(a / b), b > 0.
    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /// @dev Deliver every output leg for this fill, solver → the leg's recipient
    ///      (`recipientOut[j]`, `address(0)` = the maker — so a fee leg is just an
    ///      output addressed to the originator).
    ///      • SELL: outputs are auction-priced — each leg is `ceil(fillAmount ·
    ///        currentAmountOut / anchor)` at the current tick, so the maker is
    ///        never underpaid.
    ///      • BUY: outputs are FIXED — each leg is the cumulative ceil slice of
    ///        `startAmountOut[j]`, summing to exactly `startAmountOut[j]` at full
    ///        fill (and to `fillAmount` for j==0). Each leg pulls the solver's
    ///        `tokenOut` via Permit3, falling back to a direct ERC20 transferFrom
    ///        when the solver approved Settlement directly (see
    ///        `_transferFromWithFallback`).
    function _deliverOutputs(Order calldata order, FillCtx memory ctx) internal returns (uint256[] memory outs) {
        uint256 n = order.tokenOut.length;
        outs = new uint256[](n);
        bool buy = order.side == OrderSide.BUY;
        uint256 anchor = ctx.anchor;
        // SELL outputs are auction-priced; the decay bump is shared by all legs, so
        // compute it at most once — sentinel uint256.max = "not yet computed" (a real
        // bump is always ≤ 10000). Lazy so an all-fixed order never calls bumpBps.
        uint256 bump = type(uint256).max;
        for (uint256 j; j < n;) {
            uint256 amt;
            if (buy) {
                // Fixed output — the exact-output guarantee; never overridden.
                uint256 fixedOut = order.startAmountOut[j];
                amt = ctx.fullFill
                    ? fixedOut
                    : _ceilDiv(fixedOut * ctx.newFilled, anchor) - _ceilDiv(fixedOut * ctx.prevFilled, anchor);
            } else {
                if (order.startAmountOut[j] != order.endAmountOut[j] && bump == type(uint256).max) {
                    bump = order.bumpBps();
                }
                amt = _ceilDiv((ctx.newFilled - ctx.prevFilled) * order.amountOutAt(j, bump), anchor);
            }
            if (amt != 0) {
                address to = order.recipientOut[j];
                bool makerLeg = to == address(0) || to == order.maker;
                // Soft-exclusivity override: a non-exclusive in-window filler must
                // deliver MORE output. The improvement is the MAKER's compensation
                // for a bypassed exclusive filler, so it applies ONLY to the
                // maker's own SELL output legs — never a fee leg addressed to a
                // third party (which would leak the comp to the fee recipient and
                // break an "absolute" fee), and never BUY (fixed exact-output).
                // Mirrors the input side, where the override adjusts only the
                // maker's charge (fee/relayer legs are auctioned, not overridden
                // upward).
                if (!buy && ctx.overrideBps != 0 && makerLeg) {
                    amt = _ceilDiv(amt * (10_000 + ctx.overrideBps), 10_000);
                }
                outs[j] = amt;
                Permit3TransferLib.transferFromWithFallback(
                    PERMIT3, order.tokenOut[j], ctx.filler, makerLeg ? order.maker : to, amt
                );
            }
            unchecked {
                ++j;
            }
        }
    }

    /// @dev Snapshot Settlement's balance of every input token before items run.
    function _snapshotInputs(address[] calldata tokens) internal view returns (uint256[] memory bals) {
        uint256 n = tokens.length;
        bals = new uint256[](n);
        for (uint256 i; i < n;) {
            bals[i] = SafeTransferLib.balanceOf(tokens[i], address(this));
            unchecked {
                ++i;
            }
        }
    }

    /// @dev For each item, execute the slice attributable to this fill:
    ///      slice = item.amount * newFilled / anchor
    ///            - item.amount * prevFilled / anchor
    ///      Sums to exactly item.amount once the order is fully filled.
    function _executeItems(Order calldata order, FillCtx memory ctx) internal {
        for (uint256 i; i < order.items.length; i++) {
            Item calldata item = order.items[i];
            uint256 slice = ctx.fullFill
                ? item.amount
                : (item.amount * ctx.newFilled) / ctx.anchor - (item.amount * ctx.prevFilled) / ctx.anchor;
            if (slice == 0) continue;

            if (item.op == ItemOp.MAKE) {
                // Maker module pulls the funding token from order.maker via Permit3 internally.
                IMakerModule(item.module).makeOnBehalf(order.maker, slice, item.data);
            } else if (item.op == ItemOp.TAKE) {
                // Taker: Permit3 enforces the gate and dispatches. `recipient = 0` is the
                // classic flow (proceeds to Settlement for tokenIn payout); signing a
                // non-zero recipient (e.g. the maker) chains output into a subsequent item.
                address to = item.recipient == address(0) ? address(this) : item.recipient;
                PERMIT3.take(item.module, order.maker, uint160(slice), to, item.data);
            } else {
                // SETTLE: generic solver↔maker exchange — the FILLER-AWARE fallback
                // for exchanges the typed legs can't express (see {ISettlementModule}).
                // The module acts under the maker's signature + its own maker approval;
                // passing `ctx.filler` lets the maker's asset route to whoever fills. The
                // maker's receipt is guaranteed by the mandatory tokenOut delivery (run
                // before items) and/or an invariant, not by the module.
                ISettlementModule(item.module).settle(order.maker, ctx.filler, slice, item.data);
            }
        }
    }

    /// @dev Pay every input leg to the solver for this fill.
    ///      • Fixed leg (`start == end`, the common SELL input): `owed_i` is the
    ///        cumulative floor slice of `startAmountIn[i]`, summing to exactly
    ///        `startAmountIn[i]` at full fill (and to `fillAmount` for i==0) —
    ///        the exact-input guarantee.
    ///      • Auctioned leg (`start != end`): `owed_i = floor(fillAmount ·
    ///        currentAmountIn / anchor)` at the current tick — rising
    ///        `start → end`, gas bump included; the maker is never overcharged
    ///        and the total never exceeds `endAmountIn[i]`. Every BUY conversion
    ///        input is such a leg; on SELL it is the relayer-fee auction for
    ///        orders with no conversion output to price a filler's compensation
    ///        into (e.g. a pure gasless deposit).
    ///
    ///      Soft exclusivity applies to every auctioned input leg: a
    ///      non-exclusive in-window filler charges `overrideBps` less — the
    ///      auction leg moves toward the maker.
    ///
    ///      Each leg uses ONLY the TAKE proceeds produced by THIS fill (the
    ///      balance delta since `tokenInBefore[i]`) — so a pre-existing/donated
    ///      Settlement balance can never be redirected to the solver. Any
    ///      shortfall is pulled from the maker via Permit3 (falling back to a
    ///      direct ERC20 transferFrom if the maker approved Settlement directly);
    ///      any surplus proceeds are returned to the maker, not stranded.
    function _payInputsToSolver(
        Order calldata order,
        FillCtx memory ctx,
        uint256[] memory tokenInBefore,
        bool hasItems
    ) internal {
        address maker = order.maker;
        address filler = ctx.filler;
        uint256 anchor = ctx.anchor;
        bool buy = order.side == OrderSide.BUY;
        uint256 fillAmount = ctx.newFilled - ctx.prevFilled;
        // BUY inputs are auction-priced; shared bump computed once (sentinel = max).
        uint256 bump = type(uint256).max;
        for (uint256 i; i < order.tokenIn.length; i++) {
            uint256 owed;
            // Auctioned input: any leg with `start != end` (all BUY conversion
            // inputs; on SELL, the rising relayer-fee leg). `buy` short-circuits
            // so a fixed BUY leg still takes the auction path's amountInAt
            // (which returns the fixed amount) — preserving BUY's per-fill
            // floor rounding exactly as before.
            if (buy || order.startAmountIn[i] != order.endAmountIn[i]) {
                if (order.startAmountIn[i] != order.endAmountIn[i] && bump == type(uint256).max) {
                    bump = order.bumpBps();
                }
                owed = (fillAmount * order.amountInAt(i, bump)) / anchor;
                // Soft-exclusivity override: a non-exclusive in-window filler must
                // charge LESS input (the auction leg moves toward the maker).
                if (ctx.overrideBps != 0) owed = (owed * (10_000 - ctx.overrideBps)) / 10_000;
            } else {
                // Fixed input — the exact-input guarantee; never overridden.
                uint256 amt = order.startAmountIn[i];
                owed = ctx.fullFill ? amt : (amt * ctx.newFilled) / anchor - (amt * ctx.prevFilled) / anchor;
            }
            address tokenIn = order.tokenIn[i];
            // Item-free orders have no TAKE proceeds ⇒ proceeds are 0 without a
            // balanceOf (the snapshot was skipped upstream). Item orders measure
            // this fill's proceeds as the balance delta since the snapshot.
            uint256 proceeds = hasItems ? SafeTransferLib.balanceOf(tokenIn, address(this)) - tokenInBefore[i] : 0;
            if (owed == 0) {
                // Nothing owed on this leg (dust slice, or a zero-amount leg),
                // but any TAKE proceeds for this token must still be returned to
                // the maker — never stranded in Settlement (there is no sweep).
                // Zero-guarded against no-op transfers on strict tokens.
                if (proceeds != 0) SafeTransferLib.safeTransfer(tokenIn, maker, proceeds);
                continue;
            }
            if (proceeds >= owed) {
                SafeTransferLib.safeTransfer(tokenIn, filler, owed);
                unchecked {
                    uint256 surplus = proceeds - owed; // proceeds >= owed
                    if (surplus > 0) SafeTransferLib.safeTransfer(tokenIn, maker, surplus);
                }
            } else {
                if (proceeds > 0) SafeTransferLib.safeTransfer(tokenIn, filler, proceeds);
                unchecked {
                    Permit3TransferLib.transferFromWithFallback(PERMIT3, tokenIn, maker, filler, owed - proceeds); // owed > proceeds
                }
            }
        }
    }

    // ──────────────────── Validators / invariants ────────────────────

    /// @dev Pre-execution staticcall validators. `filler` is the address executing
    ///      this fill (threaded from msg.sender, or from batchFill's caller), so a
    ///      maker-signed validator can express filler-conditional policy. The shared
    ///      `takerData` (filler-supplied, unsigned, adversarial — see
    ///      {IOrderValidator}) is passed to every validator.
    function _runValidators(Order calldata order, address filler, bytes memory takerData) internal view {
        uint256 len = order.validators.length;
        for (uint256 i; i < len;) {
            Validator calldata v = order.validators[i];
            if (!_gatePasses(v.target, order, filler, v.data, takerData)) revert ValidationFailed(i);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Staticcall `target.validate(order, filler, data, takerData)` and return
    ///      whether it passed (call ok AND ≥32 bytes returned AND the bool word ==
    ///      1). The single-word return is read into scratch space, avoiding the
    ///      `bytes memory` return allocation the abstract call would make. `data` is
    ///      the maker-signed per-validator config; `takerData` is the shared
    ///      filler-supplied blob (a validator must independently verify it).
    function _gatePasses(
        address target,
        Order calldata order,
        address filler,
        bytes calldata data,
        bytes memory takerData
    ) private view returns (bool pass) {
        bytes memory cd = abi.encodeCall(IOrderValidator.validate, (order, filler, data, takerData));
        /// @solidity memory-safe-assembly
        assembly {
            let ok := staticcall(gas(), target, add(cd, 0x20), mload(cd), 0x00, 0x20)
            pass := and(and(ok, gt(returndatasize(), 31)), eq(mload(0x00), 1))
        }
    }

    /// @dev Post-execution staticcall invariants. Same shape as validators
    ///      (including the threaded `filler` and the shared `takerData`) but run
    ///      AFTER items execute, so they can assert on the order's side effects
    ///      (e.g. "maker's Aave health factor ≥ 2.0").
    function _runInvariants(Order calldata order, address filler, bytes memory takerData) internal view {
        uint256 len = order.invariants.length;
        for (uint256 i; i < len;) {
            Validator calldata v = order.invariants[i];
            if (!_gatePasses(v.target, order, filler, v.data, takerData)) revert InvariantFailed(i);
            unchecked {
                ++i;
            }
        }
    }

    function _verifySignature(bytes32 orderHash, bytes calldata sig, address expected) internal view {
        // Signature-less path: an EMPTY `sig` authorizes against the maker's on-chain
        // {approveOrder} record instead of a signature. No valid signature has zero
        // length (the shared verifier rejects it), so the sentinel can never collide
        // with a real one. This lets a maker that cannot sign — e.g. a multisig
        // without EIP-1271 — still place orders. Every other fill gate is unchanged.
        if (sig.length == 0) {
            if (!orderApproved[expected][orderHash]) revert OrderNotApproved();
            return;
        }
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), orderHash));
        // Shared verifier: EOA (ecrecover), EIP-1271 contract wallets, and
        // EIP-7702 accounts (raw-key or delegated-1271) are all accepted.
        SignatureVerification.verify(sig, digest, expected);
    }
}
