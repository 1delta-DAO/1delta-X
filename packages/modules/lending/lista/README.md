# @1delta-x/modules-lista

Lista DAO lending adapters for `Settlement`. Lista's core is a **Moolah** (a
Morpho Blue fork), so collateral custody reuses the Morpho module shape; the debt
side of a brokered market runs through a **`LendingBroker`**. Depends on `@core`.

## Shape

| Side | Contract | Where | Grant |
|---|---|---|---|
| collateral in | Moolah `supplyCollateral(onBehalf)` | Moolah singleton | Permit3 token allowance |
| collateral out | Moolah `withdrawCollateral(onBehalf, receiver)` | Moolah singleton | Moolah `setAuthorization(module)` |
| debt out (borrow) | `broker.borrow(amount, termId, user, receiver)` | LendingBroker (fixed-term) | Moolah `setAuthorization(module)` |
| debt in (repay) | `broker.repay(0, [loanId,] onBehalf)` | LendingBroker | Permit3 token allowance |

## Modules (`src/`)

| Contract | Op | `data` |
|---|---|---|
| `ListaSupplyCollateralModule` | MAKE | `abi.encode(moolah, MarketParams[, permit])` |
| `ListaBrokerRepayModule` | MAKE | `abi.encode(broker, loanToken, loanId[, DustAction[, permit]])` |
| `ListaTakerModule` (op 0) | TAKE | `abi.encode(uint8(0), broker, termId)` — fixed-term borrow → receiver |
| `ListaTakerModule` (op 1) | TAKE | `abi.encode(uint8(1), moolah, MarketParams[, BalanceMode])` — withdraw collateral → receiver |

## Scope & caveats

- **Only the fixed-term broker borrow is delegable.** Lista's flex (dynamic)
  borrow is a bare `broker.borrow(uint256)`, `msg.sender`-only, so it cannot be
  driven by a module — deliberately omitted.
- Repay uses the broker's `repay(0, …)` "repay-from-balance, refund-excess"
  semantics: the module pulls the maker-signed ceiling, the broker takes exactly
  the debt, and the surplus is swept back to the maker.
- The on-behalf `broker.borrow(amount, termId, user, receiver)` signature and its
  reliance on Moolah `setAuthorization` are transcribed from the SDK's
  `_listaBrokerBorrow` composer path; **confirm against the deployed
  `LendingBroker`** before mainnet use (verify on a BNB fork).
- `loanId == type(uint128).max` selects the flex position on repay.

## Tests

Fork BNB Chain where Lista/Moolah is deployed (set an RPC endpoint). The
`security/` auth check runs without a fork.

```
FOUNDRY_PROFILE=modules-lista forge test --root ../../../..
```
