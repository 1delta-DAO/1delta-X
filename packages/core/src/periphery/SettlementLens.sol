// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPermit3} from "../interfaces/IPermit3.sol";
import {IOrderValidator} from "../interfaces/IOrderValidator.sol";
import {SignatureVerification} from "../permit3/SignatureVerification.sol";
import {SafeTransferLib} from "../utils/SafeTransferLib.sol";
import {FeeConfig} from "../utils/FeeConfig.sol";

import {Order, Item, ItemOp, Validator, OrderSide, CurvePoint} from "../settlement/SettlementStructs.sol";
import {OrderHash} from "../settlement/OrderHash.sol";
import {DutchAuction} from "../settlement/DutchAuction.sol";

/// @dev The subset of {UniversalSettlement}'s public/external surface this lens
///      reads. All are views on the live settlement, so the lens never needs the
///      settler's internal storage layout — only its already-exposed getters.
interface ISettlementState {
    function filled(bytes32 orderHash) external view returns (uint256);
    function isNonceCancelled(address maker, uint256 nonce) external view returns (bool);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function PERMIT3() external view returns (IPermit3);
}

/// @title SettlementLens
/// @notice Read-only companion to {UniversalSettlement}. Holds the entire
///         off-chain preflight / preview / well-formedness surface a solver,
///         relayer, or maker UI calls BEFORE signing or submitting an order.
///         None of it runs during a fill, so it lives out here to keep the core
///         settler under the EIP-170 runtime-bytecode limit.
///
///         Every function is a pure/view helper over the order struct plus the
///         settlement's public state (`filled`, the nonce bitmap, live Permit3
///         allowances), read through {ISettlementState}. The lens holds no funds
///         and no approvals; it can only ever read.
contract SettlementLens {
    using OrderHash for Order;
    using DutchAuction for Order;

    /// @notice The settlement this lens reports on.
    ISettlementState public immutable SETTLEMENT;
    /// @notice Cached from the settlement at deploy — the Permit3 whose maker
    ///         allowances bound how much a plain order can actually fill.
    IPermit3 public immutable PERMIT3;

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

    constructor(address settlement) {
        SETTLEMENT = ISettlementState(settlement);
        PERMIT3 = ISettlementState(settlement).PERMIT3();
    }

    // ──────────────────── Order hash / previews ────────────────────

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
        return _anchorTotal(order) - SETTLEMENT.filled(order.hash());
    }

    // ──────────────────── Solver preflight ────────────────────

    /// @notice One-call preflight for a solver/filler: classify the order, report
    ///         how much is ACTUALLY fillable right now (capped by the maker's live
    ///         Permit3 allowance + balance for plain orders), whether the
    ///         signature recovers to the maker, and whether the order's
    ///         pre-execution validators currently pass for `filler`. The 0x
    ///         `getOrderRelevantState` analogue — lets a filler skip orders that
    ///         would revert without simulating the whole fill.
    /// @dev    `fillableAmount` is in anchor units (`tokenIn[0]` for SELL,
    ///         `tokenOut[0]` for BUY). For orders WITH items the tokenIn is
    ///         (partly) produced on-chain by TAKE legs, which can't be known
    ///         statically, so the allowance/balance cap is applied only to plain
    ///         (item-free) orders; item orders report the full remaining amount.
    ///         For BUY orders the maker-capacity cap uses each leg's worst-case
    ///         (ceiling) input tick, so it is a conservative lower bound. This is a
    ///         best-effort hint, not a guarantee — the fill remains the truth.
    /// @param  filler The would-be filler the validators are previewed for
    ///         (validators receive the filler address, so filler-conditional
    ///         orders — e.g. per-order solver whitelists — preview correctly).
    ///         `validatorsPass` covers `order.validators` only; post-execution
    ///         invariants depend on the fill's side effects and are not
    ///         previewable statically.
    /// @param  takerData The filler-supplied blob the filler intends to submit with
    ///         the fill (unsigned/adversarial — see {IOrderValidator}); previewed
    ///         through the validators exactly as the settlement would pass it, so a
    ///         takerData-consuming validator (e.g. an off-chain attestation gate)
    ///         previews correctly. Pass empty (`""`) for orders that don't use it.
    function getOrderRelevantState(Order calldata order, bytes calldata sig, address filler, bytes calldata takerData)
        external
        view
        returns (OrderStatus status, uint256 fillableAmount, bool isSignatureValid, bool validatorsPass)
    {
        bytes32 orderHash = order.hash();
        try this.checkSignature(orderHash, sig, order.maker) {
            isSignatureValid = true;
        } catch {
            isSignatureValid = false;
        }
        (status, fillableAmount) = _orderState(order, orderHash);
        validatorsPass = _validatorsPass(order, filler, takerData);
    }

    /// @notice Batch preflight (one `filler`, many orders — the common solver
    ///         loop). Any order that reverts (malformed, etc.) degrades to
    ///         `Invalid` / 0 / false instead of failing the whole call — the 0x
    ///         "swallows reverts" batch-state behaviour.
    /// @param  takerDatas Per-order filler-supplied blobs, aligned 1:1 with
    ///         `orders` (`takerDatas[i]` previews order `i`). Pass empty entries for
    ///         orders that don't consume it. Must be the same length as `orders`.
    function getOrderRelevantStates(
        Order[] calldata orders,
        bytes[] calldata sigs,
        address filler,
        bytes[] calldata takerDatas
    )
        external
        view
        returns (
            OrderStatus[] memory statuses,
            uint256[] memory fillableAmounts,
            bool[] memory sigValids,
            bool[] memory validatorsPass
        )
    {
        uint256 n = orders.length;
        statuses = new OrderStatus[](n);
        fillableAmounts = new uint256[](n);
        sigValids = new bool[](n);
        validatorsPass = new bool[](n);
        for (uint256 i; i < n; i++) {
            try this.getOrderRelevantState(orders[i], sigs[i], filler, takerDatas[i]) returns (
                OrderStatus s, uint256 f, bool v, bool vp
            ) {
                statuses[i] = s;
                fillableAmounts[i] = f;
                sigValids[i] = v;
                validatorsPass[i] = vp;
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
        if (SETTLEMENT.isNonceCancelled(order.maker, order.nonce)) return (OrderStatus.Cancelled, 0);

        uint256 anchor = _anchorTotal(order);
        uint256 done = SETTLEMENT.filled(orderHash);
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
    ///      capacity_i = min(live Permit3 allowance to the settlement, balance) and
    ///      perUnitIn_i is the input cost of one anchor unit — the fixed
    ///      `startAmountIn[i]` for SELL, or the worst-case `endAmountIn[i]` for BUY
    ///      (so the BUY cap is a conservative lower bound and never depends on the
    ///      not-yet-started auction tick).
    function _makerFillableCap(Order calldata order, uint256 anchor) internal view returns (uint256 cap) {
        cap = type(uint256).max;
        bool buy = order.side == OrderSide.BUY;
        address spender = address(SETTLEMENT);
        for (uint256 i; i < order.tokenIn.length; i++) {
            address token = order.tokenIn[i];
            (uint160 allowed, uint48 expiration,) = PERMIT3.tokenAllowance(order.maker, spender, token);
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

    // ──────────────────── Well-formedness ────────────────────

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
        if (SETTLEMENT.isNonceCancelled(order.maker, order.nonce)) return (false, "nonce cancelled");
        if (SETTLEMENT.filled(order.hash()) >= anchor) return (false, "order fully filled");

        return (true, "");
    }

    // ──────────────────── Internal helpers ────────────────────

    /// @dev Preview the order's pre-execution validators for `filler` — the same
    ///      AND-composition the settlement runs in `_runValidators`, evaluated as
    ///      a view. Mirrors the settlement's gate exactly: staticcall
    ///      `target.validate(order, filler, data, takerData)`, pass iff the call
    ///      succeeds, returns ≥32 bytes, and the bool word is 1.
    function _validatorsPass(Order calldata order, address filler, bytes calldata takerData)
        internal
        view
        returns (bool)
    {
        uint256 len = order.validators.length;
        for (uint256 i; i < len; i++) {
            Validator calldata v = order.validators[i];
            if (!_gatePasses(v.target, order, filler, v.data, takerData)) return false;
        }
        return true;
    }

    /// @dev Byte-for-byte mirror of the settlement's validator gate (see
    ///      {UniversalSettlement._gatePasses}): single-word return read into
    ///      scratch space, no `bytes memory` return allocation.
    function _gatePasses(
        address target,
        Order calldata order,
        address filler,
        bytes calldata data,
        bytes calldata takerData
    ) private view returns (bool pass) {
        bytes memory cd = abi.encodeCall(IOrderValidator.validate, (order, filler, data, takerData));
        /// @solidity memory-safe-assembly
        assembly {
            let ok := staticcall(gas(), target, add(cd, 0x20), mload(cd), 0x00, 0x20)
            pass := and(and(ok, gt(returndatasize(), 31)), eq(mload(0x00), 1))
        }
    }

    /// @dev The fill denominator in anchor units: the FIXED side's leg 0 —
    ///      `startAmountIn[0]` (SELL) or `startAmountOut[0]` (BUY).
    function _anchorTotal(Order calldata order) internal pure returns (uint256) {
        return order.side == OrderSide.BUY ? order.startAmountOut[0] : order.startAmountIn[0];
    }

    /// @dev Recompute the settlement's EIP-712 order digest and verify `sig`
    ///      against it. Uses the SETTLEMENT's domain separator (name +
    ///      verifyingContract are the settler's, not this lens's), so a signature
    ///      that verifies here is exactly one the settler will accept.
    function _verifySignature(bytes32 orderHash, bytes calldata sig, address expected) internal view {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", SETTLEMENT.DOMAIN_SEPARATOR(), orderHash));
        // Shared verifier: EOA (ecrecover), EIP-1271 contract wallets, and
        // EIP-7702 accounts (raw-key or delegated-1271) are all accepted.
        SignatureVerification.verify(sig, digest, expected);
    }
}
