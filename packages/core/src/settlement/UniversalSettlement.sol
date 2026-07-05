// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPermit3} from "../interfaces/IPermit3.sol";
import {IMakerModule} from "../interfaces/IMakerModule.sol";
import {IOrderValidator} from "../interfaces/IOrderValidator.sol";
import {SignatureVerification} from "../permit3/SignatureVerification.sol";
import {SafeTransferLib} from "../utils/SafeTransferLib.sol";

// Re-exported so downstream files can keep importing the order types from here.
import {Order, Item, ItemOp, Validator} from "./SettlementStructs.sol";
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

    bytes32 public immutable DOMAIN_SEPARATOR;
    IPermit3 public immutable PERMIT3;

    /// @notice Allowance-less trampoline for `fillWithCallback` (see the contract
    ///         for the security rationale). Deployed here so it is dedicated to
    ///         this Settlement and can never be an approved Permit3 spender.
    SolverCallbackExecutor public immutable EXECUTOR;

    /// @notice orderHash → cumulative filled amountIn
    mapping(bytes32 => uint256) public filledAmountIn;

    uint256 private _locked = 1;

    // ──────────────────── Events ────────────────────

    event OrderFilled(
        bytes32 indexed orderHash,
        address indexed maker,
        address indexed solver,
        uint256 fillAmountIn,
        uint256[] fillAmountsOut
    );

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

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(address permit3) {
        PERMIT3 = IPermit3(permit3);
        EXECUTOR = new SolverCallbackExecutor();
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("UniversalSettlement"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    // ──────────────────── Fill ────────────────────

    /// @notice Fill (up to) `fillAmountIn` of an order. Partial fills allowed.
    ///         Lending items are executed pro-rata for this fill's slice.
    function fill(Order calldata order, bytes calldata sig, uint256 fillAmountIn)
        external
        nonReentrant
        returns (uint256[] memory fillAmountsOut)
    {
        bytes32 orderHash = order.hash();
        _verifySignature(orderHash, sig, order.maker);
        return _fillCore(order, orderHash, fillAmountIn, address(0), "");
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
    function fillWithCallback(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmountIn,
        address callbackTarget,
        bytes calldata callbackData
    ) external nonReentrant returns (uint256[] memory fillAmountsOut) {
        bytes32 orderHash = order.hash();
        _verifySignature(orderHash, sig, order.maker);
        return _fillCore(order, orderHash, fillAmountIn, callbackTarget, callbackData);
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
        uint256 fillAmountIn
    ) external nonReentrant returns (uint256[] memory fillAmountsOut) {
        bytes32 orderHash = order.hash();
        // Permit3 verifies the sig against (PermitBatchWitness + orderHash) and
        // applies all allowances. The order itself doesn't need a separate sig
        // — the witness binding makes the permit endorse this exact order.
        PERMIT3.permitBatchWithWitness(order.maker, batch, orderHash, OrderHash.WITNESS_TYPESTRING, sig);
        return _fillCore(order, orderHash, fillAmountIn, address(0), "");
    }

    function _fillCore(
        Order calldata order,
        bytes32 orderHash,
        uint256 fillAmountIn,
        address callbackTarget,
        bytes memory callbackData
    ) internal returns (uint256[] memory fillAmountsOut) {
        if (fillAmountIn == 0) revert ZeroFill();
        if (fillAmountIn < order.minFillAmountIn) revert FillTooSmall();
        if (block.timestamp > order.deadline) revert OrderExpired();

        // Exclusivity window — if set, only the nominated filler may fill until
        // `exclusivityEndTime`. After that, anyone can fill.
        if (
            order.exclusiveFiller != address(0) && block.timestamp < order.exclusivityEndTime
                && msg.sender != order.exclusiveFiller
        ) revert NotExclusiveFiller();

        if (_isNonceCancelled(order.maker, order.nonce)) revert NonceCancelled();

        _runValidators(order);

        // amountIn[0] is the fill denominator; fillAmountIn is in tokenIn[0] units.
        uint256 amountIn0 = order.amountIn[0];
        uint256 prevFilled = filledAmountIn[orderHash];
        uint256 newFilled = prevFilled + fillAmountIn;
        if (newFilled > amountIn0) revert OverFill();
        filledAmountIn[orderHash] = newFilled;

        // 0. Optional solver callback (taker-interaction analogue). Runs BEFORE
        //    any funds move, so a zero-inventory solver can source `tokenOut`
        //    just-in-time. Routed through EXECUTOR (allowance-less), never called
        //    from Settlement itself, so it cannot leverage Settlement's Permit3
        //    spender status. Under `nonReentrant`, so it cannot re-enter a fill.
        if (callbackTarget != address(0)) {
            EXECUTOR.execute(callbackTarget, callbackData);
        }

        // 1. Solver → maker: each tokenOut, auction-priced, pro-rata this fill.
        fillAmountsOut = _deliverOutputs(order, fillAmountIn, amountIn0);

        // Snapshot each tokenIn before items so the payout uses ONLY this fill's
        // TAKE proceeds — never any pre-existing/donated balance held by
        // Settlement. Output delivery is a direct solver→maker transfer, so it
        // never touches Settlement's tokenIn balance.
        uint256[] memory tokenInBefore = _snapshotInputs(order.tokenIn);

        // 2. Pro-rata operation items for this fill
        _executeItems(order, prevFilled, newFilled);

        // 3. Settle each tokenIn → solver. TAKE items route proceeds to this
        //    contract; any shortfall is pulled from the maker via Permit3.
        _payInputsToSolver(order, prevFilled, newFilled, amountIn0, tokenInBefore);

        // 4. Post-execution invariants (e.g. "my Aave health factor ≥ 2.0 after this fill").
        _runInvariants(order);

        emit OrderFilled(orderHash, order.maker, msg.sender, fillAmountIn, fillAmountsOut);
    }

    /// @dev Deliver every output leg solver→maker for this fill. Each output is
    ///      priced at its current auction tick and scaled by the fill fraction
    ///      `fillAmountIn / amountIn0`, ceil-rounded so the maker is never
    ///      underpaid. Permit3 enforces the solver's token allowance to this
    ///      contract on each leg.
    function _deliverOutputs(Order calldata order, uint256 fillAmountIn, uint256 amountIn0)
        internal
        returns (uint256[] memory outs)
    {
        uint256 n = order.tokenOut.length;
        outs = new uint256[](n);
        for (uint256 j; j < n; j++) {
            uint256 currentOut = order.currentAmountOutAt(j);
            // ceilDiv — maker never underpaid at current auction rate
            uint256 amt = (fillAmountIn * currentOut + amountIn0 - 1) / amountIn0;
            outs[j] = amt;
            if (amt != 0) {
                PERMIT3.transferFrom(msg.sender, order.maker, order.tokenOut[j], uint160(amt));
            }
        }
    }

    /// @dev Snapshot Settlement's balance of every input token before items run.
    function _snapshotInputs(address[] calldata tokens) internal view returns (uint256[] memory bals) {
        uint256 n = tokens.length;
        bals = new uint256[](n);
        for (uint256 i; i < n; i++) {
            bals[i] = IERC20(tokens[i]).balanceOf(address(this));
        }
    }

    /// @dev For each item, execute the slice attributable to this fill:
    ///      slice = item.amount * newFilled / amountIn
    ///            - item.amount * prevFilled / amountIn
    ///      Sums to exactly item.amount once the order is fully filled.
    function _executeItems(Order calldata order, uint256 prevFilled, uint256 newFilled) internal {
        uint256 amountIn = order.amountIn[0];
        for (uint256 i; i < order.items.length; i++) {
            Item calldata item = order.items[i];
            uint256 slice = (item.amount * newFilled) / amountIn - (item.amount * prevFilled) / amountIn;
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

    /// @dev Pay every input leg to the solver for this fill. Each `tokenIn[i]`
    ///      owes a cumulative pro-rata slice
    ///          owed_i = amountIn[i]·newFilled/amountIn0 - amountIn[i]·prevFilled/amountIn0
    ///      which sums exactly to `amountIn[i]` at full fill; for i==0 it equals
    ///      `fillAmountIn` exactly (no rounding, since amountIn0 == amountIn[0]).
    ///
    ///      Each leg uses ONLY the TAKE proceeds produced by THIS fill (the
    ///      balance delta since `tokenInBefore[i]`) — so a pre-existing/donated
    ///      Settlement balance can never be redirected to the solver. Any
    ///      shortfall is pulled from the maker via Permit3 (the maker's token
    ///      allowance is the gate); any surplus proceeds are returned to the
    ///      maker, not stranded.
    function _payInputsToSolver(
        Order calldata order,
        uint256 prevFilled,
        uint256 newFilled,
        uint256 amountIn0,
        uint256[] memory tokenInBefore
    ) internal {
        address maker = order.maker;
        for (uint256 i; i < order.tokenIn.length; i++) {
            uint256 amt = order.amountIn[i];
            uint256 owed = (amt * newFilled) / amountIn0 - (amt * prevFilled) / amountIn0;
            if (owed == 0) continue;

            address tokenIn = order.tokenIn[i];
            uint256 proceeds = IERC20(tokenIn).balanceOf(address(this)) - tokenInBefore[i];
            if (proceeds >= owed) {
                SafeTransferLib.safeTransfer(tokenIn, msg.sender, owed);
                uint256 surplus = proceeds - owed;
                if (surplus > 0) SafeTransferLib.safeTransfer(tokenIn, maker, surplus);
            } else {
                if (proceeds > 0) SafeTransferLib.safeTransfer(tokenIn, msg.sender, proceeds);
                PERMIT3.transferFrom(maker, msg.sender, tokenIn, uint160(owed - proceeds));
            }
        }
    }

    // ──────────────────── Validators / invariants ────────────────────

    function _runValidators(Order calldata order) internal view {
        for (uint256 i; i < order.validators.length; i++) {
            Validator calldata v = order.validators[i];
            (bool ok, bytes memory ret) = v.target.staticcall(abi.encodeCall(IOrderValidator.validate, (order, v.data)));
            if (!ok || ret.length < 32 || !abi.decode(ret, (bool))) {
                revert ValidationFailed(i);
            }
        }
    }

    /// @dev Post-execution staticcall invariants. Same shape as validators but
    ///      run AFTER items execute, so they can assert on the order's side
    ///      effects (e.g. "maker's Aave health factor ≥ 2.0").
    function _runInvariants(Order calldata order) internal view {
        for (uint256 i; i < order.invariants.length; i++) {
            Validator calldata v = order.invariants[i];
            (bool ok, bytes memory ret) = v.target.staticcall(abi.encodeCall(IOrderValidator.validate, (order, v.data)));
            if (!ok || ret.length < 32 || !abi.decode(ret, (bool))) {
                revert InvariantFailed(i);
            }
        }
    }

    function _verifySignature(bytes32 orderHash, bytes calldata sig, address expected) internal view {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, orderHash));
        // Shared verifier: EOA (ecrecover), EIP-1271 contract wallets, and
        // EIP-7702 accounts (raw-key or delegated-1271) are all accepted.
        SignatureVerification.verify(sig, digest, expected);
    }

    // ──────────────────── Views ────────────────────

    function hashOrder(Order calldata order) external pure returns (bytes32) {
        return order.hash();
    }

    function previewAmountOut(Order calldata order) external view returns (uint256[] memory) {
        return order.currentAmountOut();
    }

    function remaining(Order calldata order) external view returns (uint256) {
        return order.amountIn[0] - filledAmountIn[order.hash()];
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
    ///         is a legitimate config): any `0 < minFillAmountIn < amountIn` lets
    ///         a solver leave a remainder smaller than `minFillAmountIn` that can
    ///         then never be filled. Only `minFillAmountIn ∈ {0, amountIn}`
    ///         guarantees no unfillable tail.
    function validateOrder(Order calldata order) external view returns (bool ok, string memory reason) {
        // ── array shape ──
        uint256 nIn = order.tokenIn.length;
        if (nIn == 0 || nIn != order.amountIn.length) return (false, "tokenIn/amountIn length mismatch");
        uint256 nOut = order.tokenOut.length;
        if (nOut == 0 || nOut != order.startAmountOut.length || nOut != order.endAmountOut.length) {
            return (false, "tokenOut/amountOut length mismatch");
        }

        // ── structural / economic sanity (time-independent) ──
        if (order.amountIn[0] == 0) return (false, "amountIn is zero");
        for (uint256 j; j < nOut; j++) {
            if (order.startAmountOut[j] == 0) return (false, "startAmountOut is zero (giveaway)");
            if (order.startAmountOut[j] < order.endAmountOut[j]) return (false, "startAmountOut < endAmountOut");
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
        if (order.minFillAmountIn > order.amountIn[0]) return (false, "minFillAmountIn > amountIn (unfillable)");
        if (order.decayDuration != 0 && order.decayStartTime == 0) return (false, "decay set without decayStartTime");

        // ── current fillability (time/state-dependent) ──
        if (order.deadline < block.timestamp) return (false, "order expired");
        if (_isNonceCancelled(order.maker, order.nonce)) return (false, "nonce cancelled");
        if (filledAmountIn[order.hash()] >= order.amountIn[0]) return (false, "order fully filled");

        return (true, "");
    }
}
