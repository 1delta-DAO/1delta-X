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
(`AggregatorFillSolver` is a case in point: its balance-delta discipline is
FoT-correct on the solver itself, but since routes run in `RouteSandbox` a
fee-on-transfer `tokenIn` routed with `amountInOffset` always reverts — the
push to the sandbox is a second taxed transfer — and that is accepted, not
patched: see "Fee-on-transfer" under `aggregator/` below.)

Most of these contracts are permissionless fillers: anyone may run one to fill
an order. The flash solvers hold no funds between fills (their safety rests on
exhaustive sweeps; `AggregatorFillSolver` instead uses delta-scoped per-fill
amounts, a sandboxed route and MANDATORY operator gating, `UsdrifInventorySolver` operator gating and owner
budgets — see SECURITY.md, "Any contract that fills on its own behalf") — each fill sources its collateral
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
    contract (inheriting `MatchRaceGuard`) if you need one. Plans whose orders carry
    a `SETTLE` item are refused too (`SettleUnsupported(order, item)`, 2026-10-14):
    the core's `matchSettle` admits SETTLE since task 31, and a SETTLE item pays its
    asset to the same caller (an OCO claim moves nothing, but the wrapper cannot tell
    the two apart). Optional immutable
    operator set (`constructor(settlement, operators)`, empty = open): only a
    GATED instance is a filler identity an order may name.
- **`aggregator/`** — zero-inventory fills against an off-chain DEX-aggregator
  route (`CallbackMode.PostInputs`: take the maker's `tokenIn`, swap it, deliver
  `tokenOut` — no flash loan, no held capital):
  - `AggregatorFillSolver.sol` — the fill itself. **There is no router
    allowlist (BREAKING, 2026-10): every route runs in `RouteSandbox`**, never as
    the solver, and **every instance is operator-GATED (BREAKING, 2026-10 quick
    audit): the constructor reverts `NoOperators` on an empty operator set.** The
    `msg.sender == EXECUTOR` and arming-flag gates bound *when* the callback runs,
    not what the route does; the route is made from an identity that owns nothing
    of the solver's and holds no authority, so the target may be anything an
    operator names (a new venue needs no redeploy). It may NOT be anything a
    stranger names: every target the sandbox calls keeps a standing max approval
    from it, and a stranger able to drive it (`target = token, data =
    approve(harvester, max)`, or just `target = harvester`) could plant a grant that
    later reaches an honest fill's in-flight spread from a hook token in the
    order's sweep list or a hooked router — two PoCs, `test/RouteSandbox.t.sol`.
    An arbitrary-call sandbox is incompatible with permissionless routing. The solver keeps the value
    and its Settlement approvals and **never approves a router, the sandbox or
    any other target** (no per-fill approval, no standing mode, no `prime`).
    Every amount it spends, approves or
    sweeps is a **delta** measured against a pre-fill snapshot, so a residue an
    earlier fill left behind is not reachable by the next caller. **The surplus is
    split, not swept — on BOTH sides**: a constructor `SurplusPolicy` (immutable,
    like the operator set) returns `makerPpm` of the spread to the maker as price
    improvement and `protocolPpm` to the route/API provider; the caller may
    carve an originator share out of its own remainder (`RoutePlan.originator`
    / `originatorPpm`), and keeps the rest. Unspent input is split by the same
    shares in `tokenIn` units (it used to go to the filler alone, which let an
    exact-output route move the whole spread out of the policy's reach — F28).
    This is the only place a surplus split is *enforceable* — the contract is
    the swapper, so it can measure the surplus; Settlement never sees it. See
    docs/originator-fees.md §5.
    **The operator set** (constructor, immutable, 1–4 entries, mandatory) gates
    `executeFill`, `executeItemFill` and `sweep`. Besides the sandbox argument
    above it is what makes delta-verify orders, a non-zero surplus policy (a
    route author can steer the spread around the split) and retain mode sound —
    each used to be refused on an open instance (`DirectNeedsOperators` /
    `PolicyNeedsOperators` / `RetainNeedsOperators`, removed with the open mode).
    It is also what makes `Order.exclusiveFiller = thisSolver` mean "exclusive to
    its operators": core compares the exclusive filler to the fill's `msg.sender`,
    which is the solver *contract*. A new operator means a new instance. The set
    is immutables, not a mapping — a membership test is then a compare rather than
    a cold SLOAD; `GATED()` is kept as a constant `true` getter for wiring checks.
    ⚠ The trust boundary is whoever WRITES the route: an executor that forwards
    third-party API calldata verbatim puts that API inside it, and every target a
    route ever names keeps its sandbox approval for good. A hostile route can reach
    this fill's in-flight input — on the pull path that fails the output check
    unless it takes only the spread above `minOut`; on the direct path the input
    residue (the spread) is the route's to divert — and, through a target it named,
    the in-flight spread of later fills in which that target gets control. So
    decode and validate API calldata (router, tokens, amount, recipient, min-out)
    before submitting, and never name a target you would not trust with a later
    fill's in-flight balance; `packages/beta-filler` does this for Sushi.
    **Supported shapes:** any number of input/output legs over ≤ 8 distinct tokens
    (each token measured and split on its own delta; only `legsIn[0]`'s token is
    pushed to the route — a second input leg's token stays on the solver and is
    split as residue — and the pull path funds every output token at its own
    proceeds); one route call, no native value. **An output leg in the anchor
    token** (an in-kind sourcing fee, `legsOut[j].token == legsIn[0].token`) is
    kept back, not routed, on both entries: `executeItemFill` because PRESEND nets
    the pool's outstanding outputs, `executeFill` because the typed callback
    (2026-10-06) subtracts the leg's priced amount from the input delta before the
    push — a patched exact-input route then swaps `input − leg`. (Before the typed
    callback the pull path routed the whole input and a patched route failed the
    leg's pull, `TransferFromFailed` — review 2026-10-05 S1;
    `test/AggregatorAmountMismatch.t.sol`.) **Stranded tokens:** the sandbox
    sweeps only the order's token set; a token outside it that a route leaves
    there (an intermediate hop's refund) stays until an operator routes `target =
    token, data = transfer(solver, balance)` (any carrier order) and then
    `sweep`s it on (`test_sandbox_strandedTokenIsRecoverableByAnOperator`).
    **Fee-on-transfer `tokenIn` + `amountInOffset` always reverts** (accepted,
    2026-10): the patched amount is what reached the solver, the push to the
    sandbox is a second taxed transfer, so the router's pull exceeds what the
    sandbox holds. Core stays asset-general; this solver specialises to tokens
    that transfer exactly (`NO_PATCH` with a quote sized for the twice-taxed
    amount still works, as does a solver written for the token).
    **Item orders** go through `executeItemFill(order, sig, fillAmount, plan,
    takerData, lateItems, permits)` (audit 2026-09-30 AGG-6): the core's `PostInputs` mode
    is item-free, so it drives a one-order `matchSettle` plan it writes itself —
    items not flagged in `lateItems` (TAKE: withdraw / borrow; a SETTLE claim) → PULL the
    shortfall → PRESEND the input here → CALL `onMatchRoute` (same sandboxed route
    as `onFill`; EVERY output token's proceeds are PUSHED to the pool, nothing is
    approved — so an opaque route may fund two output tokens) →
    DELIVER → items flagged in `lateItems` (wallet-funded MAKE: deposit / repay; and,
    since the core change of 2026-10-14 (task 31), the PRE-FUNDED MAKE — the 15
    pre-fund lending sinks, `NativeUnwrapModule` — and the leg-reference TAKE_FOR).
    The core hands an order its delivery ledger only at its DELIVER step, so a
    delivery-consuming item flagged EARLY reverts `ForLegInvalid` instead of spending
    residue. Zero inventory for all of them (`test/AggregatorZeroCapitalItems.t.sol`:
    native-out through the module, swap → supply, an OCO bracket leg with the claim
    early or late, a two-token route). `minBumpBps` / `amountOutOffset` cannot take
    effect on this path and are REFUSED (`ItemFillUnsupported`, task 17; they used to
    be silently ignored). The pool's surplus is swept back here and split by the same policy. The core
    still enforces the maker's `ItemPolicy` against the chosen placement, and
    refuses delta-verify orders (`DirectNotMatchable` here, first), repeated input
    tokens and the BALANCE-relative TAKE_FOR; a leverage CYCLE (a borrow that needs
    this fill's own delivery deposited first) reverts `BatchNotWhole` / `LegUnfunded`
    — those stay with the flash family or an inventory filler. **SETTLE receipts**
    land on this contract (the `matchSettle` caller): the route sells one only if it
    is `legsIn[0]`'s token and the item is flagged early; a receipt in any other
    token (a second-token `ProportionalSweepModule` sweep, an NFT) is neither routed
    nor split — it stays as retained value (out of later fills' reach, delta rule)
    for the operators to `sweep`, and the legs must be fundable from `legsIn[0]`
    alone. A POOL route is single-output (its path ends in the anchor). A TAKE item that produces **more than
    its leg owes** is refunded to the maker on this path too since core B-1
    (2026-10-06: the crossing part of a credit joins `outstanding`, so PRESEND hands
    the route exactly `owed`); before B-1 the excess reached the route and the
    Phase-3 refund reverted `TransferFailed` (review 2026-10-05). **Single-signature PermitBatchWitness
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
    and only then falling back (−9.0k execution gas per fill on the pull path —
    historical, measured when `PostInputsDirect` landed; no standing test isolates
    it, not re-run). When the plan
    needs a price the core resolved — an output leg in the anchor token to keep
    back, or `RoutePlan.amountOutOffset` set — the fill starts as
    `PostInputsTypedDirect` instead and the callback is `onSettlementFill`
    (`ISettlementCallback`, the route as `userData`, `pricedOut[]` per leg); every
    other fill keeps the untyped `onFill`, because the typed payload costs ~+5.9k
    execution gas (`AggregatorFillGasTest.test_gas_direct_seeded_liveAmountOut`
    179,773 vs `test_gas_direct_seeded` 173,864; unit mocks, profile `solvers`,
    re-run 2026-10-06; the core's share alone is +3.9k on the Rootstock fork,
    `FreshTxComparisonTest.test_fresh_typedPayloadOverhead_*` 123,963 vs 120,062). **`RoutePlan.minBumpBps`** (2026-10,
    BREAKING with `amountOutOffset`) is forwarded to `fillWithCallback` as the
    filler's price floor, exactly `fillUpTo`'s: set it to the bump the route was
    quoted at (lens `previewBump` at the send gas price) and a tick that moved
    maker-ward before inclusion — a priority auction whose effective bid rose, a
    gas bump, a custom curve — reverts `BumpTooLow` before anything moves
    (`test_minBump_priorityDirectBuy_makerWardMoveRevertsBumpTooLow`).
    **Direct delivery.** On an order signed with `timing` bit 104
    (`DutchAuction.deltaVerifyOutputs`, SDK `withDeltaVerifyOutputs`) the route
    pays the maker itself and the core verifies the balance delta, so this
    contract never approves Settlement and never holds `tokenOut`: quote the
    route with `recipient = order.maker`, exact-output for the priced amount,
    and the unspent input comes back as the spread (`tokenIn` residue, same
    policy). Detected from the order — the caller cannot choose it — and
    `minOut`/`maxPay` are ignored on that path. Measured 167.1k → 142.7k per
    fill (historical unit benchmark, execution gas, pre multi-token — not re-run);
    on the Rootstock fork today pull → direct is 310,502 → 252,567 execution,
    282,890 → 247,907 net of refund (`SandboxGasBench.test_sandbox_gas_*`, see the
    gas table below). The app signs every order this way. Set `RoutePlan.amountOutOffset` to
    the route's `amountOut` word and the solver writes the LIVE `legsOut[0]` price
    into it (typed callback): a SELL included after its auction decayed then pays
    the maker exactly what the core verifies, and the decay since the quote stays
    here as input residue instead of reaching the maker
    (`test_live_directSellAfterDecay_paysTheLiveTickAndKeepsTheDecay`). Left
    `NO_PATCH`, the route pays the quoted figure as before. The patched word is the
    live price of the ANCHOR legs (task 16, 2026-10-14): `pricedOut[0]` on a direct
    order; on a pull order the sum over every leg in the anchor output token — a fee
    leg listed first used to make the word the fee (`test/AggregatorPatchAndItemGuards.t.sol`).
    **Native delivery (solver v3, task 30, 2026-10-14).** A DIRECT order whose
    `legsOut[0].token` is the instance's `NATIVE_BALANCE` (the `NativeBalance` view,
    `packages/periphery/src/NativeBalance.sol`: `balanceOf(a) = a.balance`) receives
    raw native coin with zero capital and no Settlement change: quote the route to end
    in `WNATIVE` paying THE SOLVER (a pool route's last hop does so by itself); the
    typed callback `withdraw`s exactly the core's `pricedOut[0]` and sends it with a
    full-gas `call` to the leg's recipient (`0` = maker); the core verifies the native
    balance delta. The WNATIVE spread stays and is split by the policy; `minOut` /
    `maxPay` apply in WNATIVE. Refused shapes (`NativeLegShape`): not direct, or
    WNATIVE / NATIVE_BALANCE in any other leg. A reverting recipient kills the fill
    (`NativeSendFailed`); `receive()` accepts only `WNATIVE` (`NotWNative`).
    `nativeDelivery()` returns `(nativeBalance, wnative)`; both zero = off. Gas: +27.0k
    execution vs the same order taking WRBTC on the live Rootstock Settlement
    (~2.8k refunded at tx end; `test/NativeDeliveryRootstock.fork.t.sol`, opt-in
    `RSK_FORK_URL`), +15.3k on the unit mocks; an EMPTY recipient account adds the
    EVM's +25k new-account charge.
    **Custody: hold DUST, not value.** These are two separate decisions and only
    one of them pays.
    *Dust is worth having.* An inbound transfer to a zero balance costs the
    token's 0→non-zero SSTORE; one wei of each traded token parked here makes it
    a non-zero→non-zero write instead, measured at **−17,100 per fill** of
    EXECUTION gas on a live Rootstock pool (re-run 2026-10-06, profile `solvers`,
    fork block 8,920,000, direct path, refunds not deducted:
    `FreshTxComparisonTest.test_fresh_custody_payoutSpread` 275,459 seeded vs
    `NoFloorTest.test_nofloor_dexFill` 292,612 unseeded, `test/RawSwapComparison.t.sol`;
    was −17,153 before tasks 06/08). ⚠ Net of the end-of-tx refund
    (2026-10-04, pre-06/08, not re-run — no standing test prints the no-floor
    refund) it pays on the PULL path (+20.3k without it: the refunds then
    exceed the gasUsed / 5 cap) and is refund-neutral on the direct path — see the
    `RouteSandbox` dust-floor note below. The floor is self-sustaining: the route consumes exactly
    what the fill delivered, so the wei stays.
    *The floor seeds itself* (2026-10; no `FLOOR_TOKENS` needed). A token the
    solver held NOTHING of before a fill keeps one wei of that fill, out of the
    filler's side only: `_splitSurplus` pays the filler's share less one wei
    (output spread, input residue, a non-anchor input leg — any token, both
    entries), and `_seedIn` routes `delta − 1` of the anchor input on a pull or
    netted fill whose route is patched (`amountInOffset` set). The maker's priced
    amount, every fee leg, the core's verified / pulled delivery and every
    `SurplusPolicy` share are computed exactly as on a pre-seeded instance —
    pinned twin-for-twin (cold vs seeded instance, same order) in
    `test/AggregatorSelfSeed.t.sol`, incl. the typed callback with an in-kind fee
    leg, the netted `executeItemFill` path and a partial-fill / rate fuzz
    (`testFuzz_seed_pull_makerIndependentOfFloor`). Per path:

    | path | `tokenIn` floor | `tokenOut` floor |
    | --- | --- | --- |
    | pull, `amountInOffset` set (the beta's pull shape) | 1st fill — route one wei short | 1st fill with a spread |
    | pull, `NO_PATCH` | only if the route leaves input residue (a short route would fail its quoted pull) | 1st fill with a spread |
    | direct, exact-output (the beta's direct shape) | 1st fill — out of the input residue (route NOT shortened) | never lands here |
    | direct, exact-input | never (the maker owns the whole output; shortening the route would short the maker) | never lands here |
    | `executeItemFill`, patched | 1st fill — route one wei short of the PRESEND | 1st fill with a swept spread |
    | non-zero maker or protocol share | residue only — not withheld (their cut of the spread must not depend on the floor) | 1st fill, from the filler's remainder |
    | filler share 0 (maker + protocol = 100%), or retain mode | no seed / retain keeps everything anyway | same |

    The one fill a withheld wei can fail is a patched pull route quoted at ZERO
    margin over `minOut` / the maker's pull (the spread must cover one input wei's
    worth): it reverts `InsufficientOutput` before anything settles
    (`test_seed_zeroMarginPatchedRoute_revertsOnlyCold`). Real quotes carry gas +
    min profit, and one wei of an 18-decimal input moved the live Sushi route by
    zero USDT0 units (`test_sushi_usdrifToUsdt0_pullFill`). The 1-wei residue is
    split by the policy like any residue, so with a 100% maker / protocol / originator
    share it goes to that party and the token simply seeds from a later fill.
    Measured on the live Rootstock pool (block 8,920,000, profile `solvers`,
    execution / net tx gas, spread to a pre-paid treasury, 2026-10-07):

    | fill | pre-2026-10 contract (no floor) | self-seeding |
    | --- | --- | --- |
    | pull, FIRST fill on a cold instance (`SelfSeedColdBench.test_selfseed_pull`) | 344,815 / 301,945 | 348,958 / 326,574 |
    | pull, every later fill (`SelfSeedSteadyBench.test_selfseed_pull`) | 344,815 / 301,945 | **310,692 / 282,708** |
    | direct exact-output, FIRST fill (`SelfSeedColdBench.test_selfseed_direct`) | 310,774 / 275,183 | 311,040 / 286,444 |
    | direct exact-output, every later fill (`SelfSeedSteadyBench.test_selfseed_direct`) | 310,774 / 275,183 | **276,651 / 266,355** |

    i.e. −34.1k execution per fill on both paths (the exact-output direct path
    writes the `tokenIn` slot twice — arrival, then the residue swept back after the
    push emptied it — so one wei saves two 0→non-zero writes), −19.2k net pull and
    −8.8k net direct; the first fill pays +24.6k / +11.3k net (refunds it no longer
    earns), so the floor has paid for itself by the second / third fill. The
    self-seeded steady state prices exactly like a `deal`t or `FLOOR_TOKENS` floor
    (pull 310,692 patched here vs `SandboxGasBench.test_sandbox_gas_pull` 310,579
    unpatched). On an instance that ALREADY has its floors the code adds +77 / +52
    execution on the pull path (with / without a spread) and +15 on the direct
    path (`test_gas_baseline_dust`, `test_gas_baseline_dust_noSurplus`,
    `test_gas_direct_seeded`: 208,578 → 208,655, 198,955 → 199,007, 173,864 →
    173,879; `SandboxGasBench` direct 252,567 → 252,619, pull 310,502 → 310,579). A
    token that can NEVER be seeded on its path (a `NO_PATCH` pull route that
    consumes the whole input) re-runs the `_seedIn` checks each fill: +185
    (`test_gas_retain`, 159,236 → 159,421).
    *Retained value is not.* `RoutePlan.profitRecipient = the solver` measured
    **0** against paying the spread straight out on the direct-delivery path —
    an exact-input route leaves no residue to retain (re-run 2026-10-06: 275,459
    both, `FreshTxComparisonTest.test_fresh_custody_{retain,payout}Spread`,
    execution gas, floor seeded) — and ~3k on the pull path (historical, no
    standing pull-path test, not re-run).
    So point `profitRecipient` at a treasury and let the contract hold dust only:
    it holds the maker's input mid-fill, so every wei parked here is something a
    future mistake can be paired with. On the direct path it never touches
    `tokenOut` at all. The operators take retained value out with
    `sweep(token, to, amount)` (never mid-fill; audit 2026-09-30 AGG-1).
    Since v3, `sweepAll(tokens, to, keep)` pays out every listed token's balance above
    `keep` in one transaction: `keep = 1` leaves the 1-wei floors, and `keep = 0` empties
    the instance. It saves a 21k transaction base per extra token, and the amounts are
    read on chain. `packages/beta-filler/e2e/sweep-solver.sh` uses it when the solver has
    it.
    *Gas:* the multi-token generalisation (AGG-2/AGG-6) and the reentrancy state
    cost ≈ +5k per fill on the two-token benchmark (historical: 1-wei floor pull
    path 168.2k → 173.3k, direct 135.5k → 139.8k). Today's unit benchmark
    (`AggregatorFillGas.t.sol`, `FOUNDRY_PROFILE=solvers`, mocked router and tokens,
    EXECUTION gas inside the test — no 21k intrinsic, no calldata, refunds not
    deducted; re-run 2026-10-07, after the sandbox, the 2026-10-05 anchor fix,
    tasks 06/08 and the self-seeding floor):

    | test | figure | floor |
    | --- | --- | --- |
    | `test_gas_baseline_cold` (pull) | 252,644 | none (the fill self-seeds `tokenOut`) |
    | `test_gas_baseline_dust` (pull, 10% surplus) | 208,655 | 1 wei per token, minted in the test body |
    | `test_gas_baseline_dust_noSurplus` (pull) | 199,007 | 1 wei per token, minted in the test body |
    | `test_gas_retain_seeded` / `test_gas_gated_seeded` (pull, retain) | 197,336 | 1 wei per token, minted in the test body |
    | `test_gas_retain` second / third fill (same tx) | 159,421 | warm from the first fill |
    | `test_gas_selfSeed_patched` first / second fill (same tx) | 256,807 / 144,009 | none, then self-seeded |
    | `test_gas_direct_seeded` (direct, untyped) | 173,879 | 1 wei `tokenIn`, minted in the test body |
    | `test_gas_direct_seeded_liveAmountOut` (direct, typed) | 179,786 | 1 wei `tokenIn`, minted in the test body |
    | `test_gas_floor_plainFill` (inventory EOA, plain `fill`) | 91,058 | — |

    One forge test is one transaction, so a floor minted in the test body is a
    DIRTY slot when the fill writes it (the EIP-2200 trap below — the "fresh tx" in
    some of these tests' labels is aspirational): read these for the DIFFERENCE one
    change makes, never as a receipt figure; the fork suites (`RawSwapComparison`,
    `RouteSandboxFork`) seed in `setUp`.
    ⚠ Measuring this: EIP-2200 prices an SSTORE against the slot's value at the
    START OF THE TRANSACTION, so a benchmark that seeds a floor and zeroes it
    inline measures a dirty-slot write and reports the floor as worthless.
    **Direct pool routes (2026-10-12, BREAKING constructor).** `RoutePlan.router =
    POOL_ROUTE` (`address(0)`) makes `data` a pool plan — `amountIn(32) ‖
    amountOut(32) ‖ token0 ‖ fee(3) ‖ venue(1) ‖ token1 ‖ …`, swap order, 1–4 hops,
    `amountOut == 0` = exact-input — that the solver executes ITSELF: it calls
    `pool.swap` and pays the owed input with a plain `transfer` inside
    `uniswapV3SwapCallback`. No sandbox push, no router, no sweep, no approval. Pools
    are never taken from calldata: each hop's pool is recomputed as
    `CREATE2(factory, keccak256(abi.encode(token0, token1, fee)), initCodeHash)` over
    an IMMUTABLE venue allowlist (`PoolVenue[]`, constructor, ≤ 4, `poolVenue(i)` /
    `poolFor(venue, a, b, fee)` to check it). Rootstock: venue 0 = Uniswap v3 / Oku
    (factory `0xaF37…aD82`), venue 1 = SushiSwap v3 (factory `0x46B3…202e`), both
    with the canonical v3 init code hash `0xe34f…8b54` — verified by deriving the
    live WRBTC/USDT0 0.3% pools `0xaeF6…9Bbd` / `0x6d77…Fd71` and the Oku
    USDRIF/USDT0 0.05% pool `0xD845…19d6`
    (`PoolRouteForkBench:test_fork_poolDerivation_bothVenues`). The callback pays
    only (a) while `_active == SWAPPING` — set around the outermost `pool.swap` of an
    operator's fill, in the existing guard slot (no new storage, no transient
    storage); (b) when `msg.sender` is the derived pool of the hop its own data
    names (a genuine pool calls back only the caller of its own `swap`, with that
    caller's data); (c) the positive delta of the hop's INPUT token, and on hop 0 at
    most the routed delta (exact-output: also ≤ the plan's ceiling word). Exact-output
    multi-hop is the standard recursion (each callback buys its input from the
    previous hop, paid straight to the calling pool). The path must start at
    `legsIn[0]`'s token and end at the anchor output token; the last hop pays
    `legsOut[0]`'s recipient on a direct order and the solver on a pull order — both
    from the ORDER. Offsets keep their meaning: `amountInOffset = 0` rewrites the
    amountIn word with the routed delta, `amountOutOffset = 32` the amountOut word with
    the live `pricedOut[0]` (typed callback); anything else is `BadPoolRoute`.
    `minOut` / `maxPay` / the core's delta check / the split / the self-seeded floor
    are unchanged. Tests: `test/AggregatorPoolRoute.t.sol` (derivation, the four
    shapes on one and two hops, both venues, every floor, the callback gates —
    `test_callback_unarmed_revertsEvenForTheGenuinePool`,
    `test_callback_armed_wrongCallerRefused`,
    `test_callback_genuinePoolWithAnotherHopsData_refused`,
    `test_callback_owedOnTheWrongToken_refused`, `test_callback_owedAboveBudget_refused`,
    `test_callback_reentryFromSwapRefused`, `test_budget_exactOut_neverReachesHeldValue`).
    Opaque aggregator routes (Sushi API / Nordstern) keep the sandbox path.
    **Gas, pool vs sandbox vs a raw SwapRouter02 swap** — live Rootstock pools, block
    9,295,925, fresh tx (all setup in `setUp`, nothing read in the measured tx),
    steady state (solver floors, sandbox's standing router approval, recipients paid
    before), spread to a treasury; execution / NET tx gas (execution + calldata + 21k
    − refund, capped at gasUsed / 5); `PoolRouteForkBench` (`test/PoolRouteFork.t.sol`),
    the DEPLOYED bytecode (`solvers-deploy`: via-IR, runs 1e6 — `AGG_ARTIFACT`, see
    *Gas pass 2026-10-12* below; re-measured after the `SurplusSplit` event was
    removed, −2,615…−2,618 on every solver fill, raw-router rows unchanged):

    | shape | raw SwapRouter02 (trader's tx) | sandbox fill | **pool fill** | pool − sandbox (net) | pool vs raw (net) |
    | --- | --- | --- | --- | --- | --- |
    | 1 hop direct exact-out, 0.0002 WRBTC → 16 USDT0 (the live shape) | 101,402 / 121,186 (exactOutputSingle) | 264,694 / 263,426 | **205,847 / 229,039** | −34,387 | 1.89× |
    | 1 hop direct exact-out, live `amountOut` (typed) | — | — | 211,272 / 234,440 | — | — |
    | 1 hop direct exact-out on the SushiSwap v3 pool | — | — | 194,658 / 217,862 | — | — |
    | 1 hop pull exact-in | 96,579 / 119,163 (exactInputSingle) | 299,725 / 281,117 | **252,063 / 252,291** | −28,826 | 2.12× |
    | 2 hops direct exact-out, 100 USDRIF → USDT0 → 0.0011 WRBTC | 166,996 / 187,408 (exactOutput) | 334,995 / 334,439 | **269,598 / 293,338** | −41,101 | 1.57× |
    | 2 hops pull exact-in | 192,256 / 195,568 (exactInput) | 388,527 / 350,803 | **315,642 / 313,642** | −37,161 | 1.60× |
    | 3 hops direct exact-out, mixed venues: USDRIF →(Oku 0.05%) USDT0 →(Sushi 0.3%) WRBTC →(Oku 0.3%) 900 RIF | — | — | **340,156 / 364,208** | — | — |
    | 3 hops pull exact-in, mixed venues | 292,989 / 276,677 (exactInput, all-Oku path) | — | **405,111 / 400,611** | — | 1.45× |
    | ERC-2612 permit in the fill (USD₮0 → WRBTC, direct) | — | — | **277,305 / 282,849** | — | — |

    ⚠ The 2-hop figures published here before 2026-10-12 (302,524 / 324,305) were 4.5k
    LOW: the bench read `balanceOf(maker)` inside the measured transaction, which warmed
    the account and slot the fill then wrote. Every pre-fill read is now taken in
    `setUp` (or derived from what `setUp` dealt).
    Unit benchmark (mocks, legacy test profile, read the difference only):
    `AggregatorPoolRouteTest:test_gas_unit_direct_pool` 152,123 vs
    `test_gas_unit_direct_sandbox` 179,483; `test_gas_unit_pull_pool` 177,029 vs
    `test_gas_unit_pull_sandbox` 203,029.
    **ERC-2612 permits (2026-10-12, BREAKING ABI).** `executeFill(order, sig,
    fillAmount, plan, takerData, Permit2612[] permits)` and `executeItemFill(…,
    lateItems, permits)` run `token.permit(owner, SETTLEMENT, value, deadline, v, r, s)`
    for each entry BEFORE the fill: a gasless maker's book-carried permit funds the
    order inside the fill transaction (Settlement's direct-approval fallback pulls with
    the allowance). `owner` must be the order's maker (`PermitOwnerNotMaker`); a failed
    call is accepted only if Settlement's allowance from the maker already covers
    `value` (relayed / front-run), else `PermitFailed` before anything moves. A maker
    in Permit3 strict mode has no fallback: the fill reverts `Permit3Denied`
    (`test_permit_strictMakerHasNoFallback`). The old 5-argument entry is gone (one
    selector, `0xd828b11a`). Gas (same fork bench, USD₮0 → WRBTC pool fill, net,
    deployed bytecode after the 2026-10-12 gas pass): Permit3-funded 236,467, direct
    approval 237,016, **permit in the fill 282,849 (+45.8k net / +58.7k execution:
    USD₮0's allowance 0→value and nonce 0→1 writes)**; a permit someone already relayed
    costs +33.2k when still passed (the failed call verifies the signature first) and 0
    when omitted (`PoolRouteForkRelayedBench`); the replaced relay design's standalone
    permit tx was 95,083 net — so in-fill saves ~49k gas and one block on the first fill.
    **Gas pass 2026-10-12 — see the next item.**
  - **Gas pass 2026-10-12** (`AggregatorFillSolver` only; no core change; every check
    kept — operator gate, the 1/2/3/4/5/6 armed states, the callback's CREATE2 pool
    derivation + hop budget, delta measurement, `minOut` / `maxPay`, `RouteOverspent`,
    the Settlement-approval clear, permit owner == maker). Fork bench above, NET tx gas,
    one change at a time, each measured on the legacy test build AND the via-IR deploy
    build (1-hop direct / 1-hop pull / 2-hop pull / 3-hop pull):

    | change | legacy Δ net | via-IR Δ net | kept |
    | --- | --- | --- | --- |
    | `_derive`: CREATE2 pool address hashed in scratch memory (was `abi.encodePacked` + `abi.encode` allocations), twice per hop | −492 / −492 / −1,000 / −1,514 | −758 / −758 / −1,534 / −2,311 | ✅ |
    | hops read by raw `calldataload` at a proven-in-bounds offset; `pool.swap` encoded straight into free memory (`_poolSwap`: no `abi.encodePacked(budget, path)` copy, no second ABI copy, 64-byte return required instead of `extcodesize`) | −1,869 / −2,383 / −4,628 / −6,869 | −1,277 / −1,709 / −3,344 / −4,978 | ✅ |
    | `uniswapV3SwapCallback`: budget / token by `calldataload` (was bounds-checked slices) | −375 per paying callback | −257 | ✅ |
    | `_plan` reads `legsIn` / `legsOut` in CALLDATA (`PackedArrays`, was a memory copy via `PackedArraysMem`) — every path | −403…−428 | −2,617…−2,812 | ✅ |
    | `_splitSurplus` skips the three ppm products when no share but the filler's exists (`SEED_INPUT && originatorPpm == 0`) — every path | −731 | −500 | ✅ |
    | pool-route shape check + amount words by `calldataload` (`_poolShape`, `_poolAmounts`) | −996…−1,005 | −336 | ✅ |
    | `NO_PATCH = 2^255`, any bit-255 offset = no patch (was `type(uint256).max`: 32 non-zero calldata bytes = 512 gas → 140) — `type(uint256).max` still reads as no patch | −770 (2 unpatched offsets) | −770 | ✅ |
    | … the same tested as `offset >> 255` instead of `>= NO_PATCH` | +18, −147 B | +18 | ❌ |
    | ERC-2612 `permit` call encoded in free memory, return data not copied | −271 (permit fill) / −518 (already relayed) | −198 / −511 | ✅ |
    | hand-encoded `fillWithCallback` call, Yul helper functions | +2,587 | +3,687 | ❌ |
    | … straight-line, canonical re-encoding with the decoder's own tail checks | −573 | −146 | ❌ (a hand-rolled `Order` ABI encoder on the fill path is not worth 146 gas on the shipped build) |
    | **compiler: `solvers-deploy` → via-IR, runs 20,000** | — | −2.3k / −2.4k / −2.5k / −3.0k (vs legacy) | ✅ |
    | … runs 1,000,000 (= 2^32−1, step function) | — | a further −93…−108 | ✅ (runtime 20,935) |
    | … runs 200 | — | +1.1k…+1.4k vs runs 20,000 | ❌ |
    | `SurplusSplit` event removed (LOG3 + 4 data words, emitted once per token per fill; nothing read it — off-chain, each share is the token's own `Transfer` log) — every path | −2,653 (1-hop direct / 1-hop pull / 2-hop direct / permit, each measured) | −2,618 direct, −2,615 pull (every pool and sandbox row above; retain −2,625…−2,628) | ✅ (runtime 20,779, −156 B) |
    | 1-wei floor on each INTERMEDIATE token of an exact-input multi-hop route (`amount − 1` to the next hop) | +20.2k (2 hops) / +40.3k (3 hops) on the first fill, +3.1k per intermediate on every later one | — | ❌ (refund-neutral to begin with: the unseeded and the seeded intermediate measure 316,257 both — the slot round-trips inside the tx) |

    Total, deployed bytecode vs the pre-pass legacy build (the event removal
    included): **1-hop direct −11,060 (240,099 → 229,039), 1-hop pull −11,729, 2-hop
    direct −13,686, 2-hop pull −15,163, 3-hop mixed direct −16,300, 3-hop mixed pull
    −18,600, permit in the fill −11,756, sandbox routes −7.1k.** Measured but
    deliberately NOT done: a packed `RoutePlan` encoding (a new entry point)
    would save ≈1.1k calldata for ≈0.3k decode — not worth an ABI break; a 1-wei
    Settlement allowance "floor" is both refund-neutral and a standing allowance (the
    stale-approval PoC's precondition). The typed callback (live `amountOut`) costs
    +5.4k net on the pool path — the core prices every leg twice; nothing to take out on
    this side.
    **Retain mode is the cheaper filler configuration** (`profitRecipient = the
    solver`, swept in batches with `sweep`): 223,855 vs 229,039 direct (−5,184), 246,084
    vs 252,291 pull (−6,207), 287,575 vs 293,338 2-hop direct, 308,458 vs 313,642 2-hop
    pull — it skips the per-fill payout `transfer`. Defaults are unchanged.
    **Deployed bytecode is via-IR now, tests compile legacy:** `make
    test-solvers-deployed` builds `solvers-deploy` and runs the WHOLE solvers suite
    against that artifact (every test deploys through `newAgg`,
    `test/shared/AggDeploy.sol`, which loads `AGG_ARTIFACT`); the fork bench takes the
    same switch. Assembly blocks each carry an `EQUIVALENT SOLIDITY` note; new pins:
    `testFuzz_poolFor_matchesReferenceFormula`, `test_poolFor_preservesFreeMemoryPointer`,
    `test_noPatch_anyBit255Value`, `test_callback_shortPrefixRecursionReverts`, the
    `BadPoolSwap` selector in `test_route_nonexistentPoolReverts`.
  - `RouteSandbox.sol` — the identity every route runs from, deployed by the
    solver's constructor (`SANDBOX()`; `OWNER()` = the solver). One entry,
    `exec(tokenIn, target, data, sweepTokens)`, owner-only: (1) give `target` a
    standing max approval on `tokenIn` if the current one does not cover what is
    held; (2) `target.call(data)`, bubbling the revert as `RouteFailed`; (3)
    UNCONDITIONALLY sweep the full balance of every `sweepTokens` entry, in the
    order given, then `tokenIn` if unlisted, back to the solver. The solver pushes
    exactly the measured fill delta of `tokenIn` (`transfer`, never an approval),
    calls `exec` with the patched route and the order's whole token set as
    `sweepTokens` **ordered output tokens first, then `tokenIn`, then the other
    inputs** (defence in depth: a `transfer` hook in a non-output token runs after
    the spread has left), then checks
    `RouteOverspent` (no input token below its snapshot) and proceeds as before
    (minOut / maxPay / delivery / split). The trust argument is
    `SolverCallbackExecutor`'s, applied to the solver's own side:
    *push-funded* — it never calls `transferFrom`, so nobody ever approves it, and
    the solver must not either (the target may be a token: `target = USDT0, data =
    transferFrom(solver, attacker, …)` would drain a solver→sandbox allowance);
    *ends empty* — every call returns every token of the order, so its own
    standing approvals reach nothing BETWEEN fills (⚠ but they do reach a later
    fill's in-flight balance if their holder gets control during it — which is why
    only operators may name targets, see above);
    *no authority* — nobody grants it a Permit3 book, a signer slot or an operator
    role, and Settlement, Permit3, the EXECUTOR, the solver and itself are refused
    as targets anyway (`ForbiddenTarget`, defence in depth). Tokens are NOT
    refused as targets: one can only move what the sandbox holds (this fill's
    input — the fill then fails its output check unless only the part above
    `minOut` goes) or create standing approvals (see the ⚠ above). **No native value**: `exec` is not payable and there is no
    `receive`, so a route that pays native coin here reverts.
    **Route recipient:** pull = the solver (paying the sandbox settles too, but
    leaves the proceeds there for the rest of the route call — don't); direct =
    the maker. The PAYER the router sees is the sandbox — Sushi's
    RedSnwapper `snwap` and Uniswap's SwapRouter02 both pull only from their own
    `msg.sender`, so the sandbox's standing approvals to them are inert (tested on
    a Rootstock fork, `test/RouteSandboxFork.t.sol`).
    **Gas** (live Rootstock pool, fresh tx, steady state, one harness for all
    three; execution / net of the end-of-tx refund — net = execution + calldata +
    the 21k intrinsic − refund, capped at gasUsed / 5; solver floor seeded,
    spread to a treasury; fork block 8,920,000; measured 2026-10-04 BEFORE tasks
    06/08 with the pre-sandbox contract compiled side by side, so NOT re-runnable
    as a set): direct 236.4k / 231.0k with
    the old per-fill router approval, 209.6k / 224.2k with the old STANDING
    approval, **247.9k / 242.6k sandboxed**; pull 294.3k / 266.0k, 267.5k /
    259.2k, **305.9k / 277.6k**. So the allowlist-free route costs **+11.5k net
    per fill against per-fill approvals and +18.4k net (+38.3k execution) against
    standing ones** (`SandboxGasBench`). Runtime 13,980 bytes then (was 15,894).
    Re-run 2026-10-06 on `SandboxGasBench`'s own fixture (which warms ~2.5k more
    than that harness; profile `solvers`, same block, untyped callback):
    `test_sandbox_gas_direct` **252,567 / 247,907** (refund 37,900; gross 285,807),
    `test_sandbox_gas_pull` **310,502 / 282,890** (refund 60,600; gross 343,490) —
    +2.2k execution / +2.8k net on both paths since 2026-10-04 (same fixture then:
    250,372 / 245,060 and 308,320 / 280,056).
    **RouteSandbox dust floor — measured, not adopted** (2026-10-04, pre-06/08,
    `SandboxGasBench` with `FLOOR` patched to 1 — not re-runnable without editing
    the constant; net tx gas as above, solver floor seeded). Keeping 1 wei per token
    on the sandbox cut execution gas by exactly 17,100 and the refund by exactly
    17,100: the sandbox's slot is written and restored within one transaction,
    and EIP-2200/3529 refund the restore. Net transaction gas was identical
    (242,605 both ways direct; 277,601 pull), so `FLOOR = 0` and the sandbox
    ends every call holding nothing. A floor only pays once a transaction's
    refunds exceed the gasUsed / 5 cap — which is exactly why the SOLVER's floor
    still pays on the pull path (no solver floor: refund 94.8k against a ~74.5k
    cap, +20.3k net — 2026-10-04, not re-run) while being refund-neutral on the direct path. Price every
    "floor" claim net of refunds.
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


## Deploying an AggregatorFillSolver

`script/DeployAggregatorFill.s.sol`, driven by `make deploy-aggregator-fill RPC=…
DEPLOY_ARGS=… VERIFY_ARGS=…` under the `solvers-deploy` profile (via-IR, optimizer runs
1,000,000, `evm_version = cancun` for Rootstock — since the 2026-10-12 gas pass; the test
profile `solvers` stays legacy, so run `make test-solvers-deployed` before a deploy: the
whole suite against this profile's artifact). It reads `SETTLEMENT`,
`OPERATORS` (required, 1–4: the constructor reverts on an empty set and the old
`ALLOW_OPEN` is refused), the surplus-policy ppm values (read as `uint256` and
bounded — never silently truncated to `uint32`), the POOL VENUES and the optional
`FLOOR_TOKENS` (1 wei of each sent to the new solver) from the environment.
**Pool venues (2026-10-12):** `POOL_FACTORIES` + `POOL_INIT_HASHES` (comma lists, same
length, ≤ 4; venue index = position). Both unset on chain 30 = the verified Rootstock
defaults, venue 0 = Uniswap v3 / Oku `0xaF37EC98A00FD63689CF3060BF3B6784E00caD82`,
venue 1 = SushiSwap v3 `0x46B3fDF7b5CDe91Ac049936bF0bDb12c5d22202e`, both with
`0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54`; unset
elsewhere = no venues (pool routes off); `NO_POOL_VENUES=true` forces none. After
deploying, the script reads every venue back and proves it with a probe pair —
`poolFor(i, probe)` must equal the factory's own `getPool(probe)` and have code — the
WRBTC/USDT0 0.3% pool on chain 30, or `POOL_PROBE="tokenA,tokenB,fee"` elsewhere — so
a wrong init code hash fails the deploy, not the first fill.
`FLOOR_TOKENS` is **no
longer needed** (2026-10): the solver seeds a token's 1-wei floor out of its own
first fill of it (see *The floor seeds itself* above). Pre-seeding still works and
saves that first fill the refund it forgoes (~+11k / +25k net, direct / pull) — worth
it only for a token you expect to trade exactly once or twice. An operator with code —
a contract or an EIP-7702 delegated EOA — is logged loudly and refused unless
`ALLOW_CONTRACT_OPERATORS=true`. It takes the signer from the CLI flags, and
reverts unless every immutable — including the deployed
`RouteSandbox`'s owner / Settlement / Permit3 / EXECUTOR — reads back as requested.
**BREAKING (2026-10-14, solver v3):** the constructor is `(settlement, operators,
policy, venues, nativeBalance, wnative)` — `NATIVE_BALANCE` (the deployed
`NativeBalance` view) and `WNATIVE` from the environment; unset = native delivery off;
on chain 30 `WNATIVE` defaults to WRBTC `0x542f…677d` when `NATIVE_BALANCE` is set; the
script probes the view (`balanceOf(x) == x.balance`, 18 decimals) and reads both back
through `nativeDelivery()`. `FillRoute`'s `sameOut` word is now `legs` (same ABI type,
so `onFill`'s selector is unchanged). (2026-10-12: `(settlement, operators, policy,
venues)`; executeFill / executeItemFill take a trailing `Permit2612[] permits`.)
(2026-10: `(settlement, operators, policy)`, reverting `NoOperators` on an empty set;
the script refuses the removed `ROUTERS`, `STANDING`, `PRIME_TOKENS` and
`ALLOW_OPEN`.)
**Deploying native delivery (task 30).** `make deploy-native-delivery` runs
`script/deploy-native-delivery.sh`, which creates `NativeBalance` and a v3 solver wired to
it in one `forge script` run (`DEPLOY_NATIVE_BALANCE=true`). By default it only runs the
preflight and a simulation against the live chain: chain id, deployer balance, the
predicted addresses, and every read-back check. `BROADCAST=1` deploys after a typed
`yes`, signing with the `deployer` keystore. It prices at `minimumGasPrice × 1.03` with a
1.1× gas reserve; forge's defaults would ask the deployer to reserve ~0.000187 RBTC for a
~0.000137 RBTC deploy. Afterwards it reads both contracts back, prints the record lines,
and verifies both on Sourcify.

`make size-check-solvers` reports the runtime size under that profile (**22,777** /
24,576 bytes, initcode 27,623, after `sweepAll` (+357) and the hand-encoded `matchSettle`
call (−789); 23,151 / 27,997 after solver v3 — native delivery, tasks 16/17 — from a
wiped `out/solvers-deploy`. The big size lever is `optimizer_runs`, measured 2026-10-15
on this tree (runtime / gas per fill): 1e6 22,777 / 0, 3e4 21,817 / +25, 2e4 21,367 / +110,
1.5e4 20,133 / +700, 1e4 19,450 / +740; 20,779 / 25,430 — initcode embeds the sandbox — after the 2026-10-12 gas pass
and the `SurplusSplit` event removal (−156 B; 20,935 / 25,586 before it), via-IR runs
1e6; legacy runs 20,000 was 21,001 / 26,245 after pool routes
and permits: ≈ +1.1k for the permit path, ≈ +1.8k for the route driver, the rest the
callback, venue immutables and views; was 15,127 / 19,560 after the self-seeding floor,
15,176 / 19,562 after tasks 06/08, 13,935 / 18,314 after the 2026-10 gated-only change).
Simulated against live Rootstock (2026-10-12, `forge script` without `--broadcast`,
`SETTLEMENT` = the beta's `0xe6ED…ddf5`): ~6.75M gas, both default venues derive their
probe pool. The Rootstock beta runbook is in `packages/beta-filler/README.md`.

**Redeploying the Rootstock beta solver (plain CREATE, new address):**

```bash
make size-check-solvers
SETTLEMENT=0xe6EDbb5c49Fb4CFb313476e3B78E274D3584ddf5 \
OPERATORS=0xcafe35944e3195d59b4a354Ea23D60a0445c083a \
make deploy-aggregator-fill RPC=https://public-node.rsk.co \
  DEPLOY_ARGS="--account deployer --sender 0x00001d4754680958E7f8fe42D60842Ebde4Cb30D --legacy --slow --gas-estimate-multiplier 110"
# verify (Blockscout imports Sourcify): read SANDBOX() on-chain first — forge's
# simulated child address is not reliable for the sandbox
FOUNDRY_PROFILE=solvers-deploy forge verify-contract --verifier sourcify --chain 30 <solver> \
  packages/solvers/src/aggregator/AggregatorFillSolver.sol:AggregatorFillSolver
```

Then point the app (`VITE_DEPLOYMENTS[30].solver` — delta-verify orders name it as
`exclusiveFiller`) and the filler (`AGGREGATOR_SOLVER`) at the new address. Orders
already signed for the OLD solver (exclusiveFiller = 0x33cc…E287) stay fillable only
by it: keep the old instance's operator running until they expire or are cancelled.

## Losing races cheaply

> The full write-up — off-chain build order, the exact-equality rationale, and the
> revert-reason taxonomy — is **[docs/filler-strategy.md](../../docs/filler-strategy.md)**,
> the recommended shape for any `matchSettle` filler. This section is the summary.

A profitable match is visible to every solver at once, so several land a
transaction for it in the same block. One wins; the rest revert — and reverting
is not free.

An unguarded loser learns the race is over only well into the approach:
`matchSettle` derives the token universe, takes a `balanceOf` snapshot per token
and hashes the first order (keccak over the full struct and every dynamic
sub-array) before `_openGated` reads `filled` — which it does BEFORE `ecrecover`
and the validators (corrected 2026-09-30, X-SPEC-8) — and reverts `OverFill`. Every one of those steps is wasted, and the waste grows with
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
validators (`MatchRaceGuardTest.test_raceLoser_guardIsFarCheaperThanReverting`,
`test/MatchRaceGuard.t.sol`; execution gas of the losing call, no 21k intrinsic, no
calldata; profile `solvers`, re-run 2026-10-06 — the 2026-09 figures were
34,679 / 3,641 / 31,038, −89%; the core's losing path got cheaper since):

| race loss | gas |
| --- | --- |
| unguarded (`matchSettle` direct) | 23,409 |
| guarded | **3,743** |
| saved | 19,666 (**−84%**) |

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
