# @1delta-x/solvers

Off-chain filler / solver reference implementations for `Settlement`.

Most of these contracts are permissionless fillers: anyone may run one to fill
an order. They hold no funds between fills — each fill sources its collateral
inventory from a flash-loan provider, routes it through Settlement to satisfy
the order, swaps the borrow proceeds back to the collateral asset, and repays
the flash in the same transaction. The shared fill → swap → repay machinery
lives in `base/BaseFlashSolver.sol`; each concrete solver only differs in which
flash provider it draws inventory from.

The exception is the **`inventory/`** group: fills whose recycle leg cannot
complete inside the fill transaction (so flash capital is impossible). Those
solvers are principals — they hold real inventory between fills and every
entrypoint is owner/operator-gated.

## Layout

`src/` is grouped by **fill shape** — the order shape each solver fills:

- **`base/`** — shared abstract bases:
  - `BaseFlashSolver.sol` — the flash-fill machinery (flash → fill → swap → repay).
  - `MatchRaceGuard.sol` — the **cheap-loss** primitive for contested matches
    (below).
- **`single-input/`** — solvers for single debt-leg leverage orders. One per
  flash provider:
  - `LimitOrderLeverageSolver.sol` — **Balancer v2** (defines `IBalancerVault`)
  - `AaveV3FlashSolver.sol` — **Aave v3** (defines `IAaveV3Pool`)
  - `MorphoFlashSolver.sol` — **Morpho Blue** (defines `IMorphoFlash`)
  - `EulerFlashSolver.sol` — **Euler EVK** (defines `IEulerFlashVault`)
- **`multi-input/`** — solvers for multi-input orders (several `tokenIn` legs,
  e.g. a dual conversion where borrow proceeds and maker equity both flow to the
  solver):
  - `MultiInputLeverageSolver.sol` — **Balancer v2**
  - `AaveV3MultiInputFlashSolver.sol` — **Aave v3**
  - `MorphoMultiInputFlashSolver.sol` — **Morpho Blue**
  - `EulerMultiInputFlashSolver.sol` — **Euler EVK**
- **`multi-output/`** — solvers for multi-output orders:
  - `MultiOutputFlashSolver.sol` — **Balancer v2**
- **`match/`** — `matchSettle` front-ends:
  - `GuardedMatchSolver.sol` — guard → `matchSettle` → forward the edge to the
    caller. See [Losing races cheaply](#losing-races-cheaply).
- **`aggregator/`** — zero-inventory fills against an off-chain DEX-aggregator
  route (`CallbackMode.PostInputs`: take the maker's `tokenIn`, swap it, deliver
  `tokenOut` — no flash loan, no held capital):
  - `AggregatorFillSolver.sol` — the fill itself. **The router set is an
    immutable constructor argument**, and that is a security invariant rather
    than configuration: `executeFill` is permissionless *and* is the thing that
    arms the callback, so the `msg.sender == EXECUTOR` and arming-flag gates
    authenticate nothing on their own — an attacker satisfies both by starting a
    fill of an order they signed as their own maker. Only the allowlist keeps the
    raw route call from being an "invoke anything as this contract" primitive.
    Same reasoning as the owner-whitelisted venue list in
    `UsdrifInventorySolver`, minus the owner. Every amount it spends, approves or
    sweeps is a **delta** measured against a pre-fill snapshot, so a residue an
    earlier fill left behind is not reachable by the next caller.
  - `FillRecovery.sol` — rebuild the in-flight `FillCtx` from inside a callback
    when the order shape allows it. Refuses proportional-under-`PostInputs`,
    fill-module and fill-once orders, whose delta it cannot recover by
    subtraction; for those, use a `*Typed` `CallbackMode`
    (`ISettlementCallback` carries the resolved numbers) or
    `SettlementLens.previewFillInFlight`.
- **`inventory/`** — inventory-funded (non-flash) fillers:
  - `UsdrifInventorySolver.sol` — **USDRIF→USDT0 exits on Rootstock**. Fills a
    maker's direct USDRIF→USDT0 order from its own USDT0 inventory and, in the
    same tx, escrows the USDRIF into MoC's native redemption (`redeemTP` to
    itself — allowed for a principal, unlike a user-side wrapper). The queue
    delivers RIF ~30–90s later; an operator then `sell`s it back to USDT0
    through any owner-whitelisted venue (Uni v3 router, aggregators — opaque
    calldata, with the output floor enforced by balance delta). This is the
    one-signature variant of the two-phase flow in
    `packages/modules/redeem/usdrif` (there the user redeems first and the
    order carries the redemption-settled validator, optionally a price band;
    here the order needs none — it fills in seconds, so the signed output floor
    is the whole protection).

The single-input Aave/Morpho/Euler solvers each define the provider interface
(`IAaveV3Pool`, `IMorphoFlash`, `IEulerFlashVault`); their multi-input
counterparts import it from the single-input file. Balancer's `IBalancerVault`
is defined in `LimitOrderLeverageSolver.sol` and reused by the other Balancer
solvers.


## Losing races cheaply

> The full write-up — off-chain build order, the exact-equality rationale, and the
> revert-reason taxonomy — is **[docs/filler-strategy.md](../../docs/filler-strategy.md)**,
> the recommended shape for any `matchSettle` filler. This section is the summary.

A profitable match is visible to every solver at once, so several land a
transaction for it in the same block. One wins; the rest revert — and reverting
is not free.

An unguarded loser learns the race is over only at the very end of the approach:
`matchSettle` derives the token universe, takes a `balanceOf` snapshot per token,
hashes the first order (keccak over the full struct and every dynamic sub-array),
`ecrecover`s its signature, runs its validators, and *then* reads `filled` and
reverts `OverFill`. Every one of those steps is wasted, and the waste grows with
the size of the plan and the cost of the orders' validators.

But the losing condition is knowable from **one storage slot per order**, and the
solver already knows every order hash off-chain. `MatchRaceGuard` checks that
first, from a parameter list small enough to be nearly free, and bails before the
plan is ever touched:

```solidity
function settleMatch(
    bytes32[] calldata orderHashes,
    uint256[] calldata expectedFilled,
    MatchPlan calldata plan              // ← still untouched calldata when the guard fires
) external returns (uint256[][] memory outs, address[] memory tokens, uint256[] memory swept) {
    _requireUntouched(orderHashes, expectedFilled);
    return SETTLEMENT.matchSettle(plan);  // residual → plan.profitRecipient, never through here
}
```

Measured on the smallest possible contested plan — two item-free orders, no
validators (`test/MatchRaceGuard.t.sol`):

| race loss | gas |
| --- | --- |
| unguarded (`matchSettle` direct) | 34,679 |
| guarded | **3,641** |
| saved | 31,038 (**−89%**) |

That is the *floor* of the benefit: the guarded cost grows by one `SLOAD` per
order, while the unguarded cost grows with plan size, item count, and validator
work. Note the guard saves **execution**, not calldata — the EVM charges for
calldata whether or not it is read, so a loser still pays for the plan bytes it
submitted. Keep guard parameters small and put them first.

**Exact equality, not "is there room left."** A netted plan is balanced against a
specific chain state: `Pricing.inputOwed` computes a fixed leg as
`amt·newFilled/anchor − amt·prevFilled/anchor`, so `prevFilled` moving shifts the
owed amount by a rounding unit *even when plenty of room remains* — and a plan
that is off by one wei no longer nets (the pool comes up short and the settlement
reverts `BatchNotWhole`). "Still has room" is the wrong question; "is the state I
simulated against still the state on chain" is the right one, and it is also the
cheaper check. `test_partialFillByCompetitor_alsoTripsGuard` pins this.

The guard reverts `OrderTaken(index, expected, actual)` — typed, so a searcher's
infrastructure can separate a routine race loss from a genuine failure without
re-simulating.
