# Solver Framework

Base contracts and examples for solvers that fill lending settlement orders. Solvers compose flash loans, DEX swaps, and other external calls around the `Settlement.settle()` call to source liquidity for lending operations.

## Design principle

The Settlement contract never touches flash loans or DEX routers. It only validates the signed lending operations and conversion rates. Solvers handle all the complex routing:

```
┌─ Solver Contract ──────────────────────────────────────────────┐
│                                                                 │
│  1. Flash loan tokens from Aave/Balancer                       │
│  2. Swap via DEX aggregator (1inch, 0x, Paraswap)              │
│  3. Approve Settlement for conversion tokens                    │
│  4. Settlement.settle(order, sig)                               │
│     └── validates order, executes lending ops, checks rates     │
│  5. Receive borrow proceeds / conversion outputs                │
│  6. Repay flash loan + premium                                  │
│  7. Keep profit (spread between auction rate and execution)     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## SolverBase.sol

Abstract base contract that handles:

- **Flash loan callback** (`IFlashLoanReceiver.executeOperation`) — decodes the settlement payload, calls `_executeStrategy()`, approves flash loan repayment
- **Strategy hook** (`_executeStrategy`) — override in concrete solvers to implement the specific flow
- **Settlement call** (`_settleOrder`) — low-level call to `Settlement.settle()` with memory→calldata bridging
- **DEX swap helper** (`_swap`) — approve + call any `IDexAggregator`
- **Access control** — `onlyOperator` modifier for the solver's off-chain bot
- **Token rescue** — `rescueTokens()` for stuck funds

## LeverageSolver.sol

Concrete solver for creating leveraged long positions.

### Example flow: 3x ETH/USDC long

User has 1 WETH, wants 3x leverage (3 WETH collateral, ~4000 USDC debt).

```
executeLeverage(order, sig, flashAssets=[USDC], flashAmounts=[4000e6], routeData)
  │
  ├── Flash loan 4000 USDC from Aave
  │
  └── executeOperation callback:
      ├── Swap 4000 USDC → 2 WETH via DEX
      ├── Approve Settlement for 2 WETH
      ├── settlement.settle(order, sig)
      │   ├── Transfer 2 WETH solver → maker (conversion)
      │   ├── Deposit 3 WETH to Aave (1 maker + 2 from solver)
      │   ├── Borrow 4000 USDC from Aave → settlement → solver
      │   └── Validate dutch auction rate
      └── Approve flash loan repayment (4000 USDC + 3.6 USDC premium)

Result:
  Maker: 3 WETH collateral, 4000 USDC debt on Aave
  Solver: kept spread between dutch auction rate and DEX execution
```

### Entry points

| Function | Description |
|----------|-------------|
| `executeLeverage(order, sig, flashAssets, flashAmounts, routeData)` | Initiate a leverage position via flash loan. Only callable by operator. |

## Writing a new solver

1. Extend `SolverBase`
2. Override `_executeStrategy()` with your flash loan + swap + settle logic
3. Add an entry point that initiates the flash loan with encoded params
4. Deploy with `(settlement, operator, flashLoanProvider, dexAggregator)`

### Common patterns

**Deleverage / unwind:**
```
1. Flash loan USDC
2. settle() → repay USDC debt, withdraw WETH collateral
3. Swap WETH → USDC
4. Repay flash loan
```

**Position migration (Aave → Compound):**
```
1. Flash loan USDC
2. settle() order A → repay Aave debt, withdraw Aave collateral
3. settle() order B → deposit Compound collateral, borrow Compound
4. Repay flash loan with Compound borrow proceeds
```

**Collateral swap (ETH → WBTC on same protocol):**
```
1. Flash loan ETH
2. settle() → deposit ETH + borrow USDC + conversion
3. Swap USDC → WBTC
4. settle() → deposit WBTC (separate order)
5. Repay flash loan
```
