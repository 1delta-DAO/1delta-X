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
| `GearboxCreditWithdrawModule` | TAKE | `botMulticall([withdrawCollateral→receiver])` — collateral out, **no new debt** | `abi.encode(creditAccount, token)` |
| `GearboxCreditPreFundModule` | MAKE (pre-funded) | op `AddCollateral`: `botMulticall([addCollateral])`; op `Repay`: `botMulticall([addCollateral(underlying), decreaseDebt])` — both of the core-delivered leg, from the module's own balance | `abi.encode(forDesc, creditAccount, token)`, op in descriptor bits [244,252); `Repay` requires `token == creditManager.underlying()` (`NotUnderlying`) |

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
| credit withdraw | `setBotPermissions(module, WITHDRAW_COLLATERAL)` (`0x20`) | taker allowance |
| credit add-collateral / repay, **pre-funded** | `setBotPermissions(module, ADD_COLLATERAL \| DECREASE_DEBT)` (`0x05`, one grant for both ops) | — (no receive-side grant at all) |

## Zero-capital position shapes (`matchSettle`)

Until 2026-10-18 the credit side was pull-only and could not be deleveraged at
all: the only value-out op was the borrow module's `increaseDebt +
withdrawCollateral`, so a position could be levered up through modules but never
closed, with any amount of capital (review M-2), and every credit sink pulled from
the maker's wallet (M-1). With the withdraw-only TAKE and the pre-funded MAKE, the
two acyclic directions run at zero filler capital — sources (TAKE) early, sinks
(pre-funded MAKE) late:

| Shape | Early (source) | Late (sink) | Needs |
|---|---|---|---|
| lever up | `GearboxCreditBorrowModule` | `GearboxCreditPreFundModule` AddCollateral | headroom on the existing collateral |
| deleverage / **close** | `GearboxCreditWithdrawModule` | `GearboxCreditPreFundModule` Repay | headroom for the withdraw; a delivery that leaves the debt at 0 or ≥ `minDebt` |

Gearbox semantics the pre-funded Repay inherits, all fork-pinned
([`fork/CreditPreFundFork`](test/fork/CreditPreFundFork.t.sol)):

- `decreaseDebt` **caps at the total debt** (principal + interest + fees). A
  close is signed with headroom; the uncapped part of the delivery, already moved
  in by `addCollateral`, stays on the maker's own account as underlying collateral
  (a forced `Recycle`, exactly as the pull `GearboxCreditRepayModule`) — nothing
  is stranded on the module and nothing reaches the filler.
- A delivery that would leave a residual debt in (0, `minDebt`) reverts
  `BorrowAmountOutOfLimitsException` — fail closed.
- One debt update per block per account: only Repay touches debt, once.
- "Close" through modules = debt to zero plus a withdraw of the collateral:
  `closeCreditAccount` is owner-only, so the empty account stays the maker's. A
  debt-free account releases everything through `GearboxCreditWithdrawModule`.
- A withdraw past the headroom fails Gearbox's end-of-multicall collateral check
  (`NotEnoughCollateralException`): the LTV-edge close is a true cycle and stays
  with the flash family.

The netted interleaving (two makers' deliveries parked on one singleton, residue
present, the core ledger refusing an item before its delivery, the borrower check
on a foreign account) runs on a mock suite in
[`unit/NettedCreditPreFund`](test/unit/NettedCreditPreFund.t.sol).

## Fork validation (credit-account side)

The credit-account fund-flow is **validated on a mainnet fork** against the
deployed wstETH credit suite (v3.1) — `test/fork/CreditFlow.t.sol`: real
`openCreditAccount`, exact-mask bot grants, add-collateral, borrow
(`increaseDebt` + `withdrawCollateral`, minding the once-per-block debt-update
rule), partial repay, and a full close to zero debt. `test/fork/CreditPreFundFork.t.sol`
adds the withdraw-only TAKE and the pre-funded credit MAKE on the same suite, and
a one-order acyclic full close ("repay with collateral") through the real
`matchSettle` at zero capital. Notes that generalize:
amounts must respect the suite's `debtLimits` (minDebt applies to every state
except a full close), and quota calls are unnecessary only when the collateral
is the underlying. The `security/` auth suites run without a fork.

```
FOUNDRY_PROFILE=modules-gearbox-v3 forge test --root ../../../..
```
