// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {
    Order,
    LendingItem,
    LendingOp,
    ConversionItem,
    Condition,
    ConditionType
} from "../types/DataTypes.sol";
import {OrderLib} from "../libraries/OrderLib.sol";
import {DutchDecayLib} from "../libraries/DutchDecayLib.sol";
import {ILendingModule} from "../interfaces/ILendingModule.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";

/// @title Settlement
/// @notice Intent-based lending settlement contract.
///
///  Design overview
///  ───────────────
///  • Makers sign EIP-712 orders that authorise specific lending operations
///    (deposit, withdraw, borrow, repay) and optional token conversions priced
///    via a dutch auction.
///
///  • Solvers (msg.sender) fill orders by calling `settle()`.  They compose
///    flash-loans, DEX swaps, and other external calls *around* the settle call
///    to source liquidity.  The Settlement contract itself never touches flash
///    loans — it only validates the lending items and conversion rates.
///
///  Token-flow model
///  ─────────────────
///  For conversions the flow is:
///    1. Solver transfers `tokenOut` to the Settlement *before* calling settle,
///       or the Settlement pulls it from the solver via transferFrom.
///    2. Settlement forwards `tokenOut` to the maker (needed for deposits, etc.).
///    3. Settlement executes lending items (deposits pull from maker, borrows
///       send proceeds to the Settlement).
///    4. Settlement transfers conversion `tokenIn` (e.g. borrow proceeds) to
///       the solver.
///    5. Dutch-auction validation ensures the maker got a fair rate.
///
///  For lending-only (no-conversion) orders the solver is compensated via MEV;
///  the condition field gates execution (e.g. "only when gas price ≤ X").
///
contract Settlement {
    using OrderLib for Order;
    using DutchDecayLib for ConversionItem;

    // ──────────────────── Storage ────────────────────

    bytes32 public immutable DOMAIN_SEPARATOR;

    address public owner;

    /// @notice Bitmap-based nonce management.
    ///         maker → word index → bitmap of used nonces.
    ///         Each word covers 256 sequential nonces (wordIndex * 256 .. wordIndex * 256 + 255).
    mapping(address => mapping(uint256 => uint256)) public nonceBitmap;

    /// @notice module address → whitelisted
    mapping(address => bool) public modules;

    /// @notice re-entrancy lock
    uint256 private _locked = 1;

    // ──────────────────── Events ────────────────────

    event OrderSettled(
        bytes32 indexed orderHash,
        address indexed maker,
        address indexed solver
    );

    event OrdersCancelled(address indexed maker, uint256[] nonces);

    event ModuleUpdated(address indexed module, bool enabled);

    // ──────────────────── Errors ────────────────────

    error InvalidSignature();
    error OrderExpired();
    error NonceUsed();
    error ConditionNotMet();
    error ModuleNotWhitelisted();
    error InsufficientOutput();
    error Reentrancy();
    error OnlyOwner();

    // ──────────────────── Modifiers ────────────────────

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    // ──────────────────── Constructor ────────────────────

    constructor() {
        owner = msg.sender;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("LendingSettlement"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    // ──────────────────── Admin ────────────────────

    function setModule(address module, bool enabled) external onlyOwner {
        modules[module] = enabled;
        emit ModuleUpdated(module, enabled);
    }

    // ──────────────────── Maker self-service ────────────────────

    /// @notice Cancel one or more orders by marking their nonces as used.
    ///         Only callable by the maker themselves.
    function cancelOrders(uint256[] calldata noncesToCancel) external {
        for (uint256 i; i < noncesToCancel.length; i++) {
            _useNonce(msg.sender, noncesToCancel[i]);
        }
        emit OrdersCancelled(msg.sender, noncesToCancel);
    }

    /// @notice Invalidate all nonces in a 256-nonce word in one shot.
    ///         Useful for emergency cancellation of a range of orders.
    /// @param wordIndex The word to invalidate (covers nonces wordIndex*256 .. wordIndex*256+255)
    function invalidateNonceWord(uint256 wordIndex) external {
        nonceBitmap[msg.sender][wordIndex] = type(uint256).max;
    }

    // ──────────────────── Settlement ────────────────────

    /// @notice Settle a single signed lending order
    function settle(Order calldata order, bytes calldata sig) external nonReentrant {
        _settle(order, sig);
    }

    /// @notice Settle multiple orders atomically in a single transaction.
    ///         Useful for solvers batching related positions (e.g. migrations).
    function settleBatch(Order[] calldata orders, bytes[] calldata sigs) external nonReentrant {
        for (uint256 i; i < orders.length; i++) {
            _settle(orders[i], sigs[i]);
        }
    }

    // ──────────────────── Core logic ────────────────────

    function _settle(Order calldata order, bytes calldata sig) internal {
        // 1. Verify signature
        bytes32 orderHash = _verifyOrder(order, sig);

        // 2. Check deadline & nonce
        if (block.timestamp > order.deadline) revert OrderExpired();
        _useNonce(order.maker, order.nonce);

        // 3. Check execution conditions (all must pass)
        _checkConditions(order.conditions, order.maker);

        // 4. Process conversions: forward tokenOut from solver → maker
        _processConversionInputs(order);

        // 5. Execute lending items through modules
        _executeLendingItems(order);

        // 6. Process conversions: forward tokenIn from this contract → solver
        //    and validate dutch-auction amounts
        _processConversionOutputs(order);

        emit OrderSettled(orderHash, order.maker, msg.sender);
    }

    // ──────────────────── Nonce management ────────────────────

    /// @dev Bitmap nonce: each nonce maps to a bit in a 256-bit word.
    ///      Reverts if already used; sets the bit atomically.
    function _useNonce(address maker, uint256 nonce) internal {
        uint256 wordIndex = nonce >> 8; // nonce / 256
        uint256 bitIndex = nonce & 0xff; // nonce % 256
        uint256 mask = 1 << bitIndex;

        uint256 word = nonceBitmap[maker][wordIndex];
        if (word & mask != 0) revert NonceUsed();
        nonceBitmap[maker][wordIndex] = word | mask;
    }

    /// @notice Check if a nonce has been used (view helper)
    function isNonceUsed(address maker, uint256 nonce) external view returns (bool) {
        uint256 wordIndex = nonce >> 8;
        uint256 bitIndex = nonce & 0xff;
        return (nonceBitmap[maker][wordIndex] & (1 << bitIndex)) != 0;
    }

    // ──────────────────── Signature verification ────────────────────

    function _verifyOrder(Order calldata order, bytes calldata sig) internal view returns (bytes32 orderHash) {
        orderHash = order.hash();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, orderHash));

        (bytes32 r, bytes32 s, uint8 v) = _splitSig(sig);
        address signer = ecrecover(digest, v, r, s);
        if (signer != order.maker || signer == address(0)) revert InvalidSignature();
    }

    function _splitSig(bytes calldata sig) private pure returns (bytes32 r, bytes32 s, uint8 v) {
        r = bytes32(sig[0:32]);
        s = bytes32(sig[32:64]);
        v = uint8(sig[64]);
    }

    // ──────────────────── Condition checking ────────────────────

    /// @dev All conditions must pass (AND-composed). Empty array = unconditional.
    function _checkConditions(Condition[] calldata conditions, address maker) internal view {
        for (uint256 i; i < conditions.length; i++) {
            _checkCondition(conditions[i], maker);
        }
    }

    function _checkCondition(Condition calldata cond, address maker) internal view {
        ConditionType ct = cond.conditionType;
        if (ct == ConditionType.NONE) return;

        if (ct == ConditionType.MAX_GAS_PRICE) {
            if (tx.gasprice > cond.threshold) revert ConditionNotMet();
        } else if (ct == ConditionType.MIN_TIMESTAMP) {
            if (block.timestamp < cond.threshold) revert ConditionNotMet();
        } else if (ct == ConditionType.MAX_TIMESTAMP) {
            if (block.timestamp > cond.threshold) revert ConditionNotMet();
        } else if (ct == ConditionType.PRICE_GTE) {
            if (_readOraclePrice(cond.target) < int256(cond.threshold)) revert ConditionNotMet();
        } else if (ct == ConditionType.PRICE_LTE) {
            if (_readOraclePrice(cond.target) > int256(cond.threshold)) revert ConditionNotMet();
        } else if (ct == ConditionType.BALANCE_GTE) {
            if (IERC20(cond.target).balanceOf(maker) < cond.threshold) revert ConditionNotMet();
        } else if (ct == ConditionType.BALANCE_LTE) {
            if (IERC20(cond.target).balanceOf(maker) > cond.threshold) revert ConditionNotMet();
        } else if (ct == ConditionType.PREDICATE) {
            _checkPredicate(cond.target, cond.data);
        }
    }

    /// @dev Read latest price from a Chainlink AggregatorV3-compatible feed.
    function _readOraclePrice(address feed) internal view returns (int256 price) {
        // latestRoundData() → (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
        (, price,,,) = IAggregatorV3(feed).latestRoundData();
        if (price <= 0) revert ConditionNotMet();
    }

    /// @dev Arbitrary staticcall predicate — must return at least 32 bytes with a nonzero first word.
    function _checkPredicate(address target, bytes calldata data) internal view {
        (bool ok, bytes memory result) = target.staticcall(data);
        if (!ok || result.length < 32 || abi.decode(result, (uint256)) == 0) revert ConditionNotMet();
    }

    // ──────────────────── Conversion processing ────────────────────

    /// @dev For each conversion, transfer tokenOut from solver to maker.
    function _processConversionInputs(Order calldata order) internal {
        for (uint256 i; i < order.conversions.length; i++) {
            ConversionItem calldata c = order.conversions[i];
            uint256 requiredOut = c.currentAmountOut();

            // Pull tokenOut from solver (msg.sender) and send to maker
            IERC20(c.tokenOut).transferFrom(msg.sender, order.maker, requiredOut);
        }
    }

    /// @dev Execute each lending item through its module
    function _executeLendingItems(Order calldata order) internal {
        for (uint256 i; i < order.items.length; i++) {
            LendingItem calldata item = order.items[i];
            if (!modules[item.module]) revert ModuleNotWhitelisted();

            ILendingModule module = ILendingModule(item.module);

            if (item.operation == LendingOp.DEPOSIT) {
                IERC20(item.asset).transferFrom(order.maker, address(this), item.amount);
                IERC20(item.asset).approve(item.module, item.amount);
                module.deposit(item.asset, item.amount, order.maker, item.data);
            } else if (item.operation == LendingOp.WITHDRAW) {
                module.withdraw(item.asset, item.amount, order.maker, order.maker, item.data);
            } else if (item.operation == LendingOp.BORROW) {
                module.borrow(item.asset, item.amount, order.maker, address(this), item.data);
            } else if (item.operation == LendingOp.REPAY) {
                IERC20(item.asset).transferFrom(order.maker, address(this), item.amount);
                IERC20(item.asset).approve(item.module, item.amount);
                module.repay(item.asset, item.amount, order.maker, item.data);
            }
        }
    }

    /// @dev Transfer conversion tokenIn (e.g. borrow proceeds) from this contract to solver.
    function _processConversionOutputs(Order calldata order) internal {
        for (uint256 i; i < order.conversions.length; i++) {
            ConversionItem calldata c = order.conversions[i];

            uint256 balance = IERC20(c.tokenIn).balanceOf(address(this));
            if (balance < c.amountIn) revert InsufficientOutput();

            IERC20(c.tokenIn).transfer(msg.sender, c.amountIn);
        }
    }

    // ──────────────────── View helpers ────────────────────

    /// @notice Preview the current required output for a conversion's dutch auction
    function previewConversion(ConversionItem calldata conversion) external view returns (uint256) {
        return conversion.currentAmountOut();
    }

    /// @notice Hash an order (useful for off-chain tooling)
    function hashOrder(Order calldata order) external pure returns (bytes32) {
        return order.hash();
    }
}
