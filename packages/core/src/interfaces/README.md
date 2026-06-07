# Interfaces

Shared interfaces used across the settlement system.

## ILendingModule.sol

The core adapter interface that each lending protocol must implement. The Settlement calls these modules to execute lending operations on behalf of makers.

**Mutative functions:**
| Function | Description |
|----------|-------------|
| `deposit(asset, amount, onBehalfOf, data)` | Deposit collateral into the lending protocol |
| `withdraw(asset, amount, onBehalfOf, to, data)` | Withdraw collateral to a recipient |
| `borrow(asset, amount, onBehalfOf, to, data)` | Borrow on behalf of user, send proceeds to recipient |
| `repay(asset, amount, onBehalfOf, data)` | Repay debt on behalf of user |

**Balance views:**
| Function | Description |
|----------|-------------|
| `getCollateralBalance(asset, user, data)` | User's collateral position in underlying units |
| `getDebtBalance(asset, user, data)` | User's debt in underlying units |
| `getLendingBalance(asset, user, data)` | User's supply/lending balance (e.g. Morpho loan-token supply) |

The `bytes data` parameter carries protocol-specific configuration (pool address, market params, interest rate mode, cToken address, etc.). Each module defines its own encoding.

**Prerequisites for modules:**
- Must be whitelisted via `Settlement.setModule(address, true)`
- Users must pre-approve the module (or the settlement) for token transfers
- For borrow operations, users must set up credit delegation (Aave) or `allow()` (Compound V3)

## IFlashLoanProvider.sol

Minimal Aave V3-style flash loan interface used by solver contracts.

```solidity
function flashLoan(address receiver, address[] assets, uint256[] amounts, bytes params) external;
```

The `IFlashLoanReceiver` callback interface:
```solidity
function executeOperation(address[] assets, uint256[] amounts, uint256[] premiums, address initiator, bytes params)
    external returns (bool);
```

## IDexAggregator.sol

Minimal DEX aggregator interface (1inch / 0x style) used by solver contracts.

```solidity
function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, bytes routeData)
    external returns (uint256 amountOut);
```

The `routeData` is opaque — constructed off-chain by the solver using the DEX aggregator's API.
