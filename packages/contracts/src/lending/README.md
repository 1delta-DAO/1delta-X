# Lending Modules

Protocol-specific adapters that implement `ILendingModule`. Each module translates the generic `deposit/withdraw/borrow/repay` + `bytes data` interface into the actual protocol calls.

## ILendingModule interface

```solidity
// Mutative
function deposit(address asset, uint256 amount, address onBehalfOf, bytes calldata data) external;
function withdraw(address asset, uint256 amount, address onBehalfOf, address to, bytes calldata data) external;
function borrow(address asset, uint256 amount, address onBehalfOf, address to, bytes calldata data) external;
function repay(address asset, uint256 amount, address onBehalfOf, bytes calldata data) external;

// Balance views
function getCollateralBalance(address asset, address user, bytes calldata data) external view returns (uint256);
function getDebtBalance(address asset, address user, bytes calldata data) external view returns (uint256);
function getLendingBalance(address asset, address user, bytes calldata data) external view returns (uint256);
```

The `data` parameter is opaque to the Settlement — each module decodes protocol-specific params from it. Because `data` is included in the EIP-712 hash (as `keccak256(data)`), the maker commits to the exact protocol params when signing.

## Modules

### AaveLendingModule

Supports Aave V2 and V3 pools (and forks like Spark, Seamless).

**`data` encoding:** `abi.encode(address pool, uint8 version, uint256 interestRateMode)`

| Field | Values |
|-------|--------|
| `pool` | Aave Pool/LendingPool contract address |
| `version` | `2` = Aave V2 (uses `deposit`), `3` = Aave V3 (uses `supply`) |
| `interestRateMode` | `0` = none (some forks), `1` = stable, `2` = variable |

**Balance views:**
- Collateral: `aToken.balanceOf(user)` via `pool.getReserveData(asset)`
- Debt: `variableDebtToken.balanceOf` or `stableDebtToken.balanceOf` based on `interestRateMode`
- Lending: same as collateral (aToken)

### MorphoLendingModule

Supports Morpho Blue and forks (e.g. Lista/Moolah).

**`data` encoding:** `abi.encode(address morpho, MarketParams market, bool isCollateral)`

| Field | Values |
|-------|--------|
| `morpho` | Morpho Blue singleton address |
| `market` | `MarketParams(loanToken, collateralToken, oracle, irm, lltv)` |
| `isCollateral` | `true` = collateral operations (`supplyCollateral`/`withdrawCollateral`), `false` = loan-token supply/withdraw |

**Balance views:**
- Collateral: `position().collateral` (raw amount)
- Debt: `borrowShares → assets` conversion via `mulDivUp(shares, totalBorrowAssets + 1, totalBorrowShares + 1e6)`
- Lending: `supplyShares → assets` conversion via `mulDivDown`

### CompoundV3LendingModule

Supports Compound V3 (Comet) markets.

**`data` encoding:** `abi.encode(address comet)`

Compound V3 uses the same `supplyTo`/`withdrawFrom` for both base and collateral assets — the Comet contract distinguishes internally.

**Balance views:**
- Collateral: `comet.userCollateral(user, asset)` (first element of tuple)
- Debt: `comet.borrowBalanceOf(user)`
- Lending: `comet.balanceOf(user)` (base asset supply)

### CompoundV2LendingModule

Supports Compound V2, Venus, and forks.

**`data` encoding:** `abi.encode(address cToken, uint8 variant)`

| Variant | Protocol | Deposit method | Borrow method |
|---------|----------|---------------|---------------|
| `0` | Venus | `mintBehalf(receiver, amount)` | `borrowBehalf(borrower, amount)` |
| `1` | Classic Compound | `mint(amount)` + transfer cTokens | `borrow(amount)` |
| `2` | iToken-style | `mint(receiver, amount)` | — |

**Balance views:**
- Collateral: `cToken.balanceOf(user) * exchangeRateStored / 1e18`
- Debt: `cToken.borrowBalanceStored(user)`
- Lending: same as collateral

### SiloV2LendingModule

Supports Silo V2 markets.

**`data` encoding:** `abi.encode(address silo, uint8 collateralType)`

| CollateralType | Meaning |
|---------------|---------|
| `0` | Protected collateral |
| `1` | Default (non-protected) — uses simpler function signatures |
| `2+` | Other protocol-defined types |

**Balance views:**
- Collateral: `silo.maxWithdraw(user)`
- Debt: `silo.maxRepay(user)`
- Lending: same as collateral

### UniversalLendingModule

Optional aggregator that routes to protocol-specific modules by lender ID.

**`data` encoding:** `abi.encode(uint16 lenderId, bytes innerData)`

| lenderId | Protocol |
|----------|----------|
| 0 | Aave V3 |
| 1 | Aave V2 |
| 2 | Compound V3 |
| 3 | Compound V2 |
| 4 | Morpho |
| 5 | Silo V2 |

Delegates all calls (including balance views) to the sub-module registered via `setLenderModule(lenderId, moduleAddress)`.

## Adding a new protocol

1. Create `NewProtocolLending.sol` implementing `ILendingModule`
2. Define the `data` encoding for that protocol's params
3. Implement all 7 functions (4 mutative + 3 views)
4. Deploy and whitelist via `Settlement.setModule(address, true)`
5. Optionally register in `UniversalLendingModule` via `setLenderModule(id, address)`
