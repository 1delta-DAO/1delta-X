# @1delta-x/modules-morpho-midnight

Morpho **Midnight** lending adapters for `UniversalSettlement`. Each contract is
a thin, stateless adapter that performs a Midnight action on the order maker's
behalf when Settlement processes an order item. Composed inside one signed order,
they express leverage, deleverage, lend and redeem as a single atomic intent that
any solver can fill.

The dependency points one way: this package depends on `@core`, never the
reverse. The modules live in [`src/`](src/); the mock-based unit tests in
[`test/`](test/).

This is the Midnight sibling of [`@1delta-x/modules-morpho-blue`](../morpho-blue). Read the
Morpho / Aave READMEs for the Settlement fill mechanics (MAKE / TAKE, Permit3
token + taker gates, forward flow: deliver outputs → items → pay inputs). Below
we cover **what Midnight does differently** — and it differs a lot.

## What Midnight is (and isn't)

Midnight is a fixed-rate, fixed-maturity, **order-book** lending primitive —
**NOT a Morpho Blue fork**. There is no pool `supply`/`borrow`: lending and
borrowing both happen through `take`, which consumes an **off-chain-signed maker
`Offer`** (lend = buy zero-coupon credit units, borrow = sell debt units).
Position lifecycle is handled by `supplyCollateral` / `withdrawCollateral` /
`repay` / `withdraw` (credit redemption). Deployed on **Base** at
`0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A`.

Every entry-point takes the full `Market` struct, which embeds a **dynamic**
`CollateralParams[]` array (and `Offer` embeds a `Market` + dynamic `bytes`).
Unlike the static Morpho `MarketParams` (5 words), a Midnight `Market` cannot be
hand-packed at fixed offsets — so these modules **decode fully-typed tuples** and
any op / balance-mode flag rides **inside** the tuple (there is no static base to
append a trailing raw word past). The taker ref is still `keccak256(data)`, so
every field the module decodes is part of the maker-approved bytes.

Position views are keyed by a market **`id`** = the SSTORE2-pointer CREATE2
address Midnight stores the market blob at:
`keccak256(0xff ‖ market.midnight ‖ 0 ‖ keccak256(SSTORE2_PREFIX ‖ abi.encode(market)))`.
[`MidnightIdLib.toId`](src/interfaces/IMidnight.sol) reproduces it so the repay
cap and full-mode withdrawals can read `debt` / `credit` / `collateral`.

## Modules (`src/`)

| Contract | Op | Midnight action | `data` |
|---|---|---|---|
| [`MidnightSupplyCollateralModule`](src/MidnightModules.sol) | MAKE | pull collateral → `supplyCollateral(onBehalf = maker)` | `abi.encode(Market, collateralIndex)` |
| [`MidnightRepayModule`](src/MidnightModules.sol) | MAKE | read `debt(id, maker)` → pull-exact `repay(min(amount, debt))`, `callback = 0` | `abi.encode(Market)` |
| [`MidnightLendModule`](src/MidnightModules.sol) | MAKE | pull loan-token budget → `take(offer.buy = false, taker = maker)` (buy credit); sweep unspent to maker | `abi.encode(Offer, ratifierData, units)` |
| [`MidnightTakerModule`](src/MidnightModules.sol) | TAKE | combined: `op=0` → `withdrawCollateral`; `op=1` → `withdraw` (redeem credit). Exact / Full mode. | `abi.encode(uint8 op, Market, collateralIndex, uint8 balanceMode)` |
| [`MidnightBorrowModule`](src/MidnightModules.sol) | TAKE | `take(offer.buy = true, taker = maker)` (sell debt units) → forward proceeds to `receiver` | `abi.encode(Offer, ratifierData, units)` |
| [`interfaces/IMidnight.sol`](src/interfaces/IMidnight.sol) | — | structs + minimal Midnight surface + `MidnightIdLib.toId` | — |

MAKE constructors take `(permit3, midnight, settlement)`; TAKE constructors take
`(permit3, midnight)`. The Midnight singleton is fixed at deploy time; the market
/ offer is selected per-item via `data`.

## Authorization

A module only moves a maker's funds if these are signed/approved beforehand —
Settlement and the solver can never widen them:

| Gate | Who enforces | What it caps |
|---|---|---|
| Permit3 **token** allowance (`approveToken(module, token, cap)`) | Permit3 | MAKE legs — how much of *this token* the module may pull (supply, repay, lend budget) |
| Permit3 **taker** allowance (`approveTaker(settlement, ref, cap)`) | Permit3, TAKE only | how much may be drawn on *this exact item* (`ref = keccak256(data)`); keyed by **spender = Settlement** |
| Midnight **authorization** (`setIsAuthorized(module, true, maker)`) | Midnight | any leg where the module acts as `taker`/`onBehalf` ≠ `msg.sender` |

> **Midnight's coarse auth.** `setIsAuthorized(module, true, maker)` grants the
> module full control of the maker's position. The combined `MidnightTakerModule`
> multiplexes `withdrawCollateral` + `withdraw` behind a leading `op` flag, so a
> single authorization covers both; the op flag is the first tuple field, so the
> legs hash to **different** Permit3 taker refs and each still carries its own
> per-market, amount-gated allowance.
>
> **The lend leg needs auth too.** Because `take` routes the bought credit to
> `taker = maker` while the module is `msg.sender`, Midnight's authorization gate
> fires even though `MidnightLendModule` is a value-in MAKE — atypical, but
> intrinsic to giving the maker (not the module) the credit.

## Flows

### Leverage — supply collateral, borrow against it (order-book fill)

```
order: tokenIn = LOAN, tokenOut = COLL   items = [MAKE supplyCollateral, TAKE borrow]

  deliver: solver ──COLL──▶ maker                     (tokenOut)
  [0] MAKE  SupplyCollateralModule  maker ──COLL──▶ supplyCollateral(onBehalf = maker)
  [1] TAKE  BorrowModule            take(offer.buy, taker = maker) ──LOAN──▶ Settlement
  pay:      Settlement ──LOAN──▶ solver               (borrow proceeds)
```

The borrow leg's `units` is fixed in the signed data, so a borrow item **must**
ride a fill-or-kill order (a fixed unit count can't be pro-rata'd across partial
fills).

### Deleverage — repay, withdraw collateral

```
order: tokenIn = COLL, tokenOut = LOAN   items = [MAKE repay, TAKE withdrawCollateral]

  deliver: solver ──LOAN──▶ maker
  [0] MAKE  RepayModule             repay(min(amount, debt))          (pull-exact, callback = 0)
  [1] TAKE  TakerModule (op=0)      withdrawCollateral ──COLL──▶ Settlement
  pay:      Settlement ──COLL──▶ solver
```

`Full` balance mode (a `balanceMode` tuple field) withdraws the maker's ENTIRE
collateral to the module, forwards the signed slice to `receiver`, and sweeps the
surplus back to the maker — pair with fill-or-kill.

### Lend / Redeem

`MidnightLendModule` (MAKE) buys credit for the maker against an `offer.buy =
false` offer, sweeping the unspent budget back. `MidnightTakerModule` op=1 (TAKE)
redeems credit for the loan token — a redeem-and-swap exit.

## Security properties

- **MAKE modules reject non-Settlement callers** (`NotSettlement`); **TAKE modules
  reject non-Permit3 callers** (`OnlyPermit3`). Without these a direct call
  bypasses the Permit3 allowance gate and, combined with the maker's standing
  Midnight authorization, could drain a delegated withdraw/borrow.
- **Repay is pull-exact.** `repay(min(amount, debt))` pulls only what it repays,
  so nothing sits in the module and over-repay (which Midnight reverts on) can't
  happen; `callback = 0` forces Midnight to pull straight from the module, never a
  caller-supplied repay callback.
- **Sweeps go to the maker, never `data`.** Every residual/surplus destination is
  the `onBehalfOf` argument, not an attacker-controllable field. `nonReentrant`
  guards the MAKE modules against weird-token transfer hooks.

## Flash loans

A `MidnightFlashSolver` in [`@solvers`](../../../solvers/src/single-input/MidnightFlashSolver.sol)
sources leverage inventory from Midnight's fee-free **multi-token** `flashLoan`
(wrapping the single collateral asset in a one-element array; repay by approving
Midnight to pull it back, returning `keccak256("morpho.midnight.callbackSuccess")`).

## Tests

Midnight positions are opened by signed maker offers + ratifiers — impractical to
seed on a live fork — so, like the composer's Midnight suite, the tests drive a
faithful [`MidnightMock`](test/shared/MidnightMock.sol) (real selectors, real
token flows, real `setIsAuthorized` gating, positions keyed by the same
`MidnightIdLib.toId` the modules compute) with mock ERC20s, over the **real**
`UniversalSettlement` + `Permit3`. No fork.

```
FOUNDRY_PROFILE=modules-morpho-midnight forge test
```

| Test | Flow |
|---|---|
| [`MidnightFlows`](test/MidnightFlows.t.sol) | supply+borrow, repay+withdraw (exact & full), lend (+ budget buffer), redeem credit |
| [`security/ModuleAuth`](test/security/ModuleAuth.t.sol) | `NotSettlement` / `OnlyPermit3` direct-call rejection; `setIsAuthorized` gate is load-bearing |

> A live Base-fork test against the real singleton would additionally prove the
> `toId` derivation and the offer/ratifier economics, but requires constructing
> signed maker offers — out of scope for this unit suite.
