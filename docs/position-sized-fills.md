# Position-sized fills — selling the accrued interest instead of returning it as dust

**Status:** one venue-agnostic fill module + a `positionOf` read on seven taker
modules (aave-v3, compound-v3, morpho-blue collateral, silo, euler-v2, exactly,
gearbox-v3). Zero Settlement bytes.

## The problem

A maker signing *"exit my Aave WETH position"* cannot know the amount — it accrues
between signing and inclusion. Today that gap is closed at the **module**, by
`DustHandler.BalanceMode.Full`: the module reads the live position, forwards the
signed `amount` to the order, and pays the remainder back to `onBehalfOf`.

The position ends fully exited, which is correct. But the remainder arrives as the
**raw underlying in the maker's wallet** — unconverted, at dust size, and denominated
in exactly the token they signed an order to get rid of.

```
signed:    1.0 WETH → 2000 USDC          (2000/WETH)
position:  1.3 WETH at fill time
result:    2000 USDC  +  0.3 WETH sitting in the wallet
```

## Why `Proportional` is not the fix

[`Proportional`](../packages/core/src/settlement/Proportional.sol) is the core's
balance-relative encoding, and its own contract note names this drift — *"accrued
interest, a rebase, a pending transfer landing"* — as the thing it exists to absorb.
It is still the wrong shape here, for two independent reasons:

1. **The output is anchor-invariant.** A proportional order is full-fill only, so the
   fill fraction is exactly 1 and `ceil(anchor · start / anchor) == start`. The maker
   receives the *same* output whether the balance resolved at 1.0 or at 1.3
   (`Proportional.sol:100-118`). It absorbs the drift; it does not price it. The dust
   would be **given away**, not converted.
2. **It cannot see a position.** `resolve()` reads `balanceOf(legToken, maker)` in
   `OrderGates.anchorTotal`, *before any funds move* — and pre-withdraw the maker
   holds none of the underlying.

Extending it is also closed off by a measured decision: resolving markers on
`legsIn[1..n]` cost **+2,106 bytes** of Settlement (25,264 vs EIP-170's 24,576),
buyable back only at `optimizer_runs = 2000` for **+4,307 gas on every fill of every
order** (`Pricing.sol:127-141`).

## The mechanism

`order.fillModule` already carries a fill-time number into the core, and — unlike a
proportional leg — **every leg and every item scales by `delta / fillTotal`**
(`Pricing.outputAt`, `Base._prorate`). So resolving the position in a fill module and
returning it as `delta` sells the accrued interest **at the maker's own signed rate**:

```
fillTotal   = 1.5 WETH    (the maker-signed CAP)
legsIn[0]   = { WETH, 1.5 WETH, 0 }
legsOut[0]  = { USDC, 3000 USDC, 0 }
items[0]    = { TAKE, AaveV3WithdrawModule, 1.5 WETH, 0, (pool, asset, aToken) }

position resolves to 1.3 WETH
⇒ delta = 1.3 → maker is paid ceil(1.3 · 3000 / 1.5) = 2600 USDC, wallet dust 0
```

`IFillModule.resolveFill` is a `view` STATICCALL made in `OrderState._openFill` —
after the reentrancy guard, before items, pricing and the input pull.

### Which item carries the position — found, not indexed

The fill module **scans** the items for the one whose module answers `positionOf`,
rather than reading item 0. That is forced by how a real close is shaped: a levered
position cannot have its collateral moved out while the debt is open (Aave reverts on
the health factor, error 35), so a close is signed `[repay, withdraw]` and the
position-bearing item is **not first**. Pinning an index would have made the whole
close flow unexpressible.

The item identifies itself — a module that does not implement `IPositionSource` has no
such function and reverts; one that does but refuses the op in its `data` (a borrow
leg, a share-denominated side) reverts too. Both are skipped. Two reporters revert
`AmbiguousPositionItem` rather than letting signing order decide.

The cost is diagnostic, not safety: a refusing module's own revert reason is swallowed
by the `try`/`catch` and surfaces as `NoPositionItem`.

### Where the venue knowledge lives

`PositionFillModule` holds **none**. It takes no constructor arguments and there is
one deployment for every venue. It finds the position-bearing item in the maker-signed order (see above) and
asks *that* module what the position is, through
[`IPositionSource`](../packages/core/src/interfaces/IPositionSource.sol):

```solidity
function positionOf(address user, bytes calldata data)
    external view returns (address asset, uint256 amount);
```

Three consequences, all of them the point:

1. **The byte map is decoded once**, in the module that defines it. A reader that
   decoded `data`'s layout from outside would be a second copy of it — exactly the
   failure this codebase keeps finding (a rule re-typed per call site landing on one
   sibling and missing its neighbour).
2. **The module asked IS the module that executes the item.** The pairing is
   structural, not configured, so there is no address to get wrong — and no
   `_morpho`-style constructor argument that can silently disagree with the taker
   module's own immutable.
3. **The module's own `Full` branch calls `positionOf` too.** The number a fill is
   *priced* against and the number the withdraw actually *takes* are then the same
   function, not two copies of one read.

`resolveFill` itself deliberately stays *off* the lending modules. It takes
`Order calldata`, and `Order` is the most-churned type in the codebase (the
timing fold, the LegIn/LegOut redesign, packed arrays, fill modules, rising
inputs) — every one of those would force a recompile of every lending package. And
those are the contracts holding standing allowances: Permit3 taker allowances are
keyed on the module address, and makers hold a direct aToken approval to the
withdraw module, so redeploying one invalidates every maker's approvals. The fill
module holds nothing and is pure view, so the churn belongs there.

`IPositionSource` must never reach Settlement's compilation unit — same rule as
`IFundingSource`, where merely declaring the function measured +7 bytes.

### The three amounts must be the same number

`Base._prorate` and `Pricing.inputOwed` both compute `x · delta / fillTotal`, which is
**exact — no rounding at all — only when `x == fillTotal`**. So the base requires

```
items[0].amount == legsIn[0].start == fillTotal
```

and refuses anything else (`DenominatorMismatch`). Signed any other way the item slice
and the leg charge drift apart by a rounding unit. A shape that can only be signed
wrongly is a shape the module refuses.

### What it retires

Because the position is resolved **before** the item runs, the item runs in `Exact`
mode with `amount == the live position`. Within one block the venue's index cannot
move between the STATICCALL and the withdraw, so **the residual is zero**: no `Full`
branch, no `FullFillGuard`, no sweep.

That is worth having on its own. `FullFillGuard` exists only because a module cannot
tell the core what it moved, so the maker must pre-commit the slice against a
hand-written per-module byte map — and that map has already produced one
filler-reachable force-unwind (`CompoundV3Modules.sol:259-266`: the Comet allow-by-sig
`nonce` read as the maker's signed total, letting a filler unwind a whole position on a
dust slice).

## Guards, and why each exists

| guard | error | why |
|---|---|---|
| `fillTotal != 0` | `NoDenominator` | `fillTotal` **is** the cap. A maker's *position* is not under their sole control — on every venue here a third party may `supply(asset, amount, onBehalfOf = maker)`, exactly as anyone may raise a wallet balance by transferring in. Uncapped would be a standing offer to sell an arbitrarily large position at a price signed for a much smaller one. `0` is the unset value, so it must not mean "unbounded". Same reasoning as `ProportionalNeedsCap`. |
| `prevFilled == 0` | `AlreadyFilled` | One-shot. The first fill is a **partial** one whenever the position is below the cap, so without this the order stays open at the signed rate and a later re-supply is sellable at the old price. `Proportional` gets this free by being full-fill only. The fill-once timing bit **cannot** substitute — it requires `delta == fillTotal`, precisely the case this module does not produce. |
| `asset == legsIn[0].token` | `PositionAssetMismatch` | **The units check.** The module reports what token its position is denominated in; if it is not the token being sold, the fill numerator and the leg it scales are denominated differently. Nothing checked this in the per-venue design. |
| `item.amount == legsIn[0].start == fillTotal` | `DenominatorMismatch` | See "the three amounts". |
| `delta <= fillAmount` | `PositionExceedsQuote` | **The solver's staleness bound.** `Proportional` gets this free from `fillUpTo`'s clamp — "the solver is never silently made to buy more than it priced" — but a fill-module order **bypasses that clamp** (`Core._clampToRemaining` returns a module order's proposal untouched). So `fillAmount` is honoured as a ceiling. It *reverts* rather than filling small, which is `Proportional`'s semantics too: the order is one-shot, so a small fill would leave the maker partially exited with their exit order spent — and would hand the filler the unwind size after all. A solver with no view on size passes `fillTotal`, which can never bind. |
| SELL side | `NotASellOrder` | A BUY order prices off `legsOut[0]`; "sell my whole position" is a SELL. |
| the op byte | the module's own `BadOp` | Most of these modules multiplex borrow and withdraw behind a leading op byte. Sizing a borrow leg from a supply position would price the fill off an unrelated number. Enforced *inside* `positionOf`, where the op is already being decoded. |
| no `positionOf` at all | STATICCALL reverts | A module that does not implement the interface has no such function, so the fill fails closed rather than resolving something. |

The core keeps the money-critical half regardless: it owns the denominator, the
`filled + delta <= fillTotal` cap, and the uniform per-leg scaling. A wrong number from
a fill module mis-sizes the *fraction*, which scales the maker's side and the solver's
side identically.

## Venue coverage

| venue | reader | denominated in |
|---|---|---|
| aave-v3 | `aToken.balanceOf(user)` — rebases 1:1 | the underlying, from `data` |
| compound-v3 | `baseToken()` split: `balanceOf` for base, `collateralBalanceOf` otherwise | the asset, from `data` |
| morpho-blue | `position(id, user).collateral` — asset-denominated and exact | `marketParams.collateralToken` |
| silo, euler-v2, exactly, gearbox-v3 | `previewRedeem(balanceOf(user))` / `convertToAssets(balanceOf(user))` — the RAW position | `vault.asset()`, read from the **vault**, never from `data` |


⚠ **NOT `maxWithdraw`, and this was a real bug until 2026-09-10.** `maxWithdraw` is a
REACHABILITY figure — `ISilo` calls it *"liquidity-bounded"*, `IEulerV2` *"given
liquidity & health"* — and `IPositionSource` forbids it in capitals. Two things went
wrong while it was there: on a `[repay, withdraw]` close `resolveFill` runs *before*
the repay, so the number reflected a debt the fill was about to retire and the close
**half-exited while succeeding**; and vault cash is third-party movable, so a flash
loan collapsed the delta to dust and consumed the maker's one-shot order for ~nothing.
The raw share conversion is what this package's own fork tests already used, for
exactly this reason. If the position is unreachable the venue's withdraw reverts —
which is the loud failure the interface asks for.

`positionOf` returns the **raw** position, deliberately *not* bounded by the module's
allowance the way `fundingSource` is. That is the right answer for a preflight ("can
this be pulled?") and the wrong one for sizing a fill: a short approval must make the
fill revert on the pull, not quietly sell a fraction *and consume the maker's one-shot
exit order*, leaving them half-exited with nothing left to fill. Fail closed, not
small.

### Deliberately not covered

- **Morpho Blue's loan/earn side (`Op.Withdraw`)** is refused with the module's own `BadOp`. The
  position is denominated in **shares**, and the module must return assets. The honest
  conversion needs the market's *accrued* totals, and getting it subtly wrong
  mis-prices the maker's fill rather than reverting. The paired `_withdrawLoanFull`
  sidesteps this by settling its remainder **by shares** — an option a fill module does
  not have. Keeps `BalanceMode.Full` until a share→asset reader lands.
- **compound-v2 / venus.** `balanceOfUnderlying` is not `view`, and
  `exchangeRateStored` is stale. Keeps `BalanceMode.Full`.

## For fillers

**Most of the time, nothing.** The size of a position-sized order is discovered the
same way any module order's size is — the lens already mirrors `_openFill`, including
the `resolveFill` call:

```solidity
(uint256 delta, uint256[] memory received, uint256[] memory paid) =
    lens.previewFill(order, order.fillTotal, filler, takerData);

settlement.fill(order, sig, delta);          // submit the size you quoted
```

Two properties make this a universal recipe rather than a special case:

- **`order.fillTotal` is a probe that can never bind.** The core caps every module
  order at `filled + delta <= fillTotal` regardless, so passing the signed
  denominator is always safe — for identity orders, `FullFillModule`,
  `TwapFillModule` and this one alike. No classification needed to quote.
- **Re-submitting the returned `delta` *is* the staleness bound.** It costs nothing
  on orders where size is fixed, and on this one it is exactly the protection
  `fillUpTo`'s clamp would have given if module orders went through it.

Pinned end to end by `test_fillerRecipe_probeWithFillTotal_thenSubmitTheDelta`, which
asserts the preview's `paid`/`received` match the executed fill exactly.

### ⚠ On the netted path (`matchSettle`), the two calls take different numbers

The probe takes `fillTotal`; the **fill takes the quoted `delta`** — and in a batch
that distinction is the whole ballgame. `p.fillAmounts[i]` reaches `resolveFill`
during **phase 1**, before any token moves (`Batch._matchOpenAll`), so passing the
quoted size makes a drifted position revert at open, cheaply. Passing `fillTotal`
instead lets the plan proceed on a size the solver never simulated, and it blows up
later as `BatchNotWhole` / `LegUnfunded` / a reverting venue call — after signatures,
venue reads and real withdraws have been paid for.

**That bound is the only one a netted solver has for this shape.** A
`MatchRaceGuard`-style `filled[hash]` equality check cannot substitute: a lending
index ticking, or a third party calling `supply(..., onBehalfOf = maker)`, changes
the resolved size *without touching `filled`*. Position-sized orders are the one
class whose plan can be invalidated by state that guard does not track — which is
exactly what `dynamicSize` on `describeFill` is telling you.

Pinned by `test_matchSettle_positionGrewPastTheQuote_revertsAtOpen`.

**And do not bundle two orders that share one position.** `matchSettle` resolves
every order's delta in phase 1, before any withdraw runs, so both resolve against the
same live balance and the plan tries to withdraw it twice. The one-shot guard does
not help — it keys on the order hash, and these are two different orders. It fails
closed, but only because the venue's own receipt transfer reverts on a drained
balance, not because the settler noticed; the solver sees an untyped
`TransferFromFailed`.

⚠ **And that is venue-specific.** It holds for Aave, Morpho and Comet *collateral*,
but **not** for Comet's BASE ledger, where the repo's own interface says
`withdrawFrom` will *"withdraw a base supply, **or BORROW past it**"* — so a second
drain becomes new debt on the maker rather than a revert. `CometTakerModule` now
bounds a base withdraw by the live supply (`WouldBorrow`) precisely so this premise
holds everywhere. Pinned by `test_matchSettle_twoOrdersOneposition_failsClosed`.

### The netting recipe, and why it works

A position-sized exit **does** net against a plain order with zero solver capital.
Alice sells her whole live position; Bob is an ordinary limit buyer:

```
schedule: ITEM(alice,0)  → alice's withdraw puts WETH in the pool
          PULL(bob,0)    → bob's USDC into the pool
          DELIVER(alice) → pool → alice: USDC   (funded by bob)
          DELIVER(bob)   → pool → bob:   WETH   (funded by alice)
```

Measured (`test_match_positionSizedExit_netsAgainstAPlainBuy_zeroSolverCapital`,
462,725 gas): Alice sold her live 1.3 WETH and was paid 2,600 USDC — *pro rata for
all of it*, accrued interest included. Bob got his signed 1.2 WETH for 2,700 USDC.
The solver started flat and ended with the spread in both assets (+0.1 WETH,
+100 USDC). No order-granular sequence exists for this: Alice can't be paid before
Bob pays, and Bob can't be delivered before Alice withdraws.

**The asymmetry that makes it delicate:** Alice's size is resolved on-chain, Bob's
is a signed constant, so they net only if Alice's delta covers Bob's delivery. Hence
two rules:

1. **Size the fixed side at or below the floor you'll accept from the dynamic one**,
   never at the expectation. A surplus is solver profit; a shortfall is a revert.
2. **Both drift directions need a bound, and they come from different parties.**
   `fillAmounts[i]` is a *ceiling* (the solver's), so it catches growth. A **shrink**
   is bounded only by the maker's `minFillAnchor`.

### `minFillAnchor` is not optional on an order meant for netting

Measured from identical state, same drift, the only difference being the floor
(`test_gas_failAtOpen_vs_failLate`):

| | solver's gas |
|---|---|
| shrink caught at open by `minFillAnchor` | **66,864** |
| no floor — dies when `DELIVER(bob)` finds the pool short | **370,169** |

**5.5×.** Both are atomic, so the makers are indifferent; the whole difference is the
solver's, paid for signatures, the venue read and a real `pool.withdraw` before
finding out. This is precisely the case `MatchRaceGuard` cannot pre-empt, because
`filled[hash]` does not move when a lending index ticks.

### When a filler does want to classify

A hardcoded list of fill-module addresses is brittle, so the modules self-describe
through the optional
[`IFillModuleDescribe`](../packages/core/src/interfaces/IFillModuleDescribe.sol) —
a revert means "no description available", the `ITakerModuleDescribe` convention:

```solidity
(bytes32 kind, bool dynamicSize, bool oneShot) = IFillModuleDescribe(order.fillModule).describeFill();
```

| module | kind | dynamicSize | oneShot |
|---|---|---|---|
| `PositionFillModule` | `"POSITION_SIZED"` | yes — moves with accrual, and with anyone supplying on the maker's behalf | yes — closed after one fill even when it advanced less than the cap |
| `FullFillModule` | `"FULL_FILL"` | no — `fillTotal - prevFilled` is a signed constant | yes |
| `TwapFillModule` | `"TWAP"` | yes, in the *clock* rather than chain state | no — a sequence of fills is the point |

`dynamicSize` is the flag that says "re-quote close to submission"; `oneShot` says
"do not plan a follow-up, and do not read a small `delta` as *more available later*".
Note the address check is a single compare anyway — `PositionFillModule` is
venue-agnostic, so there is one deployment, not one per venue.

⚠ `getOrderRelevantStates`' `fillableAmount` reports the order's **remaining
denominator** (the maker's cap), not the resolved position — it is a liveness signal,
not a quote. Use `previewFill` for the size.

## Known edges

- **This is the first composition of a `fillModule` with *executing items* in the
  tree.** `FillModule.t.sol` only ever feeds an item to the lens, and
  `BridgedOrderInbox` rejects fill-module orders outright. The fork suites below are
  the whole of the evidence.
- The **maker's** matching floor is `order.minFillAnchor`, which the core already
  checks against the resolved `delta` — no machinery needed in the fill module.
  Without it a filler could burn a one-shot exit order on a dust position.
- Mutually exclusive with proportional legs (`Pricing.sol:116-119`) and with
  balance-relative funding descriptors below full fill.
- The order is left **partially filled** after its one fill. That is intended; the
  `AlreadyFilled` guard is what makes it safe.

## Tests

- `packages/modules/lending/aave-v3/test/swaps/PositionSizedWithdraw.t.sol` — the
  property (`test_positionSized_sellsTheAccruedInterestToo`), the `BalanceMode.Full`
  baseline it replaces asserted at the **same rate**
  (`test_baseline_fullMode_leavesTheExcessUnconverted`), the cap clamp, and every guard.
- `packages/modules/lending/compound-v3/test/swaps/PositionSizedWithdraw.t.sol` — both
  Comet ledgers, seeded to **different** amounts so a reader consulting the wrong one
  cannot coincidentally pass, plus the wrong-op guard.
- **All seven venues now have `positionOf` coverage** (the audit found only three
  did, and the four gaps were exactly where findings 1, 3 and 12 lived):
  `silo/test/fork/PositionSized.t.sol`, `euler-v2/test/fork/PositionSized.t.sol` and
  `exactly/test/fork/PositionSized.t.sol` open a **levered** position so
  `maxWithdraw` is clipped strictly below the real balance, then assert the reader
  reports the raw one — reverting silo's reader to `maxWithdraw` makes it report
  **3.32 wstETH against a real 5.0**, which is the bug quantified on live mainnet
  state. Gearbox has **both**: `gearbox-v3/test/fork/PoolPositionSized.t.sol` proves the
  reader against the real PoolV3 — whose address is **derived from
  `CreditManagerV3.pool()`** on the credit manager the package already pins, so it is
  authoritative for the block rather than a guessed constant — and
  `test/unit/GearboxPoolPositionSized.t.sol` keeps the mock, because only a mock can
  FORCE both divergences (a clipped `maxWithdraw`, and a `data.asset` disagreeing
  with `pool.asset()`) that a liquid live pool will not reliably produce.
- `packages/modules/lending/morpho-blue/test/closing/PositionSizedLoopClose.t.sol` and
  `packages/modules/lending/compound-v3/test/closing/PositionSizedLoopClose.t.sol` — the
  same close on a storage-only position (morpho) and on Comet's collateral ledger, each
  with a `test_positionItemIsNotIndexZero` that pins why the scan is needed.
- `packages/modules/lending/aave-v3/test/closing/PositionSizedLoopClose.t.sol` — a full
  wstETH/WETH loop close on a fork: withdraw the whole wstETH position, sell it for
  WETH (the solver's side — there is no swap item, the legs *are* the swap), repay the
  WETH debt, and take the remainder as native ETH via `NativeUnwrapModule`. Also the
  A/B gas comparison and the loose-cap failure below.

### Measured, on the loop close

| | position-sized | `BalanceMode.Full` |
|---|---|---|
| gas (90 days of accrual) | 487,189 | 525,457 |
| unconverted wstETH left with the maker | **0** | 2,864,921,722,160,599 wei |

**Position-sizing is ~38k gas CHEAPER**, which is not what I expected. It adds a
`resolveFill` staticcall and a venue read, but it removes a second `pool.withdraw`:
`Full` must withdraw the whole position and then split it with two ERC-20 transfers,
and position-sizing leaves nothing to split. (`Full` itself was 536,396 before the
withdraw-once-then-sweep change; see I-8 in `module-security-model.md`.) The sign inverts only
when accrual is exactly zero (then `bal > amount` is false, `Full` makes one withdraw,
and the staticcall makes position-sizing ~13k dearer) — so it is logged, not asserted.

### The one shape that bites: a loose cap

Every leg scales by `delta / fillTotal`, and `delta` is the **collateral**. The
**debt does not scale with it**. So the WETH leg funding the repay must be signed with
enough headroom to still cover the debt after being scaled by the ratio the collateral
came in at. A cap far above the real position scales that leg down while the debt
stays put, and the repay pull exceeds what was delivered.

It fails **closed** — `test_capTooLoose_underfundsTheRepay_andFailsClosed` asserts the
debt and collateral are untouched — which matters because the order is one-shot: a
partial close would leave the maker levered with their exit order spent. The rule for
signers is that the cap is *the expected position plus an accrual margin*, not a loose
upper bound.
