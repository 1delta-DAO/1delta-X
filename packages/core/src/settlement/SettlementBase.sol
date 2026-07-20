// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPermit3} from "../interfaces/IPermit3.sol";
import {IMakerModule} from "../interfaces/IMakerModule.sol";
import {IFillModule} from "../interfaces/IFillModule.sol";
import {ISettlementModule} from "../interfaces/ISettlementModule.sol";
import {IOrderValidator} from "../interfaces/IOrderValidator.sol";
import {SignatureVerification} from "../permit3/SignatureVerification.sol";
import {SafeTransferLib} from "../utils/SafeTransferLib.sol";
import {Order, Item, ItemOp, Validator, OrderSide, CurvePoint, FillCtx} from "./SettlementStructs.sol";
import {OrderHash} from "./OrderHash.sol";
import {NonceManager} from "./NonceManager.sol";
import {SolverCallbackExecutor} from "./SolverCallbackExecutor.sol";

/// @title SettlementBase
/// @notice Shared foundation for the settler: storage, the EIP-712 domain, the
///         reentrancy lock, on-chain order authorization, signature verification,
///         the validator/invariant gates, and the fill primitives BOTH the
///         single-order path ({SettlementCore}) and the netted-batch path
///         ({SettlementBatch}) build on (`_openFill`, `_executeItems`,
///         `_exclusivity`, `_snapshotInputs`, `_anchorTotal`). Split out so the
///         hot single-order flow and the advanced batch flows each read in
///         isolation. All storage lives HERE — the derived contracts add behaviour
///         only, so the layout is fixed by this file.
abstract contract SettlementBase is NonceManager {
    using OrderHash for Order;


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

    /// @notice A maker cancelled a SPECIFIC order by hash via {cancelOrder} — the
    ///         per-order-hash cancellation, complementing {NonceManager}'s bulk
    ///         nonce cancellation. Permanent; the order can never fill again.
    event OrderCancelledByHash(address indexed maker, bytes32 indexed orderHash);


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

    /// @dev `batchSettle` was given an order carrying MAKE/TAKE/SETTLE items — the
    ///      netted flow is item-free (same rationale as `PostInputs`).
    error BatchSettleNoItems();

    /// @dev A netted `batchSettle` left Settlement holding LESS of `token` than it
    ///      did before the batch — the solver under-covered the residual, so the
    ///      batch would have drawn down a pre-existing/donated balance. Reverts.
    error BatchNotWhole(address token);

    /// @dev A `batchSettleItems` order's item-funded input leg (not in the solver's
    ///      pull-set) produced FEWER proceeds than the leg owes — the item did not
    ///      fund the obligation and there is no self-funded pull to make it up.
    error BatchItemsInputUnfunded();

    /// @dev `batchSettleItems`' `sequence` is not a permutation of `[0, n)` — it has
    ///      the wrong length, an out-of-range index, or a duplicate.
    error BatchItemsBadSequence();

    /// @dev A `batchSettleItems` order carries a SETTLE item. SETTLE routes the
    ///      maker's asset to the filler, not a pool counterparty — out of scope for
    ///      the netted item flow (a shared-pool SETTLE needs its own design).
    error BatchItemsSettleUnsupported();

    /// @dev A `batchSettleItems` order repeats an input token across two `tokenIn`
    ///      legs. The pooled input settlement attributes proceeds per token via a
    ///      balance delta; two same-token legs would mis-account. Use distinct
    ///      tokens (leverage/repay/migrate orders already do).
    error BatchItemsDuplicateInput();

    /// @dev An empty `sig` was supplied for a fill, but the maker has no matching
    ///      on-chain {approveOrder} record for this order.
    error OrderNotApproved();

    /// @dev {approveOrder} called with an order whose `maker` is not the caller.
    error NotOrderMaker();
    /// @dev The order was cancelled by hash via {cancelOrder} (`filled` sentinel).
    error OrderCancelled();


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
        filled[orderHash] = newFilled;
        ctx = FillCtx(orderHash, total, prevFilled, newFilled, overrideBps, filler, prevFilled == 0 && newFilled == total);
    }


    /// @dev The fill denominator in anchor units: the FIXED side's leg 0 —
    ///      `startAmountIn[0]` (SELL) or `startAmountOut[0]` (BUY).
    function _anchorTotal(Order calldata order) internal pure returns (uint256) {
        return order.side == OrderSide.BUY ? order.startAmountOut[0] : order.startAmountIn[0];
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
