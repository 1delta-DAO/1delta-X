// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPermit3} from "../interfaces/IPermit3.sol";
import {IMakerModule} from "../interfaces/IMakerModule.sol";
import {IOrderValidator} from "../interfaces/IOrderValidator.sol";
import {SignatureVerification} from "../permit3/SignatureVerification.sol";
import {SafeTransferLib} from "../utils/SafeTransferLib.sol";
import {Permit3TransferLib} from "../utils/Permit3TransferLib.sol";
import {FeeConfig} from "../utils/FeeConfig.sol";

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
    error ReverseModeRequiresNoItems();
    /// @dev Fee over `MAX_FEE_BPS`, or a non-zero fee with a zero recipient
    ///      (which would otherwise burn the skim to `address(0)`).
    error InvalidFee();

    /// @notice Where the solver callback runs relative to settlement, chosen by
    ///         the filler in `fillWithCallback`.
    enum CallbackMode {
        PreDelivery, // callback → deliver outputs → items → pay inputs (works for any order)
        PostInputs // pay inputs → callback → deliver outputs (item-free only; JIT-from-proceeds)
    }

    /// @notice Lifecycle status for the solver-preflight view. Mirrors 0x's
    ///         `OrderStatus` so an off-chain filler can classify an order from a
    ///         single `getOrderRelevantState` call.
    enum OrderStatus {
        Invalid, // malformed (bad array shape) — can never fill
        Fillable, // open, at least one unit still fillable
        Filled, // fully filled
        Cancelled, // nonce bit set, or below the maker's rollback floor
        Expired // past deadline
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
    function fill(Order calldata order, bytes calldata sig, uint256 fillAmount)
        external
        nonReentrant
        returns (uint256[] memory fillAmountsOut)
    {
        bytes32 orderHash = order.hash();
        _verifySignature(orderHash, sig, order.maker);
        return _fillCore(order, orderHash, fillAmount, msg.sender, address(0), "", CallbackMode.PreDelivery);
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
        return _fillCore(order, orderHash, fillAmount, msg.sender, callbackTarget, callbackData, mode);
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
        return _fillCore(order, orderHash, fillAmount, msg.sender, address(0), "", CallbackMode.PreDelivery);
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
            try this.fillSelf(orders[i], sigs[i], fillAmounts[i], filler) returns (uint256[] memory outs) {
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
    ///         and runs the fill for an explicit `filler`. `onlySelf` — external
    ///         callers must use `fill`.
    function fillSelf(Order calldata order, bytes calldata sig, uint256 fillAmount, address filler)
        external
        returns (uint256[] memory)
    {
        if (msg.sender != address(this)) revert OnlySelf();
        bytes32 orderHash = order.hash();
        _verifySignature(orderHash, sig, order.maker);
        return _fillCore(order, orderHash, fillAmount, filler, address(0), "", CallbackMode.PreDelivery);
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
        CallbackMode mode
    ) internal returns (uint256[] memory) {
        if (fillAmount == 0) revert ZeroFill();
        if (fillAmount < order.minFillAnchor) revert FillTooSmall();
        if (block.timestamp > order.deadline) revert OrderExpired();

        uint256 overrideBps = _exclusivity(order, filler);
        if (_isNonceCancelled(order.maker, order.nonce)) revert NonceCancelled();
        _runValidators(order);

        FillCtx memory ctx = _openFill(order, orderHash, fillAmount, overrideBps, filler);

        return mode == CallbackMode.PostInputs
            ? _settlePostInputs(order, ctx, callbackTarget, callbackData)
            : _settleForward(order, ctx, callbackTarget, callbackData);
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

    /// @dev Reserve this fill's slice: check over-fill and bump the cumulative
    ///      counter, then package the context. The anchor is the FIXED side's leg
    ///      0 (`tokenIn[0]` for SELL, `tokenOut[0]` for BUY).
    function _openFill(
        Order calldata order,
        bytes32 orderHash,
        uint256 fillAmount,
        uint256 overrideBps,
        address filler
    ) internal returns (FillCtx memory ctx) {
        uint256 anchor = _anchorTotal(order);
        uint256 prevFilled = filled[orderHash];
        uint256 newFilled = prevFilled + fillAmount;
        if (newFilled > anchor) revert OverFill();
        filled[orderHash] = newFilled;
        ctx = FillCtx(orderHash, anchor, prevFilled, newFilled, overrideBps, filler, prevFilled == 0 && newFilled == anchor);
    }

    /// @dev Forward flow: optional callback → deliver outputs → items → pay
    ///      inputs → invariants. The callback runs BEFORE any funds move, routed
    ///      through the allowance-less EXECUTOR (cannot leverage Settlement's
    ///      Permit3 spender status) and under `nonReentrant`.
    function _settleForward(
        Order calldata order,
        FillCtx memory ctx,
        address callbackTarget,
        bytes memory callbackData
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
        _runInvariants(order);
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
        bytes memory callbackData
    ) internal returns (uint256[] memory outs) {
        if (order.items.length != 0) revert ReverseModeRequiresNoItems();
        // No items ⇒ no TAKE proceeds ⇒ proceeds are 0 by construction, so
        // `_payInputsToSolver` (hasItems=false) pulls exactly `owed` from the
        // maker → solver with no balance snapshot needed.
        _payInputsToSolver(order, ctx, new uint256[](0), false);
        if (callbackTarget != address(0)) EXECUTOR.execute(callbackTarget, callbackData);
        outs = _deliverOutputs(order, ctx);
        _runInvariants(order);
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

    /// @dev Deliver every output leg solver→maker for this fill.
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
        // Optional sourcing fee: skim `feeBps` of each delivered leg to the fee
        // recipient. The solver's total delivery is unchanged (amt = maker + fee);
        // the maker forgoes the fee, having signed `feeConfig`. `outs[j]` records
        // the GROSS `amt` so events/previews stay solver-denominated.
        (address feeRecipient, uint256 feeBps) = FeeConfig.unpack(order.feeConfig);
        // Bound the fee and forbid a non-zero fee with no recipient (would burn
        // the skim to address(0)). feeBps == 0 disables the skim entirely.
        if (feeBps > FeeConfig.MAX_FEE_BPS) revert InvalidFee();
        if (feeBps != 0 && feeRecipient == address(0)) revert InvalidFee();
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
                // Soft-exclusivity override: a non-exclusive in-window filler must
                // deliver MORE output (the auction leg moves toward the maker).
                if (ctx.overrideBps != 0) amt = _ceilDiv(amt * (10_000 + ctx.overrideBps), 10_000);
            }
            outs[j] = amt;
            if (amt != 0) {
                // fee floors, so the maker keeps the rounding remainder.
                uint256 fee = feeBps == 0 ? 0 : (amt * feeBps) / 10_000;
                if (amt - fee != 0) {
                    Permit3TransferLib.transferFromWithFallback(
                        PERMIT3, order.tokenOut[j], ctx.filler, order.maker, amt - fee
                    );
                }
                if (fee != 0) {
                    Permit3TransferLib.transferFromWithFallback(
                        PERMIT3, order.tokenOut[j], ctx.filler, feeRecipient, fee
                    );
                }
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
            } else {
                // Taker: Permit3 enforces the gate and dispatches. `recipient = 0` is the
                // classic flow (proceeds to Settlement for tokenIn payout); signing a
                // non-zero recipient (e.g. the maker) chains output into a subsequent item.
                address to = item.recipient == address(0) ? address(this) : item.recipient;
                PERMIT3.take(item.module, order.maker, uint160(slice), to, item.data);
            }
        }
    }

    /// @dev Pay every input leg to the solver for this fill.
    ///      • SELL: inputs are FIXED — `owed_i` is the cumulative floor slice of
    ///        `startAmountIn[i]`, summing to exactly `startAmountIn[i]` at full
    ///        fill (and to `fillAmount` for i==0).
    ///      • BUY: inputs are auction-priced — `owed_i = floor(fillAmount ·
    ///        currentAmountIn / anchor)` at the current tick, so the maker is
    ///        never overcharged and the total never exceeds `endAmountIn[i]`.
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
            if (buy) {
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
            if (owed == 0) continue;

            address tokenIn = order.tokenIn[i];
            // Item-free orders have no TAKE proceeds ⇒ proceeds are 0 without a
            // balanceOf (the snapshot was skipped upstream). Item orders measure
            // this fill's proceeds as the balance delta since the snapshot.
            uint256 proceeds = hasItems ? SafeTransferLib.balanceOf(tokenIn, address(this)) - tokenInBefore[i] : 0;
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

    function _runValidators(Order calldata order) internal view {
        uint256 len = order.validators.length;
        for (uint256 i; i < len;) {
            Validator calldata v = order.validators[i];
            if (!_gatePasses(v.target, order, v.data)) revert ValidationFailed(i);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Staticcall `target.validate(order, data)` and return whether it passed
    ///      (call ok AND ≥32 bytes returned AND the bool word == 1). The single-word
    ///      return is read into scratch space, avoiding the `bytes memory` return
    ///      allocation the abstract call would make.
    function _gatePasses(address target, Order calldata order, bytes calldata data)
        private
        view
        returns (bool pass)
    {
        bytes memory cd = abi.encodeCall(IOrderValidator.validate, (order, data));
        /// @solidity memory-safe-assembly
        assembly {
            let ok := staticcall(gas(), target, add(cd, 0x20), mload(cd), 0x00, 0x20)
            pass := and(and(ok, gt(returndatasize(), 31)), eq(mload(0x00), 1))
        }
    }

    /// @dev Post-execution staticcall invariants. Same shape as validators but
    ///      run AFTER items execute, so they can assert on the order's side
    ///      effects (e.g. "maker's Aave health factor ≥ 2.0").
    function _runInvariants(Order calldata order) internal view {
        uint256 len = order.invariants.length;
        for (uint256 i; i < len;) {
            Validator calldata v = order.invariants[i];
            if (!_gatePasses(v.target, order, v.data)) revert InvariantFailed(i);
            unchecked {
                ++i;
            }
        }
    }

    function _verifySignature(bytes32 orderHash, bytes calldata sig, address expected) internal view {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), orderHash));
        // Shared verifier: EOA (ecrecover), EIP-1271 contract wallets, and
        // EIP-7702 accounts (raw-key or delegated-1271) are all accepted.
        SignatureVerification.verify(sig, digest, expected);
    }

    // ──────────────────── Views ────────────────────

    function hashOrder(Order calldata order) external pure returns (bytes32) {
        return order.hash();
    }

    /// @notice Current output tick for every leg — the auction price for SELL, the
    ///         fixed output for BUY.
    function previewAmountOut(Order calldata order) external view returns (uint256[] memory) {
        return order.currentAmountOut();
    }

    /// @notice Current input tick for every leg — the rising auction price for BUY,
    ///         the fixed input for SELL.
    function previewAmountIn(Order calldata order) external view returns (uint256[] memory) {
        return order.currentAmountIn();
    }

    /// @notice Remaining fillable amount, in anchor units (`tokenIn[0]` for SELL,
    ///         `tokenOut[0]` for BUY).
    function remaining(Order calldata order) external view returns (uint256) {
        return _anchorTotal(order) - filled[order.hash()];
    }

    // ──────────────────── Solver preflight ────────────────────

    /// @notice One-call preflight for a solver/filler: classify the order, report
    ///         how much is ACTUALLY fillable right now (capped by the maker's live
    ///         Permit3 allowance + balance for plain orders), and whether the
    ///         signature recovers to the maker. The 0x `getOrderRelevantState`
    ///         analogue — lets a filler skip orders that would revert without
    ///         simulating the whole fill.
    /// @dev    `fillableAmount` is in anchor units (`tokenIn[0]` for SELL,
    ///         `tokenOut[0]` for BUY). For orders WITH items the tokenIn is
    ///         (partly) produced on-chain by TAKE legs, which can't be known
    ///         statically, so the allowance/balance cap is applied only to plain
    ///         (item-free) orders; item orders report the full remaining amount.
    ///         For BUY orders the maker-capacity cap uses each leg's worst-case
    ///         (ceiling) input tick, so it is a conservative lower bound. This is a
    ///         best-effort hint, not a guarantee — the fill remains the truth.
    function getOrderRelevantState(Order calldata order, bytes calldata sig)
        external
        view
        returns (OrderStatus status, uint256 fillableAmount, bool isSignatureValid)
    {
        bytes32 orderHash = order.hash();
        try this.checkSignature(orderHash, sig, order.maker) {
            isSignatureValid = true;
        } catch {
            isSignatureValid = false;
        }
        (status, fillableAmount) = _orderState(order, orderHash);
    }

    /// @notice Batch preflight. Any order that reverts (malformed, etc.) degrades
    ///         to `Invalid` / 0 / false instead of failing the whole call — the 0x
    ///         "swallows reverts" batch-state behaviour.
    function getOrderRelevantStates(Order[] calldata orders, bytes[] calldata sigs)
        external
        view
        returns (OrderStatus[] memory statuses, uint256[] memory fillableAmounts, bool[] memory sigValids)
    {
        uint256 n = orders.length;
        statuses = new OrderStatus[](n);
        fillableAmounts = new uint256[](n);
        sigValids = new bool[](n);
        for (uint256 i; i < n; i++) {
            try this.getOrderRelevantState(orders[i], sigs[i]) returns (OrderStatus s, uint256 f, bool v) {
                statuses[i] = s;
                fillableAmounts[i] = f;
                sigValids[i] = v;
            } catch {
                statuses[i] = OrderStatus.Invalid;
            }
        }
    }

    /// @notice External wrapper so the (reverting) signature check can be caught
    ///         by `try/catch` from a `view`. Reverts iff the signature is invalid.
    function checkSignature(bytes32 orderHash, bytes calldata sig, address expected) external view {
        _verifySignature(orderHash, sig, expected);
    }

    /// @dev Status + live-fillable amount (anchor units), without touching the sig.
    function _orderState(Order calldata order, bytes32 orderHash)
        internal
        view
        returns (OrderStatus status, uint256 fillableAmount)
    {
        // Malformed shape → Invalid (guards the array indexing below).
        uint256 nIn = order.tokenIn.length;
        uint256 nOut = order.tokenOut.length;
        if (
            nIn == 0 || order.startAmountIn.length != nIn || order.endAmountIn.length != nIn || nOut == 0
                || order.startAmountOut.length != nOut || order.endAmountOut.length != nOut
        ) {
            return (OrderStatus.Invalid, 0);
        }
        if (block.timestamp > order.deadline) return (OrderStatus.Expired, 0);
        if (_isNonceCancelled(order.maker, order.nonce)) return (OrderStatus.Cancelled, 0);

        uint256 anchor = _anchorTotal(order);
        uint256 done = filled[orderHash];
        if (done >= anchor) return (OrderStatus.Filled, 0);

        fillableAmount = anchor - done;
        // Plain orders: the maker funds tokenIn from their wallet, so cap the
        // fillable amount by their live capacity across every input leg.
        if (order.items.length == 0) {
            uint256 cap = _makerFillableCap(order, anchor);
            if (cap < fillableAmount) fillableAmount = cap;
        }
        status = OrderStatus.Fillable;
    }

    /// @dev Max fillable (anchor units) the maker can currently fund across all
    ///      input legs: min_i( capacity_i · anchor / perUnitIn_i ), where
    ///      capacity_i = min(live Permit3 allowance to this contract, balance) and
    ///      perUnitIn_i is the input cost of one anchor unit — the fixed
    ///      `startAmountIn[i]` for SELL, or the worst-case `endAmountIn[i]` for BUY
    ///      (so the BUY cap is a conservative lower bound and never depends on the
    ///      not-yet-started auction tick).
    function _makerFillableCap(Order calldata order, uint256 anchor) internal view returns (uint256 cap) {
        cap = type(uint256).max;
        bool buy = order.side == OrderSide.BUY;
        for (uint256 i; i < order.tokenIn.length; i++) {
            address token = order.tokenIn[i];
            (uint160 allowed, uint48 expiration,) = PERMIT3.tokenAllowance(order.maker, address(this), token);
            uint256 capacity = allowed;
            if (expiration != 0 && expiration < block.timestamp) capacity = 0; // allowance lapsed
            uint256 bal = SafeTransferLib.balanceOf(token, order.maker);
            if (bal < capacity) capacity = bal;

            uint256 perUnitIn = buy ? order.endAmountIn[i] : order.startAmountIn[i];
            // Scale leg-i capacity back into anchor units. Guard the multiply: an
            // unbounded (e.g. max) allowance times a large `anchor` can exceed
            // uint256 — treat an overflowing product as "this leg imposes no
            // binding cap" so this preflight view never reverts. `capacity == 0`
            // still falls through to a binding 0.
            uint256 inUnits;
            if (perUnitIn == 0) {
                inUnits = type(uint256).max; // leg needs nothing → no constraint
            } else if (capacity > type(uint256).max / anchor) {
                inUnits = type(uint256).max; // product overflows → non-binding
            } else {
                inUnits = (capacity * anchor) / perUnitIn;
            }
            if (inUnits < cap) cap = inUnits;
        }
    }

    /// @notice Off-chain / preview check for order well-formedness. Intentionally
    ///         NOT called during `fill` — fills stay cheap and unopinionated — so
    ///         call this from a maker UI, relayer, or test before signing or
    ///         submitting, to catch self-inflicted misparameterizations. Returns
    ///         the first problem found (`ok == false`), else `(true, "")`.
    ///
    /// @dev    Trust model: a malformed order can only ever harm its own maker
    ///         (all token moves are gated by the maker's signature + Permit3
    ///         allowances), so these are footgun guards, not protocol invariants.
    ///         Scope: structural/economic sanity + current fillability. It does
    ///         NOT judge whether the price is *good*.
    ///
    ///         Stranded-tail caveat (not flagged here, as partial-fill-with-floor
    ///         is a legitimate config): any `0 < minFillAnchor < anchor` lets
    ///         a solver leave a remainder smaller than `minFillAnchor` that can
    ///         then never be filled. Only `minFillAnchor ∈ {0, anchor}`
    ///         guarantees no unfillable tail.
    function validateOrder(Order calldata order) external view returns (bool ok, string memory reason) {
        // ── array shape ──
        uint256 nIn = order.tokenIn.length;
        if (nIn == 0 || nIn != order.startAmountIn.length || nIn != order.endAmountIn.length) {
            return (false, "tokenIn/amountIn length mismatch");
        }
        uint256 nOut = order.tokenOut.length;
        if (nOut == 0 || nOut != order.startAmountOut.length || nOut != order.endAmountOut.length) {
            return (false, "tokenOut/amountOut length mismatch");
        }

        // ── structural / economic sanity (time-independent) ──
        uint256 anchor = _anchorTotal(order);
        if (anchor == 0) return (false, "anchor amount is zero");
        if (order.side == OrderSide.SELL) {
            // Inputs fixed (start == end); outputs decay downward from a positive start.
            for (uint256 i; i < nIn; i++) {
                if (order.startAmountIn[i] != order.endAmountIn[i]) return (false, "sell input must be fixed");
            }
            for (uint256 j; j < nOut; j++) {
                if (order.startAmountOut[j] == 0) return (false, "startAmountOut is zero (giveaway)");
                if (order.startAmountOut[j] < order.endAmountOut[j]) return (false, "startAmountOut < endAmountOut");
            }
        } else {
            // Outputs fixed (start == end, positive); inputs rise upward to a ceiling.
            for (uint256 j; j < nOut; j++) {
                if (order.startAmountOut[j] == 0) return (false, "amountOut is zero (giveaway)");
                if (order.startAmountOut[j] != order.endAmountOut[j]) return (false, "buy output must be fixed");
            }
            for (uint256 i; i < nIn; i++) {
                if (order.endAmountIn[i] == 0) return (false, "endAmountIn is zero");
                if (order.endAmountIn[i] < order.startAmountIn[i]) return (false, "endAmountIn < startAmountIn");
            }
        }
        // Distinct within each array and disjoint across — the per-token proceeds
        // snapshot double-counts a shared balance, so overlap is forbidden in v1.
        for (uint256 i; i < nIn; i++) {
            for (uint256 k = i + 1; k < nIn; k++) {
                if (order.tokenIn[i] == order.tokenIn[k]) return (false, "duplicate tokenIn");
            }
            for (uint256 j; j < nOut; j++) {
                if (order.tokenIn[i] == order.tokenOut[j]) return (false, "tokenIn == tokenOut");
            }
        }
        for (uint256 j; j < nOut; j++) {
            for (uint256 k = j + 1; k < nOut; k++) {
                if (order.tokenOut[j] == order.tokenOut[k]) return (false, "duplicate tokenOut");
            }
        }
        if (order.minFillAnchor > anchor) return (false, "minFillAnchor > anchor (unfillable)");
        if (order.decayDuration != 0 && order.decayStartTime == 0) return (false, "decay set without decayStartTime");

        // ── soft exclusivity override ──
        if (order.exclusivityOverrideBps != 0) {
            if (order.exclusiveFiller == address(0)) return (false, "override without exclusiveFiller");
            if (order.exclusivityOverrideBps > 10_000) return (false, "exclusivityOverrideBps > 10000");
        }
        // ── piecewise auction curve (monotonic time, bounded bump) ──
        for (uint256 c; c < order.curve.length; c++) {
            if (order.curve[c].bumpBps > 10_000) return (false, "curve bumpBps > 10000");
            if (c != 0 && order.curve[c].timeDelta <= order.curve[c - 1].timeDelta) {
                return (false, "curve timeDelta not increasing");
            }
        }
        if (order.curve.length != 0 && order.decayStartTime == 0) return (false, "curve set without decayStartTime");
        // ── gas bump ──
        if (order.gasBumpBps != 0) {
            if (order.gasPriceRef == 0) return (false, "gasBump without gasPriceRef");
            if (order.gasBumpBps > 10_000) return (false, "gasBumpBps > 10000");
        }
        // ── sourcing fee ──
        {
            (address feeRecipient, uint256 feeBps) = FeeConfig.unpack(order.feeConfig);
            if (feeBps > FeeConfig.MAX_FEE_BPS) return (false, "feeBps > MAX_FEE_BPS");
            if (feeBps != 0 && feeRecipient == address(0)) return (false, "fee set without recipient");
        }

        // ── current fillability (time/state-dependent) ──
        if (order.deadline < block.timestamp) return (false, "order expired");
        if (_isNonceCancelled(order.maker, order.nonce)) return (false, "nonce cancelled");
        if (filled[order.hash()] >= anchor) return (false, "order fully filled");

        return (true, "");
    }
}
