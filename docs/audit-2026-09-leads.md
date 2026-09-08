# Audit 2026-09 — open leads

Companion to **F25** in [reference-audits.md](./reference-audits.md), which records
the five findings that were fixed. This file holds the **leads**: trails with a
concrete code smell where the exploit path was not closed in one pass.

A lead is not a false positive and not a finding. It is a place where the code
depends on something it does not itself enforce. Most resolve into "correct, but
for a reason that is not written down" — which is worth writing down, because the
next change is what breaks it.

Each entry states what was **verified** and what remains **open**, so nobody
re-derives the same ground. Verification status is mine, not the reporting lens's.

---

## Tier A — ~~verified real, needs a decision~~ — **ALL CLOSED**

### A-1. ~~Aave v3 borrow forwards a nominal amount, never a measured delta~~ — **CLOSED**

Fixed as F25/G-7. All three v3 paths (`AaveV3BorrowModule.takeOnBehalf`, both
leverage modules in `AaveV3FusedModules.sol`) now snapshot, measure and
`require(received >= amount)`, with the excess swept to `onBehalfOf` — the shape
`AaveV4BorrowModule` already carried. Retained here because the *reasoning* is the
reusable part: the precondition (a v3 reserve that under-delivers) was never proven,
and the fix was applied anyway because a one-`balanceOf`-pair guard is cheaper than
an open-ended assumption about every present and future reserve.

### A-2. ~~`FullFillGuard` requires a word the byte maps never declare~~ — **CLOSED**

Fixed as F25/G-10. The Aave v3 and v4 withdraw byte maps now declare `totalAmount`
as MANDATORY under `Full`, and state why the permit block can share the offset
there (the two modes are mutually exclusive branches) while the Morpho and Comet
auth blocks could not. Documentation only — the guard's behaviour was always
correct, the specification was not.

### A-3. ~~Dangling approval to an order-supplied `pool`~~ — **CLOSED**

Fixed as F25/G-8, at **six** sites rather than the four this lead named — the two
fused leverage modules had it too. Regression tests in
`aave-v3/test/unit/DanglingApproval.t.sol` use a pool that pulls nothing, so they
prove the clear is unconditional rather than incidental to the target's behaviour.
Retained here for the reasoning: there was no exploit, and it was fixed anyway
because a standing claim on a shared singleton's future balance is what converts
someone else's later bug into a theft.

### A-4. ~~`ItemPolicy.ANY` leaves makers exposed by default~~ — **RESOLVED**

The blocking unknown is answered: `packages/app/src/config/deployments.ts` states
plainly that **nothing is deployed yet**, so the finite-allowance population this
turned on is **zero**. No signed orders to migrate, no live exposure.

Option B (netting the pull against a projected item credit in `_stepPull`) is
therefore unjustified — a change to the netted hot path bought with no present
risk. Option A landed instead, adapted: the SDK has no single order builder to
carry a default, so it gained `itemPolicyWarning(order)` beside `withItemPolicy` /
`itemPolicyOf`.

**Why a warning and not a gate.** The obvious home for a hard check is `packOrder`,
alongside `assertOrderNonce`. It cannot go there: the golden-hash fixture and
several conformance tests deliberately sign item-bearing orders at `ANY`, so
rejecting them would either break the pinned EIP-712 hash or force a wire change to
buy nothing — and `ANY` is REQUIRED to participate in a cycle. The gate belongs in
whatever order builder ships to users; the SDK's job is to make the hazard
impossible to miss, which the function's doc-block now does.


## Tier B — ~~fragility: correct today, for reasons nothing enforces~~ — **ALL CLOSED**

These are the entries most worth keeping. In each case the safety argument runs
through a *different* part of the system than the one that looks responsible, so a
local, reasonable-looking change breaks it silently.

### B-1. ~~`outstanding` undercounts what the pool owes~~ — **DOCUMENTED** (F25/G-11)

The guarantor is now named at the PRESEND site: `_sweepSurplus`'s per-token floor
plus the refund transfer reverting on a drained pool, NOT the `outstanding` ledger
its comment used to credit. The three changes that would reopen the hole are listed
there. The ledger itself is unchanged by choice — seeding it with the reconciliation
surplus would make the bound self-sufficient, but that is a hot-path change and
should be argued on its own merits rather than smuggled in as a doc fix.

### B-2. ~~`fillWithPermitTake` treats authorization as a post-condition~~ — **CLOSED** (F25/G-11)

The `PermitTakeNotConsumed` assertion moved into `_settleForward`, immediately
after `_executeItems` and BEFORE `_payInputsToSolver`, so the maker's wallet is
drawn only once their signature has actually been consumed. Free on every other
entry (a length test on empty `bytes`). This was the item to land before the bridge
work: the old placement was safe only because every item op is atomically
revertible, which a cross-chain message is not.

### B-3. ~~The funding leg's token is never bound~~ — **CLOSED IN THE LENS**

Landed as the recommended middle path: `SettlementLens` now cross-checks the
BALANCE form's descriptor token against `IFundingSource.fundingSource`, exactly as
it already did for the leg-reference form, with the same degradation rule (a module
that cannot answer reports `address(0)` and the check skips rather than rejecting a
fillable order). Three tests in `TakeForItem.t.sol` cover mismatch, match, and the
silent module.

**Deliberately NOT promoted to an on-chain revert**, unlike its siblings
(`DeltaVerifySameToken`, `DeltaVerifyDuplicateLeg`, `OutputToSettlement`). Two
reasons, the second binding: both halves are maker-signed, so no filler chooses
either and the realistic failure is an order builder getting it wrong — which a
preflight catches. And Settlement now has **91 bytes** of EIP-170 headroom
(24,485 / 24,576) after Phase 2, while the lens has ~3KB spare. Spending core
bytecode on a check only a malformed order can trip is the wrong trade at that
margin. Revisit if headroom is recovered.


### B-4. ~~`_permitBatchHead` is the last returndata-to-scratch site~~ — **CLOSED**

Fixed as F25/G-9: `returndatacopy` now targets the calldata buffer the block just
built and no longer needs, matching `Core._execute` and `Base._callWithTail`. The
runtime was never wrong — the revert is immediate — but the `memory-safe-assembly`
annotation was a false promise to an optimizer that is entitled to believe it, and
the deploy profile is via-IR.

### B-5. ~~`PackedArraysMem.count` documented as a bounds source~~ — **CLOSED** (F25/G-12)

`count` is now `countUnchecked`, matching the calldata library's naming so the
hazard is visible at the call site, and `validateFixed` / `validateLegsIn` /
`validateLegsOut` mirror the real validator. **Seven** call sites across five files
were repointed — two more than this lead identified, since both ERC-7683 adapters
also indexed against the unchecked count.

## Tier C — ~~documentation drift~~ — **ALL CLOSED**

All five corrected as F25/G-10, together with the two byte maps from A-2. The table
of what each comment claimed versus what the code does is in F25; it is kept there
rather than duplicated here because the interesting part is the pattern, not the
individual lines: every one of them asserted an invariant that lived somewhere else
or nowhere at all, which is the F23 shape this repo has now hit three times.

## Tier D — ~~blocked on information outside this repo~~ — **RESOLVED**

### D-1. ~~Live allowance across a counterparty-chosen callback~~ — **CLOSED, and it corrected one of our own comments**

Resolved by reading the deployed source (`morpho-org/midnight`, `src/Midnight.sol`).
The answer settles the contradiction between our two in-repo documents, and
`ICallbacks.sol` was the one telling the truth.

`take` resolves the payer and pulls in this order:

```solidity
address payer = buyerCallback != address(0) ? buyerCallback : (offer.buy ? buyer : msg.sender);
if (buyerCallback != address(0))
    require(IBuyCallback(buyerCallback).onBuy(...) == CALLBACK_SUCCESS, ...);
SafeTransferLib.safeTransferFrom(loanToken, payer, ...);   // AFTER the callback
if (sellerCallback != address(0)) ISellCallback(sellerCallback).onSell(...);
```

Three consequences:

1. **Naming an address as payer means naming it as the CALLBACK**, and Midnight
   invokes it and requires the success sentinel *before* it pulls. The same shape
   holds on every other payer path — `repay` (`onRepay`), `liquidate`
   (`onLiquidate`), `flashLoan` (`onFlashLoan`). A standing allowance is never
   sufficient on its own.
2. **No module in the package implements any of those callbacks**, so no module can
   be named as payer by anyone. The window is closed.
3. The buy-side pull happens BEFORE `onSell`, so by the time counterparty code runs
   the module's remaining allowance is the unspent budget — and re-entering to draw
   it still requires `onBuy`.

**`MidnightSupplyCollateralModule`'s comment was wrong** and has been corrected. It
claimed "any external account can call `take` designating THIS module as the payer,
and a standing allowance is what would let that pull succeed". It cannot. The
scoped approve + clear is kept — defence in depth if a module ever gains a
callback, and no allowance outliving the call that needed it — but the justification
now matches the code.

Also checked: `MidnightFlashSolver` DOES implement `onFlashLoan` and so IS nameable
as a flash payer, but it is guarded by `msg.sender == midnight` plus an in-flight
flag it arms itself. Not reachable by an outside caller.


## Tier E — closed by inspection (recorded so they are not re-opened)

- **Delta-verify leg addressed at `payTo`** (`Core._settlePostInputs`). Three lenses
  reached it; all three independently concluded the same thing. `payTo` is only
  redirectable from `fillUpTo`, which hardcodes `PreDelivery`, so in PostInputs mode
  the recipient is always `ctx.filler` — the filler paying itself a fee it skipped.
  Economically null. *Becomes live if `payTo` redirection is ever extended past
  `fillUpTo`.*
- **`_clampToRemaining` second anchor read.** Re-derives `anchorTotal` after
  `_verifySignature` may have run maker-controlled 1271/7702 code. Divergence fails
  closed in both directions (`OverFill` if it grew, `ProportionalNeedsFullFill` if
  it shrank). Liveness only — but it makes `fillUpTo`, the documented entry for
  proportional orders, non-deterministically unfillable for contract makers.
  Clamping against the already-pinned `ctx.anchor` removes the second read.
- **`Full` mode has a floor but no ceiling.** Every `BalanceMode.Full` path unwinds
  the maker's entire live position with only `received >= amount` checked, and the
  filler picks the timing. Verified: the excess always returns to `onBehalfOf`.
  Loss-of-yield and timing exposure, not theft. A maker-signed maximum would bound
  it on both sides.
- **`TakerAllowance.takeFor`'s `forAmount` is ungated.** The doc says the user's
  token allowance to the module bounds it; the adapters recommend **infinite**
  approvals, so the real bound is Settlement's descriptor discipline — one caller's
  property, not the hub's. No non-Settlement spender exists today. *Revisit before
  shipping a second composite spender.*
- **`Pricing.inputOwed` per-fill truncation on BUY.** Routes fixed BUY legs through
  the per-fill form while SELL uses cumulative differencing; only the latter sums
  exactly. Loss is ≤1 raw unit per slice, borne by whoever chose to slice.
- **Exact-mode aToken rounding** (`AaveV3WithdrawModule`). No 1-wei mop-up, which
  the module's own `Full` branch documents needing. Liveness; rounding direction
  against Aave's scaled-balance math was not verified.
- **`AaveV3FusedLeverageModule` rounding + narrowing.** Cumulative-floor borrow vs
  per-fill-ceil collateral gives a ≤(N−1)-unit overdraw that can revert the final
  slice on an exact allowance; and `collateral` is the one derived amount in the
  composite family crossing `uint160` unchecked. Both self-limiting.
- **`MidnightLoopCallback._swap` uncleared router allowance.** The file's only
  approval not scoped-and-cleared, on the reasoning that the router consumes
  exactly `amountIn`. Router is immutable and trusted.
- **`TakerAllowance.takeFor` emits no `forAmount`.** `take` and `takeFor` emit an
  identical `Taken` event, so an indexer cannot distinguish them, and the one amount
  Permit3 does *not* bound has no on-chain record.

---

## What the twelve lenses checked and cleared

Recorded because a negative result from a hostile pass is worth as much as a
finding, and re-deriving it is expensive.

`OrderHash.hash` — all 16 preimage slots against the typehash field order, and the
four address masks. `Base._callWithTail` — head/offset/tail arithmetic for all four
arities (n = 2 MAKE, 3 SETTLE, 4 take, 5 takeFor), including solc's `bytes calldata`
bound check. `Core._permitBatch{Tail,Head}` — offsets, strides and total length
against `abi.encodeCall`; selectors `0x9fc0d7da`, `0x6c837b2e` and `0x69f330c9`
confirmed with `cast sig`. `Permit3Hash` calldata walkers including the zero-length
case. `SafeTransferLib` (verbatim Solady, FMP restore). `Allowance.grant/spend`
packed-slot masking. `PackedArrays.validateFixed/validateRecords` bounds and cursor
overflow. `matchSettle` value conservation — every maker's net contribution reduces
to exactly `owed` under **any** schedule, `outstanding` cannot underflow, and the
duplicate-PULL / duplicate-DELIVER / duplicate-ITEM guards all sit at the step.
`SIGNER_NONCE_NS` disjointness (the bit-255 test is provably equivalent to the
word-index form). `revokeOrderApproval`'s `wasApproved` proof-of-makership. Merkle
bulk-signature second-preimage. Every module entry-point gate. The reentrancy-guard
hand-arming rule across all four straight-line entries. `SolverCallbackExecutor`
reachability with `target` = Permit3 / Settlement / itself.

**One structural negative worth stating on its own:** there are **no `payable`
functions and no native-token sentinel branches anywhere in the audited scope** —
`grep` for `payable|msg.value|0xEeee|NATIVE` hits only a router interface
declaration. The entire native/ERC-20 confusion class is inapplicable to core as it
stands.

---

# The plan

Sequenced so that each phase is independently shippable and nothing in an earlier
phase depends on a decision from a later one. The ordering is by **blast radius**,
not by severity: the leads with the smallest radius are also the ones whose absence
most often turns a future refactor into a finding, and they cost the least to land.

## ~~Phase 1 — zero-risk, no behaviour change~~ — **DONE** (F25 / G-8, G-9, G-10)

All four items landed: the five drifted comments, the two Aave byte maps,
`_permitBatchHead`'s returndata buffer, and the approval clears. One note for the
record — the approval clear was needed at **six** sites, not the four this plan
predicted, because the two fused leverage modules have their own `forceApprove`.
That is the second time in this audit that asking "where else?" found 50% more
instances than the finding named. It is worth making that question a standing step
rather than an instinct.

## ~~Phase 2 — invariant hardening~~ — **DONE** (F25 / G-11, G-12)

| lead | change | note |
| --- | --- | --- |
| B-1 | either seed `outstanding` with the reconciliation surplus, or state at the PRESEND site that `_sweepSurplus` is the sole guarantor | **prefer the comment first**, the ledger change second |
| B-2 | move the `permitTake`-consumed assertion to immediately after `_executeItems` | turns a post-condition into a pre-condition |
| B-5 | give `PackedArraysMem` a real validating count, then repoint the two solver call sites | the solvers are the actual exposure, not the library |

**B-1 deserves a word on sequencing.** The extraction fails closed today, so the
urgent part is not the ledger — it is that the PRESEND comment claims a property
(*"correct at ANY point in the schedule"*) that is only true for delivery
obligations. Writing down that `_sweepSurplus` is what actually holds the line is
free and prevents the class; changing the ledger is a real change to a hot path and
should be justified on its own merits, not smuggled in as a doc fix.

**B-2 is the one to do before the bridge work lands.** `fillWithPermitTake`'s safety
is atomic-revert, and it is void the moment an item op acquires an effect that
outlives the transaction. A cross-chain message is precisely that.

## ~~Phase 3 — needs a decision before any code~~ — **DONE**

All three decisions were resolvable without guessing. D-1 by reading the deployed
Midnight source; A-4 because `deployments.ts` says nothing is live, so the
population it hinged on is zero; B-3 by the 91-byte bytecode margin, which settled
lens-vs-on-chain on its own. The original write-ups follow for the reasoning.

These two are not "fix or don't". Each has a real trade-off and the answer changes
what gets written.

### D-1 — the Midnight allowance window. **Do the research first.**

Cheapest item on the list with the widest range of outcomes. Read
`morpho-org/midnight`'s `take`: does the buy-side pull precede the seller callback,
and does a `takerCallback` payer require `isAuthorized`? Then check
`repay(callback)` and `flashLoan(callback)`, which may pull from a named payer
*without* invoking it — that would route around the interface gap the modules
currently rely on.

Three outcomes: exploitable (a finding, fix immediately); blocked by design (close
the lead, record why); blocked incidentally (**the current state** — fix
structurally anyway, because "safe because we happen not to implement `onBuy`" is
not a property, and the next interface addition silently removes it).

### A-4 — `ItemPolicy.ANY` is the default that leaves makers exposed

`matchSettle` is permissionless, so a solver picks the step order, and PULL-before-
ITEM makes the maker front the whole leg. Tokens are refunded; allowance is not.

- **Option A — default new orders to `CANONICAL` in the SDK builder.** No contract
  change, no wire change for existing orders. Does nothing for orders already
  signed, and nothing for non-SDK signers.
- **Option B — net the pull against a projected item credit in `_stepPull`.** Fixes
  every order including signed ones. A real change to the netted hot path.

Recommend **A now, B only if the finite-allowance population turns out to be
large** — which is the number to go measure first. `uint160.max` grants are immune,
and if that is what everyone actually uses, this is theoretical.

### B-3 — bind the funding leg's token on-chain

The precedent cuts toward doing it: `DeltaVerifySameToken`,
`DeltaVerifyDuplicateLeg` and `OutputToSettlement` were all promoted from lens
advice to on-chain reverts for this exact reason. The argument against is that both
halves are maker-signed, so nothing a filler chooses is involved — it is a
malformed-order footgun.

The cheap middle: extend the **lens** to cross-check the balance form the way it
already cross-checks the leg form, and decide on the on-chain revert separately.
That closes the realistic path (an order builder gets it wrong) without touching a
hot path or the bytecode budget — which matters, at 162 bytes of headroom.

## Phase 4 — standing

- Re-run the Tier E list when the code they depend on moves. Each entry names its
  trigger: `payTo` redirection extending past `fillUpTo`; a second composite
  spender for `takeFor`; `Full` mode gaining a maker-signed ceiling.
- The remaining audit skills (`x-ray`, and the Trail of Bits `token-integration-analyzer`,
  `dimensional-analysis` and `variant-analysis` lenses) have not been run.
  `variant-analysis` is the one with a track record here: G-6 was six instances of
  one rule, and the twelve-lens pass found them only because three lenses
  volunteered the variant question unprompted.

## What this plan deliberately does not do

No entry proposes reworking a subsystem. Every finding in F25 was a break in a rule
this codebase already had, and every lead above is either a missing instance of an
existing rule or an undocumented dependency between two parts. The correct response
to that is more instances and better documentation, not new architecture.
