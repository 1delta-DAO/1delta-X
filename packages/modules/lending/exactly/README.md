# @1delta-x/modules-exactly

Exactly lending adapters for `Settlement`. Each contract is a **single-op
module** that performs exactly one Exactly action (deposit, withdraw, borrow,
repay) on the order maker's behalf. Composed inside one signed order they express
leverage, deleverage and migration as a single atomic intent. Depends on `@core`.

## Why Exactly fits the mechanic

Each `Market` is an **ERC-4626 vault + floating & fixed borrow books**. Because
`borrow`/`withdraw` carry a `receiver`, the value-out legs forward straight to the
order's `receiver` — the clean case. `maturity == 0` in the order `data` selects
the floating pool; a non-zero unix timestamp selects a fixed pool, with the
maker-signed slippage guard (`maxAssets` on borrow, `minAssetsRequired` on
withdraw) carried alongside.

## Modules (`src/`)

| Contract | Op | Exactly action | `data` |
|---|---|---|---|
| `ExactlyDepositModule` | MAKE | `deposit` / `depositAtMaturity` (onBehalfOf) | `abi.encode(market, asset, maturity, minAssets[, permit])` |
| `ExactlyRepayModule` | MAKE | `repay` / `repayAtMaturity`; recycle/sweep dust | `abi.encode(market, asset, maturity, maxAssets[, DustAction[, permit]])` |
| `ExactlyTakerModule` (op 0) | TAKE | `borrow` / `borrowAtMaturity` → receiver | `abi.encode(uint8(0), market, asset, maturity, maxAssets)` |
| `ExactlyTakerModule` (op 1) | TAKE | `withdraw` / `withdrawAtMaturity` → receiver | `abi.encode(uint8(1), market, asset, maturity, minAssets[, BalanceMode])` |

## Authorization (per leg)

| Leg | Protocol grant | Permit3 |
|---|---|---|
| deposit / repay | — (permissionless value-in) | token allowance (module) |
| borrow / withdraw | `market.approve(module, max)` — one ERC-4626 share allowance covers **both** legs (Exactly consumes it when principal != caller) | taker allowance (Settlement, `keccak256(data)`) |

Collateral counts only once the maker has `Auditor.enterMarket(market)` — a
maker-side permission (`enterMarket` uses `msg.sender`), not a module call. The
taker module enforces `msg.sender == permit3`; the MAKE modules enforce
`msg.sender == settlement`.

## Notes on the fixed (`…AtMaturity`) legs

- Early fixed repay is a **discount** (the pool rebates unassigned earnings), so
  the actual transfer ≤ face; overdue accrues a per-second late penalty. The
  off-chain order-prep sizes `amount`/`maxAssets` from `previewRepayAtMaturity`
  (+buffer) and this module bounds the transfer + disposes any surplus.
- `BalanceMode.Full` is floating-only (`maxWithdraw`); fixed positions withdraw an
  explicit `positionAssets` face.

## Tests

Fork Optimism/Base where Exactly is deployed (set an RPC endpoint). The
`security/` auth check runs without a fork.

```
FOUNDRY_PROFILE=modules-exactly forge test --root ../../../..
```
