// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {PackedArrays} from "@core/settlement/PackedArrays.sol";
import {Settlement, Order, CallbackMode, MatchStep} from "@core/settlement/Settlement.sol";
import {DutchAuction} from "@core/settlement/DutchAuction.sol";
import {Batch} from "@core/settlement/Batch.sol";
import {RouteSandbox, MULTI_ROUTE} from "./RouteSandbox.sol";
import {MatchRaceGuard} from "../base/MatchRaceGuard.sol";

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
///  pulled here) — except on a NATIVE order (below), where the WNATIVE does land
///  here; the route's own `amountInMaximum` is the solver's protection.
///  Set `RoutePlan.amountOutOffset` on such a route: the exact-output word is then
///  rewritten with the LIVE `legsOut[0]` price the core is about to verify, so a
///  SELL included after its auction has decayed pays the maker the tick at
///  inclusion — not the quote — and the difference stays here as input residue
///  (2026-10; before it, that decay reached the maker as price improvement).
///
///  NATIVE DELIVERY (2026-10-14, solver v3, task 30) — raw native coin, zero capital
///  ────────────────────────────────────────────────────────────────────────────────
///  A DIRECT order whose `legsOut[0].token` is this instance's {NATIVE_BALANCE} (the
///  `NativeBalance` view: `balanceOf(a) == a.balance`, packages/periphery) asks for raw
///  native coin. The core only READS that view around the callback, so no Settlement
///  change is needed. For such an order the route must end in {WNATIVE} and pay THIS
///  contract — quote an opaque route with `recipient = this solver`; a pool route's last
///  hop pays here by itself — and the TYPED callback then `withdraw`s exactly the core's
///  `pricedOut[0]` and sends it with a full-gas `call` to the leg's recipient (from the
///  order; `address(0)` = the maker). The spread over the priced amount stays here in
///  WNATIVE and is split by the {SurplusPolicy} like any output surplus; `minOut` and
///  `maxPay` keep their PULL meaning, measured in WNATIVE (see {_payNative}). Shape rules
///  ({NativeLegShape}): direct only; no other leg may name WNATIVE or NATIVE_BALANCE; a
///  NativeBalance leg other than leg 0 is not delivered (the core's delta check fails it).
///  Measured on the live Rootstock Settlement (`test/NativeDeliveryRootstock.fork.t.sol`,
///  deployed bytecode, solver floors seeded): +27.0k execution gas against the same
///  order taking WRBTC, ~2.8k of it refunded at the end of the transaction. An EMPTY
///  recipient account (no balance, nonce or code) adds the EVM's +25k new-account charge.
///  Off by default: both constructor addresses zero.
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
///       the immutable router allowlist) — every OPAQUE route; a POOL route
///       ({POOL_ROUTE}) is the one exception, and it names no target at all (see
///       "DIRECT POOL ROUTES" below for its own three rules). The EXECUTOR check and the arming flag
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
///       an unrelated fill left parked here. The ONE exception is deliberate and
///       capped: {RoutePlan.inventory} (2026-10-18, see INVENTORY below) — an explicit,
///       operator-supplied per-call ceiling on what a fill may draw from value held
///       before it, never a balance-derived figure.
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
///  instances any more). Retain mode is also the CHEAPER configuration: it skips the
///  per-fill payout `transfer` (−5.2k net on the direct pool fill, −6.2k pull; fork
///  bench, 2026-10-12) — recommended for a filler that sweeps in batches.
///
///  NO FLOOR FOR A POOL ROUTE'S INTERMEDIATE TOKENS (measured 2026-10-12, rejected).
///  An exact-input multi-hop route parks each intermediate here between hops; it
///  arrives and leaves in the same transaction, so its slot goes 0 → x → 0 (or
///  1 → x+1 → 1 with a floor) and the EIP-3529 refund returns the difference either
///  way: the Rootstock fork bench measures the unseeded and the seeded intermediate to
///  the gas (316,257 both, 2 hops). Keeping a wei back (`amount − 1` to the next hop)
///  only makes the slot END changed: +20.2k on the first fill, +3.1k on every later one.
///  A floor pays only for a slot that would otherwise END the transaction at zero —
///  the order's own tokens, which {_seedIn} / {_splitSurplus} seed.
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
///  and split on its own delta — see {FillRoute}); one route per fill (one call, or
///  a {MULTI_ROUTE} sequence), no native value. `legsIn[0]`'s token (the anchor) is
///  what a route is pushed and patched with. A FURTHER INPUT CURRENCY — an input token
///  no output leg is paid in — is ROUTED on {executeItemFill} with a {MULTI_ROUTE}
///  (pushed to the sandbox at its delta, {_pushExtras}) and REFUSED everywhere else
///  ({MultiInputUnrouted}; review 2026-10-18 S-3 — it used to stay here and be split
///  as filler residue, the maker's second token silently becoming spread). A
///  non-anchor input token that is also an output token nets in place against its
///  output legs, as before. Zero input legs (an NFT sale) and zero output legs are
///  admitted since 2026-10-18; both empty is {NoLegs}.
///
///  INVENTORY (2026-10-18, review S-1) — it can only improve a fill
///  ───────────────────────────────────────────────────────────────
///  {RoutePlan.inventory} lets ONE fill draw up to that much of the anchor output token
///  from this contract's own pre-fill balance, on top of the route's proceeds: a route
///  shortfall is covered, or the route is left out entirely (an EMPTY route, `router =
///  POOL_ROUTE`, `data = ""` — the maker's input then stays here as residue). PULL: the
///  Settlement approval is `proceeds + min(inventory, held)`; NETTED: that much is
///  pushed and the pool sweeps the unused part back; DIRECT: the leg-0 recipient's
///  measured shortfall against the core's live price is sent ({_topUp}), at most the
///  cap — so a DIRECT order naming this solver, the app's default, is servable from
///  inventory too; NATIVE: the unwrap may use WNATIVE inventory. `maxPay` still caps
///  the total on PULL, NETTED and NATIVE; on DIRECT `maxPay` is ignored like everywhere
///  else on that path, and the draw's only cap is `inventory` itself (review 2026-10-18
///  D-1, pinned by `test_P1_direct_topUpIgnoresMaxPay`). It reopens none of the three invariants above: no call target is
///  added, no allowance survives the fill, and the one non-delta amount is bounded by
///  an explicit per-call cap that only an OPERATOR can set (only operators start fills,
///  and the operators can {sweep} the same balance anyway — the cap bounds what one
///  mis-priced call may spend; it grants nothing). `0` = the delta-only behaviour.
///
///  RACES (2026-10-18, review S-5)
///  ──────────────────────────────
///  {executeFill}: pass the core's remainder sentinel `fillAmount = type(uint256).max`
///  with a PATCHED input (`amountInOffset` set) and a competitor's partial fill no
///  longer reverts this one `OverFill`: the core fills what is left, the route swaps
///  exactly that, and `minOut` is scaled pro rata to what was routed against the
///  quoted amount ({_minOut}) — a price floor, so the smaller remainder still clears
///  it; `minBumpBps` (the core's) stays the price protection. {executeItemFill}: the
///  {ItemFillGuard} runs {MatchRaceGuard}'s `filled` check (and, for a fill-once order,
///  the nonce check) before the permits, the plan build and `matchSettle`, so a lost
///  race costs a few thousand gas — {MatchRaceGuard.OrderTaken} / `NonceTaken`.
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
///      withdraw, borrow — or a SETTLE claim) run first, the maker's remaining input
///      is pulled, the input is pre-sent here, the route runs as the plan's `CALL`
///      step and pays Settlement, the outputs are delivered, and items that consume
///      the delivery run last — a wallet-funded MAKE (deposit, repay) and, since the
///      core change of 2026-10-14 (task 31), a PRE-FUNDED MAKE (the 15 pre-fund
///      lending sinks, `NativeUnwrapModule`) and a leg-reference TAKE_FOR. The core
///      hands an order its delivery ledger only at its DELIVER step, so such an item
///      flagged EARLY fails closed (`ForLegInvalid`) instead of spending residue.
///      Zero inventory, zero flash, zero Settlement bytes. Still refused on that path:
///      delta-verify orders ({DirectNotMatchable} — the netted path cannot verify a
///      recipient delta; use {executeFill}, which also carries NATIVE delivery), the
///      core's BALANCE-relative TAKE_FOR form, and a CYCLE (a leverage TAKE_FOR whose
///      borrow needs this fill's own delivery deposited first — `BatchNotWhole` /
///      `LegUnfunded`): those stay with the flash family (`BaseFlashSolver`) or an
///      inventory filler. `minBumpBps` / `amountOutOffset` cannot take effect there and
///      are refused ({ItemFillUnsupported}); the price floor there is the plan's
///      ABSOLUTE `minOut` with `maxPay` (S-6, see {executeItemFill}).
///    • MULTI-OUTPUT routes: an opaque route may produce several output tokens; every
///      output token's proceeds of the fill are approved (pull) / pushed (netted)
///      at their own delta, so one route can fund an order with two output legs in
///      two tokens (an LP-mint shape). A POOL route is single-output: its path ends
///      in the anchor output token, so a second output token gets no proceeds and
///      the fill fails closed.
///    • SETTLE RECEIPTS on {executeItemFill}: a SETTLE item pays its asset to THIS
///      contract (`matchSettle`'s caller). Flag it EARLY (it lands before the route)
///      and it can be SOLD in the same fill (review 2026-10-18 S-2):
///        – in `legsIn[0]`'s token: it is part of the routed anchor delta, as before;
///        – in a FOREIGN ERC-20 (a `ProportionalSweepModule` sweep of a second token):
///          list it in {ItemFillGuard.receipts} — snapshotted with the order's tokens,
///          pushed to the sandbox on a {MULTI_ROUTE}, swept back and split like any
///          residue; unlisted, it stays here as retained value (unreachable by later
///          fills, every amount being a delta) for the operators' {sweep};
///        – an ERC-721 / ERC-1155 (`NftSettlementModule`, `Erc1155SettlementModule`):
///          the receiver hook ({fallback}) accepts it only inside an armed item fill
///          before its route and forwards it straight to the sandbox, where a
///          {MULTI_ROUTE} sells it (e.g. `[collection.setApprovalForAll(market), market
///          .buy(…, payTo = this solver)]`); the sale proceeds then pay the maker — an
///          NFT sale with ZERO filler capital. An order with no input legs (the sale's
///          shape) is admitted. A LATE NFT SETTLE is refused (nothing could sell it), and
///          an NFT the route does not sell stays in the sandbox, recoverable by an
///          operator route (`target = collection, data = transferFrom(sandbox, …)`).
///      An `OcoGroupModule` claim moves nothing and fills early or late.
///    • Single-signature PermitBatchWitness orders: their FIRST fill has no
///      callback entry (`fillWithPermit` passes no callback, and `fillWithCallback`
///      / `matchSettle` verify only an Order signature), so it needs capital up
///      front. The flash family can take it through its permit envelope
///      ({BaseFlashSolver.PERMIT_ENVELOPE}) — but ONLY where a flash provider exists
///      (Balancer / Aave / Euler / Morpho / Midnight): on Rootstock there is none, so
///      there the first fill needs a filler holding the output (corrected 2026-10-18,
///      review §5; this note used to say the flash family "takes such an order",
///      unconditionally). The structural fix is core-side (review C-1: callback
///      arguments on `fillWithPermit`). Every LATER slice is fillable here: the
///      settler skips signature verification once `filled != 0`.
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
///
///  DIRECT POOL ROUTES (2026-10-12) — Uniswap-v3-style pools, no sandbox
///  ─────────────────────────────────────────────────────────────────────
///  `RoutePlan.router == POOL_ROUTE` swaps on the pools themselves: this contract
///  calls `pool.swap` and pays inside `uniswapV3SwapCallback` with a plain `transfer`
///  of exactly what the pool is owed. No push to the sandbox, no router, no sweep, no
///  approval of anything (Rootstock fork, live pools, net of refunds, against the
///  sandbox route on the deployed via-IR build after the 2026-10-12 gas pass: −34.4k
///  per direct exact-output fill, −28.8k pull exact-input, −41.1k / −37.2k on two hops;
///  `test/PoolRouteFork.t.sol`). Exact-input and exact-output, 1..{MAX_POOL_HOPS}
///  hops; exact-output multi-hop uses the standard recursive callback (each pool's
///  callback buys its input from the previous hop, paid straight to the calling
///  pool; only hop 0 is paid from here). Every settlement rule stays as on an opaque
///  route: the routed amount is the same delta, `minOut` / `maxPay` / the core's delta
///  check / the surplus split / the self-seeded floor all run unchanged, and the
///  amount words follow `amountInOffset` / `amountOutOffset` (0 / 32) exactly as an
///  opaque route's calldata words do.
///
///  WHY THIS DOES NOT RE-OPEN THE PERMISSIONLESS-ARMING HOLE. The route is executed
///  AS THIS CONTRACT again (the sandbox exists because opaque calldata must not be),
///  so the three invariants are re-established for the pool path specifically:
///    1. NOTHING IS CALLED THAT A PLAN NAMES. A pool route makes exactly one kind of
///       external call — `swap` on an address this contract COMPUTES as
///       `CREATE2(factory, keccak256(abi.encode(token0, token1, fee)), initCodeHash)`
///       over an IMMUTABLE venue allowlist ({PoolVenue}, constructor-fixed, no setter).
///       The init code hash pins the pool BYTECODE, so every derived address is
///       either genuine pool code or empty (the call then reverts). Tokens, fee and
///       venue index come from the plan; the target never does.
///    2. THE CALLBACK PAYS ONLY THE POOL OF THE ARMED HOP, ONLY WHAT IT IS OWED, ONLY
///       WITHIN THIS FILL'S DELTA. {uniswapV3SwapCallback} requires (a) `_active ==
///       SWAPPING`, a state set only around the outermost `pool.swap` of a fill an
///       OPERATOR started and the EXECUTOR called back (the existing 1/2/3 guard slot,
///       no new storage, no transient storage); (b) `msg.sender ==` the derived pool
///       of the hop its `data` names — a genuine pool calls back only the `msg.sender`
///       of its OWN `swap`, i.e. this contract, echoing this contract's data, so a
///       forged caller is never that address and forged data only names a pool the
///       caller is not; (c) a positive delta of the hop's INPUT token, paid in that
///       token only, and on hop 0 at most `budget` = the routed delta (exact-output:
///       also ≤ the plan's ceiling). Retained value, the floor, a donation or another
///       token are therefore unreachable, exactly as through the sandbox.
///    3. NO ALLOWANCE IS CREATED. The pool validates payment by its own balance delta;
///       the only allowance this contract ever sets is still Settlement's, cleared
///       after the fill.
///  The path must run from `legsIn[0]`'s token to the anchor output token, and on a
///  direct order the last hop pays `legsOut[0]`'s recipient (from the ORDER — never a
///  plan field), on a pull order — and on a NATIVE order, whose path ends in WNATIVE —
///  this contract. The full rule list and the PoCs that
///  pin it: `test/AggregatorPoolRoute.t.sol`.
///
///  ERC-2612 PERMITS (2026-10-12) — gasless makers, one transaction
///  ───────────────────────────────────────────────────────────────
///  Both entries take the maker's EIP-2612 permits ({Permit2612}) and run
///  `token.permit(maker, SETTLEMENT, value, deadline, v, r, s)` before the fill, so a
///  maker who signed one next to the order (it travels with the book announce) is
///  funded inside the fill transaction instead of by a separate relay transaction:
///  Settlement's direct-approval fallback pulls with the allowance it creates. The
///  owner must be the order's maker; a failed call (relayed first, front-run) is
///  accepted only when Settlement's allowance already covers `value` — see
///  {_permits}. Strict-mode makers (Permit3 `setStrictMode`) have that fallback off
///  by design: such a fill reverts `Permit3Denied`.
/// @notice One aggregator route, as the solver received it off-chain.
/// @param router the route's TARGET — the venue's entrypoint, from the quote. Any
///        contract: it is called by {RouteSandbox}, never by the solver. Settlement,
///        Permit3, the EXECUTOR and the solver itself are refused
///        ({RouteSandbox.ForbiddenTarget}). On the pull path quote it to pay the
///        SOLVER. Paying the sandbox also settles (the sweep returns it, outputs
///        first), but leaves the proceeds — spread included — in the sandbox for the
///        rest of the route call, where any holder of a sandbox approval that gains
///        control later in that call can take the part above `minOut`. Don't.
///        {POOL_ROUTE} (`address(0)`) instead = a DIRECT POOL ROUTE: `data` is a pool
///        plan (layout at {POOL_ROUTE}) this contract executes itself, no sandbox.
/// @param minOut floor on the swap proceeds — SOLVER-side protection against a
///        stale route; the maker's own floor is the signed band Settlement enforces.
///        Measured in the ANCHOR OUTPUT TOKEN: the first output token no input leg
///        pays (`legsOut[0]`'s on every plain order), as what the route produced in
///        it — any inflow of that token the fill paid here BEFORE the route (an
///        input leg in the same token) is netted out first (review 2026-10-05).
///        Ignored on a direct-delivery order (see the contract note), except a NATIVE
///        one, where it floors the route's WNATIVE proceeds. NOT COMPARED on an order
///        with no output leg (an admitted zero-output order: there is no anchor output
///        to measure) — `maxPay` likewise (review 2026-10-18 D-3)
/// @param maxPay ceiling on what Settlement may pull from this contract in the
///        anchor output token — PER TOKEN, so two legs in it (maker + fee) must fit
///        under it together. `0` = no cap, meaning "up to THIS FILL's proceeds" —
///        never the contract's balance. A `maxPay` above the proceeds is clamped
///        down to them for the same reason. Together with `minOut` this pins the
///        spread: the fill can only succeed if `proceeds >= minOut` and the maker
///        takes at most `maxPay`, so profit >= `minOut - maxPay` by construction
///        (with {inventory} drawn: `>= minOut - maxPay` still, the draw counting as
///        paid). Below 2^128 ({AmountTooLarge}).
/// @param inventory the most of the ANCHOR OUTPUT token this fill may draw from the
///        solver's OWN balance — value held BEFORE the fill — on top of the route's
///        proceeds (review 2026-10-18 S-1). `0` = none: every amount is this fill's delta,
///        exactly as before. Set, it covers a route shortfall or replaces the route
///        outright (an EMPTY route: `router = POOL_ROUTE`, `data = ""`), so inventory can
///        only ever ADD to what a fill can pay — never be required by it. Bounded three
///        ways: by this cap, by the pre-fill balance, and by what the order demands —
///        PULL: Settlement is approved `proceeds + min(inventory, held)` (it pulls the
///        priced legs, the rest of the approval is zeroed); NETTED: that much is pushed
///        and the pool sweeps the unused part straight back; DIRECT: the leg-0 recipient's
///        measured shortfall against the core's live price is sent, at most `inventory`
///        ({InsufficientOutput} past it); NATIVE: the unwrap may use it. `maxPay` still
///        caps the total — except on DIRECT, where `maxPay` is ignored and this cap
///        alone bounds the top-up (review 2026-10-18 D-1). Inventory is drawn only
///        ABOVE the route's own proceeds, which must first reach `minOut`
///        ({InsufficientOutput}): with `minOut >= maxPay` (a filler's usual
///        `owed + cost` / `owed`) a pull fill never draws. Only an operator can start a fill, and only a fill an operator
///        started can draw — the operators can {AggregatorFillSolver.sweep} the same
///        balance anyway, so the cap grants no authority they lack; it bounds what one
///        mis-priced call can spend. The maker's input a draw pays for is residue, split
///        by the {SurplusPolicy} like any (retain mode keeps it here as the new
///        inventory). Below 2^128 ({AmountTooLarge}). BREAKING (2026-10-18): new field.
/// @param amountInOffset byte offset within `data` of the 32-byte input amount to
///        REWRITE with the amount actually routed — this fill's input delta less the
///        output legs it owes in that same token (see {AggregatorFillSolver.onSettlementFill}),
///        and, on the first pull / netted fill of a token the solver holds none of,
///        less the one wei it keeps as its self-seeded balance floor
///        ({AggregatorFillSolver._seedIn}) — or {NO_PATCH} to leave the calldata
///        exactly as the aggregator returned it.
///        ⚠ The word AS SENT is also {AggregatorFillSolver._minOut}'s `quoted`: `minOut`
///        is scaled down by `routed / quoted` whenever the fill routes less. So the word
///        MUST be the amount the solver will route — the input less any same-token
///        legs kept back — never the whole `owed` with a fee leg kept (95 → 86 with a
///        10 % fee leg on a FULL fill), never a loose `amountInMaximum`-style ceiling
///        (2× halves the floor), never a `type(uint256).max` placeholder (the scaling
///        overflows and the fill reverts). An EMPTY route has no word: leave this at
///        {NO_PATCH} there — an offset reads whatever calldata follows the empty blob
///        (review 2026-10-18 D-2 / D-4; pinned by the P2–P5 probes).
///        See the ⚠ note on {AggregatorFillSolver} about resolved amounts.
/// @param amountOutOffset byte offset within `data` of the 32-byte OUTPUT amount to
///        rewrite with the ANCHOR legs' live price at inclusion (the core's typed
///        `pricedOut`), or {NO_PATCH}: on a DIRECT order `pricedOut[0]` (the leg the route
///        pays); on a PULL order the sum over every leg in the anchor output token (the
///        core pulls each from here — task 16, 2026-10-14; it used to write `pricedOut[0]`
///        whatever the anchor, so a fee leg listed first made the word the fee). Meant
///        for an exact-output quote: the route then produces exactly what the core
///        demands, and the auction's decay since the quote stays here as input residue
///        instead of reaching the maker as price improvement (task 05). Setting it
///        switches the fill to the TYPED callback (~+5.9k gas; see `_typed`). REFUSED by
///        {AggregatorFillSolver.executeItemFill} ({AggregatorFillSolver.ItemFillUnsupported},
///        task 17 — no priced amount reaches a `CALL` step). BREAKING (2026-10): new field.
/// @param minBumpBps the filler's PRICE FLOOR on the order's resolved bump, in bps of
///        the band — passed to `fillWithCallback` exactly as {Settlement.fillUpTo}
///        takes it (`0` = none; a miss reverts `BumpTooLow` before anything moves).
///        Set it to the bump the route was quoted at, so an order whose tick can move
///        maker-ward between quote and inclusion (a priority auction included at a
///        lower bid, a `gasBumpBps` order, a custom curve) reverts instead of eroding
///        the spread. REFUSED by {AggregatorFillSolver.executeItemFill} when non-zero
///        ({AggregatorFillSolver.ItemFillUnsupported}, task 17 — `matchSettle` carries
///        no floor). BREAKING (2026-10): new field.
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
    uint256 inventory;
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
///      aggregator's calldata as quoted. ANY offset with bit 255 set means "no patch"
///      (no calldata is that long); `2^255` is the canonical encoding because it is the
///      cheapest such word in CALLDATA — one non-zero byte (16 + 31·4 = 140 gas) where
///      `type(uint256).max` costs 32 (512 gas). 2026-10-12, was `type(uint256).max`,
///      which still reads as "no patch".
uint256 constant NO_PATCH = 1 << 255;

/// @dev `RoutePlan.router` sentinel for a DIRECT POOL ROUTE (2026-10): `data` is then
///      not calldata for a target but a pool plan the solver executes itself against
///      Uniswap-v3-style pools it DERIVES from its immutable venue allowlist — see
///      {AggregatorFillSolver} "DIRECT POOL ROUTES". `address(0)` was never a usable
///      route target (the sandbox's call to it is a no-op that settles nothing).
///
///      `data` layout (all big-endian, no ABI head):
///        [0:32)   amountIn  — exact-input: the amount swapped; exact-output: the
///                             input ceiling (`amountInMaximum`). `amountInOffset = 0`
///                             rewrites it with the routed delta, as on any route.
///        [32:64)  amountOut — `0` = EXACT-INPUT; otherwise the exact output paid to
///                             the payee. `amountOutOffset = 32` rewrites it with the
///                             core's live price of the anchor legs (typed callback;
///                             see {RoutePlan.amountOutOffset}), as on any route.
///        [64:)    path, in SWAP order: token0 ‖ fee(3) ‖ venue(1) ‖ token1 ‖ fee ‖
///                 venue ‖ token2 … — one 24-byte (fee, venue) pair per hop, 1 to
///                 {AggregatorFillSolver.MAX_POOL_HOPS} hops. `token0` must be the
///                 order's anchor input, the last token its anchor output.
///      The offsets keep their meaning: on a pool route the only patchable words are
///      0 (`amountInOffset`) and 32 (`amountOutOffset`); any other value but
///      {NO_PATCH} reverts {AggregatorFillSolver.BadPoolRoute}.
address constant POOL_ROUTE = address(0);

/// @notice One Uniswap-v3-style deployment a pool route may swap on: pools are never
///         taken from calldata, they are recomputed as
///         `CREATE2(factory, keccak256(abi.encode(token0, token1, fee)), initCodeHash)`.
/// @param factory      the venue's pool factory (the CREATE2 deployer of its pools)
/// @param initCodeHash the keccak of the venue's pool creation code — pins the pool
///                     BYTECODE, so every address it derives runs genuine pool code
struct PoolVenue {
    address factory;
    bytes32 initCodeHash;
}

/// @notice A maker's signed ERC-2612 permit, executed by {AggregatorFillSolver.executeFill}
///         / {AggregatorFillSolver.executeItemFill} BEFORE the fill: `token.permit(owner,
///         SETTLEMENT, value, deadline, v, r, s)`. The spender is fixed to Settlement
///         (not a field): Settlement's direct-approval fallback pulls the maker's input
///         with it (`Base._pullViaPermit3` → plain `transferFrom` for a NON-STRICT maker).
///         `owner` must be the order's maker.
struct Permit2612 {
    address token;
    address owner;
    uint256 value;
    uint256 deadline;
    uint8 v;
    bytes32 r;
    bytes32 s;
}

/// @notice {AggregatorFillSolver.executeItemFill}'s race guard and foreign receipts (review
///         2026-10-18 S-5 / S-2), checked by the solver before anything moves. (The item
///         path's PRICE floor is the plan's absolute `minOut` with `maxPay` — see
///         {AggregatorFillSolver.executeItemFill}, S-6.)
/// @param orderHash / expectedFilled {MatchRaceGuard}'s `filled` check for this one order
///        ({MatchRaceGuard._requireUntouched}'s rule, EXACT equality — see there why):
///        `filled[orderHash]` must still read `expectedFilled`, the value the plan was
///        simulated against — ONE `SLOAD` before the permits, the plan build and
///        `matchSettle`, so a lost race reverts {MatchRaceGuard.OrderTaken} for a few
///        thousand gas instead of the full approach. `orderHash == 0` = no check. The
///        hash is the caller's (off-chain / `SettlementLens.hashOrder`), never
///        recomputed here — that is the point; a WRONG hash only makes the guard read
///        another slot (it can refuse a good fill, never admit a bad one: the core
///        gates the order itself)
/// @param liveNonce also require the ORDER'S OWN `(maker, nonce)` to be live —
///        {MatchRaceGuard.NonceTaken} — for a FILL-ONCE order (an OCO bracket leg) or one
///        cancelled by nonce, which `filled` cannot show ({MatchRaceGuard}'s ⚠). The
///        one-order form of {MatchRaceGuard._requireNoncesLive}: the pair is read from
///        the order rather than passed twice. One more `SLOAD` (two on a bitmap nonce)
/// @param receipts FOREIGN tokens a SETTLE item pays the solver (a second-token sweep —
///        anything no leg names): snapshotted with the order's own tokens, pushed to the
///        sandbox on a {MULTI_ROUTE} so the route can sell them, swept back and split like
///        any residue. Without this entry such a receipt is retained (see "SETTLE
///        RECEIPTS"). An NFT needs no entry: the receiver hook forwards it.
struct ItemFillGuard {
    bytes32 orderHash;
    uint256 expectedFilled;
    bool liveNonce;
    address[] receipts;
}

/// @dev The pool interface a pool route calls — Uniswap v3's, which SushiSwap v3 and
///      Oku share (one callback name, `uniswapV3SwapCallback`).
interface IUniswapV3PoolSwap {
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
}

/// @notice The resolved route handed to {AggregatorFillSolver.onSettlementFill} (as the
///         typed callback's `userData`) and to {AggregatorFillSolver.onMatchRoute}.
/// @dev    A STRUCT rather than a parameter list, deliberately. The flat form hit
///         the stack limit at six arguments under the legacy profile this package
///         compiles with, and every future field would hit it again; a struct
///         costs one memory pointer and makes the shape extensible.
///
///         THE TOKEN SET (audit 2026-09-30 AGG-2 / AGG-6). Every DISTINCT token the
///         order's legs name, input legs first — so `tokens[0]` is always
///         `legsIn[0]`'s token, the anchor the route swaps (with NO input leg, the
///         first output token), then on {AggregatorFillSolver.executeItemFill} the
///         {ItemFillGuard.receipts} (flagged in neither mask). `inMask` / `outMask`
///         flag which of them an input / output leg pays (a token can be both: a
///         same-token order, a fee leg in the input token). Each is measured
///         against its own pre-fill snapshot in `before`, so a second input leg in a
///         third token is measured on its own delta (routed on a netted {MULTI_ROUTE},
///         refused otherwise — S-3; it used to be paid here and never looked at
///         again, then split as residue), and
///         every output token is approved to Settlement at ITS OWN measured
///         proceeds, so the pull path is no longer limited to one output token.
struct FillRoute {
    address router;
    uint256 minOut;
    /// @dev TWO plan figures in one word (2026-10-18): bits [0, 128) = {RoutePlan.maxPay},
    ///      bits [128, 256) = {RoutePlan.inventory} — both refused at or above 2^128
    ///      ({AggregatorFillSolver.AmountTooLarge}). Packed for the reason {legs} is: a
    ///      new word travels solver → Settlement → EXECUTOR → solver on every fill.
    uint256 maxPay;
    uint256 amountInOffset;
    uint256 amountOutOffset;
    /// @dev THREE leg facts packed in one word (2026-10-14, solver v3; was `sameOut`,
    ///      whose low bits keep their meaning):
    ///        • bits [0, 127) — {LEGS_SAME}: bit `j` set = output leg `j` is paid in
    ///          `tokens[0]`, the anchor INPUT token (an in-kind fee leg).
    ///          {onSettlementFill} keeps those legs' priced amounts here instead of
    ///          routing them (review 2026-10-05 S1);
    ///        • bit 127 — {LEGS_NATIVE}: NATIVE delivery (task 30). `legsOut[0]` is in
    ///          {AggregatorFillSolver.NATIVE_BALANCE}; the route ends in WNATIVE paid
    ///          to THIS contract (`tokens[outAnchor]` is WNATIVE), and the typed
    ///          callback unwraps `pricedOut[0]` and sends it to `payee`;
    ///        • bits [128, 256) — the OUT-LEG MASK (task 16): bit `128 + j` = output
    ///          leg `j`'s priced amount is part of the route's exact-output word
    ///          (`amountOutOffset`). PULL: every leg paid in the anchor output token
    ///          (the core pulls each of them from here); DIRECT: leg 0 alone (the leg
    ///          the route — a pool route's last hop — pays). Empty when
    ///          `amountOutOffset` is {NO_PATCH}.
    ///      Any bit set ⇒ the fill needs the TYPED callback, so {_typed} still tests
    ///      this one word. Legs past index 126 / 127 cannot be flagged: an order with
    ///      that many output legs AND an in-kind leg or a patched exact-output word
    ///      there under-keeps / under-produces, and the core's pull fails (closed).
    ///      PACKED, NOT NEW FIELDS, BY MEASUREMENT (deployed via-IR bytecode, the
    ///      `AggregatorFillGasTest` cold pull fill): two added words cost +589 gas — every
    ///      word travels solver → Settlement → EXECUTOR → solver — and turning `direct`
    ///      into a flags word cost +124 more (it changes {onFill}'s selector and the
    ///      dispatch order). This layout keeps the struct's ABI type, and so {onFill}'s
    ///      selector, exactly as before.
    uint256 legs;
    /// @dev The order's distinct leg tokens; `tokens[0]` = `legsIn[0]`'s token.
    address[] tokens;
    /// @dev Each token's balance, taken in `executeFill` BEFORE Settlement moved
    ///      anything. Everything `onSettlementFill` spends is measured against these, so the
    ///      callback can only ever reach this fill's own proceeds. `0` (unread) for
    ///      an output-only token on the direct path, which never lands here.
    uint256[] before;
    /// @dev Bit `k` set = `tokens[k]` is paid to this contract during the fill: by an
    ///      input leg, or — a NATIVE order's WNATIVE anchor — by the route (set by
    ///      {AggregatorFillSolver._nativeLeg}, so it is snapshotted, overspend-checked and
    ///      split with no extra test on the hot path).
    uint256 inMask;
    /// @dev Bit `k` set = `tokens[k]` is owed by an output leg.
    uint256 outMask;
    /// @dev Index in `tokens` of the ANCHOR OUTPUT token — the one `minOut` and
    ///      `maxPay` apply to: the first output token no input leg pays, else
    ///      `legsOut[0]`'s (see {_plan}).
    uint256 outAnchor;
    /// @dev The order carries {DutchAuction.deltaVerifyOutputs}: the route pays
    ///      the recipients itself and this contract never approves Settlement.
    bool direct;
    /// @dev Where a POOL route's last hop pays: `legsOut[0]`'s resolved recipient
    ///      on a direct order, this contract otherwise — and on a NATIVE order (any
    ///      route) the native leg's resolved recipient, while the route itself pays
    ///      this contract. Set by {_plan} from the ORDER, never from the plan; zero on
    ///      an opaque non-native route.
    address payee;
    bytes data;
}

/// @dev {FillRoute.legs} fields — see there.
uint256 constant LEGS_SAME = (1 << 127) - 1;
uint256 constant LEGS_NATIVE = 1 << 127;
uint256 constant LEGS_OUT_SHIFT = 128;

/// @dev The wrapped-native token's unwrap (WETH9 / WRBTC).
interface IWNative {
    function withdraw(uint256 amount) external;
}

contract AggregatorFillSolver is MatchRaceGuard {
    // `SETTLEMENT` (public immutable) is {MatchRaceGuard}'s — the settler whose
    // `filled` book {executeItemFill}'s race guard reads is the one every fill uses.
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

    /// @dev `_active` while a POOL ROUTE's swap is in flight — the only state in which
    ///      {uniswapV3SwapCallback} pays. Set around the outermost `pool.swap` and
    ///      restored to the fill's own state (3 or 5) after it, so it is reachable only
    ///      from inside a fill an operator started (see {_poolRoute}).
    uint256 private constant SWAPPING = 6;

    /// @notice Most hops one pool route may take.
    uint256 public constant MAX_POOL_HOPS = 4;
    /// @notice How many {PoolVenue}s this instance derives pools from (0..{MAX_SET}).
    uint256 public immutable POOL_VENUES;
    /// @dev The venue allowlist, as immutables (same reason as the operator set: a
    ///      compare and a bytecode constant per hop, never an SLOAD). Unused slots are
    ///      zero and refused by {_venue}.
    address private immutable FACTORY0;
    address private immutable FACTORY1;
    address private immutable FACTORY2;
    address private immutable FACTORY3;
    bytes32 private immutable INIT_HASH0;
    bytes32 private immutable INIT_HASH1;
    bytes32 private immutable INIT_HASH2;
    bytes32 private immutable INIT_HASH3;

    /// @dev Uniswap v3 `TickMath` bounds ± 1: the "no price limit" a router passes when
    ///      the caller sets none. Slippage on a pool route is bounded by the hop budget,
    ///      `minOut` and the core's delivery checks, never by a price limit.
    uint160 private constant MIN_SQRT_RATIO_PLUS_1 = 4295128740;
    uint160 private constant MAX_SQRT_RATIO_MINUS_1 = 1461446703485210103287273052203988822378723970341;

    /// @notice The `NativeBalance` view token (packages/periphery/src/NativeBalance.sol)
    ///         a DIRECT order names as `legsOut[0].token` to receive raw native coin;
    ///         `address(0)` = native delivery OFF on this instance (task 30).
    address private immutable NATIVE_BALANCE;
    /// @notice The wrapped native token a native order's route must end in — WRBTC on
    ///         Rootstock. Unwrapped here and sent to the leg's recipient. `address(0)`
    ///         exactly when {NATIVE_BALANCE} is.
    address private immutable WNATIVE;

    /// @notice This instance's native-delivery pair (task 30): the `NativeBalance` view
    ///         token a DIRECT order names as `legsOut[0].token`, and the wrapped native
    ///         its route must end in. Both zero = native delivery off.
    /// @dev    ONE getter for the two private immutables rather than two public ones:
    ///         every external function lengthens the selector dispatch every fill pays,
    ///         and two getters measured +44 gas on the pull hot path.
    function nativeDelivery() external view returns (address nativeBalance, address wnative) {
        return (NATIVE_BALANCE, WNATIVE);
    }

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
    ///      {PackedArrays}' leg readers are unchecked, and a blob declaring zero
    ///      legs with trailing bytes would otherwise name an arbitrary token.
    error NoLegs();
    /// @dev A {PoolVenue} with a zero factory or init code hash, or more than {MAX_SET}.
    error BadVenue();
    /// @dev A pool route named a venue index this instance does not have.
    error UnknownVenue(uint256 venue);
    /// @dev A malformed pool route: bad length, too many hops, a first token that is
    ///      not the anchor input, a last token that is not the anchor output, a
    ///      direct order whose `legsOut[0]` is not that anchor output, or an offset
    ///      other than 0 / 32 / {NO_PATCH}.
    error BadPoolRoute();
    /// @dev {uniswapV3SwapCallback} from anything but the pool the armed hop derives.
    error NotPool();
    /// @dev A pool asked for more than the hop's budget — on the first hop, more of
    ///      the maker's input than this fill routed — or an exact-input route asked
    ///      to swap more than that.
    error PoolOverBudget(uint256 owed, uint256 budget);
    /// @dev A pool callback that owes nothing of the hop's input token, or a swap that
    ///      did not consume / deliver its exact amount (a liquidity-exhausted pool).
    error BadPoolSwap();
    /// @dev A {Permit2612} whose `owner` is not the order's maker.
    error PermitOwnerNotMaker(address owner);
    /// @dev `token.permit` failed AND Settlement's allowance from the maker is still
    ///      below the permit's value (it was neither relayed nor approved otherwise).
    error PermitFailed(address token);
    /// @dev {executeItemFill} was given a `minBumpBps` or an `amountOutOffset`: the
    ///      netted path can honour neither (`matchSettle` carries no bump floor, and no
    ///      priced amount reaches a `CALL` step), so an operator's floor would silently
    ///      do nothing (task 17). Refused before anything moves.
    error ItemFillUnsupported();
    /// @dev The constructor's native pair is half-set (one of `nativeBalance` /
    ///      `wnative` zero, or both the same address).
    error BadNative();
    /// @dev A native order (`legsOut[0].token == NATIVE_BALANCE`) of a shape this
    ///      contract does not deliver: not DIRECT (a pull leg in a view token can never
    ///      be paid — the core's `transferFrom` on it reverts anyway, this fails before
    ///      the route), or WNATIVE / NATIVE_BALANCE named by any OTHER leg (input or
    ///      output) — the WNATIVE delta here would then not be this leg's alone.
    error NativeLegShape();
    /// @dev The native send to the leg's recipient failed (its `receive()` reverted).
    ///      Same posture as `NativeUnwrapModule`: the whole fill reverts.
    error NativeSendFailed(address to);
    /// @dev Native coin from anything but {WNATIVE}'s `withdraw`.
    error NotWNative();
    /// @dev {RoutePlan.maxPay} or {RoutePlan.inventory} at or above 2^128 — they share
    ///      one word of {FillRoute}.
    error AmountTooLarge();
    /// @dev An input token that is neither `legsIn[0]`'s nor an output token, on a
    ///      route other than a {MULTI_ROUTE} — the maker's second currency would be
    ///      split here as residue instead of routed (review 2026-10-18 S-3).
    error MultiInputUnrouted();

    /// @param operators who may call `executeFill`: 1..{MAX_SET} non-zero addresses.
    ///        EMPTY REVERTS ({NoOperators}) — see the trust-model note.
    /// @param policy    the immutable surplus split — see {SurplusPolicy}
    /// @param venues    the Uniswap-v3-style deployments a POOL ROUTE may swap on,
    ///        0..{MAX_SET} (`venue` index = position here). Empty = pool routes off.
    /// @dev   BREAKING (2026-10): the router set, the `standing` flag and the
    ///        prime list are gone. Routes run in the {RouteSandbox} this
    ///        constructor deploys, which may call any target. BREAKING (2026-10
    ///        quick audit): an empty operator set no longer means "permissionless";
    ///        it reverts. BREAKING (2026-10-12): the `venues` argument.
    /// @param nativeBalance the `NativeBalance` view token direct native orders name
    ///        (task 30) — `address(0)` turns native delivery off ({NATIVE_BALANCE})
    /// @param wnative the wrapped native the route ends in for such an order (WRBTC on
    ///        Rootstock) — `address(0)` exactly when `nativeBalance` is ({BadNative}).
    ///        BREAKING (2026-10-14, solver v3): both arguments are new.
    constructor(
        address settlement,
        address[] memory operators,
        SurplusPolicy memory policy,
        PoolVenue[] memory venues,
        address nativeBalance,
        address wnative
    ) MatchRaceGuard(settlement) {
        if ((nativeBalance == address(0)) != (wnative == address(0)) || (wnative != address(0) && nativeBalance == wnative))
        {
            revert BadNative();
        }
        NATIVE_BALANCE = nativeBalance;
        WNATIVE = wnative;
        if (venues.length > MAX_SET) revert BadSetSize();
        for (uint256 i; i < venues.length; i++) {
            if (venues[i].factory == address(0) || venues[i].initCodeHash == bytes32(0)) revert BadVenue();
        }
        POOL_VENUES = venues.length;
        PoolVenue memory none;
        PoolVenue memory v0 = venues.length > 0 ? venues[0] : none;
        PoolVenue memory v1 = venues.length > 1 ? venues[1] : none;
        PoolVenue memory v2 = venues.length > 2 ? venues[2] : none;
        PoolVenue memory v3 = venues.length > 3 ? venues[3] : none;
        (FACTORY0, INIT_HASH0) = (v0.factory, v0.initCodeHash);
        (FACTORY1, INIT_HASH1) = (v1.factory, v1.initCodeHash);
        (FACTORY2, INIT_HASH2) = (v2.factory, v2.initCodeHash);
        (FACTORY3, INIT_HASH3) = (v3.factory, v3.initCodeHash);
        if (operators.length == 0) revert NoOperators();
        if (uint256(policy.makerPpm) + policy.protocolPpm > PPM) revert BadSurplusSplit();
        if (policy.protocolPpm != 0 && policy.protocolRecipient == address(0)) revert BadSurplusSplit();
        MAKER_SURPLUS_PPM = policy.makerPpm;
        PROTOCOL_SURPLUS_PPM = policy.protocolPpm;
        PROTOCOL_RECIPIENT = policy.protocolRecipient;
        SEED_INPUT = policy.makerPpm == 0 && policy.protocolPpm == 0;
        address executor = address(Settlement(payable(settlement)).EXECUTOR());
        EXECUTOR = executor;
        SANDBOX = new RouteSandbox(settlement, address(Settlement(payable(settlement)).PERMIT3()), executor);
        if (operators.length > MAX_SET) revert BadSetSize();
        for (uint256 i; i < operators.length; i++) {
            if (operators[i] == address(0)) revert BadOperator();
        }
        (OPERATOR0, OPERATOR1, OPERATOR2, OPERATOR3) = _four(operators);
    }

    /// @notice Accepts native coin from {WNATIVE}'s `withdraw` ONLY — the unwrap step of
    ///         a native delivery, which is sent on within the same callback. Anything
    ///         else reverts {NotWNative}, so no route, maker or stranger can park native
    ///         here by a plain send (SELFDESTRUCT / coinbase cannot be refused; such coin
    ///         is never spent: every send is exactly what that callback unwrapped).
    /// @dev    WETH9 / WRBTC `withdraw` pays with `transfer` (2,300 gas stipend): this
    ///         body is one immutable compare and must stay that small. On an instance
    ///         with native delivery off `WNATIVE` is zero and nothing is accepted.
    receive() external payable {
        if (msg.sender != WNATIVE) revert NotWNative();
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

    /// @notice Venue `i` of the pool-route allowlist — reverts {UnknownVenue} past
    ///         {POOL_VENUES}.
    function poolVenue(uint256 i) public view returns (address factory, bytes32 initCodeHash) {
        if (i >= POOL_VENUES) revert UnknownVenue(i);
        if (i == 0) return (FACTORY0, INIT_HASH0);
        if (i == 1) return (FACTORY1, INIT_HASH1);
        if (i == 2) return (FACTORY2, INIT_HASH2);
        return (FACTORY3, INIT_HASH3);
    }

    /// @notice The pool a pool route's hop `(tokenA, tokenB, fee)` on `venue` swaps on —
    ///         the ONLY address {uniswapV3SwapCallback} pays. Pure CREATE2 arithmetic over
    ///         the immutable venue: nothing a caller supplies is trusted as a pool.
    function poolFor(uint256 venue, address tokenA, address tokenB, uint24 fee) public view returns (address) {
        (address factory, bytes32 initCodeHash) = poolVenue(venue);
        return _derive(factory, initCodeHash, tokenA, tokenB, fee);
    }

    /// @dev The CREATE2 pool address, hashed in SCRATCH memory (no allocation).
    ///      EQUIVALENT SOLIDITY (the pre-2026-10-12 body, pinned against the live
    ///      factories' `getPool` in `test/PoolRouteFork.t.sol` and against the mock
    ///      factory in `test/AggregatorPoolRoute.t.sol`):
    ///
    ///          (address t0, address t1) = a < b ? (a, b) : (b, a);
    ///          return address(uint160(uint256(keccak256(abi.encodePacked(
    ///              hex"ff", factory, keccak256(abi.encode(t0, t1, fee)), initCodeHash)))));
    ///
    ///      `a`, `b`, `factory` must be clean (upper 96 bits zero) and `fee < 2^24` —
    ///      every caller passes Solidity-typed values or `shr`-extracted calldata
    ///      fields, so `abi.encode`'s word cleaning is a no-op on them. The salt
    ///      preimage borrows the free-memory-pointer word (0x40) and restores it;
    ///      the CREATE2 preimage is Solady's `predictDeterministicAddress` layout
    ///      (0xff ‖ factory ‖ salt ‖ initCodeHash over [0x00, 0x55)).
    function _derive(address factory, bytes32 initCodeHash, address a, address b, uint256 fee)
        private
        pure
        returns (address pool)
    {
        /// @solidity memory-safe-assembly
        assembly {
            let m := mload(0x40)
            let x := xor(a, b)
            let t0 := xor(a, mul(x, gt(a, b))) // min(a, b)
            mstore(0x00, t0)
            mstore(0x20, xor(t0, x)) // max(a, b)
            mstore(0x40, fee)
            let salt := keccak256(0x00, 0x60)
            mstore8(0x00, 0xff)
            mstore(0x35, initCodeHash)
            mstore(0x01, shl(96, factory))
            mstore(0x15, salt)
            pool := and(keccak256(0x00, 0x55), 0xffffffffffffffffffffffffffffffffffffffff)
            mstore(0x40, m)
        }
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
    /// @param  permits the maker's ERC-2612 permits to execute BEFORE the fill (see
    ///         {Permit2612}, {_permits}); empty for an order funded by an existing
    ///         approval. BREAKING (2026-10-12): new argument, the 5-argument entry is gone.
    function executeFill(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmount,
        RoutePlan calldata plan,
        bytes calldata takerData,
        Permit2612[] calldata permits
    ) external returns (uint256[] memory fillAmountsOut) {
        if (!isOperator(msg.sender)) revert NotOperator(msg.sender);
        if (_active != 1) revert Reentrancy();
        if (permits.length != 0) _permits(permits, order.maker);
        return _executeFill(order, sig, fillAmount, plan, takerData);
    }

    /// @dev {executeFill}'s body, in its own frame: the `permits` array's two stack
    ///      words push the fill past the legacy profile's stack limit otherwise.
    function _executeFill(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmount,
        RoutePlan calldata plan,
        bytes calldata takerData
    ) private returns (uint256[] memory fillAmountsOut) {
        // Built BEFORE the fill, because its snapshots are balances that only mean
        // anything pre-fill — and reused afterwards for the sweep, so the callback
        // and the sweep can never disagree about what this fill created.
        FillRoute memory route = _plan(order, plan);
        // MULTI-INPUT (review 2026-10-18 S-3): an input token that is neither the
        // anchor nor an output token is the maker's payment in a second currency. It
        // must be ROUTED, never silently split here as filler residue — and this entry
        // routes the anchor alone, so it refuses the shape; {executeItemFill} with a
        // {MULTI_ROUTE} routes it. (A non-anchor token that is ALSO an output nets in
        // place against its output legs, as before.)
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
    ///       delivery: a wallet-funded MAKE (deposit, repay), a PRE-FUNDED MAKE (swap →
    ///       supply / repay into a pre-fund module, `NativeUnwrapModule`), a
    ///       leg-reference TAKE_FOR. Such an item flagged early reverts in the core
    ///       (`ForLegInvalid`: its order's delivery ledger is empty until DELIVER).
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
    ///  core's: no delta-verify order, no repeated input token, no BALANCE-relative
    ///  TAKE_FOR — pre-funded MAKE, leg-reference TAKE_FOR and SETTLE items are admitted
    ///  since 2026-10-14 (task 31; flag the delivery-consuming ones LATE, an early one
    ///  reverts `ForLegInvalid`). A SETTLE receipt lands HERE: see the contract note
    ///  ("SETTLE RECEIPTS") for when the route sells it and when it is only retained.
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
    /// @param plan as {executeFill}'s, with the netted path's PRICE FLOOR in it (review
    ///        2026-10-18 S-6). `matchSettle` carries no bump floor (`minBumpBps` is refused
    ///        here), so the floor is the solver's own: `minOut` is ABSOLUTE on this entry
    ///        (never scaled pro rata, unlike {executeFill}) and `maxPay` caps the push of
    ///        the anchor output — together `spread >= minOut − maxPay`, whichever side of
    ///        the order moves maker-ward between quote and inclusion: a SELL whose output
    ///        tick rose needs more than `maxPay` and the pool comes up short
    ///        (`BatchNotWhole`); a BUY whose input tick fell routes less and an
    ///        exact-input route misses `minOut` ({InsufficientOutput}). Set both to the
    ///        quote's figures (the beta filler's `minOut = owed + cost, maxPay = owed`).
    ///        ⚠ An EXACT-OUTPUT quote on this path (fixed output word, input as the
    ///        ceiling) keeps its spread as input residue, which no floor sees: quote item
    ///        fills exact-input when the floor matters. (A separate input floor — a
    ///        `minIn` on the guard — was built and measured at +331 B, which the deployed
    ///        size budget did not have; see the 2026-10-18 report.)
    /// @param lateItems bit `k` set = item `k` runs AFTER delivery (step 6), clear =
    ///        before the input is pulled (step 1). Bits past the item count revert
    ///        {BadItemSchedule}. ⚠ Never flag a TAKE that produces an INPUT-leg token
    ///        late: the PULL has already drawn the whole leg from the wallet, the late
    ///        TAKE credits it again and the core refunds the duplicate — tokens
    ///        round-trip, but the maker's Permit3 allowance is spent twice for one
    ///        fill (the asymmetry `Batch._stepPull` documents). A late TAKE whose
    ///        proceeds are not an input-leg token (borrow after the deposit) is fine:
    ///        the core refunds them to the maker.
    /// @param permits as {executeFill}'s (BREAKING 2026-10-12, new last argument).
    /// @param guard the race guard and the foreign receipts — see
    ///        {ItemFillGuard}. BREAKING (2026-10-18): new last argument (all-empty = the
    ///        previous behaviour).
    /// @return fillAmountsOut the delivered amount per output leg (`matchSettle`'s
    ///         `outs[0]`).
    function executeItemFill(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmount,
        RoutePlan calldata plan,
        bytes calldata takerData,
        uint256 lateItems,
        Permit2612[] calldata permits,
        ItemFillGuard calldata guard
    ) external returns (uint256[] memory fillAmountsOut) {
        if (!isOperator(msg.sender)) revert NotOperator(msg.sender);
        if (_active != 1) revert Reentrancy();
        // S-5: the race guard FIRST — before the permits, the plan build and the
        // order hash `matchSettle` computes — so a competitor that landed first costs
        // this call its SLOADs and nothing else ({MatchRaceGuard}, reused as is).
        _raceGuard(guard, order.maker, order.nonce);
        // Task 17: neither field can take effect on the netted path, so a set one is
        // an operator expecting protection it would not get — refuse, never ignore.
        // The netted path's price floor is the plan's ABSOLUTE `minOut` with `maxPay`
        // (S-6, see the `plan` parameter note).
        if (plan.minBumpBps != 0 || plan.amountOutOffset < NO_PATCH) revert ItemFillUnsupported();
        // The netted path's PULL step draws through the same `Base._pullViaPermit3`
        // fallback as {executeFill}'s, so a maker permit funds it identically.
        if (permits.length != 0) _permits(permits, order.maker);
        return _executeItemFill(order, sig, fillAmount, plan, takerData, lateItems, guard);
    }

    /// @dev {executeItemFill}'s race guard ({ItemFillGuard}): {MatchRaceGuard}'s two
    ///      checks for ONE order, with its errors and its settler. Not its array helpers
    ///      on purpose — measured on the deployed profile, `_requireUntouched` /
    ///      `_requireNoncesLive` over one-element calldata arrays cost 758 B of runtime
    ///      (the array walk, two high-level calls and their decoders), the same two checks
    ///      as Solidity ~400 B; these are two raw `staticcall`s with the errors encoded by
    ///      hand. EQUIVALENT SOLIDITY:
    ///
    ///          if (g.orderHash != 0 && SETTLEMENT.filled(g.orderHash) != g.expectedFilled)
    ///              revert OrderTaken(0, g.expectedFilled, <actual>);
    ///          if (g.liveNonce && SETTLEMENT.isNonceCancelled(maker, nonce))
    ///              revert NonceTaken(0, maker, nonce);
    ///
    ///      A failed or short read fails CLOSED (it reads as taken / cancelled).
    function _raceGuard(ItemFillGuard calldata g, address maker, uint256 nonce) private view {
        address s = address(SETTLEMENT);
        bytes4 taken = OrderTaken.selector;
        bytes4 nonceTaken = NonceTaken.selector;
        /// @solidity memory-safe-assembly
        assembly {
            let h := calldataload(g) //                      g.orderHash
            if h {
                let expected := calldataload(add(g, 0x20)) // g.expectedFilled
                mstore(0x00, 0x288cdc91) //                    filled(bytes32)
                mstore(0x20, h)
                let ok := and(gt(returndatasize(), 0x1f), staticcall(gas(), s, 0x1c, 0x24, 0x00, 0x20))
                let actual := mload(0x00)
                if or(iszero(ok), iszero(eq(actual, expected))) {
                    let m := mload(0x40)
                    mstore(m, taken) //                        OrderTaken(0, expected, actual)
                    mstore(add(m, 0x04), 0)
                    mstore(add(m, 0x24), expected)
                    mstore(add(m, 0x44), actual)
                    revert(m, 0x64)
                }
            }
            // g.liveNonce
            if calldataload(add(g, 0x40)) {
                let m := mload(0x40)
                mstore(m, 0x5b8a7d48) //                       isNonceCancelled(address,uint256)
                mstore(add(m, 0x20), maker)
                mstore(add(m, 0x40), nonce)
                let ok := and(gt(returndatasize(), 0x1f), staticcall(gas(), s, add(m, 0x1c), 0x44, 0x00, 0x20))
                if or(iszero(ok), mload(0x00)) {
                    mstore(m, nonceTaken) //                   NonceTaken(0, maker, nonce)
                    mstore(add(m, 0x04), 0)
                    mstore(add(m, 0x24), maker)
                    mstore(add(m, 0x44), nonce)
                    revert(m, 0x64)
                }
            }
        }
    }

    /// @dev {executeItemFill}'s body, in its own frame (legacy-profile stack).
    function _executeItemFill(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmount,
        RoutePlan calldata plan,
        bytes calldata takerData,
        uint256 lateItems,
        ItemFillGuard calldata guard
    ) private returns (uint256[] memory fillAmountsOut) {
        // Armed BEFORE the plan build (2026-10-18): {_plan} admits a multi-input order
        // only on this entry and only for a {MULTI_ROUTE} (S-3; {onMatchRoute} pushes
        // the further input currencies to the sandbox), and reads the entry from this
        // state. Nothing between here and `matchSettle` makes a state-changing call
        // (the plan build and the receipt snapshots are `balanceOf` staticcalls), so
        // the NFT hooks, which accept in this state, cannot be reached before the plan.
        _active = 4;
        FillRoute memory route = _plan(order, plan);
        if (route.direct) revert DirectNotMatchable();
        if (guard.receipts.length != 0) _addReceipts(route, guard.receipts);
        bytes memory cd = _matchCalldata(order, sig, fillAmount, takerData, route, lateItems);
        fillAmountsOut = _callMatch(cd);
        // Same reasoning as {executeFill}: a plan whose CALL never reached
        // {onMatchRoute} delivered out of something other than this fill's route.
        if (_active != 5) {
            _active = 1;
            revert CallbackDidNotRun();
        }

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

    /// @dev The one-order plan {executeItemFill} runs — see the step list there —
    ///      as the finished `matchSettle(MatchPlan)` CALLDATA. Token indices are
    ///      Settlement's universe indices: `matchSettle` derives its universe as the
    ///      order's input tokens then its output tokens, first occurrence kept — the
    ///      SAME rule {_plan} builds `route.tokens` by, so a `PRESEND` index here names
    ///      the same token there.
    ///
    ///      HAND-ENCODED (2026-10-15, size pass). NOT done for `fillWithCallback` on
    ///      purpose: the same treatment there measured −842 B but +1,261 gas on EVERY
    ///      `executeFill` (the compiler's calldata re-encoder is cheaper than a sized,
    ///      separately allocated buffer plus a copy of the callback blob) — the hot
    ///      path pays for size it does not need. Building a `MatchPlan memory` meant
    ///      copying the calldata `Order` into memory field by field (six `bytes`
    ///      decodes) and then ABI-encoding the nested `Order[]`/`bytes[]` struct back
    ///      out — two general coders for one fixed shape. Measured on the deployed
    ///      profile: −789 B runtime (23,566 → 22,777), −7.0k gas per item fill, −42 gas
    ///      on every `executeFill` (the shared code got smaller). The encoding below is
    ///      the canonical ABI encoding of the same plan, written once into memory
    ///      allocated up front:
    ///
    ///        selector ‖ 0x20 ‖ T: [8-word head: offsets of orders, sigs, fillAmounts,
    ///        takerDatas, schedule, callTargets, callDatas; profitRecipient = this]
    ///        ‖ orders = [1, 0x20, Order tuple] ‖ sigs = [1, 0x20, sig]
    ///        ‖ fillAmounts = [1, fillAmount] ‖ takerDatas = [1, 0x20, takerData]
    ///        ‖ schedule ‖ callTargets = [1, this] ‖ callDatas = [1, 0x20, onMatchRoute]
    ///
    ///      The Order tuple is re-encoded CANONICALLY by {_putOrder}: its 15 head words
    ///      are copied and its six `bytes` tails rewritten in field order through the
    ///      compiler's own bounds-checked calldata accessors, so a non-canonical input
    ///      encoding cannot change what Settlement decodes. Static head words are copied
    ///      raw: a dirty address word is not cleaned here, and Settlement's decoder
    ///      rejects it (fails closed) exactly as the copy into memory used to.
    function _matchCalldata(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmount,
        bytes calldata takerData,
        FillRoute memory route,
        uint256 lateItems
    ) private view returns (bytes memory cd) {
        uint256[] memory schedule;
        {
            uint256 nItems = PackedArrays.countUnchecked(order.items);
            if (lateItems >> nItems != 0) revert BadItemSchedule();
            schedule = _schedule(nItems, PackedArrays.countUnchecked(order.legsIn), route, lateItems);
        }
        cd = _writeMatch(order, sig, fillAmount, takerData, schedule, abi.encodeCall(this.onMatchRoute, (route)));
    }

    /// @dev {_matchCalldata}'s writer, in its own frame (legacy-profile stack).
    function _writeMatch(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmount,
        bytes calldata takerData,
        uint256[] memory schedule,
        bytes memory cb
    ) private view returns (bytes memory cd) {
        // Size first, allocate once, then write: no allocation can land inside the
        // buffer while it is being filled.
        cd = _alloc(
            0x24 + 0x100 // selector + tuple offset + tuple head
                + 0x40 + _orderSize(order) // orders
                + 0x60 + _ceil32(sig.length) // sigs
                + 0x40 // fillAmounts
                + 0x60 + _ceil32(takerData.length) // takerDatas
                + ((schedule.length + 1) << 5) // schedule
                + 0x40 // callTargets
                + 0x60 + _ceil32(cb.length) // callDatas
        );
        uint256 T;
        uint256 t;
        bytes4 sel = Batch.matchSettle.selector; // declared on Batch; not reachable via the derived name
        /// @solidity memory-safe-assembly
        assembly {
            mstore(add(cd, 0x20), sel)
            mstore(add(cd, 0x24), 0x20)
            T := add(cd, 0x44)
            t := add(T, 0x100)
            mstore(T, 0x100) //                     orders
            mstore(t, 1)
            mstore(add(t, 0x20), 0x20)
            t := add(t, 0x40)
        }
        t = _putOrder(order, t);
        /// @solidity memory-safe-assembly
        assembly {
            mstore(add(T, 0x20), sub(t, T)) //      sigs
        }
        t = _putBytes1(t, sig);
        /// @solidity memory-safe-assembly
        assembly {
            mstore(add(T, 0x40), sub(t, T)) //      fillAmounts
            mstore(t, 1)
            mstore(add(t, 0x20), fillAmount)
            t := add(t, 0x40)
            mstore(add(T, 0x60), sub(t, T)) //      takerDatas
        }
        t = _putBytes1(t, takerData);
        /// @solidity memory-safe-assembly
        assembly {
            mstore(add(T, 0x80), sub(t, T)) //      schedule (length word + steps)
            let w := shl(5, add(mload(schedule), 1))
            mcopy(t, schedule, w)
            t := add(t, w)
            mstore(add(T, 0xa0), sub(t, T)) //      callTargets = [this]
            mstore(t, 1)
            mstore(add(t, 0x20), address())
            t := add(t, 0x40)
            mstore(add(T, 0xc0), sub(t, T)) //      callDatas = [onMatchRoute(route)]
            mstore(t, 1)
            mstore(add(t, 0x20), 0x20)
            let l := mload(cb)
            mstore(add(t, 0x40), l)
            mcopy(add(t, 0x60), add(cb, 0x20), l)
            mstore(add(add(t, 0x60), l), 0)
            mstore(add(T, 0xe0), address()) //     profitRecipient: the sweep lands HERE, so
            //                                       the spread is split by policy
        }
    }

    /// @dev A `bytes` of `size` with +0x20 slack past its padded end: a tail is
    ///      zero-padded with one whole-word store that may reach one word beyond it.
    function _alloc(uint256 size) private pure returns (bytes memory b) {
        /// @solidity memory-safe-assembly
        assembly {
            b := mload(0x40)
            mstore(b, size)
            mstore(0x40, add(add(b, 0x40), and(add(size, 31), not(31))))
        }
    }

    function _ceil32(uint256 n) private pure returns (uint256) {
        return (n + 31) & ~uint256(31);
    }

    /// @dev Canonical encoded size of an `Order` tuple: 15 head words + six `bytes` tails.
    function _orderSize(Order calldata o) private pure returns (uint256) {
        return 0x1e0 + 0xc0 + _ceil32(o.legsIn.length) + _ceil32(o.legsOut.length) + _ceil32(o.curve.length)
            + _ceil32(o.items.length) + _ceil32(o.validators.length) + _ceil32(o.invariants.length);
    }

    /// @dev Write `o` canonically at `dst`; returns the end. Head copied (15 words), then
    ///      each `bytes` field's offset word rewritten and its tail appended — fields 2,
    ///      3, 8, 9, 10, 11 of {Order} (legsIn, legsOut, curve, items, validators,
    ///      invariants), each read through the compiler's bounds-checked accessor.
    function _putOrder(Order calldata o, uint256 dst) private pure returns (uint256 t) {
        /// @solidity memory-safe-assembly
        assembly {
            calldatacopy(dst, o, 0x1e0)
        }
        t = _putTail(dst, 2, dst + 0x1e0, o.legsIn);
        t = _putTail(dst, 3, t, o.legsOut);
        t = _putTail(dst, 8, t, o.curve);
        t = _putTail(dst, 9, t, o.items);
        t = _putTail(dst, 10, t, o.validators);
        t = _putTail(dst, 11, t, o.invariants);
    }

    /// @dev Field `field` of the tuple at `base` := offset of a new `bytes` tail at `t`.
    function _putTail(uint256 base, uint256 field, uint256 t, bytes calldata b) private pure returns (uint256) {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(add(base, shl(5, field)), sub(t, base))
            mstore(t, b.length)
            calldatacopy(add(t, 0x20), b.offset, b.length)
            mstore(add(add(t, 0x20), b.length), 0)
            t := add(add(t, 0x20), and(add(b.length, 31), not(31)))
        }
        return t;
    }

    /// @dev A one-element `bytes[]` at `t`: `[1, 0x20, b]`; returns the end.
    function _putBytes1(uint256 t, bytes calldata b) private pure returns (uint256) {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(t, 1)
        }
        return _putTail(t + 0x20, 0, t + 0x40, b); // element offset 0x20, then the tail
    }

    /// @dev Call `matchSettle` with the hand-encoded plan; bubble a revert verbatim (the
    ///      core's plan errors must reach the operator unchanged), and return `outs[0]`
    ///      — the delivered amounts of the one order — out of the `(uint256[][],
    ///      address[], uint256[])` return. Every read is a `returndatacopy`, which
    ///      reverts past the return buffer, and the inner length is bounded by it first.
    function _callMatch(bytes memory cd) private returns (uint256[] memory outs0) {
        address s = address(SETTLEMENT);
        /// @solidity memory-safe-assembly
        assembly {
            if iszero(call(gas(), s, 0, add(cd, 0x20), mload(cd), 0, 0)) {
                let p := mload(0x40)
                returndatacopy(p, 0, returndatasize())
                revert(p, returndatasize())
            }
            returndatacopy(0, 0, 0x20)
            let o := add(mload(0), 0x20) //            outs: first element-offset word
            returndatacopy(0, o, 0x20)
            let a := add(o, mload(0)) //               outs[0]: its length word
            returndatacopy(0, a, 0x20)
            let m := mload(0)
            if gt(m, shr(5, returndatasize())) { revert(0, 0) }
            outs0 := mload(0x40)
            let w := shl(5, add(m, 1))
            returndatacopy(outs0, a, w)
            mstore(0x40, add(outs0, w))
        }
    }

    /// @dev The step list of {_matchCalldata}, in its own frame (legacy-profile stack).
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

    /// @notice {sweep} for many tokens in ONE transaction: every token's balance above
    ///         `keep` goes to `to`. `keep = 1` leaves the self-seeded 1-wei floors (the
    ///         routine payout — the next fill's balance write stays a warm non-zero →
    ///         non-zero SSTORE); `keep = 0` empties the contract (retiring an instance).
    ///         A token at or below `keep` is skipped, not refused, so a fixed token list
    ///         can be swept whatever has accrued.
    /// @dev    Same authority and the same safety argument as {sweep}: operators only,
    ///         never mid-fill, and nothing held here between fills belongs to anyone
    ///         else. The amount is read on-chain at execution, so a fill landing between
    ///         the operator's read and inclusion only changes what is swept — never makes
    ///         the batch revert. One `Swept` per token moved, as {sweep} emits.
    ///
    ///         WHY IT EXISTS (2026-10-15): retain mode parks the spread in up to one
    ///         balance per token the solver has been paid in. Paying it out token by
    ///         token cost a 21k-gas transaction base each, plus a calldata amount the
    ///         operator had to read first; here the base is paid once.
    function sweepAll(address[] calldata tokens, address to, uint256 keep) external {
        if (!isOperator(msg.sender)) revert NotOperator(msg.sender);
        if (_active != 1) revert Reentrancy();
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            uint256 bal = SafeTransferLib.balanceOf(token, address(this));
            if (bal > keep) {
                unchecked {
                    bal -= keep;
                }
                SafeTransferLib.safeTransfer(token, to, bal);
                emit Swept(token, to, bal);
            }
        }
    }

    /// @dev Run the maker's ERC-2612 permits before the fill (2026-10-12) — the
    ///      gasless-maker funding path, in the fill transaction itself instead of a
    ///      separate relay transaction.
    ///
    ///      `token.permit(owner, SETTLEMENT, value, deadline, v, r, s)`: the spender is
    ///      Settlement, never a caller choice, because Settlement's direct-approval
    ///      fallback (`Base._pullViaPermit3`: the Permit3 leg fails → plain
    ///      `transferFrom` from a NON-STRICT maker) is what pulls the input with it.
    ///      A maker in Permit3 strict mode for that token gets no fallback: the permit
    ///      lands, the pull reverts `Permit3Denied` and the fill with it.
    ///
    ///      `owner` MUST BE THE ORDER'S MAKER. This entry is operator-gated, but it
    ///      should not become a relay for arbitrary third-party permits: only the
    ///      party whose order is filling can be the one whose allowance it sets — and
    ///      that party signed the permit for exactly this purpose.
    ///
    ///      The permit is PUBLIC (it travels with the order), so anyone may submit it
    ///      first and the token's nonce then makes ours revert. That is success, not
    ///      failure: a failed call is accepted when Settlement's allowance from the
    ///      owner already covers `value` (relayed, front-run, or approved directly),
    ///      and refused ({PermitFailed}) otherwise — before anything moves. A low-level
    ///      call, so a token without `permit` (or that reverts) lands in that check
    ///      rather than bubbling; the selector and arguments are fixed, so the call
    ///      can make the named contract do nothing but what a `permit` from this
    ///      address means to it (no core contract has that selector — pinned in
    ///      `test/AggregatorPoolRoute.t.sol`).
    function _permits(Permit2612[] calldata ps, address maker) private {
        address spender = address(SETTLEMENT);
        for (uint256 i; i < ps.length; ++i) {
            Permit2612 calldata p = ps[i];
            if (p.owner != maker) revert PermitOwnerNotMaker(p.owner);
            address token = p.token;
            uint256 value = p.value;
            uint256 deadline = p.deadline;
            uint8 v = p.v;
            bytes32 r = p.r;
            bytes32 s_ = p.s;
            bool ok;
            // EQUIVALENT SOLIDITY (the pre-2026-10-12 body): `(ok,) = token.call(
            //   abi.encodeWithSelector(0xd505accf, maker, spender, value, deadline, v, r, s))`
            // — the same 228 calldata bytes, encoded in free memory without allocating;
            // the return data is not copied (it was discarded).
            /// @solidity memory-safe-assembly
            assembly {
                let m := mload(0x40)
                mstore(m, 0xd505accf00000000000000000000000000000000000000000000000000000000) // permit(...)
                mstore(add(m, 0x04), maker)
                mstore(add(m, 0x24), spender)
                mstore(add(m, 0x44), value)
                mstore(add(m, 0x64), deadline)
                mstore(add(m, 0x84), v)
                mstore(add(m, 0xa4), r)
                mstore(add(m, 0xc4), s_)
                ok := call(gas(), token, 0, m, 0xe4, 0x00, 0x00)
            }
            if (!ok && _allowance(token, maker, spender) < value) revert PermitFailed(token);
        }
    }

    /// @dev `token.allowance(owner, spender)`; a failed or short read counts as zero.
    ///      EQUIVALENT SOLIDITY (the pre-2026-10-18 body, −~100 B as assembly):
    ///      `(bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSelector(
    ///      0xdd62ed3e, owner, spender)); if (ok && ret.length >= 32) a = abi.decode(ret,
    ///      (uint256));` — the same call; the return data is read from scratch space.
    function _allowance(address token, address owner, address spender) private view returns (uint256 a) {
        /// @solidity memory-safe-assembly
        assembly {
            let m := mload(0x40)
            mstore(m, 0xdd62ed3e00000000000000000000000000000000000000000000000000000000) // allowance(address,address)
            mstore(add(m, 0x04), owner)
            mstore(add(m, 0x24), spender)
            // Arguments evaluate right to left: the call runs before `mload(0)` is read.
            a := mul(mload(0x00), and(gt(returndatasize(), 0x1f), staticcall(gas(), token, m, 0x44, 0x00, 0x20)))
        }
    }

    /// @dev Split this fill's INCREASE in `token` — the spread, in whichever
    ///      denomination it landed — per the {SurplusPolicy} and the plan's
    ///      originator share. A no-op when nothing was left over, which is the
    ///      normal case for a route quoted at the maker's price. Shares floor;
    ///      the filler takes the rounding dust along with its remainder, so
    ///      nothing strands here — except, ONCE per token, the self-seeded 1-wei
    ///      balance floor (below), which is the filler's own.
    ///
    ///      `plan.originatorPpm` was bounded in {_plan}, BEFORE the fill, so a
    ///      mis-set share fails the round rather than reverting after the maker
    ///      has already been paid.
    ///
    ///      NO EVENT (2026-10-12): the per-token `SurplusSplit` log (LOG3 + four
    ///      words) cost 2,653 gas per fill and nothing read it. The shares are the
    ///      ERC-20 `Transfer` logs this function's own transfers already emit.
    function _splitSurplus(address token, uint256 before, address maker, RoutePlan calldata plan, address filler)
        private
    {
        uint256 bal = SafeTransferLib.balanceOf(token, address(this));
        if (bal <= before) return;
        uint256 surplus = bal - before;

        uint256 toMaker;
        uint256 toProtocol;
        uint256 toOriginator;
        uint256 toFiller = surplus;
        // No share but the filler's (the beta configuration: no immutable policy, no
        // originator) skips the three products — `SEED_INPUT` is exactly "maker and
        // protocol ppm both 0", and a zero `originatorPpm` floors to zero anyway.
        if (!SEED_INPUT || plan.originatorPpm != 0) {
            toMaker = (surplus * MAKER_SURPLUS_PPM) / PPM;
            toProtocol = (surplus * PROTOCOL_SURPLUS_PPM) / PPM;
            toOriginator = (surplus * plan.originatorPpm) / PPM;
            // The sum of the three ppm values is ≤ PPM (checked in `_plan`), so the
            // three floors sum to ≤ surplus and this cannot underflow.
            toFiller = surplus - toMaker - toProtocol - toOriginator;

            if (toMaker != 0) SafeTransferLib.safeTransfer(token, maker, toMaker);
            if (toProtocol != 0) SafeTransferLib.safeTransfer(token, PROTOCOL_RECIPIENT, toProtocol);
            if (toOriginator != 0) SafeTransferLib.safeTransfer(token, plan.originator, toOriginator);
        }
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
    }

    /// @dev {ItemFillGuard.receipts}: append each foreign receipt token after the
    ///      order's own (so Settlement's universe indices — PRESEND — are unchanged) and
    ///      snapshot it with them, before anything moves. From then on it is one more
    ///      route token: pushed to the sandbox on a {MULTI_ROUTE} ({_pushExtras}), swept
    ///      back, split. Item path only (never direct: every order token is snapshotted).
    ///      `r.tokens` is {_plan}'s `new address[](MAX_TOKENS)` shrunk to its count, so it
    ///      is grown IN PLACE back to that capacity (no copy), slotted ({TooManyTokens}
    ///      past it), and shrunk again; `before` is reallocated.
    function _addReceipts(FillRoute memory r, address[] calldata extra) private view {
        address[] memory toks = r.tokens;
        uint256 n = toks.length;
        /// @solidity memory-safe-assembly
        assembly {
            mstore(toks, MAX_TOKENS) // the capacity {_plan} allocated
        }
        uint256 m = n;
        for (uint256 i; i < extra.length; ++i) {
            (, m) = _slot(toks, m, extra[i]);
        }
        /// @solidity memory-safe-assembly
        assembly {
            mstore(toks, m)
        }
        uint256[] memory bef = new uint256[](m);
        uint256[] memory old = r.before;
        for (uint256 k; k < m; ++k) {
            bef[k] = k < n ? old[k] : SafeTransferLib.balanceOf(toks[k], address(this));
        }
        r.before = bef;
    }

    /// @dev Resolve the route against the order, in its OWN frame: the two decoded
    ///      token addresses and the two snapshots push {executeFill} past the stack
    ///      limit under the legacy (non-via-IR) profile this package compiles with
    ///      — the same split the settlement makes in its own fill helpers.
    ///
    ///      ⚠ THE LEG COUNTS ARE CHECKED HERE and nowhere else on this path.
    ///      {PackedArrays} reads a leg without consulting the blob's count byte,
    ///      and {PackedArrays.validateFixed} tolerates trailing bytes — so a
    ///      `legsOut` of `0x00 ‖ <104 bytes>` settles as ZERO output legs (the
    ///      caller owes the maker nothing) while still naming a token here. Every
    ///      leg read below is bounded by those counts (the loops; {_payee} and
    ///      {_nativeLeg} read leg 0 only with `nOut != 0`), so a zero-leg side names
    ///      nothing. ZERO INPUT LEGS (an NFT sale: the asset is a SETTLE receipt) and
    ///      ZERO OUTPUT LEGS (nothing to deliver — a route-less fill) are admitted
    ///      since 2026-10-18 (review S-2 / S-7); only both empty is {NoLegs}. With no
    ///      input leg `tokens[0]` is the first OUTPUT token: nothing is pre-sent, the
    ///      route has no anchor delta to push (zero).
    function _plan(Order calldata order, RoutePlan calldata plan) private view returns (FillRoute memory r) {
        // Read in place from CALLDATA (2026-10-12; was a memory copy of each blob via
        // {PackedArraysMem} — the same validation and the same unchecked readers).
        bytes calldata legsIn = order.legsIn;
        bytes calldata legsOut = order.legsOut;
        uint256 nIn = PackedArrays.validateFixed(legsIn, PackedArrays.LEG_IN_STRIDE);
        uint256 nOut = PackedArrays.validateFixed(legsOut, PackedArrays.LEG_OUT_STRIDE);
        if (nIn + nOut == 0) revert NoLegs();
        // Both share {FillRoute.maxPay}'s word (low / high 128 bits — packed, not a new
        // field: a word costs every fill ~300 gas through the callback round trip).
        if ((plan.maxPay | plan.inventory) >> 128 != 0) revert AmountTooLarge();
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
            (k, n) = _slot(toks, n, PackedArrays.legInToken(legsIn, i));
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
            address t = PackedArrays.legOutToken(legsOut, j);
            // NATIVE DELIVERY (task 30): a `NativeBalance` leg 0 is measured, routed and
            // split as WNATIVE — the token the route actually produces here. One
            // compare on the hot path; the shape checks ({_nativeLeg}) run after the
            // loop, only on a hit. (Calling {_nativeLeg} from inside the loop, or
            // testing `toks[outAnchor]` after it, measured 50–70 gas worse on the
            // deployed pull fill — via-IR stack pressure, not the compare.)
            if (t == NATIVE_BALANCE && j == 0) {
                t = WNATIVE;
                r.legs = LEGS_NATIVE;
            }
            (k, n) = _slot(toks, n, t);
            uint256 bit = 1 << k;
            r.outMask |= bit;
            // An output leg in the anchor input token ({LEGS_SAME}; see {FillRoute.legs} —
            // a leg past index 126 is masked off rather than tested for: −17 gas).
            if (k == 0) r.legs |= (1 << j) & LEGS_SAME;
            if (!anchored) {
                // A NATIVE leg 0 anchors at once: its WNATIVE slot is the one the unwrap
                // measures, also when the maker pays WNATIVE in (S-7).
                anchored = r.inMask & bit == 0 || r.legs & LEGS_NATIVE != 0;
                if (j == 0 || anchored) r.outAnchor = k;
            }
        }
        // MULTI-INPUT (review 2026-10-18 S-3): an input token that is neither the anchor
        // nor an output token is the maker's payment in a second currency. It must be
        // ROUTED, never silently split here as filler residue — and only the netted entry
        // with a {MULTI_ROUTE} routes it ({onMatchRoute} pushes it to the sandbox; the
        // entry is told apart by `_active`, which {executeItemFill} arms to 4 before this
        // runs and {executeFill} leaves at 1). Everything else refuses the shape. A
        // non-anchor token that is ALSO an output nets in place against its output legs.
        // One check site, not one per entry: measured −240 B on the deployed profile.
        if (r.inMask & ~r.outMask & ~uint256(1) != 0 && (plan.router != MULTI_ROUTE || _active != 4)) {
            revert MultiInputUnrouted();
        }
        /// @solidity memory-safe-assembly
        assembly {
            mstore(toks, n) // shrink to the n slots actually used
        }
        if (r.legs & LEGS_NATIVE != 0) _nativeLeg(order, r);
        r.tokens = toks;
        r.before = new uint256[](n);
        for (uint256 k; k < n; ++k) {
            if (r.direct && r.inMask & (1 << k) == 0) continue;
            r.before[k] = SafeTransferLib.balanceOf(toks[k], address(this));
        }
        // A native order's `payee` is the native recipient, set by {_nativeLeg}; its
        // pool route pays HERE ({_poolRoute}). Every other pool route's last hop pays
        // `legsOut[0]`'s recipient (direct) or this contract (pull) — and a DIRECT
        // inventory draw tops up that same recipient ({_topUp}). (An EMPTY pool route
        // pays nobody; resolving its payee anyway costs one leg read, and on a direct
        // order with no output leg — nothing to deliver — it refuses {NoLegs}.)
        if ((plan.router == POOL_ROUTE || (plan.inventory != 0 && r.direct)) && r.legs & LEGS_NATIVE == 0) {
            r.payee = _payee(order, legsOut, toks[r.outAnchor], r.direct);
        }
        // The out-leg mask. DIRECT: leg 0 alone, also whenever the callback needs that
        // leg's live price without patching it — a native unwrap or a direct inventory
        // top-up (both TYPED; the mask is what hands `pricedOut[0]` to {_onFill}).
        if (r.direct) {
            if (plan.amountOutOffset < NO_PATCH || plan.inventory != 0 || r.legs & LEGS_NATIVE != 0) {
                r.legs |= 1 << LEGS_OUT_SHIFT;
            }
        } else if (plan.amountOutOffset < NO_PATCH) {
            r.legs |= _outLegs(legsOut, nOut, toks[r.outAnchor]);
        }
        r.router = plan.router;
        r.minOut = plan.minOut;
        r.maxPay = plan.maxPay | plan.inventory << 128;
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

    /// @dev A native order's leg 0 (`legsOut[0].token == NATIVE_BALANCE`, already
    ///      slotted as WNATIVE by {_plan}, so the route's anchor output, `minOut` /
    ///      `maxPay`, the sandbox sweep and the surplus split all see the token that
    ///      actually lands here): check the shape, record the recipient in `payee`, and
    ///      flag the WNATIVE slot in `inMask` — "paid to this contract during the
    ///      fill" — which is exactly what makes the snapshot, the {RouteOverspent}
    ///      check and the split include it with no extra test on the hot path (a
    ///      direct order skips only tokens outside `inMask`). {NativeLegShape} unless:
    ///        • the order is DIRECT — on the pull path the core would `transferFrom`
    ///          the view token and revert after the route ran; refuse before it;
    ///        • no other leg, input or output, names NATIVE_BALANCE — a second native
    ///          delivery this contract does not make;
    ///        • no other OUTPUT leg pays the same recipient — one native send must not
    ///          satisfy a second native view's delta check (review L-1).
    ///      WNATIVE ITSELF IS ADMITTED next to the native leg since 2026-10-18 (review
    ///      S-7; it used to be refused):
    ///        • as an INPUT (the maker pays WRBTC, alone or beside another token): it
    ///          lands in the native slot before the route. As `legsIn[0]` its priced
    ///          leg-0 amount is KEPT BACK ({LEGS_SAME} — a pure unwrap needs no route at
    ///          all: an empty route sends `pricedOut[0]` out of the maker's own WRBTC);
    ///          as a later input it is the slot's pre-route inflow, netted out of the
    ///          `minOut` test ({_inflow}) and spendable by the unwrap;
    ///        • as a further OUTPUT leg (a relayer / originator fee in WRBTC): the core
    ///          delta-verifies it at its recipient. Paid to THIS contract (the filler's
    ///          own fee) it is simply what the route produced beyond the unwrapped
    ///          `pricedOut[0]` — any route works; paid to a third party, the route must
    ///          pay it there itself (an opaque / {MULTI_ROUTE}; a pool route's last hop
    ///          pays only here, and the core then fails it `DeltaTooLow`, closed). The
    ///          core's own `DeltaVerifySameToken` refuses a WRBTC fee leg next to a WRBTC
    ///          input.
    ///      The recipient comes from the ORDER (`address(0)` = the maker), never a
    ///      plan field: a route cannot redirect the coin. Runs only on native orders.
    function _nativeLeg(Order calldata order, FillRoute memory r) private view {
        bytes calldata legsIn = order.legsIn;
        bytes calldata legsOut = order.legsOut;
        address nb = NATIVE_BALANCE;
        // `nb == 0` (native delivery off) reaches here only for a leg naming token
        // `address(0)`, which no path can settle: refuse it the same way.
        if (!r.direct || nb == address(0)) revert NativeLegShape();
        uint256 nIn = PackedArrays.countUnchecked(legsIn); // validated by the caller
        for (uint256 i; i < nIn; ++i) {
            address t = PackedArrays.legInToken(legsIn, i);
            if (t == nb) revert NativeLegShape();
        }
        (,,, address to) = PackedArrays.legOut(legsOut, 0);
        address payee = to == address(0) ? order.maker : to;
        uint256 nOut = PackedArrays.countUnchecked(legsOut);
        for (uint256 j = 1; j < nOut; ++j) {
            (address t,,, address rj) = PackedArrays.legOut(legsOut, j);
            // No other leg to the SAME recipient (review 2026-10-14 L-1): a second
            // native view — another `NativeBalance` deployment, or any token whose
            // `balanceOf` reads `a.balance` — would be satisfied by this one send,
            // because the core's duplicate-leg guard compares token ADDRESSES. A
            // fee leg to someone else is unaffected.
            if (t == nb || (rj == address(0) ? order.maker : rj) == payee) revert NativeLegShape();
        }
        r.payee = payee;
        r.inMask |= 1 << r.outAnchor;
    }

    /// @dev {FillRoute.legs}' out-leg mask on a PULL order — which output legs' priced
    ///      amounts the exact-output word carries (task 16; before it the word took
    ///      `pricedOut[0]` whatever the anchor): every leg in the anchor output token,
    ///      because the core pulls each of them from here — a fee leg listed before
    ///      the maker's (`[tokenIn fee, tokenOut]`, `[tokenOut fee, tokenOut]`) used to
    ///      make the word the FEE, and the pull then failed. A DIRECT order's mask is
    ///      leg 0 alone and is set inline by {_plan} (the leg the route — a pool route's
    ///      last hop — pays; a second leg in the same token goes to a different
    ///      recipient, `DeltaVerifyDuplicateLeg`, and the route must pay it itself).
    ///      Only computed when `amountOutOffset` is set. Returned already shifted into
    ///      {FillRoute.legs}' out-leg bits.
    function _outLegs(bytes calldata legsOut, uint256 nOut, address anchorOut) private pure returns (uint256 m) {
        if (nOut > 256 - LEGS_OUT_SHIFT) nOut = 256 - LEGS_OUT_SHIFT;
        for (uint256 j; j < nOut; ++j) {
            if (PackedArrays.legOutToken(legsOut, j) == anchorOut) m |= 1 << (LEGS_OUT_SHIFT + j);
        }
    }

    /// @dev A pool route's final recipient, from the ORDER: on a direct order the
    ///      recipient of `legsOut[0]` (`address(0)` = the maker) — the leg whose live
    ///      price `amountOutOffset` patches in and whose delta the core verifies —
    ///      which must be paid in the anchor output token the path ends in; on a pull
    ///      order this contract, so the proceeds are measured, floored and approved
    ///      exactly as on an opaque route. Never a plan field: a route cannot pay
    ///      anyone the order does not.
    function _payee(Order calldata order, bytes calldata legsOut, address anchorOut, bool direct)
        private
        view
        returns (address to)
    {
        if (!direct) return address(this);
        if (PackedArrays.countUnchecked(legsOut) == 0) revert NoLegs(); // leg 0 is read below (validated count)
        address token;
        (token,,, to) = PackedArrays.legOut(legsOut, 0);
        if (token != anchorOut) revert BadPoolRoute();
        if (to == address(0)) to = order.maker;
    }

    /// @dev Whether this fill needs the TYPED callback: only when the plan uses a
    ///      priced amount — an output leg in the anchor input token to keep back
    ///      (`sameOut`), or an output word to patch (`amountOutOffset`). Every other
    ///      fill stays on the untyped {onFill}, because the typed payload is not free:
    ///      the core prices every leg a second time and re-encodes the route into a
    ///      larger blob — measured +5.9k execution gas on the direct two-token
    ///      benchmark (`test_gas_direct_seeded_liveAmountOut` vs `test_gas_direct_seeded`
    ///      in `test/AggregatorFillGas.t.sol`).
    ///
    ///      A NATIVE order is always typed: the amount to unwrap and send is the core's
    ///      `pricedOut[0]`, and the typed payload is the only place this contract learns
    ///      it without re-pricing the order itself (FillRecovery: carrying the order in
    ///      the callback plus a second {Pricing} pass — more gas than the ~+5.9k typed
    ///      premium, and more code). Sending the whole WNATIVE delta instead would hand
    ///      the spread to the maker and starve the {SurplusPolicy}.
    function _typed(FillRoute memory route) private pure returns (bool) {
        return route.legs != 0 || route.amountOutOffset < NO_PATCH;
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
    ///      the anchor legs ({RoutePlan.amountOutOffset}) — see the ⚠ note on resolved
    ///      amounts.
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
        if (offset >= NO_PATCH) return;
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
    ///           • with `amountOutOffset` set, the route's output word is the live price
    ///             of the anchor legs (task 16) — a direct SELL then pays the maker
    ///             exactly what the core verifies and the decay since the quote stays
    ///             here as residue;
    ///           • a NATIVE order unwraps and sends `pricedOut[0]` ({_payNative}).
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
        uint256 legs = r.legs;
        uint256 outLegs = legs >> LEGS_OUT_SHIFT;
        // Leg 0 alone (every direct order, every single-output pull order) is read
        // straight: the loop's one iteration measured ~320 gas more on the deployed
        // typed direct fill.
        // A DIRECT inventory top-up (S-1) measures what the route paid leg 0's
        // recipient, so read that balance before the route runs.
        bool topUp = r.direct && r.maxPay >> 128 != 0 && legs & LEGS_NATIVE == 0;
        uint256 pre;
        if (topUp) pre = SafeTransferLib.balanceOf(r.tokens[r.outAnchor], r.payee);
        uint256 floor = _onFill(
            r,
            _sumLegs(legs & LEGS_SAME, pricedOut),
            r.amountOutOffset,
            outLegs == 1 ? pricedOut[0] : _sumLegs(outLegs, pricedOut)
        );
        // NATIVE DELIVERY: the route left WNATIVE here; unwrap exactly the priced leg
        // and send it on. The core measures the recipient's native balance next.
        if (legs & LEGS_NATIVE != 0) _payNative(r, pricedOut[0], floor);
        else if (topUp) _topUp(r, pricedOut[0], pre);
    }

    /// @dev Pay a native order's leg 0 (task 30): `amount` = the core's `pricedOut[0]`,
    ///      exactly what its delta check will demand — never the WNATIVE delta, so the
    ///      spread over the priced amount STAYS here in WNATIVE and is split by the
    ///      {SurplusPolicy} after the fill, like any output surplus.
    ///
    ///      `minOut` and `maxPay` keep their pull-path meaning, measured in WNATIVE
    ///      (the anchor output token for such an order): the route's WNATIVE proceeds
    ///      must reach `floor` — the (pro-rata, {_minOut}) `minOut` plus any WNATIVE the
    ///      maker paid in before the route ({_inflow}, S-7) — ({InsufficientOutput}), and
    ///      the amount sent may not exceed `maxPay` (non-zero) nor the delta itself plus
    ///      the plan's {RoutePlan.inventory} draw (bounded by the pre-fill WNATIVE) —
    ///      never the contract's balance, so a retained WNATIVE floor or another fill's
    ///      residue cannot fund a send the operator did not cap.
    ///
    ///      The send is a full-gas `call` to a recipient taken from the ORDER (smart
    ///      accounts work; a reverting `receive()` kills the fill — {NativeSendFailed},
    ///      `NativeUnwrapModule`'s posture). Re-entry from that `receive()` finds every
    ///      entry closed: `_active` is 3 here (executeFill / sweep revert {Reentrancy},
    ///      both callbacks {NotArmed}, the pool callback is not `SWAPPING`), and
    ///      Settlement is `nonReentrant`. A recipient that spends native in its
    ///      `receive()` lowers its own measured delta, and the core reverts.
    ///
    ///      GAS (unit bench, `AggregatorNativeTest`): the withdraw plus the value call.
    ///      A recipient account that is EMPTY (no balance, nonce or code — a fresh
    ///      gasless maker) costs the EVM's +25k new-account charge on top.
    function _payNative(FillRoute calldata r, uint256 amount, uint256 floor) private {
        uint256 cap = _cap(r, WNATIVE, r.before[r.outAnchor], floor);
        if (amount > cap) revert InsufficientOutput(cap, amount);
        IWNative(WNATIVE).withdraw(amount);
        address to = r.payee;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeSendFailed(to);
    }

    /// @dev DIRECT inventory top-up (review 2026-10-18 S-1): the route has paid leg 0's
    ///      recipient (`payee`, from the ORDER) whatever it paid; send the SHORTFALL
    ///      against the core's live `pricedOut[0]` (`owed`) out of this contract's own
    ///      balance, at most {RoutePlan.inventory}. `pre` is the recipient's balance at
    ///      callback entry — the same figure the core snapshotted (a direct order's
    ///      output tokens are never input tokens, `DeltaVerifySameToken`), so the
    ///      shortfall is exactly what the core's delta check would miss. Never more:
    ///      a route that already paid in full draws nothing.
    function _topUp(FillRoute calldata r, uint256 owed, uint256 pre) private {
        address t = r.tokens[r.outAnchor];
        address to = r.payee;
        uint256 got = SafeTransferLib.balanceOf(t, to) - pre;
        if (got >= owed) return;
        uint256 need;
        unchecked {
            need = owed - got;
        }
        uint256 inv = r.maxPay >> 128;
        // Past the cap the core's own delta check fails the fill (`DeltaTooLow`).
        SafeTransferLib.safeTransfer(t, to, need < inv ? need : inv);
    }

    /// @dev The body of both {executeFill} callbacks — see {_route} for `kept`,
    ///      `outOffset` and `amountOut`.
    ///      Returns the anchor output's floor ({_cap}) — for {onSettlementFill}'s native
    ///      unwrap on a direct order, which {_onFill} itself never pays.
    function _onFill(FillRoute calldata r, uint256 kept, uint256 outOffset, uint256 amountOut)
        private
        returns (uint256 floor)
    {
        // Read BEFORE the route: the pre-route inflow is part of the floor, see {_inflow}.
        floor = _inflow(r);
        floor += _minOut(r, _route(r, kept, outOffset, amountOut));

        // Direct delivery: the route paid the maker, the core verifies the delta,
        // and this contract has nothing to measure and nothing to approve here (the
        // typed callback then pays a NATIVE leg or an inventory top-up).
        if (r.direct) return floor;

        // Settlement pulls every output leg next, through the direct-approval path.
        // Approve each output token at ITS OWN proceeds of this fill — never the
        // contract's balance — and, for the anchor output token, at most `maxPay`:
        //   • it CAPS the pull — a fill that would take more reverts here rather
        //     than in the solver's P&L;
        //   • the surplus is never approved, so the spread stays this contract's
        //     and no allowance survives the fill over it.
        // `maxPay == 0` means "no cap", and the cap it then takes is THIS FILL's
        // proceeds (plus the capped inventory draw) — the maker's signed band is still
        // the hard bound, so the worst case is the price the solver evaluated when it
        // bid. A `maxPay` above that is clamped for the same reason: an over-stated cap
        // must not reach into residue.
        _payOutputs(r, floor, false);
    }

    /// @dev Σ `pricedOut[j]` over the output legs flagged in `mask`. With `sameOut`:
    ///      what the core will pull back in `tokens[0]`, so it is not routed. With
    ///      the out-leg mask: the exact-output word (task 16). Zero (one test) on an empty mask.
    function _sumLegs(uint256 mask, uint256[] calldata pricedOut) private pure returns (uint256 sum) {
        for (uint256 j; mask != 0; ++j) {
            if (mask & 1 != 0) sum += pricedOut[j];
            mask >>= 1;
        }
    }

    /// @dev What this fill paid INTO this contract in the anchor output token BEFORE
    ///      the route ran — added to `minOut` to form the floor the anchor output's
    ///      whole-fill delta must reach. Non-zero only when the anchor output is also a
    ///      (non-anchor) input token (every output token is; see {_plan}) — the maker's
    ///      own input leg on the pull path, the PRESEND on the netted path, a NATIVE
    ///      order's WNATIVE input (S-7) — and without it the delta measured afterwards
    ///      would count that inflow as route proceeds, so the maker's input could
    ///      satisfy the solver's `minOut` by itself (review 2026-10-05). Read at callback
    ///      entry: inputs have landed, nothing has been routed. Zero for `tokens[0]` even
    ///      when it is an output (a same-token order): {_route} pushes that inflow INTO
    ///      the route, so the post-route delta is already "what the route left or
    ///      produced".
    function _inflow(FillRoute calldata r) private view returns (uint256 x) {
        uint256 k = r.outAnchor;
        if (k != 0 && r.inMask & (1 << k) != 0) {
            x = SafeTransferLib.balanceOf(r.tokens[k], address(this)) - r.before[k];
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
    ///         comes back in the sweep. Two differences more since 2026-10-18: on a
    ///         {MULTI_ROUTE} every further input currency and listed receipt is pushed
    ///         to the sandbox too ({_pushExtras}, S-2 / S-3), and `minOut` stays ABSOLUTE
    ///         here — never scaled by {_minOut} — so `minOut` with `maxPay` remains a
    ///         hard floor on the item path's spread (S-6).
    function onMatchRoute(FillRoute calldata r) external {
        if (msg.sender != EXECUTOR) revert OnlyExecutor();
        if (_active != 4) revert NotArmed();
        _active = 5;

        // A MULTICALL route spends the order's further input currencies and the listed
        // receipts too (S-2 / S-3): push their deltas next to the anchor's.
        if (r.router == MULTI_ROUTE) _pushExtras(r.tokens, r.before, r.outMask);
        uint256 floor = _inflow(r);
        // Nothing kept back, nothing patched on the output side: PRESEND already
        // netted the pool's outstanding obligations, and no priced amount reaches a
        // `CALL` step (`amountOutOffset` is refused on this entry).
        _route(r, 0, NO_PATCH, 0);
        _payOutputs(r, floor + r.minOut, true);
    }

    /// @dev Run the route in {SANDBOX}: PUSH this fill's anchor input there, have it
    ///      call the target, take everything back, and check the bound. Returns the
    ///      amount ROUTED (the anchor delta pushed / budgeted) — {_minOut}'s input.
    ///
    ///      THE PUSHED AMOUNT IS A DELTA of `tokens[0]` against its pre-fill
    ///      snapshot — never a balance and never a caller-declared figure: what the
    ///      maker paid is Settlement's business and a fee-on-transfer `tokenIn`
    ///      would make any figure passed here wrong, while the raw balance would hand
    ///      the route whatever an earlier fill left parked here. Under-flowing is the
    ///      correct failure: it means the input never arrived. The same delta is
    ///      what the route's calldata is patched with. On a {MULTI_ROUTE} every other
    ///      non-output token's delta — a multi-input order's second currency, a listed
    ///      SETTLE receipt — is pushed with it ({_pushExtras}); NFT receipts are already
    ///      there ({onERC721Received}).
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
    ///      `kept` — the output legs owed in `tokens[0]` ({_sumLegs} over {LEGS_SAME}) — is subtracted from
    ///      that delta and never leaves this contract, saturating at zero: a
    ///      REDUCTION of the pushed amount is always safe (the route gets less of
    ///      this fill's own input), and a `kept` above the delta means the core's
    ///      pull of those legs fails anyway. `amountOut` is written at `outOffset`
    ///      ({NO_PATCH} = untouched).
    ///
    ///      AN EMPTY ROUTE (`router == POOL_ROUTE`, `data == ""`, review 2026-10-18 S-1)
    ///      calls nothing: the input stays here as residue and the outputs come from
    ///      {RoutePlan.inventory} — an inventory fill.
    function _route(FillRoute calldata r, uint256 kept, uint256 outOffset, uint256 amountOut)
        private
        returns (uint256 amountIn)
    {
        address tokenIn = r.tokens[0];
        uint256 before0 = r.before[0];
        amountIn = SafeTransferLib.balanceOf(tokenIn, address(this)) - before0;
        unchecked {
            amountIn = amountIn > kept ? amountIn - kept : 0;
        }
        if (before0 == 0) amountIn = _seedIn(r, amountIn);
        if (r.router == POOL_ROUTE) {
            // DIRECT POOL ROUTE: no push, no sandbox, no sweep — the pools are paid
            // from here inside their callbacks, bounded by `amountIn` (the same delta
            // the sandbox would have been pushed). An empty one is no route at all.
            if (r.data.length != 0) _poolRoute(r, amountIn, outOffset, amountOut);
        } else {
            if (amountIn != 0) SafeTransferLib.safeTransfer(tokenIn, address(SANDBOX), amountIn);
            SANDBOX.exec(
                tokenIn,
                r.router,
                _patched(r.data, r.amountInOffset, amountIn, outOffset, amountOut),
                _sweepOrder(r.tokens, r.outMask)
            );
        }
        _checkInputs(r.tokens, r.before, r.inMask);
    }

    /// @dev The anchor output floor for a route that swaps `routed`: `minOut`, scaled
    ///      DOWN pro rata when the route follows the fill (`amountInOffset` set) and
    ///      routes less than the amount its calldata was quoted for (review 2026-10-18
    ///      S-5). `minOut` then reads as a PRICE floor (`minOut / quoted` per unit of
    ///      input) rather than an absolute one, which is what makes the core's
    ///      remainder sentinel usable: a filler passes `fillAmount = type(uint256).max`
    ///      and, when a competitor filled part of the order first, settles the smaller
    ///      remainder at the quoted price instead of reverting `OverFill` (or
    ///      {InsufficientOutput} on the absolute floor). Never scaled UP, and never
    ///      without a patched input (the route then swaps its quoted figure, or fails).
    ///      The quoted figure is the word at `amountInOffset` as the operator sent it —
    ///      an unquoted placeholder (0 or below the routed amount) leaves `minOut` as is.
    ///      ⚠ It is TRUSTED as "the amount this route was quoted for" (review 2026-10-18
    ///      D-2): a word above the routed amount on a FULL fill — the whole `owed` with a
    ///      same-token fee leg kept back, a loose exact-output ceiling — lowers the floor
    ///      just the same, and `type(uint256).max` overflows the product (revert). That
    ///      lowers only the OPERATOR's own floor (the maker is bound by the core); the
    ///      rule for plan builders is on {RoutePlan.amountInOffset}. On an EMPTY route
    ///      the read lands past the blob (D-4): such a plan should carry {NO_PATCH}.
    ///      The maker is untouched (the core's band binds every fill); the operator's
    ///      price protection on {executeFill} is `minBumpBps`, which the core checks.
    ///      {executeFill} ONLY: the netted path ({onMatchRoute}) keeps `minOut` absolute
    ///      — it has no core bump floor, so `minOut − maxPay` is its spread floor (S-6),
    ///      and its races are answered by the {ItemFillGuard} instead of a clamp.
    function _minOut(FillRoute calldata r, uint256 routed) private pure returns (uint256 m) {
        m = r.minOut;
        uint256 off = r.amountInOffset;
        if (m != 0 && off < NO_PATCH) {
            bytes calldata d = r.data;
            uint256 quoted;
            // Unchecked read: an offset past the blob reads foreign calldata, and that
            // fill reverts anyway — {PatchOutOfBounds} on an opaque route, {BadPoolRoute}
            // / a short pool path on a pool route — before any floor is compared. (An
            // EMPTY route has no word to patch; it only lowers the operator's own floor.)
            /// @solidity memory-safe-assembly
            assembly {
                quoted := calldataload(add(d.offset, off))
            }
            // Rounded UP: never below the exact proportion (one withheld seed wei of a
            // 1e20 input leaves a 99e6 floor at 99e6, not 98,999,999).
            if (routed < quoted) m = (m * routed + quoted - 1) / quoted;
        }
    }

    /// @dev {MULTI_ROUTE}: push every token but `tokens[0]` that no output leg is paid
    ///      in — a multi-input order's further currencies (S-3), listed SETTLE receipts
    ///      (S-2) — to the sandbox, each at THIS FILL's delta against its pre-fill
    ///      snapshot (never a balance; the delta rule of {_route}). Output tokens stay:
    ///      they hold the spread, or net against their own legs.
    function _pushExtras(address[] calldata toks, uint256[] calldata bef, uint256 outMask) private {
        for (uint256 k = 1; k < toks.length; ++k) {
            if (outMask & (1 << k) != 0) continue;
            uint256 d = SafeTransferLib.balanceOf(toks[k], address(this)) - bef[k];
            if (d != 0) SafeTransferLib.safeTransfer(toks[k], address(SANDBOX), d);
        }
    }

    /// @dev Execute a POOL ROUTE (see {POOL_ROUTE} for the `data` layout and the
    ///      contract note "DIRECT POOL ROUTES" for the security argument).
    ///
    ///      `routed` is the hop-0 BUDGET: this fill's measured input delta, less the
    ///      in-kind legs kept back and the self-seeded wei — exactly what {_route}
    ///      would have pushed to the sandbox. No pool is ever paid more of the anchor
    ///      input than that, whatever the plan says, so the floor, retained value and
    ///      every other fill's residue stay out of reach (invariant 2, delta-only).
    ///
    ///      Offsets keep their opaque-route meaning: `amountInOffset == 0` rewrites the
    ///      amountIn word with `routed`, `outOffset == 32` the amountOut word with the
    ///      live anchor-leg price; any other value but {NO_PATCH} is refused.
    function _poolRoute(FillRoute calldata r, uint256 routed, uint256 outOffset, uint256 liveOut) private {
        (uint256 o, uint256 hops) = _poolShape(r);
        (uint256 amountIn, uint256 amountOut) = _poolAmounts(o, r.amountInOffset, outOffset, routed, liveOut);

        // Armed for the callback only while the swap is in flight; restored to the
        // fill's own state (3, or 5 on the netted path) the moment it returns.
        // A NATIVE order's route pays HERE — the unwrap needs the WNATIVE; `payee` is
        // then the native recipient, paid in coin by {_payNative}.
        address payee = r.legs & LEGS_NATIVE != 0 ? address(this) : r.payee;
        uint256 state = _active;
        _active = SWAPPING;
        if (amountOut == 0) {
            if (amountIn > routed) revert PoolOverBudget(amountIn, routed);
            _exactIn(o + 64, hops, amountIn, payee);
        } else {
            // The input ceiling: the plan's `amountInMaximum`, never above the delta.
            _exactOut(o + 64, hops, amountOut, amountIn < routed ? amountIn : routed, payee);
        }
        _active = state;
    }

    /// @dev Validate a pool route's `data` and return its calldata offset and hop
    ///      count: 64 bytes of amounts + 20 for the first token + 24 per hop, 1 to
    ///      {MAX_POOL_HOPS} hops, from the anchor input to the anchor output — nothing
    ///      else is ever paid from here on hop 0, and nothing else is measured at the
    ///      end. The two token reads are in bounds (`len ≥ 108`). EQUIVALENT SOLIDITY:
    ///      `address(bytes20(d[64:84])) == tokens[0] && address(bytes20(d[len - 20:len]))
    ///      == tokens[outAnchor]`.
    function _poolShape(FillRoute calldata r) private pure returns (uint256 o, uint256 hops) {
        bytes calldata d = r.data;
        uint256 len = d.length;
        if (len < 108) revert BadPoolRoute();
        unchecked {
            hops = (len - 84) / 24;
            if ((len - 84) % 24 != 0 || hops > MAX_POOL_HOPS) revert BadPoolRoute();
        }
        address first;
        address last;
        /// @solidity memory-safe-assembly
        assembly {
            o := d.offset
            first := shr(96, calldataload(add(o, 64)))
            last := shr(96, calldataload(sub(add(o, len), 20)))
        }
        if (first != r.tokens[0] || last != r.tokens[r.outAnchor]) revert BadPoolRoute();
    }

    /// @dev A pool route's two amount words (at calldata offset `o`, in bounds — see
    ///      {_poolShape}), patched as on an opaque route: offset 0 takes the routed
    ///      delta, offset 32 the live anchor-leg price, {NO_PATCH} leaves the quoted word;
    ///      anything else is refused. EQUIVALENT SOLIDITY for the quoted words:
    ///      `uint256(bytes32(d[0:32]))`, `uint256(bytes32(d[32:64]))`.
    function _poolAmounts(uint256 o, uint256 inOffset, uint256 outOffset, uint256 routed, uint256 liveOut)
        private
        pure
        returns (uint256 amountIn, uint256 amountOut)
    {
        if (inOffset != 0 && inOffset < NO_PATCH) revert BadPoolRoute();
        if (outOffset != 32 && outOffset < NO_PATCH) revert BadPoolRoute();
        /// @solidity memory-safe-assembly
        assembly {
            amountIn := calldataload(o)
            amountOut := calldataload(add(o, 32))
        }
        if (inOffset == 0) amountIn = routed;
        if (outOffset == 32) amountOut = liveOut;
        // It enters an `int256` (`amountSpecified`): a word past that range would flip
        // the swap's direction. (`amountIn` is bounded by `routed` in the caller.)
        if (amountOut > uint256(type(int256).max)) revert BadPoolRoute();
    }

    /// @dev Exact-input, hop by hop in swap order: each hop pays THIS contract
    ///      (the last one the payee) and the next hop swaps exactly what it produced,
    ///      paid from here in its callback with that output as its budget. Every hop
    ///      must consume its whole input ({BadPoolSwap}) — a pool that stops at the
    ///      price limit would otherwise strand an intermediate token here.
    /// @param path the calldata OFFSET of the route's path (`data[64:]`), `hops` long —
    ///        bounds proven by {_poolShape} (`len == 84 + 24 · hops`).
    function _exactIn(uint256 path, uint256 hops, uint256 amount, address payee) private {
        for (uint256 k; k < hops; ++k) {
            uint256 hop;
            unchecked {
                hop = path + 24 * k; // ≤ 4 hops into a bounds-checked blob
            }
            (address pool, bool zeroForOne) = _hopPool(hop);
            // Callback data: `amount ‖ hop` (76 bytes) — the hop's own budget.
            (int256 paid, int256 got) =
                _poolSwap(pool, k + 1 == hops ? payee : address(this), zeroForOne, int256(amount), amount, hop, 44);
            if (paid != int256(amount) || got >= 0) revert BadPoolSwap();
            amount = uint256(-got);
        }
    }

    /// @dev Exact-output, the standard recursive pattern: swap the LAST hop for
    ///      exactly `amountOut` to the payee; its callback buys the owed input from
    ///      the previous hop paid straight to the calling pool, and so on down to hop
    ///      0, whose callback alone pays from here — at most `budget` of the anchor.
    /// @param path / hops as {_exactIn}; `len = 20 + 24 · hops`.
    function _exactOut(uint256 path, uint256 hops, uint256 amountOut, uint256 budget, address payee) private {
        uint256 len;
        unchecked {
            len = 20 + 24 * hops;
        }
        (address pool, bool zeroForOne) = _hopPool(path + len - 44);
        // Callback data: `budget ‖ path` — the whole path, hop 0's budget first.
        (, int256 got) = _poolSwap(pool, payee, zeroForOne, -int256(amountOut), budget, path, len);
        if (uint256(-got) != amountOut) revert BadPoolSwap();
    }

    /// @dev `pool.swap(recipient, zeroForOne, amountSpecified, <no limit>, data)` with
    ///      `data = head ‖ calldata[src : src + len]`, encoded straight into free memory
    ///      (never allocated: the buffer is dead once the call returns, and the pool's
    ///      callback runs in its own frame). Returns the pool's deltas ORIENTED by the
    ///      swap direction: `(paid, got)` = (input delta, output delta — negative).
    ///
    ///      EQUIVALENT SOLIDITY (the pre-2026-10-12 body):
    ///
    ///          (int256 a0, int256 a1) = IUniswapV3PoolSwap(pool).swap(recipient, zeroForOne,
    ///              amountSpecified, zeroForOne ? MIN_SQRT_RATIO_PLUS_1 : MAX_SQRT_RATIO_MINUS_1,
    ///              abi.encodePacked(head, calldata[src : src + len]));
    ///          (paid, got) = zeroForOne ? (a0, a1) : (a1, a0);
    ///
    ///      Same calldata byte for byte (the `bytes` tail zero-padded to a word), same
    ///      revert bubbling. The high-level call's `extcodesize` pre-check is replaced by
    ///      requiring a 64-byte return: an address without code returns nothing and the
    ///      swap reverts {BadPoolSwap} (only genuine pool code can sit at a derived
    ///      address — see "DIRECT POOL ROUTES").
    function _poolSwap(
        address pool,
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint256 head,
        uint256 src,
        uint256 len
    ) private returns (int256 paid, int256 got) {
        /// @solidity memory-safe-assembly
        assembly {
            let m := mload(0x40)
            mstore(m, 0x128acb0800000000000000000000000000000000000000000000000000000000) // swap(...)
            mstore(add(m, 0x04), recipient)
            mstore(add(m, 0x24), zeroForOne)
            mstore(add(m, 0x44), amountSpecified)
            // zeroForOne ? MIN_SQRT_RATIO_PLUS_1 : MAX_SQRT_RATIO_MINUS_1
            mstore(
                add(m, 0x64),
                xor(MAX_SQRT_RATIO_MINUS_1, mul(xor(MAX_SQRT_RATIO_MINUS_1, MIN_SQRT_RATIO_PLUS_1), zeroForOne))
            )
            mstore(add(m, 0x84), 0xa0) // offset of `data`
            mstore(add(m, 0xa4), add(len, 0x20)) // its length
            mstore(add(m, 0xc4), head)
            mstore(add(add(m, 0xe4), len), 0) // zero the tail's padding word
            calldatacopy(add(m, 0xe4), src, len)
            // 0xe4 bytes of head + `len` rounded up to a word
            if iszero(call(gas(), pool, 0, m, add(0xe4, and(add(len, 0x1f), not(0x1f))), 0x00, 0x40)) {
                returndatacopy(m, 0x00, returndatasize())
                revert(m, returndatasize())
            }
            if lt(returndatasize(), 0x40) {
                mstore(0x00, 0x17d3a782) // `BadPoolSwap()` (pinned in test/AggregatorPoolRoute.t.sol)
                revert(0x1c, 0x04)
            }
            let a0 := mload(0x00)
            let x := xor(a0, mload(0x20))
            paid := xor(a0, mul(x, iszero(zeroForOne))) // zeroForOne ? a0 : a1
            got := xor(paid, x) // the other one
        }
    }

    /// @dev The absolute calldata offset of `b`'s first byte.
    function _offsetOf(bytes calldata b) private pure returns (uint256 o) {
        /// @solidity memory-safe-assembly
        assembly {
            o := b.offset
        }
    }

    /// @dev The pool of the 44-byte hop `tokenIn ‖ fee ‖ venue ‖ tokenOut` at calldata
    ///      offset `p`, and its swap direction. The CALLER proves `p + 44` lies inside
    ///      the blob it came from (raw `calldataload`s, no slice checks).
    ///      EQUIVALENT SOLIDITY over `hop = calldata[p : p + 44]`:
    ///          tokenIn = address(bytes20(hop[0:20])); tokenOut = address(bytes20(hop[24:44]));
    ///          pool = poolFor(uint8(hop[23]), tokenIn, tokenOut, uint24(bytes3(hop[20:23])));
    function _hopPool(uint256 p) private view returns (address pool, bool zeroForOne) {
        address tokenIn;
        address tokenOut;
        uint256 fee;
        uint256 venue;
        /// @solidity memory-safe-assembly
        assembly {
            tokenIn := shr(96, calldataload(p))
            let w := calldataload(add(p, 20))
            fee := shr(232, w)
            venue := byte(3, w)
            tokenOut := shr(96, calldataload(add(p, 24)))
        }
        (address factory, bytes32 initCodeHash) = poolVenue(venue);
        pool = _derive(factory, initCodeHash, tokenIn, tokenOut, fee);
        zeroForOne = tokenIn < tokenOut;
    }

    /// @notice The pool-route swap callback (Uniswap v3, and its forks Oku / SushiSwap
    ///         v3 that share the name). Pays only what a pool THIS contract is swapping
    ///         on is owed, of the hop's input token, within the hop's budget.
    /// @dev    `data` is this contract's own `abi.encodePacked(budget, hops 0..k)` as
    ///         handed to `pool.swap` (a pool echoes it verbatim); hop k — the LAST 44
    ///         bytes — is the swap now calling back. Three gates, all load-bearing:
    ///
    ///           1. ARMED: `_active == SWAPPING`, a state only {_poolRoute} sets, and
    ///              only inside a fill an operator started and the EXECUTOR called
    ///              back. Outside it the callback pays nobody.
    ///           2. GENUINE POOL OF THE CURRENT HOP: `msg.sender` must equal the
    ///              CREATE2 address of hop k on an IMMUTABLE venue — pool code is
    ///              pinned by the venue's init code hash, and a genuine pool calls
    ///              back only the `msg.sender` of ITS OWN `swap`, i.e. us, with our
    ///              data. A forged caller cannot be that address; a forged `data`
    ///              only names a different pool, which the caller then is not.
    ///           3. EXACTLY THE OWED INPUT, WITHIN BUDGET: the positive delta of the
    ///              hop's INPUT token (`tokenIn < tokenOut` ⇒ token0), nothing of any
    ///              other token, and on hop 0 never more than `budget` — the fill's
    ///              routed delta (exact-output: also ≤ the plan's ceiling).
    ///
    ///         Hop k > 0 of an EXACT-OUTPUT route pays nothing from here: it buys the
    ///         owed amount from hop k−1 with `recipient = msg.sender` (the calling
    ///         pool), which re-enters this callback for hop k−1 under the same gates.
    ///         An exact-input route passes one hop per swap, so every callback it
    ///         triggers is "hop 0" of its own data, paying ≤ that hop's input.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (_active != SWAPPING) revert NotArmed();
        uint256 h = data.length - 44; // the current hop (checked: shorter data reverts)
        uint256 o = _offsetOf(data);
        (address pool, bool zeroForOne) = _hopPool(o + h);
        if (msg.sender != pool) revert NotPool();
        int256 owed = zeroForOne ? amount0Delta : amount1Delta;
        if (owed <= 0) revert BadPoolSwap();
        if (h == 32) {
            // `data` is exactly 76 bytes here: budget = data[0:32], tokenIn = data[32:52].
            uint256 budget;
            address tokenIn;
            /// @solidity memory-safe-assembly
            assembly {
                budget := calldataload(o)
                tokenIn := shr(96, calldataload(add(o, 32)))
            }
            if (uint256(owed) > budget) revert PoolOverBudget(uint256(owed), budget);
            SafeTransferLib.safeTransfer(tokenIn, msg.sender, uint256(owed));
        } else {
            _buyFromPrev(data, h, owed);
        }
    }

    /// @dev Exact-output recursion: hop k−1 (`data[h−24 : h+20]`) pays `owed` of hop k's
    ///      input token straight to the calling pool; its own callback carries
    ///      `data[: h+20]` — the budget and hops 0..k−1.
    function _buyFromPrev(bytes calldata data, uint256 h, int256 owed) private {
        // `h − 24` is checked: data too short to hold a previous hop reverts. `h + 20`
        // ≤ `data.length` (h = length − 44).
        uint256 o = _offsetOf(data);
        (address prevPool, bool zeroForOne) = _hopPool(o + (h - 24));
        // `data[: h + 20]` = its first word (the budget) ‖ `data[32 : h + 20]`; h ≥ 24.
        uint256 budget;
        /// @solidity memory-safe-assembly
        assembly {
            budget := calldataload(o)
        }
        _poolSwap(prevPool, msg.sender, zeroForOne, -owed, budget, o + 32, h - 12);
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
        if (!SEED_INPUT || amountIn < 2 || r.amountInOffset >= NO_PATCH || r.direct) return amountIn;
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

    /// @dev The output pass: every output token's proceeds of this fill, APPROVED to
    ///      Settlement on {executeFill}'s pull path (`push == false` — the core pulls
    ///      the priced legs next; the rest of the allowance is zeroed after the fill) or
    ///      TRANSFERRED to its pool on {executeItemFill} (`push`, the pool sweeps the
    ///      unused part back). Each token at ITS OWN delta of this fill, never a balance;
    ///      the anchor output at {_cap} (floored, inventory, `maxPay`). The calldata
    ///      arrays are resolved ONCE (re-resolving `r.tokens[k]` through the struct on
    ///      every access is measurable on the hot path). One body for both entries
    ///      (2026-10-18; was `_approveOutputs` / `_pushOutputs`, identical but for the
    ///      final call).
    function _payOutputs(FillRoute calldata r, uint256 floor, bool push) private {
        address[] calldata toks = r.tokens;
        uint256[] calldata bef = r.before;
        uint256 outMask = r.outMask;
        uint256 outAnchor = r.outAnchor;
        for (uint256 k; k < toks.length; ++k) {
            if (outMask & (1 << k) == 0) continue;
            address t = toks[k];
            uint256 cap =
                k == outAnchor ? _cap(r, t, bef[k], floor) : SafeTransferLib.balanceOf(t, address(this)) - bef[k];
            if (!push) SafeTransferLib.forceApprove(t, address(SETTLEMENT), cap);
            else if (cap != 0) SafeTransferLib.safeTransfer(t, address(SETTLEMENT), cap);
        }
    }

    /// @dev What the ANCHOR output token `t` may pay this fill (`b` = its pre-fill
    ///      balance; token and snapshot passed in, already resolved): its delta `out`
    ///      — which must reach `floor` ({InsufficientOutput}): the pro-rata `minOut`
    ///      ({_minOut}) plus any pre-route inflow ({_inflow}), so the whole-fill delta
    ///      is compared against it — plus the {RoutePlan.inventory} draw, bounded by
    ///      the pre-fill balance `before[k]` (inventory is value held BEFORE the fill;
    ///      with a zero draw this is exactly the old delta-only cap), all capped at a
    ///      non-zero `maxPay`. Both live in {FillRoute.maxPay}'s word (high / low 128).
    function _cap(FillRoute calldata r, address t, uint256 b, uint256 floor) private view returns (uint256 cap) {
        uint256 out = SafeTransferLib.balanceOf(t, address(this)) - b;
        if (out < floor) revert InsufficientOutput(out, floor);
        uint256 mp = r.maxPay;
        uint256 inv = mp >> 128;
        mp = uint128(mp);
        cap = out + (inv < b ? inv : b);
        if (mp != 0 && mp < cap) cap = mp;
    }

    // ── NFT receipts (review 2026-10-18 S-2) ────────────────────────────────────────

    /// @notice The ERC-721 / ERC-1155 receiver hooks, as one FALLBACK:
    ///         `onERC721Received(address,address,uint256,bytes)` (0x150b7a02) and
    ///         `onERC1155Received(address,address,uint256,uint256,bytes)` (0xf23a6e61).
    ///         Accepts a token ONLY while an {executeItemFill} plan is armed and its route
    ///         has not run yet (`_active == 4`) — the window in which an EARLY SETTLE item
    ///         (`NftSettlementModule` / `Erc1155SettlementModule`: maker → filler) pays this
    ///         contract — and forwards it at once to {SANDBOX}, where a {MULTI_ROUTE}
    ///         sells it ({RouteSandbox}'s own hooks accept only this contract's forward).
    ///         Everywhere else, and for every other selector, it reverts — so no transfer
    ///         can park an NFT here, which matters because this contract has no way to move
    ///         one out later ({sweep} is ERC-20). No batch hook: a batch transfer reverts.
    /// @dev    WHY THE FORWARD IS SAFE. It moves exactly the token that just arrived (a
    ///         collection records the new owner before calling back) to the authority-less
    ///         sandbox: the delta rule holds by construction. The caller is NOT
    ///         authenticated — maker-chosen module code runs in this window — but the
    ///         forward is a `safeTransferFrom` called ON THE CALLER, so a forged
    ///         "collection" only makes this contract call the forger's own code (every
    ///         entry is closed at `_active == 4`: executeFill / sweep revert {Reentrancy},
    ///         both fill callbacks and the pool callback {NotArmed}, and {onMatchRoute}
    ///         needs the EXECUTOR), and the forwarded selector (0x42842e0e / 0xf242432a)
    ///         is one no ERC-20 implements: a token contract that relays arbitrary calls
    ///         cannot be made to move this contract's ERC-20 balance, as a plain
    ///         `transferFrom(this, sandbox, id)` would on a WETH9-style token that skips
    ///         the allowance for `src == msg.sender`. A LATE SETTLE (after the route) is
    ///         refused: nothing could sell the NFT any more.
    ///
    ///         ASSEMBLY, BY MEASUREMENT (2026-10-18): the two Solidity hooks (ABI-decoded
    ///         `bytes calldata`, an encoded external call each) cost ~730 B of runtime on
    ///         the deployed profile; this body reads the two words it needs and never
    ///         decodes the rest. EQUIVALENT SOLIDITY:
    ///
    ///             function onERC721Received(address, address, uint256 id, bytes calldata)
    ///                 external returns (bytes4) {
    ///                 if (_active != 4) revert NotArmed();
    ///                 IERC721(msg.sender).safeTransferFrom(address(this), address(SANDBOX), id);
    ///                 return this.onERC721Received.selector;
    ///             }
    ///             function onERC1155Received(address, address, uint256 id, uint256 v, bytes calldata)
    ///                 external returns (bytes4) {
    ///                 if (_active != 4) revert NotArmed();
    ///                 IERC1155(msg.sender).safeTransferFrom(address(this), address(SANDBOX), id, v, "");
    ///                 return this.onERC1155Received.selector;
    ///             }
    fallback() external {
        address sandbox = address(SANDBOX);
        /// @solidity memory-safe-assembly
        assembly {
            // Not inside an armed item fill → refuse (empty revert data; `NotArmed` in
            // spirit — a collection reports it as "non-receiver").
            if iszero(eq(sload(_active.slot), 4)) { revert(0, 0) }
            let sel := shr(224, calldataload(0))
            let m := mload(0x40)
            let len := 0x64
            // The selector word FIRST: its 28 zero bytes would clobber the `from` word.
            switch sel
            case 0x150b7a02 {
                mstore(m, shl(224, 0x42842e0e)) // safeTransferFrom(address,address,uint256)
            }
            case 0xf23a6e61 {
                mstore(m, shl(224, 0xf242432a)) // safeTransferFrom(address,address,uint256,uint256,bytes)
                mstore(add(m, 0x64), calldataload(0x64)) // value
                mstore(add(m, 0x84), 0xa0) // offset of `data`
                mstore(add(m, 0xa4), 0) // `data` = ""
                len := 0xc4
            }
            default { revert(0, 0) }
            mstore(add(m, 0x04), address())
            mstore(add(m, 0x24), sandbox)
            mstore(add(m, 0x44), calldataload(0x44)) // id
            if iszero(call(gas(), caller(), 0, m, len, 0, 0)) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }
            mstore(0, shl(224, sel))
            return(0, 0x20)
        }
    }
}
