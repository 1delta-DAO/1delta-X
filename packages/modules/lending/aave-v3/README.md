# @1delta-x/modules-aave-v3

Aave v3 lending adapters for `Settlement`. Each contract is a
**single-op module** — a thin, stateless adapter that performs exactly one Aave
action (supply, withdraw, borrow, repay) on the order maker's behalf when
Settlement processes an order item. Composed together inside one signed order,
they express leverage, deleverage and cross-protocol migration as a single
atomic intent that any solver can fill.

The dependency points one way: this package depends on `@core`, never the
reverse. The modules live in [`src/`](src/); the fork tests in [`test/`](test/).

## How a module plugs into a fill

A maker signs one `Order` carrying an `Item[]`. Each item names a `module`
and an `op` (`MAKE` or `TAKE`). Settlement walks the items in order, then settles
the `tokenIn → tokenOut` swap leg between maker and solver.

```
            ┌─────────────────────── Settlement.fill ───────────────────────┐
            │                                                                          │
 solver ────┤ 1. solver ──tokenOut──▶ maker            (Permit3 pulls solver's funds)  │
            │ 2. for each Item in order:                                               │
            │      MAKE → module.makeOnBehalf(maker, slice, data)                      │
            │             module pulls the funding token from maker via Permit3        │
            │      TAKE → permit3.take(...) → module.takeOnBehalf(maker, …, receiver)   │
            │             proceeds land at `receiver` (default = Settlement)            │
            │ 3. Settlement ──tokenIn──▶ solver        (local balance + maker shortfall)│
            │ 4. validators / invariants gate the whole fill                           │
            └──────────────────────────────────────────────────────────────────────────┘
```

- **MAKE** = *value in* (deposit / repay): the module pulls the funding token
  from the maker via Permit3 and pushes it into Aave.
- **TAKE** = *value out* (borrow / withdraw): Settlement routes through
  `permit3.take`, which enforces the **taker-allowance gate** on
  `ref = keccak256(data)` before dispatching; proceeds go to `receiver`
  (`address(0)` → Settlement, funding the `tokenIn` payout; `maker` → chains the
  output into a later MAKE item).

`module` and `data` are inside the order's EIP‑712 hash, so the solver cannot
alter which Aave pool/asset is touched or how much.

## Authorization: two gates per leg

A module only moves a maker's funds if **both** of these are signed/approved by
the maker beforehand — Settlement and the solver can never widen them:

| Gate | Who enforces | What it caps |
|---|---|---|
| Permit3 **token** allowance (`approveToken(module, token, cap)`) | Permit3 | how much of *this token* the module may pull from the maker |
| Permit3 **taker** allowance (`approveTaker(settlement, ref, cap)`) | Permit3, TAKE only | how much may be drawn on *this exact position* (`ref = keccak256(data)`). Keyed by **spender = Settlement**, so only Settlement can consume it. |
| Aave **credit delegation** (`approveDelegation(module, cap)`) | Aave | borrow only — Aave's own permission for the module to incur debt |

For a borrow leg all three apply: credit delegation lets Aave mint debt to the
module, while the Permit3 taker allowance is what actually caps the fill size.

> **Security:** the taker book is keyed by spender (Settlement), so a standing
> taker allowance cannot be drained by an arbitrary caller; MAKE modules
> additionally enforce `msg.sender == settlement`. See [`/SECURITY.md`](../../../../SECURITY.md).

## Modules (`src/`)

| Contract | Op | Aave action | `data` |
|---|---|---|---|
| [`AaveV3DepositModule`](src/AaveV3Modules.sol) | MAKE | pull asset from maker → `pool.supply(onBehalfOf = maker)` | `abi.encode(pool, asset)` |
| [`AaveV3RepayModule`](src/AaveV3Modules.sol) | MAKE | pull buffered amount → `pool.repay`; sweep over-repay dust back to maker | `abi.encode(pool, asset, rateMode)` |
| [`AaveV3WithdrawModule`](src/AaveV3Modules.sol) | TAKE | pull maker's aToken → `pool.withdraw` → `receiver` | `abi.encode(pool, asset, aToken)` |
| [`AaveV3BorrowModule`](src/AaveV3Modules.sol) | TAKE | `pool.borrow(onBehalfOf = maker)` → forward to `receiver` | `abi.encode(pool, asset, rateMode)` |
| [`interfaces/IAaveV3.sol`](src/interfaces/IAaveV3.sol) | — | minimal Aave v3 pool + credit-delegation surface | — |

Because the modules are pool-address-agnostic, the **same** deposit/borrow
modules drive Aave v3, Spark, or any Aave-v3-fork by passing a different `pool`
in `data` — which is exactly what the migration flow exploits.

> Aave **v4** ships as a separate package,
> [`@1delta-x/modules-aave-v4`](../aave-v4), because v4's Hub/Spoke +
> position-manager architecture is a different integration surface from v3's
> pool. The module *shape* (MAKE/TAKE, Permit3-gated) is identical.

## Flows

### Leverage — deposit collateral, borrow against it

`_buildDepositBorrowOrder`: one MAKE then one TAKE. The maker puts WETH in and
the borrowed USDC funds the `tokenIn` the solver is paid with.

```
order: tokenIn = USDC, tokenOut = WETH      items = [MAKE deposit, TAKE borrow]

  [0] MAKE  AaveV3DepositModule   maker ──WETH──▶ pool.supply(onBehalfOf = maker)
  [1] TAKE  AaveV3BorrowModule    pool.borrow(onBehalfOf = maker) ──USDC──▶ Settlement
                                  └─ Aave credit delegation authorises the debt
  settle:   Settlement ──USDC──▶ solver        (entirely from borrow proceeds)
            solver     ──WETH──▶ maker         (tokenOut, the added collateral)
```

### Deleverage — withdraw collateral, swap to repay (`WithdrawAndSwap`)

`_buildWithdrawOrder`: a single TAKE. The maker's aWETH is pulled and burned for
WETH that goes straight to the solver, who pays USDC back as `tokenOut`.

```
order: tokenIn = WETH, tokenOut = USDC      items = [TAKE withdraw]

  [0] TAKE  AaveV3WithdrawModule  maker aWETH ──▶ pool.withdraw ──WETH──▶ Settlement
  settle:   Settlement ──WETH──▶ solver
            solver     ──USDC──▶ maker
```

### Repay — pull buffered debt token, repay, refund the dust (`Repay`)

`_buildRepayOrder`: a single MAKE. The maker signs a *buffered* amount to cover
interest accrual between signing and fill; Aave caps the pull at the live debt
and the module sweeps the remainder back to the maker.

```
order: tokenIn = WETH, tokenOut = USDC      items = [MAKE repay]

  [0] MAKE  AaveV3RepayModule    maker ──USDC(buffered)──▶ pool.repay(min(amt, debt))
                                 └─ residual dust ──USDC──▶ maker   (never to solver)
  settle:   solver ──USDC──▶ maker ;  maker ──WETH──▶ solver
```

### Migration — move a whole position across protocols (`Migrate`)

`_buildMigrationOrder`: four items chained in one atomic fill move a WETH/USDC
position from Aave v3 onto Spark. The withdraw item sets `recipient = maker` to
chain the freed WETH into the next deposit; the final borrow funds the repay.

```
items = [MAKE repay(Aave), TAKE withdraw(Aave)→maker, MAKE deposit(Spark), TAKE borrow(Spark)]

  [0] MAKE  repay     Aave    close USDC debt (buffered)
  [1] TAKE  withdraw  Aave    burn aWETH ──WETH──▶ maker        (recipient = maker, chained)
  [2] MAKE  deposit   Spark   maker ──WETH──▶ Spark.supply
  [3] TAKE  borrow    Spark   Spark.borrow ──USDC──▶ Settlement  (funds the tokenIn payout)

  Net: position leaves Aave and lands on Spark; solver fronts the repay USDC and
       is made whole by the Spark borrow — all-or-nothing.
```

## Security properties

- **Taker modules are Permit3-gated.** `takeOnBehalf` reverts with `OnlyPermit3`
  unless `msg.sender == permit3`. Without it a direct call could bypass the
  taker-allowance gate and drain a delegated borrow/withdraw — see
  [`test/security/TakerModuleAuth.t.sol`](test/security/TakerModuleAuth.t.sol).
- **Repay refunds to the maker, not `data`.** The over-repay sweep destination is
  the `onBehalfOf` function argument, not an attacker-controllable field of
  `data`, closing the "redirect the dust" vector without needing a sender gate.
  A reentrancy lock guards against weird-token transfer hooks.
- **Post-fill invariants.** Orders can carry `IOrderValidator` invariants that run
  after all items execute; a failing one reverts the whole fill and rolls maker
  state back (`test/limit-orders/Invariants.t.sol`).

## Tests

Forked Ethereum mainnet, exercising the real Aave v3 (and Spark) pools.

```
pnpm --filter @1delta-x/modules-aave-v3 test
# or, from the repo root:
forge test --match-path 'packages/modules-aave-v3/**'
```

Coverage spans each flow above plus the limit-order surface (min-fill,
exclusivity, validators, invariants), permit-based fills, and the taker-auth
security check.
