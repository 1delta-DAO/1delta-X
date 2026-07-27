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
| `GearboxPoolWithdrawModule` | TAKE | pool `withdraw` (owner allowance) | `abi.encode(pool, asset[, BalanceMode])` |
| `GearboxCreditAddCollateralModule` | MAKE | `botMulticall([addCollateral])` | `abi.encode(facade, creditAccount, token[, permit])` |
| `GearboxCreditBorrowModule` | TAKE | `botMulticall([increaseDebt, withdrawCollateral→receiver])` | `abi.encode(facade, creditAccount, asset)` |

## Authorization

| Leg | Protocol grant | Permit3 |
|---|---|---|
| pool deposit | — | token allowance (module) |
| pool withdraw | `pool.approve(module, max)` | taker allowance |
| credit add-collateral | `setBotPermissions(module, ADD_COLLATERAL)` | token allowance (module) |
| credit borrow | `setBotPermissions(module, INCREASE_DEBT \| WITHDRAW_COLLATERAL)` | taker allowance |

## ⚠️ Best-effort caveat (credit-account side)

The credit-account modules are **best-effort and unvalidated**: the bot-permission
bitmask values, credit-account address resolution, `multicall` self-call
semantics and the collateral/debt fund-flow all need confirmation on a mainnet
fork against the deployed `CreditFacadeV3`. Ship the **pool** modules first; treat
the credit modules as a design sketch pending fork tests. The `security/` auth
check runs without a fork.

```
FOUNDRY_PROFILE=modules-gearbox-v3 forge test --root ../../../..
```
