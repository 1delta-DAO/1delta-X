# @1delta-x/modules-morpho-midnight

Morpho **Midnight** lending adapters for `Settlement`. Each contract is
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
| [`MidnightLendModule`](src/MidnightModules.sol) | MAKE | pull loan-token budget → `take(offer.buy = false, taker = maker)` (buy credit); sweep unspent to maker. Full-fill only | `abi.encode(Offer, bytes ratifierData, uint256 units, uint256 totalAmount)` |
| [`MidnightTakerModule`](src/MidnightModules.sol) | TAKE | combined: `op=0` → `withdrawCollateral`; `op=1` → `withdraw` (redeem credit). Exact / Full mode (Full credit sized from `updatePosition`, not the stale `credit()`) | `abi.encode(uint8 op, Market, uint256 collateralIndex, uint8 balanceMode, uint256 totalAmount)` |
| [`MidnightBorrowModule`](src/MidnightModules.sol) | TAKE | `take(offer.buy = true, taker = maker)` (sell debt units) → forward proceeds to `receiver`; reverts if the proceeds fall short of `amount`. Full-fill only | `abi.encode(Offer, bytes ratifierData, uint256 units, uint256 totalAmount)` |
| [`MidnightPreFundModule`](src/MidnightPreFundModules.sol) | MAKE (pre-funded) | supply-collateral / repay funded by the fill's own delivered output leg | `abi.encode(forDesc, Market[, collateralIndex])` |
| [`MidnightLoopCallback`](src/MidnightLoopCallback.sol) | offer `callback` | borrow-and-loop: swaps a sell offer's proceeds to collateral and supplies it for the borrower | `callbackData = abi.encode(uint256 collateralIndex, uint24 dexFee, uint256 minRateWad)` |
| [`interfaces/IMidnight.sol`](src/interfaces/IMidnight.sol) | — | structs + minimal Midnight surface + `MidnightIdLib.toId` | — |

> **`totalAmount` is mandatory and the layouts are checked strictly.** The
> trailing `totalAmount` (the item's full signed amount; `0` for Taker `Exact`) is
> what {FullFillGuard} compares the fill slice against. Because `Market` / `Offer`
> are dynamic tuples, solc would decode an OLDER, shorter blob without it and read
> the first tail word as the total (a market's `chainId`, an offer's inner offset
> `0x1e0`) — a constant a dust slice can match. The modules therefore pin the
> dynamic member's head offset to the exact head size (`0xa0` for the Taker,
> `0x80` for Lend/Borrow) and revert `MalformedData()` otherwise; the Taker also
> rejects `balanceMode > 1` (`BadBalanceMode`).

MAKE constructors take `(permit3, midnight, settlement)`; TAKE constructors take
`(permit3, midnight)`. The Midnight singleton is fixed at deploy time; the market
/ offer is selected per-item via `data`.

## Authorization

A module only moves a maker's funds if these are signed/approved beforehand —
Settlement and the solver can never widen them:

| Gate | Who enforces | What it caps |
|---|---|---|
| Permit3 **token** allowance (`approveToken(module, token, cap)`) | Permit3 | MAKE legs — how much of *this token* the module may pull (supply, repay, lend budget) |
| Permit3 **taker** allowance (`approveTaker(settlement, module, ref, cap, expiry)`) | Permit3, TAKE only | how much may be drawn on *this exact item* (`ref = keccak256(data)`); keyed by **spender = Settlement** |
| Midnight **authorization** (`setIsAuthorized(module, true, maker)`) | Midnight | **every** module here — the venue gates `supplyCollateral`, `repay`, `withdraw`, `withdrawCollateral` and `take` on `onBehalf == msg.sender \|\| isAuthorized[onBehalf][msg.sender]` |

> **Midnight's coarse auth.** `setIsAuthorized(module, true, maker)` grants the
> module full control of the maker's position. The combined `MidnightTakerModule`
> multiplexes `withdrawCollateral` + `withdraw` behind a leading `op` flag, so a
> single authorization covers both; the op flag is the first tuple field, so the
> legs hash to **different** Permit3 taker refs and each still carries its own
> per-market, amount-gated allowance.
>
> **The value-IN legs need auth too.** The deployed venue gates `supplyCollateral`
> ("to prevent activated collateral poisoning") and `repay` exactly like the
> value-out ops, and `take` gates any `taker ≠ msg.sender`. So a maker must grant
> `MidnightSupplyCollateralModule`, `MidnightRepayModule`, `MidnightLendModule`,
> `MidnightPreFundModule` and — for a borrow-and-loop offer — `MidnightLoopCallback`
> as well as the taker/borrow modules. Fork-verified on the Base singleton
> ([`test/fork/MidnightBaseFork`](test/fork/MidnightBaseFork.t.sol): unauthorized
> `supplyCollateral` / `repay` revert `Unauthorized()` 0x82b42900). These modules
> were documented as grant-free until the 2026-09-30 audit (L-ML-1); the old test
> mock skipped the check.
>
> **A grant is full control, including re-delegation.** Midnight lets an
> authorized address call `setIsAuthorized` on the maker's behalf. Every contract
> here exercises only the one op its code performs, on maker-signed data, behind
> the Settlement / Permit3 / Midnight caller pins, and none calls
> `setIsAuthorized`, `setConsumed` or `multicall` — but revoke any grant you no
> longer use.

## Flows

### Leverage — supply collateral, borrow against it (order-book fill)

```
order: tokenIn = LOAN, tokenOut = COLL   items = [MAKE supplyCollateral, TAKE borrow]

  deliver: solver ──COLL──▶ maker                     (tokenOut)
  [0] MAKE  MidnightSupplyCollateralModule  maker ──COLL──▶ supplyCollateral(onBehalf = maker)
  [1] TAKE  MidnightBorrowModule    take(offer.buy, taker = maker) ──LOAN──▶ Settlement
  pay:      Settlement ──LOAN──▶ solver               (borrow proceeds)
```

The borrow leg's `units` is fixed in the signed data, so a borrow item **must**
ride a fill-or-kill order (a fixed unit count can't be pro-rata'd across partial
fills). The proceeds are `units · (price − settlementFee)`, and Midnight's
`feeSetter` may raise the fee at any time: the module reverts (`ShortWithdraw`)
rather than letting the core bill the gap to the maker's wallet. Sign `totalAmount`
a little below the quoted proceeds to absorb fee moves; the excess comes back.

### Deleverage — repay, withdraw collateral

```
order: tokenIn = COLL, tokenOut = LOAN   items = [MAKE repay, TAKE withdrawCollateral]

  deliver: solver ──LOAN──▶ maker
  [0] MAKE  MidnightRepayModule     repay(min(amount, debt))          (pull-exact, callback = 0)
  [1] TAKE  MidnightTakerModule (op=0)  withdrawCollateral ──COLL──▶ Settlement
  pay:      Settlement ──COLL──▶ solver
```

`Full` balance mode (a `balanceMode` tuple field) withdraws the maker's ENTIRE
collateral to the module, forwards the signed slice to `receiver`, and sweeps the
surplus back to the maker — pair with fill-or-kill. For credit (`op=1`) the
position is first brought up to date with the permissionless `updatePosition`
(loss-factor slash + accrued continuous fee); the raw `credit()` getter is stale.

### Borrow and loop — `MidnightLoopCallback`

A borrower rests a `buy = false` offer with `callback = MidnightLoopCallback` and
`receiverIfMakerIsSeller = MidnightLoopCallback`; any lender's `take` swaps the
proceeds to collateral and supplies it before Midnight's solvency check. The
slippage floor is signed as a **rate** (`minRateWad`, collateral wei per loan wei,
1e18-scaled) and applied as `ceil(sellerAssets · minRateWad / 1e18)` to each take,
because Midnight takes are partial and taker-sized — an absolute floor either
blocks every partial take or under-protects a large one (audit 2026-09-30
L-ML-4). The borrower must `setIsAuthorized(loopCallback, true, borrower)`.

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
seed on a live fork — so, like the composer's Midnight suite, the flow tests drive
a [`MidnightMock`](test/shared/MidnightMock.sol) with mock ERC20s, over the
**real** `Settlement` + `Permit3`. The mock reproduces the venue semantics the
modules depend on: `setIsAuthorized` gating on EVERY position write (supply and
repay included) with re-delegation, the ratifier gate, `maxUnits`/`maxAssets`
consumption, `SelfTake` / `UnusedReceiverMustBeZero`, the settlement fee, the
upstream payer resolution and seller solvency check, and lazy credit updates
(`credit()` stale until `updatePosition`). Prices stay at par. A Base-fork smoke
suite pins those facts against the deployed singleton.

```
FOUNDRY_PROFILE=modules-morpho-midnight forge test
```

| Test | Flow |
|---|---|
| [`MidnightFlows`](test/MidnightFlows.t.sol) | supply+borrow, repay+withdraw (exact & full), lend (+ budget buffer), redeem credit |
| [`security/ModuleAuth`](test/security/ModuleAuth.t.sol) | `NotSettlement` / `OnlyPermit3` direct-call rejection; `setIsAuthorized` gate is load-bearing |
| [`security/Audit20260930Midnight`](test/security/Audit20260930Midnight.t.sol) | 2026-09-30 audit regressions: borrow delivery bound under a fee rise, supply/repay grants, Full credit exit after a slash, strict blob heads, `balanceMode` range |
| [`MidnightLoopCallback`](test/MidnightLoopCallback.t.sol) | borrow-and-loop; rate-scaled slippage floor across partial takes |
| [`fork/MidnightBaseFork`](test/fork/MidnightBaseFork.t.sol) | **live Base singleton**: supply/repay/withdraw auth gates, re-delegation, `MidnightIdLib.toId` == the venue's `touchMarket` id, `updatePosition` present. Needs a Base RPC (public fallbacks; `BASE_RPC_URL` overrides) |

> The offer/ratifier economics (ticks, zero-coupon discounting) are still
> mock-only: exercising them on the fork needs signed maker offers.
