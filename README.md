# 1delta-x Lending Settlement Protocol

Intent-based lending settlement system that enables solvers to manage user lending positions via signed off-chain orders — similar to how 1inch Fusion and CoW Protocol work for swaps, but for lending operations.

## Architecture

```
src/
├── settlement/
│   └── Settlement.sol         Main entry point — verifies orders, executes lending ops, validates conversions
├── types/
│   └── DataTypes.sol          Order, LendingItem, ConversionItem, Condition structs
├── libraries/
│   ├── OrderLib.sol           EIP-712 struct hashing
│   ├── DutchDecayLib.sol      Linear dutch auction decay math
│   └── MakerChecks.sol        View helpers to pre-validate maker approvals/balances
├── interfaces/
│   ├── ILendingModule.sol     Adapter interface for lending protocols (deposit/withdraw/borrow/repay + balance views)
│   ├── IFlashLoanProvider.sol Aave V3-style flash loan interface
│   └── IDexAggregator.sol     1inch/0x-style swap interface
├── lending/                   Protocol-specific ILendingModule implementations
│   ├── AaveLending.sol        Aave V2 + V3
│   ├── MorphoLending.sol      Morpho Blue
│   ├── CompoundV3Lending.sol  Compound V3 (Comet)
│   ├── CompoundV2Lending.sol  Compound V2 / Venus
│   ├── SiloV2Lending.sol      Silo V2
│   └── UniversalLending.sol   Router that delegates to any sub-module by lender ID
└── solver/
    ├── SolverBase.sol         Abstract base — flash loan callback + DEX swap helper
    └── LeverageSolver.sol     Concrete solver for leverage-long positions
```

## How it works

### Two order modes

1. **Lending-only (MEV-based)** — Pure position management (deposit, withdraw, borrow, repay) gated by conditions like `MAX_GAS_PRICE`. Solver profits from MEV. No token conversion needed.

2. **Lending + Conversion (dutch auction)** — Operations requiring token swaps (leverage, migration, collateral swaps). Dutch auction decays from `startAmountOut` (best for maker) to `endAmountOut` over time, giving solvers increasing incentive to fill.

### Order lifecycle

```
1. Maker signs EIP-712 order off-chain
   (authorizes specific lending ops + optional conversions with dutch auction pricing)

2. Solver arranges liquidity (flash loans, DEX swaps)

3. Solver calls Settlement.settle(order, sig)
   ├── Verify signature
   ├── Check deadline, nonce (bitmap), conditions
   ├── Process conversions: pull tokenOut from solver → maker
   ├── Execute lending items via whitelisted modules
   ├── Process conversions: send tokenIn from settlement → solver
   └── Validate dutch auction rates

4. Maker ends up with the desired lending position
   Solver keeps the spread between auction rate and actual execution cost
```

### Flash loan composition pattern

For a 3x leveraged ETH long:

```
Solver's tx:
  1. Flash loan 4000 USDC
  2. Swap USDC → 2 WETH on DEX
  3. settlement.settle(order, sig)
     ├── Pull 2 WETH from solver → maker (conversion)
     ├── Deposit 3 WETH into Aave (1 maker + 2 solver)
     ├── Borrow 4000 USDC from Aave → settlement
     └── Send 4000 USDC to solver
  4. Repay flash loan + premium
```

The Settlement never touches flash loans — it only validates the signed lending operations and conversion rates.

## Safety model

> Authoritative security documentation lives in [`SECURITY.md`](SECURITY.md);
> the per-package READMEs ([`permit3`](packages/core/src/permit3/README.md),
> [`settlement`](packages/core/src/settlement/README.md)) document the current
> Permit3-based design. (The architecture sketch above predates the Permit3
> rewrite and is being updated.)

- **No admin, no module whitelist** — authority comes solely from the maker's
  EIP-712 signature plus their Permit3 allowances. (The earlier owner-approved
  module whitelist has been removed.)
- **Permit3 allowances are spender-keyed** — both the token and taker books are
  keyed by the approved spender (the Settlement contract), so a standing
  allowance can only be consumed by Settlement, which enforces the maker-signed
  `recipient`. TAKE modules require `msg.sender == permit3`; MAKE modules require
  `msg.sender == settlement`.
- **Only signed ops execute** — the signature commits to exact items, modules, assets, amounts, and protocol-specific `data` params
- **Bitmap nonces** — 256 nonces per storage slot, replay-proof. `cancelOrders()` for individual cancellation, `invalidateNonceWord()` for bulk emergency cancel
- **Dutch auction guarantee** — conversion rates are validated against the signed auction parameters
- **Safe token movement** — all ERC20 transfers/approvals go through `SafeTransferLib`; oracle validators enforce price freshness

## Generic `bytes data` for lending modules

Each `LendingItem` carries a `bytes data` field that is opaque to the Settlement but fully committed in the EIP-712 signature. Modules decode protocol-specific params from it:

| Module | `data` encoding |
|--------|----------------|
| Aave | `(address pool, uint8 version, uint256 interestRateMode)` |
| Morpho | `(address morpho, MarketParams market, bool isCollateral)` |
| CompoundV3 | `(address comet)` |
| CompoundV2 | `(address cToken, uint8 variant)` |
| SiloV2 | `(address silo, uint8 collateralType)` |
| Universal | `(uint16 lenderId, bytes innerData)` |

## Building and testing

```bash
cd packages/contracts
forge build
forge test -vvv
```

## Future directions

Planned features inspired by 1inch Limit Orders and CoW Protocol:

- **Predicate system** — composable on-chain conditions (health factor, oracle prices, borrow rates) via `staticcall` chains with `and/or/not`
- **Pre/post interaction hooks** — maker-defined callbacks for just-in-time liquidity, vault unwrapping, fee collection
- **Partial fills** — fill large orders incrementally with remaining-amount tracking
- **Epoch/series cancellation** — batch-invalidate all orders in a series with a single tx
- **MakerTraits bitflags** — pack deadline, allowed solver, and feature flags into a single `uint256`
- **ERC-1271 signatures** — smart wallet / Safe multisig support
- **Swap guards** — optional policy enforcement contracts for DAOs and institutional users
- **Extension system** — hash-committed optional blob for predicates, permits, and interactions (keeps base order struct minimal)
