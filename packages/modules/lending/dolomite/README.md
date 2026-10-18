# @1delta-x/modules-dolomite

Permit3 maker/taker modules for **Dolomite** (DolomiteMargin, the dYdX-Solo
`operate(accounts, actions)` engine).

Every Dolomite state change — including a DEPOSIT — is an `operate`, and `operate`
admits only a **local operator** of each referenced account. Dolomite therefore has
no permissionless value-in path: every op, in every funding shape, needs the maker's
`setOperators([{module, true}])` boolean. That one grant is unscoped by market,
token, amount and sub-account, so the package ships ONE contract for every op.

## Module (`src/DolomiteOperatorModule.sol`)

| Op | Value | Seam | Funding |
| --- | --- | --- | --- |
| `Borrow` (0) | out | TAKE | — |
| `Withdraw` (1) — Exact (`WouldBorrow`-bounded) or `Full` | out | TAKE | — |
| `Deposit` (2) | in | MAKE | PULL (Permit3) **or PRE-FUND** |
| `Repay` (3) — clamped to the live debt | in | MAKE | PULL (Permit3) **or PRE-FUND** |
| `BatchOpen` (4) / `BatchClose` (5) — one two-action `operate` | both | TAKE | PULL (side leg) |
| `Open` (6) — fused deposit + borrow | both | TAKE_FOR | PULL or PRE-FUND |

Layouts (see the contract header for the full byte map):

```
plain (MAKE pull / TAKE): abi.encode(uint8 op, dolomite, marketId, token, accountNumber, …)
pre-funded MAKE:          abi.encode(forDesc, dolomite, marketId, token, accountNumber)
                          forDesc = (5 << 253) | op << 244 | uint160(token) << 16 | legIndex
TAKE_FOR Open:            abi.encode(OpenData{forDesc, forCap, …})
```

Each signed `token` must be its market's registry token (`MarketTokenMismatch`).
Sign `accountNumber >= 100` (the borrow-position range) for any op that can carry
debt — deployments still running the pre-2025-11 risk-override setter revert
`Invalid account for debt` below it (see `test/shared/DolomiteModulesBase.t.sol`).

## Pre-funded `Deposit` / `Repay`

"Deposit / repay whatever the conversion delivered." The maker signs the converted
output leg with `recipient = DolomiteOperatorModule` and a `MAKE` item whose word 0
is the pre-fund descriptor; `makeOnBehalf` splits on word 0 exactly as the core
does (`>> 253 == 5`). The core sizes `forAmount` from the delivery ledger
(`item.amount` is unread).

- **Gate:** `_gatePreFundMake` — `msg.sender == settlement` + the descriptor; only
  `Deposit` and `Repay` are admitted (every other op is `BadOp`).
- **Floor:** `PreFundGuard.floorOf` binds the spent token to the descriptor's
  funding token and takes the pre-delivery floor; the remainder above it — a
  repay clamped to the live debt, a zero debt, a venue that consumed less — is
  swept to the maker. Approvals are scoped and cleared (`dolomite` is maker-named).
- **Why not a separate `DolomitePreFundModules.sol`:** every other venue's
  pre-fund contract consumes no standing grant. Here it would need a SECOND
  unscoped operator flag. On the operator module the maker's entire receive side
  is the flag they already granted: no Permit3 token allowance, no ERC-20 approval
  of the delivered token.

This closes the two **acyclic** position shapes at zero filler capital (review
2026-10-18 M-1):

| Shape | Items (ORDERED) |
| --- | --- |
| open against headroom | `TAKE Borrow` (early, funds the input) → swap → pre-funded `MAKE Deposit` (late) |
| close / deleverage against headroom | `TAKE Withdraw` (early) → swap → pre-funded `MAKE Repay` (late) |

Leverage at the LTV edge is a cycle and still needs a flash (or the fused
`Open` / `BatchOpen` composites).

## Test

```
FOUNDRY_PROFILE=modules-dolomite forge test
```

Forks Ethereum mainnet at block 23M (WETH = market 0, USDC = market 2; every debt
test runs unmocked on account 100). `test/netted/NettedPreFund.t.sol` runs the
pre-funded ops on `matchSettle` against a CoW counter-order with a solver holding
nothing: the acyclic open and close, two makers' deliveries parked on the one
module (with residue), a hostile zero-consume repay, an item hoisted before its own
delivery (`Base.ForLegInvalid`), and the gate / floor / cross-seam refusals.
