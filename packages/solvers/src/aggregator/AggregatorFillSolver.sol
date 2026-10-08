// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {PackedArraysMem} from "@core/settlement/PackedArraysMem.sol";
import {PackedArrays} from "@core/settlement/PackedArrays.sol";
import {Settlement, Order, CallbackMode, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {DutchAuction} from "@core/settlement/DutchAuction.sol";
import {RouteSandbox} from "./RouteSandbox.sol";

/// @title AggregatorFillSolver
/// @notice Zero-inventory fills against an off-chain aggregator route: take the
///         maker's `tokenIn`, swap it through whatever router the quote named,
///         deliver `tokenOut`. No flash loan, no held capital, and no bespoke
///         integration per venue — the route is opaque calldata.
///
///  WHY A CONTRACT IS REQUIRED HERE, and raw router calldata is not enough
///  ─────────────────────────────────────────────────────────────────────
///  `fillWithCallback` does NOT make the solver's `(target, data)` call itself.
///  It routes it through {SolverCallbackExecutor}, an allowance-less trampoline
///  that holds no funds and is an approved spender for nobody — deliberately, so
///  a filler cannot pass `target = Permit3` and drain every maker who ever
///  approved Settlement.
///
///  The consequence for aggregator injection: inside the callback the router
///  sees `msg.sender == EXECUTOR`. Aggregator routers pull their input with
///  `transferFrom(msg.sender, …)`, and the executor has neither the tokens nor
///  an approval — so passing the aggregator's own calldata straight through as
///  the callback target reverts every time. Something must hold `tokenIn`
///  mid-fill and approve the router from an identity that owns it. That is this
///  contract, and it is the whole reason it exists.
///
///  The flow (`CallbackMode.PostInputsTypedDirect` — Fusion's `takerInteraction` ordering)
///  ──────────────────────────────────────────────────────────────────────────────
///    1. `executeFill` → `settlement.fillWithCallback(..., PostInputsTypedDirect,
///       takerData, plan.minBumpBps)` — the filler's price floor rides along.
///    2. Settlement pays the maker's `tokenIn` to `ctx.filler` — THIS contract,
///       because this contract is the `msg.sender` of the fill.
///    3. EXECUTOR calls `onSettlementFill` here with the fill's resolved per-leg
///       amounts: PUSH the input (less any output leg owed in that same token) to
///       {RouteSandbox}, which approves the route's target, fires the aggregator's
///       calldata and sweeps everything back; then check the proceeds against `minOut`.
///    4. Settlement pulls `tokenOut` from this contract (Permit3, falling back to
///       a direct `transferFrom`) and delivers it to the maker.
///
///  Step 4 is why `onSettlementFill` approves Settlement for the proceeds, and why the
///  fill is started with the DIRECT bit ({CallbackMode.PostInputsTypedDirect}): this contract never
///  holds a Permit3 allowance, so the pull would probe Permit3, fail, read the
///  strict flag and only then fall back to the ERC20 `transferFrom` — 8.2k
///  gas per fill for nothing. The DIRECT bit tells the core to go straight to
///  the `transferFrom` for the FILLER'S legs (the maker's pull is untouched).
///
///  DIRECT DELIVERY — the cheap path, for orders that allow it
///  ─────────────────────────────────────────────────────────
///  An order signed with `timing` bit 104 ({DutchAuction.deltaVerifyOutputs})
///  asks the core to VERIFY each output recipient's balance increase instead
///  of pulling from the filler. For this contract that means step 3 can route
///  the swap output straight to the maker and steps 4 and its cleanup vanish:
///  no Settlement approval, no failed-Permit3 probe on the pull, no `tokenOut`
///  ever touching this contract. Measured −27k execution gas per fill against
///  the pull path on the two-token benchmark (see `test/AggregatorFillGas.t.sol`).
///  The route must then be quoted with `recipient = order.maker` and, to keep
///  the spread, as EXACT-OUTPUT for the priced amount: the input the router
///  does not consume stays here and is split in `tokenIn` units by the same
///  policy (the F28 residue path). Detected from the order, never chosen by the
///  caller — the maker signed the delivery mode, the core enforces it, and a
///  route that pays the wrong recipient simply fails the core's delta check.
///  `minOut` and `maxPay` are ignored on this path (nothing is measured or
///  pulled here); the route's own `amountInMaximum` is the solver's protection.
///  Set `RoutePlan.amountOutOffset` on such a route: the exact-output word is then
///  rewritten with the LIVE `legsOut[0]` price the core is about to verify, so a
///  SELL included after its auction has decayed pays the maker the tick at
///  inclusion — not the quote — and the difference stays here as input residue
///  (2026-10; before it, that decay reached the maker as price improvement).
///
///  ⚠ THE PRICED AMOUNT IS RESOLVED AT FILL TIME, AND AGGREGATOR CALLDATA IS NOT.
///  An aggregator bakes `amountIn` into the bytes it returns, but what the maker
///  actually pays is decided during the fill — it rises with the clock on a BUY
///  order, is read from the maker's live balance on a {Proportional} leg, shrinks
///  on a partial fill the filler sizes later, and nets differently for a
///  fee-on-transfer token. Whenever the two disagree the router pulls the QUOTED
///  figure: too high and the swap reverts, too low and the surplus strands here.
///
///  `RoutePlan.amountInOffset` is the fix — the offset of the 32-byte amount
///  inside the route's calldata, which {onSettlementFill} overwrites with the balance
///  actually received (less the output legs owed in that token) before firing it.
///  Set it and the route follows the fill;
///  leave it {NO_PATCH} for a fixed-input SELL order, where the quoted figure is
///  already exact and rewriting buys nothing.
///
///  ⚠ FEE-ON-TRANSFER ANCHOR + `amountInOffset` ALWAYS REVERTS (accepted, 2026-10).
///  The patched figure is what reached THIS contract; the push to {RouteSandbox}
///  is a second transfer and the token takes its fee again, so the sandbox holds
///  less than the route is told to pull and the router's `transferFrom` fails. Not
///  fixed here on purpose: the core stays asset-general (FoT and rebasing tokens
///  settle for every maker who signs for them), and a solver may specialise — this
///  one specialises to tokens that transfer exactly. A FoT `tokenIn` can still be
///  routed with {NO_PATCH} and a quote sized for the twice-taxed amount, or by a
///  solver written for that token.
///
///  A {Proportional} ("sell my balance") order: pass `fillAmount =
///  type(uint256).max` and set `amountInOffset`. `fillWithCallback` then fills the
///  whole anchor as resolved at inclusion, and the patched route swaps exactly that.
///  It is safe for THIS contract because it never pays the maker's fixed output
///  from its own balance: a balance that shrank since the quote swaps less, cannot
///  cover the output, and the fill reverts (Settlement is approved for no more than
///  this swap produced); one that grew is a bigger swap, and every {SurplusPolicy}
///  share and originator carve-out is a fraction of that measured spread. See
///  docs/proportional-legs.md.
///
///  ⚠ THE OFF-CHAIN QUOTE MUST NAME THIS CONTRACT. Aggregators bake the
///  recipient (and often the sender) into the calldata they return. A route
///  quoted for the solver's EOA sends the swap output to that EOA, and the fill
///  then reverts here with {InsufficientOutput} — the funds are not lost, but the
///  round is. Quote with `recipient = address(thisSolver)`.
///
///  Trust model: `executeFill` is callable by this instance's OPERATORS only —
///  GATED-ONLY since the 2026-10 quick audit: the constructor refuses an empty
///  operator set ({NoOperators}; BREAKING — there are no open instances any more).
///  The route is an arbitrary call, and an arbitrary-call sandbox is incompatible
///  with permissionless routing: a stranger who can drive the sandbox can make it
///  `approve` a contract of his (`target = token, data = approve(harvester, max)`,
///  or simply `target = harvester`, which receives the sandbox's standing max
///  approval on `tokenIn`), and that grant then reaches the in-flight balance of
///  every LATER honest fill — the filler's spread above `minOut` — from any point
///  where the attacker gets control mid-fill (a hook token in the order's sweep
///  list, a hooked exact-output router, a residue window). PoC'd twice in
///  `test/RouteSandbox.t.sol`. With the gate, the set of targets the sandbox has
///  ever approved is exactly the set the operators' routes named. THREE more
///  things bound what an operator-submitted route can do, and all three are
///  load-bearing:
///
///    1. THE ROUTE RUNS IN {RouteSandbox}, NEVER AS THIS CONTRACT (2026-10, replaces
///       the immutable router allowlist). The EXECUTOR check and the arming flag
///       bound WHEN the callback runs, not what the route does: the route's target
///       and calldata are opaque here, and may come from a third-party API the
///       operator forwards (AGG-4 below). They run from an identity that owns
///       nothing of this contract's and is trusted by nobody: the sandbox is
///       PUSH-funded with exactly this fill's input, never approved by anyone (this
///       contract included — a solver→sandbox allowance plus `target = token` would
///       be a drain), and sweeps every token of the order back here at the end of
///       the call, OUTPUT TOKENS FIRST (they hold the spread). Arbitrary targets are
///       therefore allowed; the sandbox refuses only Settlement, Permit3, the
///       EXECUTOR and this contract as targets (defence in depth). THIS CONTRACT
///       NEVER APPROVES A ROUTER OR ANY THIRD-PARTY TARGET — its only allowance is
///       Settlement's, set after the route and cleared after the fill.
///
///    2. EVERY AMOUNT IS A DELTA OF THIS FILL, never a balance. The router
///       approval, the `minOut` test, the Settlement approval and the profit
///       sweep all measure `balance − balanceBefore`, snapshotted in
///       `executeFill` before Settlement moves anything. A balance-based figure
///       would let a self-signed 1-wei order approve, deliver or sweep whatever
///       an unrelated fill left parked here.
///
///    3. NO ALLOWANCE OF THIS CONTRACT SURVIVES THE FILL. It approves no router at
///       all (the sandbox does, from its own account — see the ⚠ there on why
///       those grants are not worthless and why only operators may create them);
///       Settlement's allowances are zeroed in `executeFill` after the fill
///       returns, so a standing approval can never be paired with a later balance.
///
///  Holding nothing between fills is therefore NOT a security assumption —
///  residue is unreachable by the next caller — and the gas-optimal way to run
///  this contract deliberately holds some. Every inbound transfer to a ZERO
///  balance slot costs the token's 0→non-zero SSTORE (≈20k), twice per fill
///  (`tokenIn` arrives, `tokenOut` arrives), and the matching refunds are capped
///  per transaction. A floor of one wei per traded token makes both writes
///  non-zero→non-zero (Rootstock fork, live pool: −34.1k execution gas per fill on
///  both paths, `SelfSeedSteadyBench` vs `SelfSeedColdBench` on the pre-2026-10
///  contract).
///
///  THE FLOOR SEEDS ITSELF (2026-10) — no deploy-time token list is needed. A
///  token whose pre-fill snapshot is ZERO keeps one wei of THIS fill: {_splitSurplus}
///  pays the filler's share less one wei (output spread, input residue, any token,
///  both entries), and {_seedIn} routes `delta − 1` on a pull / netted fill whose
///  route follows `amountInOffset`. Both come out of the filler's side only — the
///  maker's priced amount, the fee legs, the core's verified delivery and every
///  {SurplusPolicy} share are computed exactly as on a seeded instance (pinned
///  twin-for-twin in `test/AggregatorSelfSeed.t.sol`); `_seedIn` lists the paths it
///  skips and why. Every later snapshot includes the wei, so it is never re-split
///  and sustains itself. `RoutePlan.profitRecipient == address(this)` (retain
///  mode) keeps the filler's whole share here anyway — recoverable by the
///  operators with {sweep} (audit 2026-09-30 AGG-1: retain mode used to be refused
///  on open instances, where nothing could move it out; there are no open
///  instances any more).
///
///  THE OPERATOR SET — mandatory since 2026-10
///  ──────────────────────────────────────────
///  `executeFill` / `executeItemFill` are restricted to an immutable set of 1..4
///  operators, fixed at construction (no owner, no setter). Besides the sandbox
///  argument above, the set is what makes delta-verify orders, a non-zero surplus
///  policy and retain mode sound (each used to be refused on an open instance —
///  `DirectNeedsOperators` / `PolicyNeedsOperators` / `RetainNeedsOperators`, now
///  removed with the open mode): in all three the route calldata decides more than
///  this fill's deltas, so its author must be trusted.
///
///  ⚠ THE TRUST BOUNDARY IS WHOEVER WRITES THE ROUTE, not only the operator key
///  (audit 2026-09-30 AGG-4). "Operator-tier trust" covers the calldata an operator
///  SUBMITS — and an off-chain executor that takes `tx.to` / `tx.data` verbatim from
///  a third-party route API (packages/auction's Sushi and Nordstern sources) puts
///  that API inside the boundary too. In the sandbox a hostile route can spend this
///  fill's in-flight input — on the pull path the fill then reverts on the output
///  check unless only the spread above `minOut` goes; on the DIRECT path the core's
///  delta check catches a route that does not pay the maker, but the input-side
///  residue (the spread) is the route's to keep or divert — AND every target it
///  names keeps a sandbox approval that reaches later fills' in-flight spread if it
///  ever regains control during one. So decode and validate API calldata before
///  submitting (router, tokens, amount, recipient against the order — what
///  packages/beta-filler does for Sushi), prefer the pull path for API routes, and
///  never name a target you would not trust with a later fill's balance.
///
///  SUPPORTED SHAPES (audit 2026-09-30 AGG-2 / AGG-6): any number of input and
///  output legs over at most {MAX_TOKENS} distinct tokens (each measured, approved
///  and split on its own delta — see {FillRoute}); one route call per fill, no
///  native value. Only `legsIn[0]`'s token (the anchor) is pushed to the sandbox
///  and routed; a further input leg's token stays here and is split as residue.
///
///  AN OUTPUT LEG IN THE ANCHOR TOKEN (an in-kind sourcing fee: `legsOut[j].token
///  == legsIn[0].token`) IS KEPT BACK, NOT ROUTED, ON BOTH ENTRIES. {executeItemFill}:
///  the core's PRESEND hands over only the pool's excess over its OUTSTANDING
///  obligations, so the leg's amount never leaves the pool. {executeFill} (since
///  2026-10, the typed callback): {onSettlementFill} subtracts the leg's priced
///  amount from the input delta before the push, so a patched exact-input route
///  swaps `input − leg` and the core's pull of the leg finds it here. Before the typed
///  callback the pull path routed the WHOLE input and a patched route failed that
///  pull (`TransferFromFailed`; review 2026-10-05 S1). Pinned in
///  `test/AggregatorAmountMismatch.t.sol`.
///
///    • ITEM-FREE orders — {executeFill} (`fillWithCallback`, `PostInputsTypedDirect`).
///    • ITEM-BEARING orders — {executeItemFill}. The core's `PostInputs` mode is
///      item-free (`ReverseModeRequiresNoItems`), so this entry drives a ONE-ORDER
///      `matchSettle` plan instead: items that produce the input (a TAKE —
///      withdraw, borrow) run first, the maker's remaining input is pulled, the
///      input is pre-sent here, the route runs as the plan's `CALL` step and pays
///      Settlement, the outputs are delivered, and items that consume the delivery
///      (a wallet-funded MAKE — deposit, repay) run last. Zero inventory, zero
///      flash, zero Settlement bytes. The core still refuses on that path what it
///      refuses for every netted plan: SETTLE and TAKE_FOR items, PUSH-funded
///      (pre-funded) MAKE items, and delta-verify orders — those stay with the
///      flash family (`BaseFlashSolver`, which fills through `fill`) or an
///      inventory filler.
///    • Single-signature PermitBatchWitness orders: their FIRST fill has no
///      callback entry (`fillWithPermit` passes no callback, and `fillWithCallback`
///      / `matchSettle` verify only an Order signature), so it needs capital up
///      front — the flash family takes such an order through its permit envelope
///      ({BaseFlashSolver.PERMIT_ENVELOPE}). Every LATER slice is fillable here:
///      the settler skips signature verification once `filled != 0`.
///
///  What it changes otherwise is WHO Settlement sees as the filler. The exclusivity
///  gate compares `order.exclusiveFiller` to `msg.sender` of the fill, which is
///  THIS contract — so an order that names this instance as its exclusive filler
///  is exclusive to its operators, which is what a capped beta or a solver that
///  wants the whole remainder needs. Supporting a new operator means deploying
///  another instance; supporting a new VENUE needs nothing (no allowlist).
///
///  STRANDED TOKENS: the sandbox sweeps the ORDER'S token set only. A token
///  outside it that a route leaves in the sandbox (an intermediate hop's refund)
///  stays there; an operator recovers it with a route of `target = token, data =
///  transfer(thisSolver, balance)` and then {sweep}s it on (tested).
/// @notice One aggregator route, as the solver received it off-chain.
/// @param router the route's TARGET — the venue's entrypoint, from the quote. Any
///        contract: it is called by {RouteSandbox}, never by the solver. Settlement,
///        Permit3, the EXECUTOR and the solver itself are refused
///        ({RouteSandbox.ForbiddenTarget}). On the pull path quote it to pay the
///        SOLVER. Paying the sandbox also settles (the sweep returns it, outputs
///        first), but leaves the proceeds — spread included — in the sandbox for the
///        rest of the route call, where any holder of a sandbox approval that gains
///        control later in that call can take the part above `minOut`. Don't.
/// @param minOut floor on the swap proceeds — SOLVER-side protection against a
///        stale route; the maker's own floor is the signed band Settlement enforces.
///        Measured in the ANCHOR OUTPUT TOKEN: the first output token no input leg
///        pays (`legsOut[0]`'s on every plain order), as what the route produced in
///        it — any inflow of that token the fill paid here BEFORE the route (an
///        input leg in the same token) is netted out first (review 2026-10-05).
///        Ignored on a direct-delivery order (see the contract note)
/// @param maxPay ceiling on what Settlement may pull from this contract in the
///        anchor output token — PER TOKEN, so two legs in it (maker + fee) must fit
///        under it together. `0` = no cap, meaning "up to THIS FILL's proceeds" —
///        never the contract's balance. A `maxPay` above the proceeds is clamped
///        down to them for the same reason. Together with `minOut` this pins the
///        spread: the fill can only succeed if `proceeds >= minOut` and the maker
///        takes at most `maxPay`, so profit >= `minOut - maxPay` by construction
/// @param amountInOffset byte offset within `data` of the 32-byte input amount to
///        REWRITE with the amount actually routed — this fill's input delta less the
///        output legs it owes in that same token (see {AggregatorFillSolver.onSettlementFill}),
///        and, on the first pull / netted fill of a token the solver holds none of,
///        less the one wei it keeps as its self-seeded balance floor
///        ({AggregatorFillSolver._seedIn}) — or {NO_PATCH} to leave the calldata
///        exactly as the aggregator returned it.
///        See the ⚠ note on {AggregatorFillSolver} about resolved amounts.
/// @param amountOutOffset byte offset within `data` of the 32-byte OUTPUT amount to
///        rewrite with `legsOut[0]`'s live price at inclusion (the core's typed
///        `pricedOut[0]`), or {NO_PATCH}. Meant for a DIRECT (delta-verify) order quoted
///        as exact-output: the route then pays exactly what the core verifies, and the
///        auction's decay since the quote stays here as input residue instead of
///        reaching the maker as price improvement (task 05). Setting it switches the
///        fill to the TYPED callback (~+5.9k gas; see `_typed`). Ignored by
///        {AggregatorFillSolver.executeItemFill} (no priced amounts reach a `CALL`
///        step, and direct orders are refused there). BREAKING (2026-10): new field.
/// @param minBumpBps the filler's PRICE FLOOR on the order's resolved bump, in bps of
///        the band — passed to `fillWithCallback` exactly as {Settlement.fillUpTo}
///        takes it (`0` = none; a miss reverts `BumpTooLow` before anything moves).
///        Set it to the bump the route was quoted at, so an order whose tick can move
///        maker-ward between quote and inclusion (a priority auction included at a
///        lower bid, a `gasBumpBps` order, a custom curve) reverts instead of eroding
///        the spread. Ignored by {AggregatorFillSolver.executeItemFill} (`matchSettle`
///        carries no floor). BREAKING (2026-10): new field.
/// @param profitRecipient where the FILLER'S share of the spread goes once the
///        maker is paid and the {SurplusPolicy} has taken the maker's and the
///        protocol's shares — less one wei of a token the solver held none of
///        before the fill (the self-seeded balance floor); `address(0)` =
///        `msg.sender`; the solver contract itself = keep it here (retain mode —
///        no transfer; see the note on holding nothing between fills). The
///        operators recover retained value with {AggregatorFillSolver.sweep}
/// @param originator the party that sourced the order (frontend, wallet, API
///        integrator) — paid `originatorPpm` of the output surplus. `address(0)`
///        with `originatorPpm == 0` = no originator share
/// @param originatorPpm the originator's share of the output surplus, in parts
///        per million. Carved out of the FILLER'S remainder — the maker's and
///        the protocol's immutable shares come first — so a caller can only give
///        away what would otherwise be its own; the sum of the three must not
///        exceed {PPM}
/// @param data  the aggregator's own calldata, quoted with `recipient = the solver`
///        (pull) or the maker (direct). The PAYER the router sees is the sandbox.
struct RoutePlan {
    address router;
    uint256 minOut;
    uint256 maxPay;
    uint256 amountInOffset;
    uint256 amountOutOffset;
    uint256 minBumpBps;
    address profitRecipient;
    address originator;
    uint32 originatorPpm;
    bytes data;
}

/// @notice How this instance splits the OUTPUT SURPLUS of a fill — the `tokenOut`
///         the route produced beyond what Settlement delivered against the
///         maker's signed price. Fixed at construction, like the operator set.
///
///  WHY THIS IS THE PLACE, and not the settler
///  ──────────────────────────────────────────
///  Settlement never sees a conversion's surplus: a solver holds the maker's
///  input, swaps it wherever it likes and delivers exactly the priced amount, so
///  anything above the auction tick stays in the solver's own contract and no
///  settler-side rule can reach it. A split is only ENFORCEABLE where the swap
///  itself runs in observable custody — which is precisely what this contract
///  is (the same reason 0x Settler can run `POSITIVE_SLIPPAGE`: it IS the
///  swapper). So the mechanic lives here, and a filler that would rather keep
///  100% of the spread is free to run its own contract and compete in the auction.
///
///  ⚠ IT BINDS THE SPREAD THAT REACHES THIS CONTRACT, i.e. ROUTES THE OPERATORS
///  WRITE (audit 2026-09-30 AGG-3; this note used to say "applies to every fill
///  routed through this instance whoever calls it"). The route calldata is the
///  caller's and opaque here: a multicall recipient split, `pull` + `sweepToken`,
///  or a caller-chosen executor can send part of the input or output elsewhere so
///  the spread never lands here and every share reads zero. No on-chain check can
///  tell that apart from a worse quote. So a non-zero policy is only meaningful
///  because the callers are operators trusted to write honest routes (every
///  instance is gated), and the originator carve-out "out of the filler's own
///  remainder" is a rule for those routes, not a bound on a hostile one.
///
///  The split is by construction the ANALOGUE of what non-conversion orders
///  already have: on a deposit the relayer earns a rising fee leg and the
///  originator a fee leg, both maker-signed (docs/originator-fees.md,
///  docs/relayer-fees.md). On a conversion the maker-signed pieces are the
///  auction band (the filler's spread) and any fee leg (the originator's
///  floor); the surplus split adds the VARIABLE part on top — price improvement
///  back to the maker, a protocol share for whoever provides the route, and an
///  originator share out of the filler's remainder.
///
/// @param makerPpm share of the output surplus returned to `order.maker` as
///        price improvement, in parts per million
/// @param protocolPpm share of the output surplus paid to `protocolRecipient` —
///        the API / route provider — in parts per million
/// @param protocolRecipient where the protocol share goes; must be non-zero when
///        `protocolPpm` is
struct SurplusPolicy {
    uint32 makerPpm;
    uint32 protocolPpm;
    address protocolRecipient;
}

/// @dev Parts per million — the unit every surplus share is expressed in.
uint256 constant PPM = 1_000_000;

/// @dev `RoutePlan.amountInOffset` / `amountOutOffset` sentinel: leave that word of the
///      aggregator's calldata as quoted.
uint256 constant NO_PATCH = type(uint256).max;

/// @notice The resolved route handed to {AggregatorFillSolver.onSettlementFill} (as the
///         typed callback's `userData`) and to {AggregatorFillSolver.onMatchRoute}.
/// @dev    A STRUCT rather than a parameter list, deliberately. The flat form hit
///         the stack limit at six arguments under the legacy profile this package
///         compiles with, and every future field would hit it again; a struct
///         costs one memory pointer and makes the shape extensible.
///
///         THE TOKEN SET (audit 2026-09-30 AGG-2 / AGG-6). Every DISTINCT token the
///         order's legs name, input legs first — so `tokens[0]` is always
///         `legsIn[0]`'s token, the anchor the route swaps. `inMask` / `outMask`
///         flag which of them an input / output leg pays (a token can be both: a
///         same-token order, a fee leg in the input token). Each is measured
///         against its own pre-fill snapshot in `before`, so a second input leg in a
///         third token has its residue split (since {RouteSandbox} only the anchor
///         `tokens[0]` is pushed to the route; the others stay here) — it used to be paid here and never looked at again — and
///         every output token is approved to Settlement at ITS OWN measured
///         proceeds, so the pull path is no longer limited to one output token.
struct FillRoute {
    address router;
    uint256 minOut;
    uint256 maxPay;
    uint256 amountInOffset;
    uint256 amountOutOffset;
    /// @dev Bit `j` set = output leg `j` is paid in `tokens[0]`, the anchor INPUT
    ///      token (an in-kind fee leg). {onSettlementFill} keeps those legs' priced
    ///      amounts here instead of routing them (review 2026-10-05 S1).
    uint256 sameOut;
    /// @dev The order's distinct leg tokens; `tokens[0]` = `legsIn[0]`'s token.
    address[] tokens;
    /// @dev Each token's balance, taken in `executeFill` BEFORE Settlement moved
    ///      anything. Everything `onSettlementFill` spends is measured against these, so the
    ///      callback can only ever reach this fill's own proceeds. `0` (unread) for
    ///      an output-only token on the direct path, which never lands here.
    uint256[] before;
    /// @dev Bit `k` set = `tokens[k]` is paid to this contract by an input leg.
    uint256 inMask;
    /// @dev Bit `k` set = `tokens[k]` is owed by an output leg.
    uint256 outMask;
    /// @dev Index in `tokens` of the ANCHOR OUTPUT token — the one `minOut` and
    ///      `maxPay` apply to: the first output token no input leg pays, else
    ///      `legsOut[0]`'s (see {_plan}).
    uint256 outAnchor;
    /// @dev The order carries {DutchAuction.deltaVerifyOutputs}: the route pays
    ///      the maker itself and this contract never approves Settlement.
    bool direct;
    bytes data;
}

contract AggregatorFillSolver {
    Settlement public immutable SETTLEMENT;
    /// @dev The allowance-less trampoline that makes every callback. Read once at
    ///      construction: it is an immutable of Settlement and never changes.
    address public immutable EXECUTOR;
    /// @notice The authority-less identity every route runs from — deployed by
    ///         this constructor, owned by this contract, and the only address this
    ///         contract ever sends a route's input to. See {RouteSandbox}.
    RouteSandbox public immutable SANDBOX;

    /// @dev 1 = idle; 2 = inside a fill this contract started, callback armed;
    ///      3 = inside that fill, callback consumed (the route ran). Held at 3
    ///      through the surplus split, so neither a reentrant `executeFill` (from a
    ///      route, or a hook token paid out by the split) nor {sweep} can run
    ///      mid-fill (audit 2026-09-30 AGG-1 / AGG-8). 4 / 5 are the same pair for
    ///      {executeItemFill} and its {onMatchRoute} step — distinct values, so
    ///      neither callback can be driven from the other entry's fill.
    uint256 private _active = 1;

    /// @notice Most distinct leg tokens one order may name — see {FillRoute}.
    uint256 public constant MAX_TOKENS = 8;

    /// @dev The callers `executeFill` admits. IMMUTABLES rather than a mapping: a
    ///      mapping membership test is a cold SLOAD (2,100 gas) on every fill, an
    ///      immutable compare is bytecode. The price is a hard cap of {MAX_SET}
    ///      entries — one or two bots drive a gated instance. Unused slots repeat
    ///      entry 0 so the membership test needs no count. Fixed at construction,
    ///      no setter: the set is part of this instance's identity; supporting a new
    ///      operator means deploying another instance, which keeps the contract
    ///      ownerless. (There is no router set any more: routes run in
    ///      {RouteSandbox}, which may call any target.)
    uint256 public constant MAX_SET = 4;
    address private immutable OPERATOR0;
    address private immutable OPERATOR1;
    address private immutable OPERATOR2;
    address private immutable OPERATOR3;

    /// @notice Whether `executeFill` is restricted to {isOperator}. ALWAYS `true`
    ///         since 2026-10 (the constructor refuses an empty set, {NoOperators});
    ///         kept as a getter so off-chain wiring checks read the same ABI.
    bool public constant GATED = true;

    /// @notice Whether `who` may call `executeFill`, `executeItemFill` and {sweep}.
    function isOperator(address who) public view returns (bool) {
        return who == OPERATOR0 || who == OPERATOR1 || who == OPERATOR2 || who == OPERATOR3;
    }

    /// @notice The surplus split — see {SurplusPolicy}. Immutable for the same
    ///         reason the operator set is: the contract stays ownerless, so there is
    ///         nobody a mutable policy could safely answer to.
    uint32 public immutable MAKER_SURPLUS_PPM;
    uint32 public immutable PROTOCOL_SURPLUS_PPM;
    address public immutable PROTOCOL_RECIPIENT;

    /// @dev Whether {_seedIn} may withhold the input floor wei from a route: only
    ///      when NO immutable policy share depends on the spread (maker and protocol
    ///      both 0), so the wei it costs the spread is the filler's alone. One
    ///      immutable instead of two compares on the seeding branch.
    bool private immutable SEED_INPUT;

    /// @notice One fill's surplus split, per token. `toFiller` is what reached
    ///         `RoutePlan.profitRecipient` — one wei short of the filler's share on
    ///         the fill that self-seeds the token's balance floor (or the whole
    ///         share, kept here, in retain mode).
    event SurplusSplit(
        address indexed token,
        address indexed maker,
        uint256 toMaker,
        uint256 toProtocol,
        uint256 toOriginator,
        uint256 toFiller
    );

    /// @notice An operator took retained value out — see {sweep}.
    event Swept(address indexed token, address indexed to, uint256 amount);

    error OnlyExecutor();
    /// @dev `makerPpm + protocolPpm + originatorPpm` exceeded {PPM}, or a
    ///      non-zero share named `address(0)` as its recipient.
    error BadSurplusSplit();
    error NotArmed();
    error InsufficientOutput(uint256 got, uint256 wanted);
    error CallbackDidNotRun();
    error PatchOutOfBounds(uint256 offset, uint256 length);
    /// @dev The caller is not in {isOperator}.
    error NotOperator(address caller);
    /// @dev An input token's balance ended BELOW its pre-fill snapshot, i.e. the
    ///      route spent more than this fill delivered. Structurally unreachable
    ///      since {RouteSandbox} (this contract pushes exactly the delta and grants
    ///      nobody an allowance a route could pull with); kept as a one-`balanceOf`
    ///      measurement so the bound never rests on that argument alone.
    error RouteOverspent();
    /// @dev An operator set may not contain `address(0)` — it could never call,
    ///      so it would only waste a slot.
    error BadOperator();
    /// @dev The operator set is larger than {MAX_SET}.
    error BadSetSize();
    /// @dev The constructor was given an EMPTY operator set. Every instance is
    ///      gated since 2026-10: a stranger who can drive {RouteSandbox} can plant a
    ///      standing approval that reaches a later honest fill's spread (see the
    ///      trust-model note). BREAKING — replaces the open mode and its
    ///      `DirectNeedsOperators` / `PolicyNeedsOperators` / `RetainNeedsOperators`.
    error NoOperators();
    /// @dev `executeFill` or {sweep} entered while a fill is in flight.
    error Reentrancy();
    /// @dev The order names more than {MAX_TOKENS} distinct leg tokens.
    error TooManyTokens();
    /// @dev {executeItemFill}'s `lateItems` names an item index the order does not have.
    error BadItemSchedule();
    /// @dev A delta-verify order on {executeItemFill}: the netted path cannot verify a
    ///      recipient delta (the core's `DeltaVerifyNotBatchable`), so refuse before
    ///      anything moves. Fill it through {executeFill}.
    error DirectNotMatchable();
    /// @dev `legsIn[0]` / `legsOut[0]` must exist before their tokens can be read —
    ///      {PackedArraysMem} is an unchecked reader, and a blob declaring zero
    ///      legs with trailing bytes would otherwise name an arbitrary token.
    error NoLegs();

    /// @param operators who may call `executeFill`: 1..{MAX_SET} non-zero addresses.
    ///        EMPTY REVERTS ({NoOperators}) — see the trust-model note.
    /// @param policy    the immutable surplus split — see {SurplusPolicy}
    /// @dev   BREAKING (2026-10): the router set, the `standing` flag and the
    ///        prime list are gone. Routes run in the {RouteSandbox} this
    ///        constructor deploys, which may call any target. BREAKING (2026-10
    ///        quick audit): an empty operator set no longer means "permissionless";
    ///        it reverts.
    constructor(address settlement, address[] memory operators, SurplusPolicy memory policy) {
        if (operators.length == 0) revert NoOperators();
        if (uint256(policy.makerPpm) + policy.protocolPpm > PPM) revert BadSurplusSplit();
        if (policy.protocolPpm != 0 && policy.protocolRecipient == address(0)) revert BadSurplusSplit();
        MAKER_SURPLUS_PPM = policy.makerPpm;
        PROTOCOL_SURPLUS_PPM = policy.protocolPpm;
        PROTOCOL_RECIPIENT = policy.protocolRecipient;
        SEED_INPUT = policy.makerPpm == 0 && policy.protocolPpm == 0;
        SETTLEMENT = Settlement(payable(settlement));
        address executor = address(Settlement(payable(settlement)).EXECUTOR());
        EXECUTOR = executor;
        SANDBOX = new RouteSandbox(settlement, address(Settlement(payable(settlement)).PERMIT3()), executor);
        if (operators.length > MAX_SET) revert BadSetSize();
        for (uint256 i; i < operators.length; i++) {
            if (operators[i] == address(0)) revert BadOperator();
        }
        (OPERATOR0, OPERATOR1, OPERATOR2, OPERATOR3) = _four(operators);
    }

    /// @dev Spread a set of 1..{MAX_SET} entries over four slots, repeating entry
    ///      0 into the unused ones (the constructor has refused an empty set).
    function _four(address[] memory set) private pure returns (address a, address b, address c, address d) {
        uint256 n = set.length;
        a = set[0];
        b = n > 1 ? set[1] : a;
        c = n > 2 ? set[2] : a;
        d = n > 3 ? set[3] : a;
    }

    /// @notice Fill `order` by routing the maker's input through `plan.router`.
    /// @param  plan the aggregator route — see {RoutePlan}. Bundled as a struct
    ///         rather than three parameters because the flat form pushes this
    ///         function past the stack limit under the legacy profile this
    ///         package compiles with.
    /// @param  takerData forwarded to the order's validators, invariants and
    ///         price module — carry the cosigned quote here for a
    ///         `ClockFlooredQuoteModule` order. ⚠ The quote must be bound to THIS
    ///         AggregatorFillSolver instance (its `filler` is the address Settlement
    ///         sees — this contract, not the EOA calling it), so it is usable by
    ///         every operator of the instance (audit 2026-09-30 CORE-FILLER-1.v3;
    ///         every instance is operator-gated since 2026-10).
    /// @dev    The spread is split AFTER the fill returns, because the surplus is
    ///         only knowable once Settlement has taken its share: the maker's and
    ///         the protocol's {SurplusPolicy} shares first, the originator's out
    ///         of what is left, and the remainder to `plan.profitRecipient`.
    ///         Whoever executes takes the risk and keeps that remainder — which is
    ///         what lets this contract stay ownerless and hold nothing between
    ///         fills. "Whoever" is one of the constructor's operators; everyone else
    ///         reverts {NotOperator} before any token moves.
    function executeFill(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmount,
        RoutePlan calldata plan,
        bytes calldata takerData
    ) external returns (uint256[] memory fillAmountsOut) {
        if (!isOperator(msg.sender)) revert NotOperator(msg.sender);
        if (_active != 1) revert Reentrancy();
        // Built BEFORE the fill, because its snapshots are balances that only mean
        // anything pre-fill — and reused afterwards for the sweep, so the callback
        // and the sweep can never disagree about what this fill created.
        FillRoute memory route = _plan(order, plan);
        _active = 2;
        fillAmountsOut = SETTLEMENT.fillWithCallback(
            order, sig, fillAmount, address(this), _callback(route), _mode(route), takerData, plan.minBumpBps
        );
        // A callback that never ran means the swap never happened, and any
        // delivery that nonetheless succeeded came out of this contract's own
        // balance. Settlement cannot report that, so we check the state only
        // `onSettlementFill` could have advanced.
        if (_active != 3) {
            _active = 1;
            revert CallbackDidNotRun();
        }

        // Settlement has taken its share; whatever allowance is left over must not
        // outlive the fill. (Not on the direct path: nothing was approved, and
        // nothing arrived here.)
        //
        // ⚠ THIS IS NOT A HEDGE AGAINST A BUGGY SETTLER, and "Settlement is
        // audited" is not an argument for dropping it. The drain uses Settlement
        // behaving exactly as specified: `_deliverOutputs` pays an order's output
        // legs BY PULLING THEM FROM THE FILLER, and the filler here is this
        // contract, for an order the attacker signed as their own maker. An
        // approval left on a token traded earlier would be directly spendable by a
        // later self-signed order naming that token in an output leg, against the
        // balance floor and the retained spread. PoC'd in
        // {AggregatorStaleApprovalTest} — it drains, and with this loop it cannot.
        uint256 n = route.tokens.length;
        if (!route.direct) {
            for (uint256 k; k < n; ++k) {
                if (route.outMask & (1 << k) != 0) {
                    SafeTransferLib.forceApprove(route.tokens[k], address(SETTLEMENT), 0);
                }
            }
        }

        // Split EVERY token's increase by the same policy. The output surplus is
        // the spread; the input residue — what the route did not consume — is the
        // SAME spread in the other denomination (F28, 2026-09-12); a non-anchor
        // input leg's token is split the same way rather than stranded (audit
        // 2026-09-30 AGG-2).
        //
        // ⚠ THE DELTA, NOT THE BALANCE, and this is a security boundary rather
        // than tidiness. `order` and the route are the caller's (and the route may
        // be a third-party API's), so a whole-balance sweep would be a
        // signature-free "send me your balance of any token I name" primitive —
        // the same one {BaseFlashSolver._requireCallbackRan} was written to close.
        // Measuring against the pre-fill snapshot means a fill can only ever pay
        // out what it produced; value held between fills leaves only by {sweep}.
        // Output tokens first, then inputs (reverse order).
        address to = plan.profitRecipient == address(0) ? msg.sender : plan.profitRecipient;
        for (uint256 k = n; k != 0;) {
            unchecked {
                --k;
            }
            // On the direct path an output-only token never lands here.
            if (route.direct && route.inMask & (1 << k) == 0) continue;
            _splitSurplus(route.tokens[k], route.before[k], order.maker, plan, to);
        }
        _active = 1;
    }

    /// @notice Fill an ITEM-BEARING `order` by routing its input through
    ///         `plan.router` — the zero-inventory counterpart of {executeFill} for the
    ///         orders the core's item-free `PostInputs` mode refuses (audit 2026-09-30
    ///         AGG-6).
    ///
    ///  The fill is a one-order `matchSettle` plan this function writes itself —
    ///  the caller chooses only WHERE each item runs, never what the plan does:
    ///
    ///    1. ITEM k for every item NOT flagged in `lateItems`, in index order — the
    ///       ones that PRODUCE the input (a TAKE: withdraw, borrow). Their proceeds
    ///       are credited to the order's input legs by the core;
    ///    2. PULL every input leg — the core draws only the shortfall the items left;
    ///    3. PRESEND every input token — the pool's excess over what it still owes
    ///       comes HERE (this contract is `matchSettle`'s caller);
    ///    4. CALL {onMatchRoute} — the route, bounded exactly as {onSettlementFill} bounds it,
    ///       then every output token's proceeds of this fill are PUSHED to
    ///       Settlement (the anchor output token's capped at `maxPay`, floored at
    ///       `minOut` — per token, see {RoutePlan});
    ///    5. DELIVER the outputs from the pool;
    ///    6. ITEM k for every item flagged in `lateItems` — the ones that CONSUME the
    ///       delivery (a wallet-funded MAKE: deposit, repay).
    ///
    ///  Settlement then sweeps the pool's surplus — the spread — back HERE (the
    ///  plan's `profitRecipient`), and it is split by the same {SurplusPolicy} and
    ///  originator share as {executeFill}, on the same pre-fill deltas.
    ///
    ///  Nothing about the maker's protection moves to this contract: the core runs
    ///  every gate at open, enforces the maker's {ItemPolicy} against the order the
    ///  steps run in (an ORDERED / ATOMIC / CANONICAL order whose policy the chosen
    ///  `lateItems` violates reverts `ItemPolicyViolated`), reconciles every input
    ///  leg, checks completeness and the invariants at the end, and floors every
    ///  touched token at its pre-plan balance. The plan's shape limits are the
    ///  core's: no SETTLE / TAKE_FOR / PUSH-funded MAKE item, no delta-verify order,
    ///  no repeated input token.
    ///
    ///  Trust and gating are {executeFill}'s, unchanged: the sandboxed route, the
    ///  delta-only amounts, the arming flag and the operator gate all apply as
    ///  written there, and no allowance survives the fill — this path never
    ///  approves Settlement at all (the proceeds are pushed).
    ///
    ///  A TAKE ITEM THAT PRODUCES MORE THAN ITS LEG OWES is refunded to the maker on
    ///  this path too, since core B-1 (2026-10-06): {Batch._creditItemProceeds} adds
    ///  the part of a credit that crosses `owed` to the pool's `outstanding`, so
    ///  PRESEND hands this contract exactly `owed` and the Phase-3 refund is funded.
    ///  (Before B-1 the excess reached the route and the refund found an empty pool —
    ///  `TransferFailed`; review 2026-10-05.) Pinned in
    ///  `test/AggregatorAmountMismatch.t.sol`.
    /// @param lateItems bit `k` set = item `k` runs AFTER delivery (step 6), clear =
    ///        before the input is pulled (step 1). Bits past the item count revert
    ///        {BadItemSchedule}. ⚠ Never flag a TAKE that produces an INPUT-leg token
    ///        late: the PULL has already drawn the whole leg from the wallet, the late
    ///        TAKE credits it again and the core refunds the duplicate — tokens
    ///        round-trip, but the maker's Permit3 allowance is spent twice for one
    ///        fill (the asymmetry `Batch._stepPull` documents). A late TAKE whose
    ///        proceeds are not an input-leg token (borrow after the deposit) is fine:
    ///        the core refunds them to the maker.
    /// @return fillAmountsOut the delivered amount per output leg (`matchSettle`'s
    ///         `outs[0]`).
    function executeItemFill(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmount,
        RoutePlan calldata plan,
        bytes calldata takerData,
        uint256 lateItems
    ) external returns (uint256[] memory fillAmountsOut) {
        if (!isOperator(msg.sender)) revert NotOperator(msg.sender);
        if (_active != 1) revert Reentrancy();
        FillRoute memory route = _plan(order, plan);
        if (route.direct) revert DirectNotMatchable();
        MatchPlan memory mp = _matchPlan(order, sig, fillAmount, takerData, route, lateItems);
        _active = 4;
        (uint256[][] memory outs,,) = SETTLEMENT.matchSettle(mp);
        // Same reasoning as {executeFill}: a plan whose CALL never reached
        // {onMatchRoute} delivered out of something other than this fill's route.
        if (_active != 5) {
            _active = 1;
            revert CallbackDidNotRun();
        }
        fillAmountsOut = outs[0];

        // Every token's increase over the pre-fill snapshot is this fill's spread —
        // the pool's sweep landed it here — split exactly as {executeFill} splits.
        _splitAll(route, order.maker, plan);
        _active = 1;
    }

    /// @dev {executeItemFill}'s split pass, in its own frame (legacy-profile stack):
    ///      every route token, output tokens first, against its pre-fill snapshot.
    function _splitAll(FillRoute memory route, address maker, RoutePlan calldata plan) private {
        address to = plan.profitRecipient == address(0) ? msg.sender : plan.profitRecipient;
        for (uint256 k = route.tokens.length; k != 0;) {
            unchecked {
                --k;
            }
            _splitSurplus(route.tokens[k], route.before[k], maker, plan, to);
        }
    }

    /// @dev The one-order plan {executeItemFill} runs — see the step list there.
    ///      Token indices are Settlement's universe indices: `matchSettle` derives
    ///      its universe as the order's input tokens then its output tokens, first
    ///      occurrence kept — the SAME rule {_plan} builds `route.tokens` by, so a
    ///      `PRESEND` index here names the same token there.
    function _matchPlan(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmount,
        bytes calldata takerData,
        FillRoute memory route,
        uint256 lateItems
    ) private view returns (MatchPlan memory p) {
        uint256 nItems = PackedArrays.countUnchecked(order.items);
        if (lateItems >> nItems != 0) revert BadItemSchedule();
        p.schedule = _schedule(nItems, PackedArrays.countUnchecked(order.legsIn), route, lateItems);
        p.orders = new Order[](1);
        p.orders[0] = order;
        p.sigs = new bytes[](1);
        p.sigs[0] = sig;
        p.fillAmounts = new uint256[](1);
        p.fillAmounts[0] = fillAmount;
        p.takerDatas = new bytes[](1);
        p.takerDatas[0] = takerData;
        p.callTargets = new address[](1);
        p.callTargets[0] = address(this);
        p.callDatas = new bytes[](1);
        p.callDatas[0] = abi.encodeCall(this.onMatchRoute, (route));
        // The sweep lands HERE so the spread is split by policy, never paid around it.
        p.profitRecipient = address(this);
    }

    /// @dev The step list of {_matchPlan}, in its own frame (legacy-profile stack).
    function _schedule(uint256 nItems, uint256 nIn, FillRoute memory route, uint256 lateItems)
        private
        pure
        returns (uint256[] memory steps)
    {
        uint256 nTok = route.tokens.length;
        steps = new uint256[](nItems + nIn + nTok + 2);
        uint256 s;
        for (uint256 k; k < nItems; ++k) {
            if (lateItems & (1 << k) == 0) steps[s++] = MatchStep.pack(MatchStep.ITEM, 0, k);
        }
        for (uint256 j; j < nIn; ++j) {
            steps[s++] = MatchStep.pack(MatchStep.PULL, 0, j);
        }
        for (uint256 t; t < nTok; ++t) {
            if (route.inMask & (1 << t) != 0) steps[s++] = MatchStep.pack(MatchStep.PRESEND, t, 0);
        }
        steps[s++] = MatchStep.pack(MatchStep.CALL, 0, 0);
        steps[s++] = MatchStep.pack(MatchStep.DELIVER, 0, 0);
        for (uint256 k; k < nItems; ++k) {
            if (lateItems & (1 << k) != 0) steps[s++] = MatchStep.pack(MatchStep.ITEM, 0, k);
        }
        /// @solidity memory-safe-assembly
        assembly {
            mstore(steps, s) // only the PRESEND slots were over-allocated
        }
    }

    /// @notice Take value this contract holds between fills — the retained spread,
    ///         the balance floor, and a stranded token an operator recovered from the
    ///         sandbox — out. Operators only, never mid-fill. Retain mode exists
    ///         because this does (audit 2026-09-30 AGG-1): every amount a fill moves
    ///         is a delta of that fill, so nothing else could move a retained balance.
    /// @dev    Safe for the same reason the operator tier already writes every
    ///         route: nothing held here between fills belongs to anyone else — makers
    ///         are paid and every share is split inside the fill.
    function sweep(address token, address to, uint256 amount) external {
        if (!isOperator(msg.sender)) revert NotOperator(msg.sender);
        if (_active != 1) revert Reentrancy();
        SafeTransferLib.safeTransfer(token, to, amount);
        emit Swept(token, to, amount);
    }

    /// @dev Split this fill's INCREASE in `token` — the spread, in whichever
    ///      denomination it landed — per the {SurplusPolicy} and the plan's
    ///      originator share. Silent when nothing was left over, which is the
    ///      normal case for a route quoted at the maker's price. Shares floor;
    ///      the filler takes the rounding dust along with its remainder, so
    ///      nothing strands here — except, ONCE per token, the self-seeded 1-wei
    ///      balance floor (below), which is the filler's own.
    ///
    ///      `plan.originatorPpm` was bounded in {_plan}, BEFORE the fill, so a
    ///      mis-set share fails the round rather than reverting after the maker
    ///      has already been paid.
    function _splitSurplus(address token, uint256 before, address maker, RoutePlan calldata plan, address filler)
        private
    {
        uint256 bal = SafeTransferLib.balanceOf(token, address(this));
        if (bal <= before) return;
        uint256 surplus = bal - before;

        uint256 toMaker = (surplus * MAKER_SURPLUS_PPM) / PPM;
        uint256 toProtocol = (surplus * PROTOCOL_SURPLUS_PPM) / PPM;
        uint256 toOriginator = (surplus * plan.originatorPpm) / PPM;
        // The sum of the three ppm values is ≤ PPM (checked in `_plan`), so the
        // three floors sum to ≤ surplus and this cannot underflow.
        uint256 toFiller = surplus - toMaker - toProtocol - toOriginator;

        if (toMaker != 0) SafeTransferLib.safeTransfer(token, maker, toMaker);
        if (toProtocol != 0) SafeTransferLib.safeTransfer(token, PROTOCOL_RECIPIENT, toProtocol);
        if (toOriginator != 0) SafeTransferLib.safeTransfer(token, plan.originator, toOriginator);
        // RETAIN MODE: a `profitRecipient` of this contract keeps the filler's
        // share here instead of paying it out every fill. Safe because every
        // amount above is a delta — a retained balance is never re-split, never
        // approved and never swept by a later caller — and it is what keeps the
        // contract's balance slots NON-ZERO between fills, so the next fill's
        // inbound transfers rewrite a live slot instead of paying to create one
        // (measured: ~44k execution gas per fill on a two-token route). The
        // operators take it out with {sweep}; see the README on the balance floor.
        if (filler != address(this)) {
            // SELF-SEEDING BALANCE FLOOR (2026-10): a token this contract held
            // NOTHING of before the fill keeps ONE WEI of the FILLER'S share, so
            // every later fill of it finds a live balance slot (README, "Dust is
            // worth having"). Out of the filler's remainder only — the maker's,
            // the protocol's and the originator's shares above are computed on the
            // whole surplus and untouched. The floor then sustains itself: every
            // later amount is a delta against a snapshot that includes it.
            // `before` is already on the stack, so a non-seeding fill pays one test.
            if (before == 0 && toFiller != 0) {
                unchecked {
                    --toFiller;
                }
            }
            if (toFiller != 0) SafeTransferLib.safeTransfer(token, filler, toFiller);
        }
        emit SurplusSplit(token, maker, toMaker, toProtocol, toOriginator, toFiller);
    }

    /// @dev Resolve the route against the order, in its OWN frame: the two decoded
    ///      token addresses and the two snapshots push {executeFill} past the stack
    ///      limit under the legacy (non-via-IR) profile this package compiles with
    ///      — the same split the settlement makes in its own fill helpers.
    ///
    ///      ⚠ THE LEG COUNTS ARE CHECKED HERE and nowhere else on this path.
    ///      {PackedArraysMem} reads a leg without consulting the blob's count byte,
    ///      and {PackedArrays.validateFixed} tolerates trailing bytes — so a
    ///      `legsOut` of `0x00 ‖ <104 bytes>` settles as ZERO output legs (the
    ///      caller owes the maker nothing) while still naming a token here. Reject
    ///      the empty blob and that shape cannot be built.
    function _plan(Order calldata order, RoutePlan calldata plan) private view returns (FillRoute memory r) {
        bytes memory legsIn = order.legsIn;
        bytes memory legsOut = order.legsOut;
        uint256 nIn = PackedArraysMem.validateLegsIn(legsIn);
        uint256 nOut = PackedArraysMem.validateLegsOut(legsOut);
        if (nIn == 0 || nOut == 0) revert NoLegs();
        // The originator's share is the caller's to give, but only out of its own
        // remainder: the maker's and the protocol's shares are fixed, so the three
        // together may not exceed the whole. Checked here so a bad plan fails
        // before any token moves.
        if (uint256(plan.originatorPpm) + MAKER_SURPLUS_PPM + PROTOCOL_SURPLUS_PPM > PPM) revert BadSurplusSplit();
        if (plan.originatorPpm != 0 && plan.originator == address(0)) revert BadSurplusSplit();
        // Retain mode (`profitRecipient == this`) needs a way out — {sweep} — and a
        // DIRECT (delta-verify) order needs a trusted route author (re-audit
        // 2026-09-29: the core fills it only for its named `exclusiveFiller`, this
        // contract, because a balance delta cannot tell the maker's delivery from
        // another inflow, so a stranger's route could settle the maker's OTHER intent
        // inside the callback). Both used to be refused here on an open instance;
        // every instance is gated now, so both hold by construction.
        r.direct = DutchAuction.deltaVerifyOutputs(order);

        // The distinct token set, inputs first (so tokens[0] is the anchor).
        address[] memory toks = new address[](MAX_TOKENS);
        uint256 n;
        for (uint256 i; i < nIn; ++i) {
            uint256 k;
            (k, n) = _slot(toks, n, PackedArraysMem.legInToken(legsIn, i));
            r.inMask |= 1 << k;
        }
        // THE ANCHOR OUTPUT — the token `minOut` and `maxPay` measure — is the first
        // output token NO INPUT LEG PAYS, not blindly `legsOut[0]`'s (review
        // 2026-10-05): with an in-kind fee leg listed first (`legsOut = [tokenIn →
        // originator, tokenOut → maker]`) the old rule floored and capped the INPUT
        // residue and left the real proceeds unbounded. Only when every output
        // token is also an input token does `legsOut[0]`'s stand, and {onSettlementFill} then
        // nets the input's inflow out of the measured delta before the floor.
        bool anchored;
        for (uint256 j; j < nOut; ++j) {
            uint256 k;
            (k, n) = _slot(toks, n, PackedArraysMem.legOutToken(legsOut, j));
            uint256 bit = 1 << k;
            r.outMask |= bit;
            if (k == 0) r.sameOut |= 1 << j; // an output leg in the anchor input token
            if (!anchored) {
                anchored = r.inMask & bit == 0;
                if (j == 0 || anchored) r.outAnchor = k;
            }
        }
        /// @solidity memory-safe-assembly
        assembly {
            mstore(toks, n) // shrink to the n slots actually used
        }
        r.tokens = toks;
        r.before = new uint256[](n);
        for (uint256 k; k < n; ++k) {
            // Nothing lands here for an output-only token on the direct path, so
            // nothing to measure against.
            if (r.direct && r.inMask & (1 << k) == 0) continue;
            r.before[k] = SafeTransferLib.balanceOf(toks[k], address(this));
        }
        r.router = plan.router;
        r.minOut = plan.minOut;
        r.maxPay = plan.maxPay;
        r.amountInOffset = plan.amountInOffset;
        r.amountOutOffset = plan.amountOutOffset;
        r.data = plan.data;
    }

    /// @dev Index of `t` in the first `n` entries of `toks`, appending it if new.
    function _slot(address[] memory toks, uint256 n, address t) private pure returns (uint256 k, uint256 newN) {
        for (k = 0; k < n; ++k) {
            if (toks[k] == t) return (k, n);
        }
        if (n == MAX_TOKENS) revert TooManyTokens();
        toks[n] = t;
        return (n, n + 1);
    }

    /// @dev Whether this fill needs the TYPED callback: only when the plan uses a
    ///      priced amount — an output leg in the anchor input token to keep back
    ///      (`sameOut`), or an output word to patch (`amountOutOffset`). Every other
    ///      fill stays on the untyped {onFill}, because the typed payload is not free:
    ///      the core prices every leg a second time and re-encodes the route into a
    ///      larger blob — measured +5.9k execution gas on the direct two-token
    ///      benchmark (`test_gas_direct_seeded_liveAmountOut` vs `test_gas_direct_seeded`
    ///      in `test/AggregatorFillGas.t.sol`).
    function _typed(FillRoute memory route) private pure returns (bool) {
        return route.sameOut != 0 || route.amountOutOffset != NO_PATCH;
    }

    /// @dev The callback mode: `PostInputsDirect`, plus the TYPED bit when {_typed}.
    function _mode(FillRoute memory route) private pure returns (CallbackMode) {
        return _typed(route) ? CallbackMode.PostInputsTypedDirect : CallbackMode.PostInputsDirect;
    }

    /// @dev The callback payload. Untyped: the {onFill} call itself. Typed: the route
    ///      ABI-encoded as a lone tuple — the core wraps it as the `userData` of
    ///      {onSettlementFill} and {_routeOf} reads it back in place. Its own frame for
    ///      the same stack reason.
    function _callback(FillRoute memory route) private view returns (bytes memory) {
        return _typed(route) ? abi.encode(route) : abi.encodeCall(this.onFill, (route));
    }

    /// @dev The {FillRoute} inside the typed callback's `userData`, as a CALLDATA
    ///      pointer — no copy, no decode. `abi.encode(route)` of a dynamic struct is
    ///      one head word (the tuple's offset, `0x20`) followed by the tuple, so the
    ///      struct starts at `u.offset + head`. Sound only because the bytes are this
    ///      contract's own {_callback} output, passed through the core untouched (the
    ///      EXECUTOR check and the arming flag have already run); the calldata
    ///      accessors still bounds-check every member read against `calldatasize`.
    function _routeOf(bytes calldata u) private pure returns (FillRoute calldata r) {
        /// @solidity memory-safe-assembly
        assembly {
            r := add(u.offset, calldataload(u.offset))
        }
    }

    /// @dev The route's calldata with the input amount rewritten to what the fill
    ///      actually routes and, if asked, the output amount to the live price of
    ///      `legsOut[0]` — see the ⚠ note on resolved amounts.
    ///
    ///      Rewriting a caller-supplied blob is only safe because BOTH halves are
    ///      the solver's own: it supplies the calldata and it owns the funds at
    ///      risk, so a wrong offset costs the solver its own gas and nothing else.
    ///      The maker is untouched either way — Settlement enforces the signed
    ///      band whatever this call does. The patched blob runs in {SANDBOX}, which
    ///      holds only the delta, so an offset aimed at the wrong word cannot reach
    ///      anything else either. The bounds check is still mandatory:
    ///      without it a short blob would let the write run past the copy.
    function _patched(bytes calldata data, uint256 inOffset, uint256 amountIn, uint256 outOffset, uint256 amountOut)
        private
        pure
        returns (bytes memory out)
    {
        out = data;
        _patch(out, inOffset, amountIn);
        _patch(out, outOffset, amountOut);
    }

    /// @dev Overwrite the 32-byte word at `offset` of `out` with `v`; {NO_PATCH} = leave it.
    function _patch(bytes memory out, uint256 offset, uint256 v) private pure {
        if (offset == NO_PATCH) return;
        if (offset + 32 > out.length) revert PatchOutOfBounds(offset, out.length);
        /// @solidity memory-safe-assembly
        assembly {
            mstore(add(add(out, 0x20), offset), v)
        }
    }

    /// @notice The fill callback, untyped — every fill whose plan uses no priced
    ///         amount (see {_typed}). Not public in effect: only the EXECUTOR may
    ///         call it, and only while `executeFill` has armed it.
    /// @dev    The EXECUTOR check and the arming flag bound WHEN this runs, not what
    ///         the route does: an operator satisfies both by starting a fill of any
    ///         order, with route calldata that may come from a third-party API.
    ///         What bounds the opaque `(router, data)` is WHERE it runs — in
    ///         {RouteSandbox}, which holds only this fill's pushed input and no
    ///         authority over this contract — not a list of trusted venues; and the
    ///         operator gate is what keeps strangers from ever writing one.
    function onFill(FillRoute calldata r) external {
        if (msg.sender != EXECUTOR) revert OnlyExecutor();
        if (_active != 2) revert NotArmed();
        _active = 3;
        _onFill(r, 0, NO_PATCH, 0);
    }

    /// @notice The fill callback, TYPED — {ISettlementCallback}'s shape, with the
    ///         {FillRoute} as `userData`; `executeFill` starts the fill as
    ///         `PostInputsTypedDirect` when the plan needs a priced amount ({_typed}).
    ///         Bound exactly as {onFill}: the EXECUTOR only, only while armed, and
    ///         either callback consumes the one arming.
    /// @dev    WHY TYPED (2026-10, review 2026-10-05 S1 / §4). `pricedOut` is what the
    ///         core is about to demand per output leg, resolved at inclusion. Two uses,
    ///         both of which only ever REDUCE what the route is handed or promised, so
    ///         neither weakens the delta discipline:
    ///           • the output legs owed in `tokens[0]` (an in-kind fee) are kept HERE
    ///             rather than routed — the same `input − leg` the netted path's
    ///             PRESEND hands over — so a patched exact-input route no longer
    ///             swaps the fee too and fails its pull;
    ///           • with `amountOutOffset` set, the route's output word is `pricedOut[0]`,
    ///             the live tick — a direct SELL then pays the maker exactly what the
    ///             core verifies and the decay since the quote stays here as residue.
    ///         `pricedIn` is not read: the routed amount stays a measured DELTA (FoT /
    ///         rebasing anchors), never a figure the core priced.
    function onSettlementFill(
        bytes32,
        uint256,
        uint256,
        uint256,
        uint256[] calldata,
        uint256[] calldata pricedOut,
        bytes calldata userData
    ) external {
        if (msg.sender != EXECUTOR) revert OnlyExecutor();
        if (_active != 2) revert NotArmed();
        _active = 3;
        FillRoute calldata r = _routeOf(userData);
        _onFill(r, _kept(r.sameOut, pricedOut), r.amountOutOffset, pricedOut[0]);
    }

    /// @dev The body of both {executeFill} callbacks — see {_route} for `kept`,
    ///      `outOffset` and `amountOut`.
    function _onFill(FillRoute calldata r, uint256 kept, uint256 outOffset, uint256 amountOut) private {
        // Read BEFORE the route: the pre-route inflow is part of it, see {_floor}.
        uint256 floor = _floor(r);
        _route(r, kept, outOffset, amountOut);

        // Direct delivery: the route paid the maker, the core verifies the delta,
        // and this contract has nothing to measure and nothing to approve.
        if (r.direct) return;

        // Settlement pulls every output leg next, through the direct-approval path.
        // Approve each output token at ITS OWN proceeds of this fill — never the
        // contract's balance — and, for the anchor output token, at most `maxPay`:
        //   • it CAPS the pull — a fill that would take more reverts here rather
        //     than in the solver's P&L;
        //   • the surplus is never approved, so the spread stays this contract's
        //     and no allowance survives the fill over it.
        // `maxPay == 0` means "no cap", and the cap it then takes is THIS FILL's
        // proceeds — the maker's signed band is still the hard bound, so the worst
        // case is the price the solver evaluated when it bid. A `maxPay` above the
        // proceeds is clamped for the same reason: an over-stated cap must not
        // reach into residue.
        _approveOutputs(r.tokens, r.before, r.outMask, r.outAnchor, floor, r.maxPay);
    }

    /// @dev Σ `pricedOut[j]` over the output legs flagged in `sameOut` — what the
    ///      core will pull back in `tokens[0]`, so it is not routed. Zero (one test)
    ///      on every plain order.
    function _kept(uint256 sameOut, uint256[] calldata pricedOut) private pure returns (uint256 kept) {
        for (uint256 j; sameOut != 0; ++j) {
            if (sameOut & 1 != 0) kept += pricedOut[j];
            sameOut >>= 1;
        }
    }

    /// @dev The floor the anchor output token's whole-fill delta must reach:
    ///      `minOut` plus what this fill paid INTO this contract in that token BEFORE
    ///      the route ran. That inflow is non-zero only when the anchor output is also
    ///      a (non-anchor) input token (every output token is; see {_plan}) — the
    ///      maker's own input leg on the pull path, the PRESEND on the netted path —
    ///      and without it the delta {_approveOutputs} measures would count that
    ///      inflow as route proceeds, so the maker's input could satisfy the solver's
    ///      `minOut` by itself (review 2026-10-05). Read at callback entry: inputs
    ///      have landed, nothing has been routed. `minOut` alone for `tokens[0]` even
    ///      when it is an output (a same-token order): {_route} pushes that inflow
    ///      INTO the route, so the post-route delta is already "what the route left
    ///      or produced". Folded into the floor rather than passed down, so the
    ///      common shape pays one mask test and no extra stack word.
    function _floor(FillRoute calldata r) private view returns (uint256 floor) {
        floor = r.minOut;
        uint256 k = r.outAnchor;
        if (k != 0 && r.inMask & (1 << k) != 0) {
            floor += SafeTransferLib.balanceOf(r.tokens[k], address(this)) - r.before[k];
        }
    }

    /// @notice The `CALL` step of an {executeItemFill} plan. Not public in effect:
    ///         only the EXECUTOR may call it, and only while {executeItemFill} has
    ///         armed it (a state {onSettlementFill} never accepts, and vice versa).
    /// @dev    The route runs under exactly {onSettlementFill}'s bounds — in the sandbox, fed
    ///         this fill's measured input delta, with the {RouteOverspent}
    ///         measurement after. The only difference is delivery: `matchSettle`
    ///         delivers from the POOL, so every output token's proceeds of this fill
    ///         are pushed to Settlement instead of approved, and the pool's surplus
    ///         comes back in the sweep.
    function onMatchRoute(FillRoute calldata r) external {
        if (msg.sender != EXECUTOR) revert OnlyExecutor();
        if (_active != 4) revert NotArmed();
        _active = 5;

        uint256 floor = _floor(r);
        // Nothing kept back, nothing patched on the output side: PRESEND already
        // netted the pool's outstanding obligations, and no priced amount reaches a
        // `CALL` step (`amountOutOffset` is ignored here, see {RoutePlan}).
        _route(r, 0, NO_PATCH, 0);
        _pushOutputs(r.tokens, r.before, r.outMask, r.outAnchor, floor, r.maxPay);
    }

    /// @dev Run the route in {SANDBOX}: PUSH this fill's anchor input there, have it
    ///      call the target, take everything back, and check the bound.
    ///
    ///      THE PUSHED AMOUNT IS A DELTA of `tokens[0]` against its pre-fill
    ///      snapshot — never a balance and never a caller-declared figure: what the
    ///      maker paid is Settlement's business and a fee-on-transfer `tokenIn`
    ///      would make any figure passed here wrong, while the raw balance would hand
    ///      the route whatever an earlier fill left parked here. Under-flowing is the
    ///      correct failure: it means the input never arrived. The same delta is
    ///      what the route's calldata is patched with.
    ///
    ///      ⚠ PUSH, NEVER APPROVE. The sandbox calls an arbitrary target, and the
    ///      target may be a token: a solver→sandbox allowance would let
    ///      `target = token, data = transferFrom(solver, attacker, …)` drain this
    ///      contract. A plain `transfer` creates no standing authority at all.
    ///
    ///      The per-fill router approval this replaces was also a BOUND (the route
    ///      could pull no more than the delta whatever its calldata said). The
    ///      sandbox keeps it structurally — it holds only what was pushed, and
    ///      nobody may pull from this contract — and {RouteOverspent} keeps it as a
    ///      measurement: no input token may end below its snapshot.
    ///
    ///      `kept` — the output legs owed in `tokens[0]` ({_kept}) — is subtracted from
    ///      that delta and never leaves this contract, saturating at zero: a
    ///      REDUCTION of the pushed amount is always safe (the route gets less of
    ///      this fill's own input), and a `kept` above the delta means the core's
    ///      pull of those legs fails anyway. `amountOut` is written at `outOffset`
    ///      ({NO_PATCH} = untouched).
    function _route(FillRoute calldata r, uint256 kept, uint256 outOffset, uint256 amountOut) private {
        address tokenIn = r.tokens[0];
        uint256 before0 = r.before[0];
        uint256 amountIn = SafeTransferLib.balanceOf(tokenIn, address(this)) - before0;
        unchecked {
            amountIn = amountIn > kept ? amountIn - kept : 0;
        }
        if (before0 == 0) amountIn = _seedIn(r, amountIn);
        if (amountIn != 0) SafeTransferLib.safeTransfer(tokenIn, address(SANDBOX), amountIn);
        SANDBOX.exec(
            tokenIn,
            r.router,
            _patched(r.data, r.amountInOffset, amountIn, outOffset, amountOut),
            _sweepOrder(r.tokens, r.outMask)
        );
        _checkInputs(r.tokens, r.before, r.inMask);
    }

    /// @dev SELF-SEEDING FLOOR, INPUT SIDE — reached only when this contract held no
    ///      `tokens[0]` before the fill. Route ONE WEI LESS than the fill delivered,
    ///      so it stays here and the next fill's inbound `tokenIn` rewrites a live
    ///      slot. {_splitSurplus} sees it as a 1-wei input residue on a zero
    ///      snapshot and keeps it (the filler's share). Every condition below is a
    ///      case where withholding could hurt someone other than the filler or
    ///      fail the fill, so seeding is skipped there and left to the residue:
    ///        • DIRECT order — the route pays the maker, so on an exact-input route
    ///          one wei less input is less for the MAKER; the exact-output direct
    ///          route already leaves the spread here as `tokenIn` residue;
    ///        • `amountInOffset == NO_PATCH` — the route pulls its QUOTED figure,
    ///          and a sandbox one wei short of it reverts the fill;
    ///        • a non-zero MAKER or PROTOCOL share ({SEED_INPUT} false) — one wei
    ///          less input is a smaller output spread, and those parties own a share
    ///          of it (sub-wei of value, but their take must never depend on this
    ///          contract's floor). A per-call ORIGINATOR share does not stop it: it
    ///          is the operator's carve-out of its own remainder, and shrinks by at
    ///          most `originatorPpm` of one input wei's worth, once per token;
    ///        • `amountIn < 2` — nothing left to route.
    ///      What remains is a PULL / netted fill whose route follows the patched
    ///      amount: the maker is paid exactly its priced amount out of the
    ///      proceeds, so the wei comes out of the filler's spread. It reverts only
    ///      where that spread is smaller than one wei of input is worth — below
    ///      `minOut` or below the core's pull — i.e. a route quoted at zero margin.
    function _seedIn(FillRoute calldata r, uint256 amountIn) private view returns (uint256) {
        // Cheapest tests first: an immutable, a stack word, then the calldata reads.
        if (!SEED_INPUT || amountIn < 2 || r.amountInOffset == NO_PATCH || r.direct) return amountIn;
        unchecked {
            return amountIn - 1;
        }
    }

    /// @dev The order the sandbox sweeps in: OUTPUT tokens first (they hold the
    ///      spread), then `tokens[0]` (the anchor input, unless it is also an output),
    ///      then the other inputs. Defence in depth for the planted-approval class
    ///      (see {RouteSandbox}): a `transfer` hook in a non-output token then runs
    ///      after the spread has left the sandbox. `tokens[0]` is the first
    ///      non-output entry in index order whenever it is not an output, so one
    ///      pass per class gives exactly that order.
    function _sweepOrder(address[] calldata toks, uint256 outMask) private pure returns (address[] memory s) {
        uint256 n = toks.length;
        s = new address[](n);
        uint256 j;
        for (uint256 k; k < n; ++k) {
            if (outMask & (1 << k) != 0) s[j++] = toks[k];
        }
        for (uint256 k; k < n; ++k) {
            if (outMask & (1 << k) == 0) s[j++] = toks[k];
        }
    }

    /// @dev {RouteOverspent}: every input token is back at or above its snapshot
    ///      once the sandbox has swept.
    function _checkInputs(address[] calldata toks, uint256[] calldata bef, uint256 inMask) private view {
        uint256 n = toks.length;
        for (uint256 k; k < n; ++k) {
            if (inMask & (1 << k) == 0) continue;
            if (SafeTransferLib.balanceOf(toks[k], address(this)) < bef[k]) revert RouteOverspent();
        }
    }

    /// @dev {_approveOutputs} for the netted path: the same per-token delta, floor
    ///      and cap, TRANSFERRED to Settlement's pool rather than approved.
    function _pushOutputs(
        address[] calldata toks,
        uint256[] calldata bef,
        uint256 outMask,
        uint256 outAnchor,
        uint256 minOut,
        uint256 maxPay
    ) private {
        uint256 n = toks.length;
        for (uint256 k; k < n; ++k) {
            if (outMask & (1 << k) == 0) continue;
            address t = toks[k];
            uint256 out = SafeTransferLib.balanceOf(t, address(this)) - bef[k];
            uint256 cap = out;
            if (k == outAnchor) {
                // `minOut` arrives as {_floor}: the route's floor plus any pre-route
                // inflow of this token, so the whole-fill delta is compared against it.
                if (out < minOut) revert InsufficientOutput(out, minOut);
                if (maxPay != 0 && maxPay < out) cap = maxPay;
            }
            if (cap != 0) SafeTransferLib.safeTransfer(t, address(SETTLEMENT), cap);
        }
    }


    /// @dev The output pass of {onSettlementFill}, over the route's calldata arrays resolved
    ///      ONCE (re-resolving `r.tokens[k]` through the struct on every access is
    ///      measurable on the hot path).
    function _approveOutputs(
        address[] calldata toks,
        uint256[] calldata bef,
        uint256 outMask,
        uint256 outAnchor,
        uint256 minOut,
        uint256 maxPay
    ) private {
        uint256 n = toks.length;
        for (uint256 k; k < n; ++k) {
            if (outMask & (1 << k) == 0) continue;
            address t = toks[k];
            uint256 out = SafeTransferLib.balanceOf(t, address(this)) - bef[k];
            uint256 cap = out;
            if (k == outAnchor) {
                // `minOut` arrives as {_floor}: the route's floor plus any pre-route
                // inflow of this token, so the whole-fill delta is compared against it.
                if (out < minOut) revert InsufficientOutput(out, minOut);
                if (maxPay != 0 && maxPay < out) cap = maxPay;
            }
            SafeTransferLib.forceApprove(t, address(SETTLEMENT), cap);
        }
    }
}
