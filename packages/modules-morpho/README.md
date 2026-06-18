# @1delta-x/modules-morpho

Morpho Blue lending adapters for `LimitOrderSettlement`. Each contract is a
**single-op module** — a thin, stateless adapter that performs exactly one Morpho
action (supply-collateral, withdraw-collateral, borrow, repay) on the order
maker's behalf when Settlement processes an order item. Composed together inside
one signed order, they express leverage, deleverage and cross-protocol migration
as a single atomic intent that any solver can fill.

The dependency points one way: this package depends on `@core`, never the
reverse. The modules live in [`src/`](src/); the fork tests in [`test/`](test/).

This package is the Morpho-Blue sibling of
[`@1delta-x/modules-aave-v3`](../modules-aave-v3). The plug-in shape (MAKE / TAKE,
Permit3 token + taker gates, post-fill invariants) is identical; what differs is
how Morpho models a position. Read the Aave README for the Settlement fill
mechanics — below we only cover **what Morpho does differently**.

## What Morpho Blue changes vs. Aave

Morpho Blue is a **singleton**: every isolated market lives in one contract and
is identified not by a pool address but by its full `MarketParams`:

```solidity
struct MarketParams { address loanToken; address collateralToken; address oracle; address irm; uint256 lltv; }
//   id = keccak256(abi.encode(marketParams))
```

So every module here takes `data = abi.encode(MarketParams)` (the Aave modules
take a pool + asset). Because the market params are inside the order's EIP-712
hash, the solver cannot retarget the oracle, IRM or LLTV.

| | Aave v3 | Morpho Blue |
|---|---|---|
| Position key | pool address + asset | `keccak256(MarketParams)` |
| Collateral receipt | aToken (ERC20) | **none** — tracked inside the singleton |
| Withdraw-collateral auth | pull aToken via Permit3 token allowance | `setAuthorization(module, true)` — **no token pull** |
| Borrow auth | `variableDebtToken.approveDelegation(module)` | `setAuthorization(module, true)` |
| Borrow proceeds | land at module, module forwards to `receiver` | Morpho sends straight to `receiver` |
| Full repay | `repay(amount)` caps at live debt | **must repay by shares** — `repay(assets)` does not cap |

The big one: **Morpho collateral is not tokenised.** The Aave withdraw module
pulls the maker's aWETH via a Permit3 token allowance; here there is nothing to
pull, so `withdrawCollateral` relies purely on Morpho's `setAuthorization` plus
the Permit3 taker-allowance gate. One fewer approval, one fewer moving part.

## Authorization: two gates per leg

A module only moves a maker's funds if **both** of these are signed/approved by
the maker beforehand — Settlement and the solver can never widen them:

| Gate | Who enforces | What it caps |
|---|---|---|
| Permit3 **token** allowance (`approveToken(module, token, cap)`) | Permit3 | MAKE legs — how much of *this token* the module may pull (supply-collateral, repay buffer) |
| Permit3 **taker** allowance (`approveTaker(settlement, ref, cap)`) | Permit3, TAKE only | how much may be drawn on *this exact market* (`ref = keccak256(data)`); keyed by **spender = Settlement** (only Settlement can consume it). See [`/SECURITY.md`](../../SECURITY.md). |
| Morpho **authorization** (`setAuthorization(module, true)`) | Morpho | borrow & withdraw-collateral — Morpho's own permission for the module to manage the position |

> **Note on Morpho's coarse auth.** `setAuthorization(module, true)` grants the
> module full control of the maker's position — both borrow *and*
> withdraw-collateral. Because each op is a **separate module address** whose code
> can only ever perform its one action, authorizing `MorphoBlueBorrowModule`
> permits only borrows, and the per-market Permit3 taker allowance is what
> actually caps the fill. Keep the modules single-op; that is the blast-radius
> boundary.

## Modules (`src/`)

| Contract | Op | Morpho action | `data` |
|---|---|---|---|
| [`MorphoBlueSupplyCollateralModule`](src/MorphoBlueModules.sol) | MAKE | pull collateral from maker → `supplyCollateral(onBehalf = maker)` | `abi.encode(MarketParams)` |
| [`MorphoBlueRepayModule`](src/MorphoBlueModules.sol) | MAKE | pull buffered loan token → `repay(shares = borrowShares)`; sweep dust back to maker | `abi.encode(MarketParams)` |
| [`MorphoBlueWithdrawCollateralModule`](src/MorphoBlueModules.sol) | TAKE | `withdrawCollateral(onBehalf = maker)` → `receiver` (no token pull) | `abi.encode(MarketParams)` |
| [`MorphoBlueBorrowModule`](src/MorphoBlueModules.sol) | TAKE | `borrow(onBehalf = maker, receiver)` — Morpho sends loan token straight to `receiver` | `abi.encode(MarketParams)` |
| [`interfaces/IMorphoBlue.sol`](src/interfaces/IMorphoBlue.sol) | — | minimal Morpho singleton surface + `MarketParamsLib.id` | — |

Constructors take `(permit3, morpho)` — the Morpho singleton address is fixed at
deploy time, while the specific market is selected per-item via `data`.

## Flows

### Leverage — supply collateral, borrow against it

One MAKE then one TAKE. The maker puts collateral in and the borrowed loan token
funds the `tokenIn` the solver is paid with.

```
order: tokenIn = loanToken, tokenOut = collateral   items = [MAKE supplyCollateral, TAKE borrow]

  [0] MAKE  SupplyCollateralModule  maker ──collateral──▶ supplyCollateral(onBehalf = maker)
  [1] TAKE  BorrowModule            borrow(onBehalf = maker) ──loanToken──▶ Settlement
                                    └─ Morpho setAuthorization permits the debt
  settle:   Settlement ──loanToken──▶ solver        (entirely from borrow proceeds)
            solver     ──collateral──▶ maker        (tokenOut, the added collateral)
```

### Deleverage — withdraw collateral, swap to repay

A single TAKE. The maker's collateral is withdrawn straight to the solver, who
pays the loan token back as `tokenOut`. No aToken pull — Morpho authorisation
plus the taker gate is the whole authorization story.

```
order: tokenIn = collateral, tokenOut = loanToken   items = [TAKE withdrawCollateral]

  [0] TAKE  WithdrawCollateralModule  withdrawCollateral ──collateral──▶ Settlement
  settle:   Settlement ──collateral──▶ solver
            solver     ──loanToken───▶ maker
```

### Repay — pull buffered loan token, repay by shares, refund the dust

A single MAKE. The maker signs a *buffered* amount to cover interest accrual
between signing and fill. The module reads the live `borrowShares` and repays by
shares so the position closes exactly; Morpho pulls only the assets it rounds up
to, and the module sweeps the remainder back to the maker.

```
order: items = [MAKE repay]

  [0] MAKE  RepayModule   maker ──loanToken(buffered)──▶ repay(shares = borrowShares)
                          └─ residual buffer ──loanToken──▶ maker   (never to solver)
```

### Migration — move a whole position across protocols

The same four-item chain as the Aave package, with Morpho on one or both sides.
The withdraw item sets `recipient = maker` to chain the freed collateral into the
next supply; the final borrow funds the repay. Because the modules are
market-agnostic (the market is just `data`), the *same* contracts migrate
Morpho→Morpho, Aave→Morpho or Morpho→Aave (pairing with the Aave modules).

```
items = [MAKE repay(src), TAKE withdrawCollateral(src)→maker, MAKE supplyCollateral(dst), TAKE borrow(dst)]
```

## Security properties

- **Taker modules are Permit3-gated.** `takeOnBehalf` reverts with `OnlyPermit3`
  unless `msg.sender == permit3`. Without it a direct call could bypass the
  taker-allowance gate and, combined with the maker's standing Morpho
  authorization, drain a delegated borrow/withdraw.
- **Repay refunds to the maker, not `data`.** The over-repay sweep destination is
  the `onBehalfOf` function argument, not an attacker-controllable field of
  `data`. A reentrancy lock guards against weird-token transfer hooks.
- **Repay-by-shares cannot overshoot.** Repaying by `borrowShares` makes Morpho
  pull exactly the rounded-up assets — it can never pull more than the buffer,
  and a stale/zero position is a no-op rather than a revert.
- **Single-op modules bound Morpho's coarse auth.** `setAuthorization` is
  position-wide, but each module's code performs only its one action, so the
  authorization a maker grants is legible from the module address alone.

## Tests

Forked Ethereum mainnet, exercising the **real Morpho Blue singleton** against the
live wstETH/USDC market (`0xb323…86cc`). The harness
([`test/shared/MorphoModulesBase.t.sol`](test/shared/MorphoModulesBase.t.sol))
extends the core `CoreSettlementBase` and binds that one market; because a Morpho
position isn't tokenised, collateral and debt are read straight off the singleton
(`morpho.position(id, account)`), with borrow shares converted to assets via
Morpho's own virtual-share math.

```
pnpm --filter @1delta-x/modules-morpho test
# or, from the repo root:
forge test --match-path 'packages/modules-morpho/**'
```

Coverage mirrors the Aave package, each with a direct fill and a single-signature
permit fill:

| Test | Flow | Morpho specifics exercised |
|---|---|---|
| [`leverage/SupplyBorrow`](test/leverage/SupplyBorrow.t.sol) | supply collateral + borrow | `supplyCollateral`; borrow sends straight to `receiver`; `setAuthorization` |
| [`swaps/WithdrawAndSwap`](test/swaps/WithdrawAndSwap.t.sol) | withdraw collateral + swap | no receipt-token pull — taker gate + `setAuthorization` only |
| [`closing/Repay`](test/closing/Repay.t.sol) | buffered repay + dust refund | repay-by-**shares** (full close), residual swept to maker |
| [`closing/Migrate`](test/closing/Migrate.t.sol) | Morpho → Aave v3 | cross-protocol: Morpho repay/withdraw + Aave deposit/borrow in one order |
| [`closing/MigrateAaveToMorpho`](test/closing/MigrateAaveToMorpho.t.sol) | Aave v3 → Morpho | the reverse: Aave repay/withdraw + Morpho supply/borrow in one order |
| [`security/TakerModuleAuth`](test/security/TakerModuleAuth.t.sol) | direct-call rejection | `OnlyPermit3` on both taker modules — load-bearing under coarse Morpho auth |

> Only one wstETH/USDC market exists at the pinned fork block, so the migration
> test crosses protocols (Morpho → Aave) — the faithful analog of the Aave
> package's Aave → Spark migration — and doubles as the composability proof that
> the Morpho and Aave modules compose in a single signed order. It pulls the Aave
> modules from [`../modules-aave-v3`](../modules-aave-v3); that is the test tree's
> only cross-package dependency.
