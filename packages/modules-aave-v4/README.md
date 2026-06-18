# @1delta-x/modules-aave-v4

Aave **v4** lending adapters for `LimitOrderSettlement`. Same single-op module
shape as [`@1delta-x/modules-aave-v3`](../modules-aave-v3) — a thin, stateless
adapter that performs exactly one Aave action (supply, withdraw, borrow, repay)
on the order maker's behalf when Settlement processes an order item — but the
action routes through Aave v4's **Hub/Spoke + position-manager** architecture
instead of a pool.

The dependency points one way: this package depends on `@core`, never the
reverse, and it does **not** depend on the v3 package. The modules live in
[`src/`](src/); the fork tests in [`test/`](test/).

## How v4 differs from v3

v4 has no monolithic pool. Every action goes through a **position manager** the
maker has approved on the spoke (`spoke.setUserPositionManager(pm, true)`), and
reserves are keyed by a `reserveId` rather than an asset+pool pair:

- **GiverPositionManager** — supply / repay. The *caller* (the module) funds the
  tokens, so the module pulls the underlying via Permit3 and ERC20-approves it to
  the giver PM before calling `supplyOnBehalfOf` / `repayOnBehalfOf`.
- **TakerPositionManager** — withdraw / borrow. These have **no `receiver`
  parameter**: proceeds land at the caller (the module) and are forwarded on. The
  owner must also grant a per-`(spoke, reserveId)` allowance to the module via
  `approveWithdraw` / `approveBorrow`.

`data` for all four modules is `abi.encode(spoke, positionManager, reserveId,
asset)`. `asset` is the underlying ERC20: a maker module pulls it via Permit3, a
taker module forwards it to `receiver`, and it is part of `keccak256(data)` — the
taker-allowance ref — so the bytes the maker authorised pin down the exact
position.

## Modules (`src/`)

| Contract | Op | Aave v4 action |
|---|---|---|
| [`AaveV4DepositModule`](src/AaveV4Modules.sol) | MAKE | pull asset from maker → `GiverPM.supplyOnBehalfOf(onBehalfOf = maker)` |
| [`AaveV4RepayModule`](src/AaveV4Modules.sol) | MAKE | pull buffered amount → `GiverPM.repayOnBehalfOf`; sweep over-repay dust back to maker |
| [`AaveV4WithdrawModule`](src/AaveV4Modules.sol) | TAKE | `TakerPM.withdrawOnBehalfOf(onBehalfOf = maker)` → forward proceeds to `receiver` |
| [`AaveV4BorrowModule`](src/AaveV4Modules.sol) | TAKE | `TakerPM.borrowOnBehalfOf(onBehalfOf = maker)` → forward to `receiver` |
| [`interfaces/IAaveV4.sol`](src/interfaces/IAaveV4.sol) | — | minimal Giver/Taker position-manager + spoke surface |

## Authorization: the two-gates model, v4 flavour

The Permit3 gating is identical to v3 — only the **protocol-native** gate differs:

| Gate | Who enforces | What it caps |
|---|---|---|
| Permit3 **token** allowance (`approveToken(module, token, cap)`) | Permit3 | how much of the funding token a MAKE module may pull from the maker |
| Permit3 **taker** allowance (`approveTaker(settlement, ref, cap)`) | Permit3, TAKE only | how much may be drawn on `ref = keccak256(data)`; keyed by **spender = Settlement** (only Settlement can consume it). See [`/SECURITY.md`](../../SECURITY.md). |
| v4 **position-manager** approval (`spoke.setUserPositionManager(pm, true)`) | the spoke | lets the PM act for the maker at all (MAKE + TAKE) |
| v4 **taker grant** (`TakerPM.approveBorrow` / `approveWithdraw(spoke, reserveId, module, cap)`) | the taker PM | TAKE only — the v4-native analogue of v3's aToken pull / `approveDelegation` |

> **Collateral is not auto-enabled.** Unlike v3's `supply`, a freshly supplied v4
> reserve does *not* count as collateral until
> `spoke.setUsingAsCollateral(reserveId, true, maker)` is called — borrowing
> against it otherwise reverts with `HealthFactorBelowThreshold()`. This package
> intentionally ships only the four value-moving modules (no collateral-toggle
> module), so the maker enables the collateral reserve as a one-time setup, the
> same category as `setUserPositionManager`.

## Tests

Forked Ethereum mainnet against the live v4 Hub/Spoke deployment. The harness
([`test/shared/AaveV4ModulesBase.t.sol`](test/shared/AaveV4ModulesBase.t.sol))
pins a block where the v4 position managers are live (later than the core
default) and resolves reserve ids dynamically.

```
pnpm --filter @1delta-x/modules-aave-v4 test
# or, from the repo root:
forge test --match-path 'packages/modules-aave-v4/**'
```

Coverage: deposit+borrow (leverage), repay with over-repay dust refund, and
withdraw. A reliable archive RPC is recommended for the pinned block, e.g.
`ETH_RPC_URL=https://eth-mainnet.public.blastapi.io`.
