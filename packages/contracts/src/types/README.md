# Types

Core data structures for the lending settlement system. All structs are defined in `DataTypes.sol` and used across settlement, libraries, and tests.

## DataTypes.sol

### Order

The top-level intent signed by the maker via EIP-712.

```solidity
struct Order {
    address maker;              // user who signs the order
    uint256 nonce;              // replay protection (bitmap-based)
    uint256 deadline;           // order expiration timestamp
    Condition condition;        // execution gate (gas price, timestamp, or none)
    LendingItem[] items;        // lending operations to execute
    ConversionItem[] conversions; // optional token conversions with dutch auction pricing
}
```

### LendingItem

A single lending operation authorized by the maker.

```solidity
struct LendingItem {
    LendingOp operation;  // DEPOSIT, WITHDRAW, BORROW, REPAY
    address module;       // whitelisted ILendingModule adapter
    address asset;        // ERC20 token
    uint256 amount;       // token amount
    bytes data;           // protocol-specific params (pool, market, mode, cToken, etc.)
}
```

The `data` field is opaque to the Settlement but committed in the EIP-712 hash as `keccak256(data)`. Each lending module decodes its own params from `data`. This enables one order struct to work across all lending protocols without protocol-specific fields.

### ConversionItem

A token conversion with dutch auction pricing. Defines the exchange rate between what the maker gives (tokenIn, typically from a borrow) and what they receive (tokenOut, typically collateral from the solver).

```solidity
struct ConversionItem {
    address tokenIn;          // token the maker gives (e.g. borrowed USDC)
    address tokenOut;         // token the maker receives (e.g. WETH for deposit)
    uint256 amountIn;         // amount of tokenIn the solver takes
    uint32 decayStartTime;    // auction start timestamp
    uint32 decayDuration;     // auction duration in seconds
    uint256 startAmountOut;   // best for maker (required at auction start)
    uint256 endAmountOut;     // worst for maker (required at auction end)
}
```

The dutch auction linearly decays from `startAmountOut` to `endAmountOut`:
- At `decayStartTime`: solver must provide `startAmountOut` (most expensive for solver)
- At `decayStartTime + decayDuration`: solver must provide `endAmountOut` (cheapest for solver)
- After expiry: stays at `endAmountOut`

### Condition

Execution gate for the order. Used primarily for lending-only (no-conversion) orders where solvers are compensated via MEV.

```solidity
struct Condition {
    ConditionType conditionType;  // NONE, MAX_GAS_PRICE, MIN_TIMESTAMP
    uint256 value;                // threshold value
}
```

### Enums

```solidity
enum LendingOp { DEPOSIT, WITHDRAW, BORROW, REPAY }
enum ConditionType { NONE, MAX_GAS_PRICE, MIN_TIMESTAMP }
```
