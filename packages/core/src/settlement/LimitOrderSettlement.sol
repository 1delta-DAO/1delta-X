// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPermit3} from "../interfaces/IPermit3.sol";
import {IMakerModule} from "../interfaces/IMakerModule.sol";
import {IOrderValidator} from "../interfaces/IOrderValidator.sol";
import {SignatureVerification} from "../permit3/SignatureVerification.sol";

/// @notice Operation kind per item. Names mirror limit-order parlance:
///         takers draw value out of a position, makers put value in.
///         (Unrelated to the order's `maker` field, which names the signer.)
///
///         MAKE — deposit/repay-style: Settlement calls the module, the
///                module pulls the funding token from the order maker via
///                Permit3.
///         TAKE — borrow/withdraw-style: Settlement calls `permit3.take`,
///                which enforces the taker allowance gate and dispatches
///                to the module; proceeds land at `receiver = Settlement`.
enum ItemOp {
    MAKE,
    TAKE
}

/// @notice A single lending item inside a LimitOrder.
/// @dev    `module` is a single-op adapter (`IMakerModule` for MAKE,
///         `ITakerModule` for TAKE). `amount` is the *total* amount for a
///         fully filled order; per-fill slices are computed pro-rata so
///         partial fills accumulate exactly to `amount` once fully filled.
///         `data` is the module's decode input and also the allowance
///         preimage (`ref = keccak256(data)` for TAKE ops).
///
///         `recipient` applies to TAKE items only — it is the address that
///         receives the protocol proceeds (e.g. borrow output, withdrawn
///         collateral). `address(0)` is the canonical default and means
///         "send to Settlement" (classic flow — proceeds flow to the solver
///         via `tokenIn` payout). Signing `recipient = maker` chains the
///         output into a subsequent MAKE item via the maker's wallet.
///         Ignored for MAKE items (set to 0 when constructing).
struct Item {
    ItemOp op;
    address module;
    uint256 amount;
    address recipient;
    bytes data;
}

/// @notice A read-only trigger. Settlement `staticcall`s `target.validate(order, data)`
///         and aborts the fill unless the returned bool is `true`. Multiple
///         validators on an order are AND-composed. Both `target` and `data`
///         are in the EIP-712 typehash → solver cannot alter.
struct Validator {
    address target;
    bytes data;
}

/// @notice A signed limit order.
struct LimitOrder {
    address maker;
    uint256 nonce;
    uint256 deadline;
    address tokenIn; //     maker gives (solver receives)
    address tokenOut; //    maker receives (solver gives)
    uint256 amountIn;
    uint32 decayStartTime;
    uint32 decayDuration;
    uint256 startAmountOut; //       best for maker (at auction start / fixed price)
    uint256 endAmountOut; //         worst for maker (at auction end)
    address exclusiveFiller; //      only this address may fill until exclusivityEndTime; 0 = open
    uint32 exclusivityEndTime; //    unix timestamp; ignored if exclusiveFiller == 0
    uint256 minFillAmountIn; //      anti-dust floor per fill; 0 = no minimum
    Item[] items;
    Validator[] validators; //       pre-execution trigger conditions; AND-composed
    Validator[] invariants; //       post-execution invariants; AND-composed
}

/// @title LimitOrderSettlement
/// @notice Signed limit-order settler with partial fills, optional dutch
///         decay, and pro-rata module-dispatched lending legs. All token
///         and taker authority flows through Permit3 — there is no module
///         whitelist, no admin role. A module's authority comes entirely
///         from the maker's signature + their per-module Permit3 allowances.
contract LimitOrderSettlement {
    bytes32 internal constant ITEM_TYPEHASH =
        keccak256("Item(uint8 op,address module,uint256 amount,address recipient,bytes data)");

    bytes32 internal constant VALIDATOR_TYPEHASH =
        keccak256("Validator(address target,bytes data)");

    bytes32 internal constant ORDER_TYPEHASH = keccak256(
        "LimitOrder(address maker,uint256 nonce,uint256 deadline,address tokenIn,address tokenOut,uint256 amountIn,uint32 decayStartTime,uint32 decayDuration,uint256 startAmountOut,uint256 endAmountOut,address exclusiveFiller,uint32 exclusivityEndTime,uint256 minFillAmountIn,Item[] items,Validator[] validators,Validator[] invariants)"
        "Item(uint8 op,address module,uint256 amount,address recipient,bytes data)"
        "Validator(address target,bytes data)"
    );

    // ──────────────────── Storage ────────────────────

    bytes32 public immutable DOMAIN_SEPARATOR;
    IPermit3 public immutable PERMIT3;

    /// @notice maker → word index → bitmap of cancelled nonces
    mapping(address => mapping(uint256 => uint256)) public nonceBitmap;

    /// @notice orderHash → cumulative filled amountIn
    mapping(bytes32 => uint256) public filledAmountIn;

    uint256 private _locked = 1;

    // ──────────────────── Events ────────────────────

    event OrderFilled(
        bytes32 indexed orderHash,
        address indexed maker,
        address indexed solver,
        uint256 fillAmountIn,
        uint256 fillAmountOut
    );
    event OrdersCancelled(address indexed maker, uint256[] nonces);

    // ──────────────────── Errors ────────────────────

    error InvalidSignature();
    error OrderExpired();
    error NonceCancelled();
    error AuctionNotStarted();
    error InvalidAuctionParams();
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
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("LimitOrderSettlement"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    // ──────────────────── Maker self-service ────────────────────

    function cancelOrders(uint256[] calldata noncesToCancel) external {
        for (uint256 i; i < noncesToCancel.length; i++) {
            _cancelNonce(msg.sender, noncesToCancel[i]);
        }
        emit OrdersCancelled(msg.sender, noncesToCancel);
    }

    function invalidateNonceWord(uint256 wordIndex) external {
        nonceBitmap[msg.sender][wordIndex] = type(uint256).max;
    }

    // ──────────────────── Fill ────────────────────

    /// @notice Fill (up to) `fillAmountIn` of an order. Partial fills allowed.
    ///         Lending items are executed pro-rata for this fill's slice.
    function fill(LimitOrder calldata order, bytes calldata sig, uint256 fillAmountIn)
        external
        nonReentrant
        returns (uint256 fillAmountOut)
    {
        bytes32 orderHash = _hashOrder(order);
        _verifySignature(orderHash, sig, order.maker);
        return _fillCore(order, orderHash, fillAmountIn);
    }

    /// @notice Single-signature fill: the maker's `sig` is over a Permit3
    ///         `PermitBatch` bound to this order's hash as a witness, so
    ///         one signature simultaneously authorises the order *and*
    ///         every Permit3 token + taker allowance the fill needs.
    ///         No standing approvals required.
    function fillWithPermit(
        LimitOrder calldata order,
        IPermit3.PermitBatch calldata batch,
        bytes calldata sig,
        uint256 fillAmountIn
    ) external nonReentrant returns (uint256 fillAmountOut) {
        bytes32 orderHash = _hashOrder(order);
        // Permit3 verifies the sig against (PermitBatchWitness + orderHash) and
        // applies all allowances. The order itself doesn't need a separate sig
        // — the witness binding makes the permit endorse this exact order.
        PERMIT3.permitBatchWithWitness(
            order.maker, batch, orderHash, _LIMIT_ORDER_WITNESS_TYPESTRING, sig
        );
        return _fillCore(order, orderHash, fillAmountIn);
    }

    /// @dev EIP-712 type string for the witness portion of a `PermitBatchWitness`
    ///      whose witness is a `LimitOrder`. Permit3 prepends its standard stub
    ///      and concatenates this. Type definitions are in alphabetical order
    ///      (Item, LimitOrder, TakerPermit, TokenPermit).
    string private constant _LIMIT_ORDER_WITNESS_TYPESTRING =
        "LimitOrder witness)"
        "Item(uint8 op,address module,uint256 amount,address recipient,bytes data)"
        "LimitOrder(address maker,uint256 nonce,uint256 deadline,address tokenIn,address tokenOut,uint256 amountIn,uint32 decayStartTime,uint32 decayDuration,uint256 startAmountOut,uint256 endAmountOut,address exclusiveFiller,uint32 exclusivityEndTime,uint256 minFillAmountIn,Item[] items,Validator[] validators,Validator[] invariants)"
        "TakerPermit(address module,bytes32 ref,uint160 amount,uint48 expiration)"
        "TokenPermit(address spender,address token,uint160 amount,uint48 expiration)"
        "Validator(address target,bytes data)";

    function _fillCore(LimitOrder calldata order, bytes32 orderHash, uint256 fillAmountIn)
        internal
        returns (uint256 fillAmountOut)
    {
        if (fillAmountIn == 0) revert ZeroFill();
        if (fillAmountIn < order.minFillAmountIn) revert FillTooSmall();
        if (block.timestamp > order.deadline) revert OrderExpired();

        // Exclusivity window — if set, only the nominated filler may fill until
        // `exclusivityEndTime`. After that, anyone can fill.
        if (
            order.exclusiveFiller != address(0)
                && block.timestamp < order.exclusivityEndTime
                && msg.sender != order.exclusiveFiller
        ) revert NotExclusiveFiller();

        if (_isNonceCancelled(order.maker, order.nonce)) revert NonceCancelled();

        _runValidators(order);

        uint256 prevFilled = filledAmountIn[orderHash];
        uint256 newFilled = prevFilled + fillAmountIn;
        if (newFilled > order.amountIn) revert OverFill();
        filledAmountIn[orderHash] = newFilled;

        uint256 currentOut = _currentAmountOut(order);
        // ceilDiv — maker never underpaid at current auction rate
        fillAmountOut = (fillAmountIn * currentOut + order.amountIn - 1) / order.amountIn;

        // 1. Solver → maker: tokenOut (Permit3 enforces solver's allowance to this contract)
        PERMIT3.transferFrom(msg.sender, order.maker, order.tokenOut, uint160(fillAmountOut));

        // 2. Pro-rata operation items for this fill
        _executeItems(order, prevFilled, newFilled);

        // 3. Settle tokenIn → solver. TAKE items route proceeds to this
        //    contract; any shortfall is pulled from the maker via Permit3.
        _payTokenInToSolver(order.tokenIn, order.maker, fillAmountIn);

        // 4. Post-execution invariants (e.g. "my Aave health factor ≥ 2.0 after this fill").
        _runInvariants(order);

        emit OrderFilled(orderHash, order.maker, msg.sender, fillAmountIn, fillAmountOut);
    }

    // ──────────────────── Operation execution ────────────────────

    /// @dev For each item, execute the slice attributable to this fill:
    ///      slice = item.amount * newFilled / amountIn
    ///            - item.amount * prevFilled / amountIn
    ///      Sums to exactly item.amount once the order is fully filled.
    function _executeItems(LimitOrder calldata order, uint256 prevFilled, uint256 newFilled) internal {
        uint256 amountIn = order.amountIn;
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

    /// @dev Pay `fillAmountIn` of tokenIn to the solver. Uses local balance
    ///      accumulated from TAKE items first; any shortfall is pulled from
    ///      the maker via Permit3 (the maker's token allowance to this
    ///      contract is the gate).
    function _payTokenInToSolver(address tokenIn, address maker, uint256 fillAmountIn) internal {
        uint256 localBal = IERC20(tokenIn).balanceOf(address(this));
        if (localBal >= fillAmountIn) {
            IERC20(tokenIn).transfer(msg.sender, fillAmountIn);
        } else {
            if (localBal > 0) IERC20(tokenIn).transfer(msg.sender, localBal);
            PERMIT3.transferFrom(maker, msg.sender, tokenIn, uint160(fillAmountIn - localBal));
        }
    }

    // ──────────────────── Nonce management ────────────────────

    function _cancelNonce(address maker, uint256 nonce) internal {
        nonceBitmap[maker][nonce >> 8] |= (1 << (nonce & 0xff));
    }

    function _isNonceCancelled(address maker, uint256 nonce) internal view returns (bool) {
        return (nonceBitmap[maker][nonce >> 8] & (1 << (nonce & 0xff))) != 0;
    }

    function isNonceCancelled(address maker, uint256 nonce) external view returns (bool) {
        return _isNonceCancelled(maker, nonce);
    }

    // ──────────────────── Dutch decay ────────────────────

    function _currentAmountOut(LimitOrder calldata order) internal view returns (uint256) {
        if (order.startAmountOut < order.endAmountOut) revert InvalidAuctionParams();

        if (order.decayDuration == 0 || order.startAmountOut == order.endAmountOut) {
            return order.startAmountOut;
        }

        if (block.timestamp < order.decayStartTime) revert AuctionNotStarted();

        uint256 elapsed = block.timestamp - order.decayStartTime;
        if (elapsed >= order.decayDuration) return order.endAmountOut;

        uint256 decay = (order.startAmountOut - order.endAmountOut) * elapsed / order.decayDuration;
        return order.startAmountOut - decay;
    }

    // ──────────────────── Hashing & signature ────────────────────

    function _hashOrder(LimitOrder calldata order) internal pure returns (bytes32) {
        // Split into two encodings to avoid stack-too-deep.
        bytes memory head = abi.encode(
            ORDER_TYPEHASH,
            order.maker,
            order.nonce,
            order.deadline,
            order.tokenIn,
            order.tokenOut,
            order.amountIn,
            order.decayStartTime,
            order.decayDuration,
            order.startAmountOut,
            order.endAmountOut
        );
        bytes memory tail = abi.encode(
            order.exclusiveFiller,
            order.exclusivityEndTime,
            order.minFillAmountIn,
            _hashItems(order.items),
            _hashValidators(order.validators),
            _hashValidators(order.invariants)
        );
        return keccak256(bytes.concat(head, tail));
    }

    function _hashItems(Item[] calldata items) private pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](items.length);
        for (uint256 i; i < items.length; i++) {
            hashes[i] = keccak256(
                abi.encode(
                    ITEM_TYPEHASH,
                    uint8(items[i].op),
                    items[i].module,
                    items[i].amount,
                    items[i].recipient,
                    keccak256(items[i].data)
                )
            );
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function _hashValidators(Validator[] calldata validators) private pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](validators.length);
        for (uint256 i; i < validators.length; i++) {
            hashes[i] = keccak256(
                abi.encode(VALIDATOR_TYPEHASH, validators[i].target, keccak256(validators[i].data))
            );
        }
        return keccak256(abi.encodePacked(hashes));
    }

    // ──────────────────── Validators ────────────────────

    function _runValidators(LimitOrder calldata order) internal view {
        for (uint256 i; i < order.validators.length; i++) {
            Validator calldata v = order.validators[i];
            (bool ok, bytes memory ret) = v.target.staticcall(
                abi.encodeCall(IOrderValidator.validate, (order, v.data))
            );
            if (!ok || ret.length < 32 || !abi.decode(ret, (bool))) {
                revert ValidationFailed(i);
            }
        }
    }

    /// @dev Post-execution staticcall invariants. Same shape as validators but
    ///      run AFTER items execute, so they can assert on the order's side
    ///      effects (e.g. "maker's Aave health factor ≥ 2.0").
    function _runInvariants(LimitOrder calldata order) internal view {
        for (uint256 i; i < order.invariants.length; i++) {
            Validator calldata v = order.invariants[i];
            (bool ok, bytes memory ret) = v.target.staticcall(
                abi.encodeCall(IOrderValidator.validate, (order, v.data))
            );
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

    function hashOrder(LimitOrder calldata order) external pure returns (bytes32) {
        return _hashOrder(order);
    }

    function previewAmountOut(LimitOrder calldata order) external view returns (uint256) {
        return _currentAmountOut(order);
    }

    function remaining(LimitOrder calldata order) external view returns (uint256) {
        return order.amountIn - filledAmountIn[_hashOrder(order)];
    }
}
