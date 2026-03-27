// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Lending operation types
enum LendingOp {
    DEPOSIT,
    WITHDRAW,
    BORROW,
    REPAY
}

/// @notice Condition types for gating order execution.
///         These act as settlement triggers — solvers monitor conditions off-chain
///         and submit settlements when triggers fire. On-chain validation confirms.
enum ConditionType {
    NONE, //           always passes
    MAX_GAS_PRICE, //  tx.gasprice <= threshold
    MIN_TIMESTAMP, //  block.timestamp >= threshold
    MAX_TIMESTAMP, //  block.timestamp <= threshold
    PRICE_GTE, //      Chainlink oracle price >= threshold (trigger: price rises to level)
    PRICE_LTE, //      Chainlink oracle price <= threshold (trigger: price drops to level)
    BALANCE_GTE, //    maker's ERC20 balance >= threshold
    BALANCE_LTE, //    maker's ERC20 balance <= threshold
    PREDICATE //       arbitrary staticcall to target with data, must return nonzero
}

/// @notice A single execution condition that must be satisfied for settlement.
///         Multiple conditions on an order are AND-composed (all must pass).
/// @dev The `target` and `data` fields are type-specific:
///
///      | Type           | target               | threshold          | data                           |
///      |----------------|----------------------|--------------------|--------------------------------|
///      | MAX_GAS_PRICE  | (ignored)            | max gwei           | (empty)                        |
///      | MIN_TIMESTAMP  | (ignored)            | unix timestamp     | (empty)                        |
///      | MAX_TIMESTAMP  | (ignored)            | unix timestamp     | (empty)                        |
///      | PRICE_GTE      | Chainlink price feed | min price (feed decimals) | (empty)               |
///      | PRICE_LTE      | Chainlink price feed | max price (feed decimals) | (empty)               |
///      | BALANCE_GTE    | ERC20 token          | min balance        | (empty)                        |
///      | BALANCE_LTE    | ERC20 token          | max balance        | (empty)                        |
///      | PREDICATE      | target contract      | (ignored)          | calldata for staticcall        |
///
struct Condition {
    ConditionType conditionType;
    address target;
    uint256 threshold;
    bytes data;
}

/// @notice A single lending operation that the solver executes on behalf of the maker
struct LendingItem {
    LendingOp operation;
    address module; // lending protocol adapter
    address asset;
    uint256 amount;
    bytes data; // protocol-specific params (e.g. Morpho MarketParams, Aave interest rate mode, Compound comet address)
}

/// @notice A token conversion with dutch auction pricing
/// @dev The maker signs that they accept converting amountIn of tokenIn
///      for at least currentAmountOut of tokenOut (decayed via dutch auction).
///      tokenIn is what the maker gives (e.g. debt from borrow).
///      tokenOut is what the maker receives (e.g. collateral from solver).
struct ConversionItem {
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    uint32 decayStartTime;
    uint32 decayDuration;
    uint256 startAmountOut; // best for maker (at auction start)
    uint256 endAmountOut; // worst for maker (at auction end)
}

/// @notice An intent-based lending order signed by the maker
/// @dev Makers sign this off-chain via EIP-712. Solvers submit settlements.
///      - Conditions are AND-composed: ALL must pass for the order to be fillable.
///      - For lending-only orders (no conversions): solver is compensated via MEV,
///        and conditions gate execution (e.g. gas price, oracle price triggers).
///      - For conversion orders: dutch auction pricing determines the exchange rate.
///        Solvers compose flash loans, DEX swaps, etc. around the settlement call.
///
///      Example condition compositions:
///        - Stop-loss:  [PRICE_LTE(ETH/USD, $2000)]
///        - Cheap exec: [MAX_GAS_PRICE(20 gwei), MIN_TIMESTAMP(tomorrow)]
///        - Auto-delev: [PREDICATE(healthFactorChecker)]  -- custom contract
///        - Range fill: [PRICE_GTE(ETH/USD, $3000), PRICE_LTE(ETH/USD, $3500)]
struct Order {
    address maker;
    uint256 nonce;
    uint256 deadline;
    Condition[] conditions;
    LendingItem[] items;
    ConversionItem[] conversions;
}
