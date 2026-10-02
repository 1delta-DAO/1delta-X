# @1delta-x/solvers

Off-chain filler / solver reference implementations for `Settlement`.

**Where asset weirdness is handled.** The settler is general and immutable, so
it carries fee-on-transfer and rebasing tokens for every maker who signs for
them — `timing` bit 104 enforces the maker's floor NET of the fee, and an
unmarked order delivers nominally, which is the maker's own signed choice
(`core/test/swaps/DeltaVerifyDelivery.t.sol` pins both). A SOLVER is the
opposite kind of contract: one per deployment, replaceable, and free to
specialise — a solver that cannot carry an odd token simply is not pointed at
one. So narrowing belongs here or in the book's token policy, never in the core.
(`AggregatorFillSolver` happens to carry them anyway: its balance-delta
discipline is FoT-correct as a side effect, and dropping it measured a net
saving of ~0 — see the note on custody.)

Most of these contracts are permissionless fillers: anyone may run one to fill
an order. They hold no funds between fills — each fill sources its collateral
inventory from a flash-loan provider, routes it through Settlement to satisfy
the order, swaps the borrow proceeds back to the collateral asset, and repays
the flash in the same transaction. The shared fill → swap → repay machinery
lives in `base/BaseFlashSolver.sol`; each concrete solver only differs in which
flash provider it draws inventory from.

**Flash-family shapes and limits** (audit 2026-09-30 FLASH-1/2/3/7, PERIPH-4.v1,
CENSUS-A-5):

- **No `SETTLE` items.** A SETTLE module pays `ctx.filler` — the solver — in any
  token it likes, and nothing would forward it, so the receipt would be left for
  the next caller. Every `executeFill` refuses such an order before the flash
  (`SettleItemsUnsupported`); MAKE/TAKE/TAKE_FOR items are fine. Sweep / tip
  orders (`ProportionalSweepModule`) must be filled by an EOA or a contract that
  forwards arbitrary tokens.
- Single-input solvers and `MultiOutputFlashSolver` take exactly one input leg
  (`MultiInputUnsupported`, checked before the flash); the `multi-input/` family
  swaps every input leg back.
- The profit is swept in the **asset the flash was repaid in** (plus `legsOut[0]`'s
  token when it differs), to `msg.sender` or to `FlashOpts.recipient`. Every
  solver has an `executeFill(…, FlashOpts opts)` overload carrying a profit
  `recipient` and a `takerData` blob (filler attestations, cosigned quotes,
  fill-module proposals); the recipient may not be the solver itself or
  Settlement's EXECUTOR (`BadProfitRecipient`) — drive a solver from a `matchSettle`
  CALL step or a `fillWithCallback` target only with an explicit recipient.
  `fillAmountIn = type(uint256).max` fills whatever remains.
- **PermitBatchWitness (single-signature) orders** (audit 2026-09-30 AGG-6): pass
  `sig = abi.encode(PERMIT_ENVELOPE, PermitBatch batch, bytes permitSig, uint256
  minBumpBps)` (or `permitEnvelope(batch, permitSig, minBumpBps)`) instead of an
  order signature, and the fill inside the flash goes through
  `Settlement.fillWithPermit` rather than `fill` — the outputs are paid from the
  flash as always, so such a maker is served with zero inventory. The envelope
  carries no authority: the settler verifies the maker's permit exactly as for an
  EOA filler.
- The repayment swap is single-hop Uniswap v3 `exactInputSingle`; the solver
  detects `SwapRouter02` (no `deadline`, e.g. Rootstock Oku and most L2s) at
  construction (`ROUTER02`). An input already in the collateral asset is not swapped.
- The provider-callback gate is open only while the provider call is in flight:
  Aave checks `initiator`, Midnight `caller`, Morpho/EVK only call back their own
  caller, and Balancer — which names no initiator — is bound to the exact payload
  `executeFill` sent. The gate does NOT stop a caller's own fake provider (an
  attacker-written "Euler vault"): that callback runs with the solver as filler,
  which is harmless only because the solver holds nothing — any residue (a
  donation, a stranded token) is claimable by anyone. Keep the zero-balance rule.
- These wrappers present THEIR OWN address to every filler gate. Never name a
  permissionless flash solver (or an open `GuardedMatchSolver`) in
  `exclusiveFiller`, a `FILLER_SET` or a filler-aware validator / price module —
  that admits every caller.

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
  - `GuardedMatchSolver.sol` — guard → `matchSettle`, the residual straight to
    `plan.profitRecipient` (never `0`, the wrapper, Settlement or the EXECUTOR —
    `ProfitStranded`). See [Losing races cheaply](#losing-races-cheaply). Plans
    with a `PRESEND` step are refused (`PresendUnsupported`): PRESEND pays the
    wrapper, which can never move a token again — call `matchSettle` from your own
    contract (inheriting `MatchRaceGuard`) if you need one. Optional immutable
    operator set (`constructor(settlement, operators)`, empty = open): only a
    GATED instance is a filler identity an order may name.
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
    earlier fill left behind is not reachable by the next caller. **The surplus is
    split, not swept — on BOTH sides**: a constructor `SurplusPolicy` (immutable,
    like the router set) returns `makerPpm` of the spread to the maker as price
    improvement and `protocolPpm` to the route/API provider; the caller may
    carve an originator share out of its own remainder (`RoutePlan.originator`
    / `originatorPpm`), and keeps the rest. Unspent input is split by the same
    shares in `tokenIn` units (it used to go to the filler alone, which let an
    exact-output route move the whole spread out of the policy's reach — F28).
    This is the only place a surplus split is *enforceable* — the contract is
    the swapper, so it can measure the surplus; Settlement never sees it. See
    docs/originator-fees.md §5.
    **An optional operator set** (constructor, immutable, empty = anyone) gates
    `executeFill`. For a plain pull-delivery fill on a per-fill instance nothing
    depends on it, but it is **load-bearing** for every mode in which the caller's
    route calldata gets more than this fill's deltas, and each requires it:
    standing allowances (`StandingNeedsOperators`), delta-verify orders
    (`DirectNeedsOperators`), a non-zero surplus policy (`PolicyNeedsOperators` —
    an open caller can route the spread around the split, so the policy binds only
    operator-written routes) and retain mode (`RetainNeedsOperators`). It is also
    what makes `Order.exclusiveFiller = thisSolver` mean anything: core compares
    the exclusive filler to the fill's `msg.sender`, which is the solver
    *contract*, so on an open instance an order exclusive to it is exclusive to
    anyone willing to route through it. A gated instance narrows that to its
    operators; a new operator means a new instance. Both sets are immutables (≤ 4
    entries each), not mappings — a membership test is then a compare rather than
    a cold SLOAD, −2.1k gas per fill per set. ⚠ The trust boundary is whoever
    WRITES the route: an executor that forwards third-party API calldata
    (`packages/auction`'s Sushi / Nordstern sources) verbatim puts that API inside
    it — on a standing instance validate API calldata (selectors, tokens,
    recipients) or use a per-fill instance for API-sourced routes.
    **Supported shapes:** any number of input/output legs over ≤ 8 distinct tokens
    (each token measured, approved and split on its own delta — a second input
    leg in a third token is routed and split, and the pull path funds every
    output token at its own proceeds); one router call, no native value.
    **Item orders** go through `executeItemFill(order, sig, fillAmount, plan,
    takerData, lateItems)` (audit 2026-09-30 AGG-6): the core's `PostInputs` mode
    is item-free, so it drives a one-order `matchSettle` plan it writes itself —
    items not flagged in `lateItems` (TAKE: withdraw / borrow) → PULL the
    shortfall → PRESEND the input here → CALL `onMatchRoute` (same router bounds
    as `onFill`; the proceeds are PUSHED to the pool, nothing is approved) →
    DELIVER → items flagged in `lateItems` (wallet-funded MAKE: deposit / repay).
    The pool's surplus is swept back here and split by the same policy. The core
    still enforces the maker's `ItemPolicy` against the chosen placement, and
    refuses what every netted plan refuses (SETTLE / TAKE_FOR / PUSH-funded MAKE
    items, delta-verify orders, repeated input tokens) — those stay with the
    flash family or an inventory filler. **Single-signature PermitBatchWitness
    orders**: the first fill has no callback entry in core (`fillWithPermit`
    runs none, and adding one costs Settlement bytes at the EIP-170 wall), so it
    needs up-front capital — the flash family takes it through the permit
    envelope (below); every later slice is fillable here, since the settler
    skips signature verification once `filled != 0`. `executeFill` and
    `executeItemFill` are non-reentrant and hold their in-fill state through the
    surplus split.
    Fills start as `CallbackMode.PostInputsDirect`: the contract never holds a
    Permit3 allowance, so bit 2 tells the core to pull its output legs by plain
    `transferFrom` instead of probing Permit3, failing, reading the strict flag
    and only then falling back (−9.0k per fill on the pull path).
    **Direct delivery.** On an order signed with `timing` bit 104
    (`DutchAuction.deltaVerifyOutputs`, SDK `withDeltaVerifyOutputs`) the route
    pays the maker itself and the core verifies the balance delta, so this
    contract never approves Settlement and never holds `tokenOut`: quote the
    route with `recipient = order.maker`, exact-output for the priced amount,
    and the unspent input comes back as the spread (`tokenIn` residue, same
    policy). Detected from the order — the caller cannot choose it — and
    `minOut`/`maxPay` are ignored on that path. Measured 167.1k → 142.7k per
    fill; the app signs every order this way.
    **`STANDING_ALLOWANCE` (constructor, immutable).** Fund routes from standing
    max approvals instead of writing the allowance slot twice per fill —
    measured 132,740 → 98,545 on a live Rootstock pool, 13% of a whole
    DEX-routed fill. It gives up "no allowance survives the fill" on the input
    side, so it is only sound for a router that pulls **exclusively from its own
    `msg.sender`**; SwapRouter02 does (`payer = msg.sender` in its own callback
    data, and `verifyCallback` rejects any non-pool caller — both halves tested
    against the live router), but an aggregator whose API takes a `payer`/`from`
    parameter does **not**, and a standing approval there is a standing drain.
    Verify that per router before deploying with it on. ⚠ The per-fill approval
    was ALSO A BOUND — it capped the route at the delta the fill delivered
    whatever the calldata said — so a standing instance re-imposes that as a
    measurement (`RouteOverspent`): the route may spend what this fill brought
    and not one wei more. Without it the caller picks `amountInOffset`, declines
    the patch and has the router sweep the contract's own balance. Tokens are primed by the
    constructor or by the permissionless `prime(token)`; `onFill` never checks —
    an unprimed token fails at the router's own pull, which costs the caller its
    own gas and is repaired by anyone.
    **Custody: hold DUST, not value.** These are two separate decisions and only
    one of them pays.
    *Dust is worth having.* An inbound transfer to a zero balance costs the
    token's 0→non-zero SSTORE; one wei of each traded token parked here makes it
    a non-zero→non-zero write instead, measured at **−17,153 per fill** on a live
    Rootstock pool (`test/RawSwapComparison.t.sol`, `NoFloorTest` is the honest
    no-floor baseline). The floor is self-sustaining: the route consumes exactly
    what the fill delivered, so the wei stays.
    *Retained value is not.* `RoutePlan.profitRecipient = the solver` measured
    **0** against paying the spread straight out on the direct-delivery path —
    an exact-input route leaves no residue to retain — and ~3k on the pull path.
    So point `profitRecipient` at a treasury and let the contract hold dust only:
    it holds the maker's input mid-fill, so every wei parked here is something a
    future mistake can be paired with. On the direct path it never touches
    `tokenOut` at all. Retain mode is only accepted on a GATED instance, whose
    operators take retained value out with `sweep(token, to, amount)` (never
    mid-fill); on an open instance it is refused, since nothing could ever move
    it out again (audit 2026-09-30 AGG-1).
    *Gas:* the multi-token generalisation (AGG-2/AGG-6) and the reentrancy state
    cost ≈ +5k per fill on the two-token benchmark (`AggregatorFillGas.t.sol`:
    1-wei floor pull path 168.2k → 173.3k, direct 135.5k → 139.8k).
    ⚠ Measuring this: EIP-2200 prices an SSTORE against the slot's value at the
    START OF THE TRANSACTION, so a benchmark that seeds a floor and zeroes it
    inline measures a dirty-slot write and reports the floor as worthless.
  - `FillRecovery.sol` — rebuild the in-flight `FillCtx` from inside a callback
    when the order shape allows it. Refuses proportional-under-`PostInputs`,
    fill-module and fill-once orders, whose delta it cannot recover by
    subtraction, and the `type(uint256).max` any-size sentinel
    (`SentinelNotRecoverable` — pass the resolved size); for those, use a
    `*Typed` `CallbackMode` (`ISettlementCallback` carries the resolved numbers)
    or `SettlementLens.previewFillInFlight`.
- **`inventory/`** — inventory-funded (non-flash) fillers:
  - `UsdrifInventorySolver.sol` — **USDRIF→USDT0 exits on Rootstock**. Fills a
    maker's direct USDRIF→USDT0 order from its own USDT0 inventory and, in the
    same tx, escrows the USDRIF into MoC's native redemption (`redeemTP` to
    itself — allowed for a principal, unlike a user-side wrapper). The queue
    delivers RIF ~30–90s later; an operator then `sell`s it back to USDT0
    through any owner-whitelisted venue (Uni v3 router, aggregators — opaque
    calldata) along an owner-configured `setSellRoute(tokenIn, tokenOut,
    minRateWad, maxAmountIn)` — pair, per-call spend budget and minimum rate are
    the owner's, enforced by balance delta; `sell` is closed until one is set.
    Fills are priced the same way: `setFillRoute(spent, received, minRateWad)`
    — an order must pay out one owner-priced token and bring back one other at
    no worse than the owner's rate (measured), so a self-signed "inventory for
    junk" order fails. Both paths also draw on one cumulative per-token budget,
    `setOutflowLimit(token, limit)` per 1-hour window, so looping calls (a
    contract operator, one transaction) cannot multiply the per-call caps. All
    three default to zero and fail closed.
    Fills take an OPERATOR price bound, `maxSpent` (`executeFill(order, sig,
    amount, maxSpent)`, `executeFillAndRedeem(order, sig, amount, maxSpent,
    qACmin)`; `type(uint256).max` = none) on top of the owner's rate — the strict
    `fill` has no price floor, and a maker who controls the pricing (priority bump,
    price module, descending curve) could otherwise move the price to the owner's
    floor between quote and inclusion. Fills refuse item-bearing orders (a maker
    item is the one maker-controlled hook inside the measured fill). Delta-verify
    orders (`timing` bit 104 — what the Rootstock app signs) that name this
    contract as `exclusiveFiller` are filled too: the solver delivers each leg from
    inventory in its own callback (`fillWithCallback`, typed mode), measured and
    capped exactly like a pull. An app order that names a DIFFERENT solver is not
    fillable here (exclusivity), so name this contract for inventory-served
    markets or sign plain pull delivery.
    ⚠ MoC's queue can be executed by ANYONE (`MocMultiCollateralGuard.execute()`
    is permissionless; only `MocQueue.execute` is guard-restricted), and executing
    it pays this contract its own redemption RIF or a failed op's USDRIF refund
    synchronously. Every measured window — `sell`'s venue call and each fill — is
    bracketed with `MocQueue.firstOperId()` and reverts
    `QueueMovedDuringMeasurement` if the queue moved, so in-window deliveries can
    never be counted as consideration or net out a spend.
    Ownership is two-step (`transferOwnership` → `acceptOwnership`). This is the
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

For an ordinary order the losing condition is knowable from **one storage slot**,
and the solver already knows every order hash off-chain. `MatchRaceGuard` checks that
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

**What `filled` cannot see.** A fill-once order (`timing` bit 100 — OCO brackets)
burns its nonce and never writes `filled`, and nonce cancellation
(`cancelOrders`, `invalidateNonceWord`, `rollbackNonces`) leaves `filled` at 0;
only the per-hash `cancelOrder` writes the `type(uint256).max` sentinel. For those
orders use `settleMatchWithNonces(orderHashes, expectedFilled, makers, nonces,
plan)`, which also checks `isNonceCancelled(maker, nonce)` (one or two more
`SLOAD`s) and reverts `NonceTaken(index, maker, nonce)`.
