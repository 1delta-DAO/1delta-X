# @1delta-x/modules-gearbox-v3

Gearbox V3 lending adapters for `Settlement`. Depends on `@core`.

## Two surfaces

1. **PoolV3 (ERC-4626)** — the passive supply side. `GearboxPoolDepositModule`
   (MAKE) and `GearboxPoolWithdrawModule` (TAKE) are clean, self-contained, and
   the solid core of this package.

2. **Credit account (leverage)** — each position is a separate account operated
   through the `CreditFacadeV3` via a `multicall` of sub-calls. On-behalf
   operation runs via the **bot** model: the account owner calls
   `setBotPermissions(module, permissions)`, and the module drives the account
   through `botMulticall`. **This is a real delegation path** — the doc's Matrix C
   "no delegation" reflects the SDK's direct route, not the on-chain surface (the
   same understatement as Dolomite's `setOperators`).

## Modules (`src/`)

| Contract | Op | Surface | `data` |
|---|---|---|---|
| `GearboxPoolDepositModule` | MAKE | pool `deposit` | `abi.encode(pool, asset[, permit])` |
| `GearboxPoolWithdrawModule` | TAKE | pool `withdraw` (owner allowance); `Full` withdraws the whole raw position and splits it | `abi.encode(pool, asset[, BalanceMode[, total]])` — `total`@96 (the item's full signed amount) is **mandatory** under `Full` (fails closed without it); `asset` is re-derived from `pool.asset()` |
| `GearboxPoolPreFundDepositModule` | MAKE (pre-funded) | pool `deposit` of the core-delivered leg from the module's own balance | `abi.encode(forDesc, pool, asset)` |
| `GearboxCreditAddCollateralModule` | MAKE | `botMulticall([addCollateral])` | `abi.encode(creditAccount, token[, permit])` |
| `GearboxCreditRepayModule` | MAKE | `botMulticall([addCollateral, decreaseDebt])` | `abi.encode(creditAccount, asset[, permit])` |
| `GearboxCreditBorrowModule` | TAKE | `botMulticall([increaseDebt, withdrawCollateral→receiver])` | `abi.encode(creditAccount, asset)` |

> `BalanceMode` is one 32-byte word: `0` = `Exact`, `Full` = the TAGGED word `0xB0DE0001` (`DustHandler.encodeMode(Full)`, SDK `encodeMode(BalanceMode.Full)`); an untagged `1` reverts `InvalidModeWord`.

The facade is never in `data` — it is DERIVED from `creditAccount` on-chain
(see `GearboxCreditAuth` in the source; taking it from calldata would reopen
the authorization/dispatch split the auth chain exists to close).

## Authorization

| Leg | Protocol grant | Permit3 |
|---|---|---|
| pool deposit | — | token allowance (module) |
| pool withdraw | `pool.approve(module, max)` | taker allowance |
| credit add-collateral | `setBotPermissions(module, ADD_COLLATERAL)` | token allowance (module) |
| credit repay | `setBotPermissions(module, ADD_COLLATERAL \| DECREASE_DEBT)` | token allowance (module) |
| credit borrow | `setBotPermissions(module, INCREASE_DEBT \| WITHDRAW_COLLATERAL)` | taker allowance |

## Fork validation (credit-account side)

The credit-account fund-flow is **validated on a mainnet fork** against the
deployed wstETH credit suite (v3.1) — `test/fork/CreditFlow.t.sol`: real
`openCreditAccount`, exact-mask bot grants, add-collateral, borrow
(`increaseDebt` + `withdrawCollateral`, minding the once-per-block debt-update
rule), partial repay, and a full close to zero debt. Notes that generalize:
amounts must respect the suite's `debtLimits` (minDebt applies to every state
except a full close), and quota calls are unnecessary only when the collateral
is the underlying. The `security/` auth suites run without a fork.

```
FOUNDRY_PROFILE=modules-gearbox-v3 forge test --root ../../../..
```
