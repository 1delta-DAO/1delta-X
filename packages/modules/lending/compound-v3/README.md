# @1delta-x/modules-compound-v3

Compound v3 (Comet) lending adapters for `Settlement`. Each contract is
a **single-op module** — a thin, stateless adapter that performs exactly one
Comet action (supply, withdraw, borrow, repay) on the order maker's behalf when
Settlement processes an order item. Composed together inside one signed order,
they express leverage, deleverage and cross-market migration as a single atomic
intent that any solver can fill.

The dependency points one way: this package depends on `@core`, never the
reverse. The modules live in [`src/`](src/); the fork tests in [`test/`](test/).

## Comet collapses four actions into two

A Comet market has **one base asset** (borrowable/lendable, e.g. USDC) and a set
of **collateral assets**. Two methods cover every position move:

| Method | `asset = base` | `asset = collateral` |
|---|---|---|
| `supplyTo(dst, asset, amt)` | lend base / **repay** a base borrow | post collateral (**deposit**) |
| `withdrawFrom(src, to, asset, amt)` | **borrow** (withdraw past supply) | **withdraw** collateral |

So Aave's four modules collapse onto two underlying calls here. For 1:1 symmetry
with [`@1delta-x/modules-aave-v3`](../aave-v3) we still ship **four named
modules** — deposit and repay both `supplyTo`, withdraw and borrow both
`withdrawFrom`. The distinct addresses give each leg its own Permit3
module/ref namespace, exactly like the Aave package.

Every module's `data` is `abi.encode(comet, asset)` — no `rateMode` (Comet has a
single rate) and no receipt token (positions are internal to Comet, read via
`balanceOf` / `borrowBalanceOf` / `collateralBalanceOf`).

## How a module plugs into a fill

A maker signs one `Order` carrying an `Item[]`. Each item names a `module`
and an `op` (`MAKE` or `TAKE`). Settlement walks the items in order, then settles
the `tokenIn → tokenOut` swap leg between maker and solver.

- **MAKE** = *value in* (deposit / repay): the module pulls the funding token
  from the maker via Permit3 and pushes it into Comet.
- **TAKE** = *value out* (borrow / withdraw): Settlement routes through
  `permit3.take`, which enforces the **taker-allowance gate** on
  `ref = keccak256(data)` before dispatching; proceeds go to `receiver`
  (`address(0)` → Settlement, funding the `tokenIn` payout; `maker` → chains the
  output into a later MAKE item).

`module` and `data` are inside the order's EIP‑712 hash, so the solver cannot
alter which Comet market/asset is touched or how much.

## Authorization: two gates per leg

A module only moves a maker's funds if **both** of these are set by the maker
beforehand — Settlement and the solver can never widen them:

| Gate | Who enforces | What it caps |
|---|---|---|
| Permit3 **token** allowance (`approveToken(module, token, cap)`) | Permit3 | how much of *this token* a MAKE module may pull from the maker |
| Permit3 **taker** allowance (`approveTaker(settlement, ref, cap)`) | Permit3, TAKE only | how much may be drawn on *this exact position* (`ref = keccak256(data)`); keyed by **spender = Settlement** (only Settlement can consume it). See [`/SECURITY.md`](../../../../SECURITY.md). |
| Comet **account manager** (`comet.allow(module, true)`) | Comet | TAKE only — Comet's own permission for the module to call `withdrawFrom` on the maker's position |

> **Note on `comet.allow`.** Unlike Aave's per-asset credit delegation +
> per-token receipt approval, Comet's `allow` is a **single boolean covering the
> maker's whole position in that market** — a granted module could withdraw any
> collateral or borrow the base, up to health limits. The actual fill size is
> still capped by the Permit3 taker allowance, but the Comet-native grant is
> broad: makers should `allow(module, false)` once they're done, or only grant it
> to modules they trust. `allow` is a Comet call and cannot ride inside a Permit3
> signature, so single-signature (`fillWithPermit`) flows still need it set up
> front (Comet's own `allowBySig` could bundle it; not wired here).

## Modules (`src/`)

| Contract | Op | Comet action | `data` |
|---|---|---|---|
| [`CometDepositModule`](src/CompoundV3Modules.sol) | MAKE | pull asset from maker → `supplyTo(dst = maker)` (collateral or base) | `abi.encode(comet, asset)` |
| [`CometRepayModule`](src/CompoundV3Modules.sol) | MAKE | pull buffered base → `supplyTo` capped at live debt; sweep over-repay back to maker | `abi.encode(comet, base)` |
| [`CometTakerModule`](src/CompoundV3Modules.sol) | TAKE | `withdrawFrom(src = maker)` → `receiver`; leg selected by leading `op` (Borrow=0 base, Withdraw=1 collateral) | `abi.encode(uint8 op, comet, asset)` |
| [`interfaces/ICompoundV3.sol`](src/interfaces/ICompoundV3.sol) | — | minimal Comet surface | — |

`CometTakerModule` fuses borrow and withdraw into one contract — both are the
same `withdrawFrom` call. A leading `op` flag in `data` selects the leg, so a
maker authorises ONE module address (`comet.allow(takerModule, true)`, or one
allow-by-sig) for both. The op byte is the first word of `data`, so the two legs
still hash to **different** Permit3 refs (`keccak256(data)`) and each gets its own
amount-gated taker allowance. Because the modules are market-address-agnostic,
the **same** modules drive any Comet market by passing a different `comet` in
`data` — which is exactly what the migration flow exploits.

## Flows

### Leverage — deposit collateral, borrow against it (`DepositBorrow`)

`_buildDepositBorrowOrder`: one MAKE then one TAKE on the USDC Comet. The maker
puts WETH in and the borrowed USDC funds the `tokenIn` the solver is paid with.

```
order: tokenIn = USDC, tokenOut = WETH      items = [MAKE deposit, TAKE borrow]

  [0] MAKE  CometDepositModule   maker ──WETH──▶ comet.supplyTo(dst = maker)
  [1] TAKE  CometTakerModule(Borrow)    comet.withdrawFrom(src = maker, USDC) ──▶ Settlement
                                 └─ comet.allow authorises the module
  settle:   Settlement ──USDC──▶ solver        (entirely from borrow proceeds)
            solver     ──WETH──▶ maker         (tokenOut, the added collateral)
```

`FlashLoanLeverage` drives the identical order with a zero-inventory solver that
flash-loans the WETH and swaps the borrowed USDC back to repay it.

### Deleverage — withdraw collateral, swap to repay (`WithdrawAndSwap`)

`_buildWithdrawOrder`: a single TAKE. The maker's collateral is withdrawn for
WETH that goes straight to the solver, who pays USDC back as `tokenOut`.

```
order: tokenIn = WETH, tokenOut = USDC      items = [TAKE withdraw]

  [0] TAKE  CometTakerModule(Withdraw)  comet.withdrawFrom(src = maker, WETH) ──▶ Settlement
  settle:   Settlement ──WETH──▶ solver
            solver     ──USDC──▶ maker
```

### Repay — pull buffered base, repay, refund the dust (`Repay`)

`_buildRepayOrder`: a single MAKE. The maker signs a *buffered* amount to cover
interest accrual between signing and fill. Comet's `supplyTo` would turn any
over-repay into a stray supply balance, so the module reads the live debt,
supplies only `min(amount, debt)`, and sweeps the remainder back to the maker.

```
order: tokenIn = WETH, tokenOut = USDC      items = [MAKE repay]

  [0] MAKE  CometRepayModule   maker ──USDC(buffered)──▶ supplyTo(min(amt, debt))
                               └─ residual dust ──USDC──▶ maker   (never to solver)
  settle:   solver ──USDC──▶ maker ;  maker ──WETH──▶ solver
```

### Migration — move a whole position across markets (`Migrate`)

`_buildMigrationOrder`: four items chained in one atomic fill move a WETH/USDC
position from the **USDC Comet** onto the **USDS Comet**. The withdraw item sets
`recipient = maker` to chain the freed WETH into the next deposit; the final
borrow funds the repay. Because the two markets have different base assets, the
swap leg is genuine (USDC in, USDS out) — unlike Aave's same-asset Aave→Spark
case.

```
items = [MAKE repay(USDC-Comet), TAKE withdraw(USDC-Comet)→maker, MAKE deposit(USDS-Comet), TAKE borrow(USDS-Comet)]

  [0] MAKE  repay     USDC-Comet   close USDC debt (buffered)
  [1] TAKE  withdraw  USDC-Comet   withdrawFrom ──WETH──▶ maker        (recipient = maker, chained)
  [2] MAKE  deposit   USDS-Comet   maker ──WETH──▶ supplyTo
  [3] TAKE  borrow    USDS-Comet   withdrawFrom(USDS) ──▶ Settlement   (funds the tokenIn payout)

  Net: position leaves the USDC market and lands on the USDS market; solver fronts
       the repay USDC and is paid in the freshly-borrowed USDS — all-or-nothing.
```

## Security properties

- **Taker modules are Permit3-gated.** `takeOnBehalf` reverts with `OnlyPermit3`
  unless `msg.sender == permit3`. Without it a direct call could bypass the
  taker-allowance gate and drain a position the maker `allow`-ed the module to
  touch — see
  [`test/security/TakerModuleAuth.t.sol`](test/security/TakerModuleAuth.t.sol).
- **Repay refunds to the maker, not `data`.** The over-repay sweep destination is
  the `onBehalfOf` function argument, not an attacker-controllable field of
  `data`, closing the "redirect the dust" vector without needing a sender gate.
  A reentrancy lock guards against weird-token transfer hooks.
- **Post-fill invariants.** Orders can carry `IOrderValidator` invariants that run
  after all items execute; a failing one reverts the whole fill and rolls maker
  state back (`test/limit-orders/Invariants.t.sol`).

## Tests

Forked Ethereum mainnet, exercising the real Compound v3 USDC and USDS Comets.

```
pnpm --filter @1delta-x/modules-compound-v3 test
# or, from the repo root:
forge test --match-path 'packages/modules-compound-v3/**'
```

Coverage spans each flow above plus the limit-order surface (min-fill,
exclusivity, validators, invariants), permit-based fills, and the taker-auth
security check.
