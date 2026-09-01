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

## Tier A — verified real, needs a decision

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

### A-4. `matchSettle` schedule ordering burns maker allowance

`Batch._stepPull`.

**Verified.** `_stepPull` draws `owed - credit`, and credit from a TAKE item exists
only if the ITEM step precedes the PULL. Scheduled the other way the maker fronts
the whole leg from their wallet; Phase 3 refunds the **tokens** but cannot refund
the **allowance**. `matchSettle` is permissionless, so the solver writes the order.

**Verified precedent.** The repo already judged the *repetition* variant (a
duplicate PULL) worth fixing in code, for this reason stated in-source: "the TOKENS
are indeed refunded — but the Permit3 ALLOWANCE spent to move them is not". The
*ordering* variant was left to a maker opt-in (`ItemPolicy.CANONICAL`), while
`ItemPolicy.ANY` is the default and what every pre-existing order reads back.

**Open.** How many live orders carry a finite (non-`uint160.max`) allowance — that
is the population this bites. `uint160.max` grants are immune.

**Recommendation.** Default new orders to `CANONICAL` in the SDK builder, or net
the pull against a projected item credit. Griefing only, no fund loss.

---

## Tier B — fragility: correct today, for reasons nothing enforces

These are the entries most worth keeping. In each case the safety argument runs
through a *different* part of the system than the one that looks responsible, so a
local, reasonable-looking change breaks it silently.

### B-1. `outstanding` undercounts what the pool owes

`Batch._stepPresend`.

**Verified.** `st.outstanding[t]` is seeded only from output legs and decremented
only by DELIVER. It does not include Phase-3 obligations —
`_matchReconcileInputs`'s surplus refund to the maker, or `_creditItemProceeds`'s
non-leg refunds. A schedule that over-produces an input token via an ITEM and then
PRESENDs it hands the solver money the settler still owes a maker.

**Verified safe — but not by the ledger.** Three lenses each traced the extraction
and it fails closed *via `_sweepSurplus`'s `nowBal >= beforeBal[k]` floor*, and via
the refund transfer itself reverting on an empty pool. Every `legsIn` token is in
`st.tokens` by construction of `_collectTokens`, so no refund token escapes the
floor.

**The problem is the comment.** The PRESEND site claims its bound "is correct at
ANY point in the schedule". That is true for *delivery* obligations only. Three
specific future changes turn this into solver-extractable maker money with no other
guard: narrowing the swept token set; moving a refund after `_sweepSurplus`; adding
a Phase-2 refund path.

**Recommendation.** Either seed `outstanding` with the reconciliation surplus as it
accrues, or state at the PRESEND site that `_sweepSurplus` is the sole guarantor.
The second is free and prevents the class.

### B-2. `fillWithPermitTake` treats authorization as a post-condition

`Core.fillWithPermitTake`.

**Verified.** This entry never calls `_verifySignature`. `_gateOrder` → `_openFill`
→ `_settleForward` all run against an unauthenticated `Order`: `_openFill` writes
`filled[orderHash]`, `_deliverOutputs` runs, `_executeItems` dispatches to
**maker-supplied module addresses**, a `TAKE_FOR` item reaches `PERMIT3.takeFor`
against the victim's **standing** taker allowance, and `_payInputsToSolver` pulls
the victim's inputs. Authorization arrives only if a TAKE item consumes the permit,
enforced by `if (ctx.permitTake.length != 0) revert PermitTakeNotConsumed()` *after*
`_settleForward` returns.

**Verified safe.** Four lenses attacked it independently — arbitrary pre-auth module
call from Settlement's identity, pre-auth `takeFor` against a standing allowance,
clearing `ctx.permitTake` without the Permit3 call, `fillModule` pointing at
attacker code (it is `view`, hence STATICCALL). All unwound by the deferred check
plus atomic revert.

**The exposure.** It is void the moment any item op acquires an effect that
outlives the transaction — a cross-chain message, a bridge-inbox item, an
off-chain-consumed event. The bridge-inbox package is precisely that shape.

**Recommendation.** Move the `permitTake` consumption assertion to immediately after
`_executeItems`, or gate item dispatch on the permit already being consumed. Turns
a post-condition into a pre-condition at no functional cost.

### B-3. The funding leg's token is never bound to the module's funding asset

`Base._forSlice`, `AaveV3TakeForLeverageModule.takeForOnBehalf`. Four lenses.

**Verified.** The leg-reference form checks the referenced leg's *recipient*
(`ForLegNotMakers`) and *index* (`ForLegMissing`) but never its **token**; the
balance form reads `balanceOf(descriptor-named token)` while the module pulls
`collateralAsset` from field 5 of its own `data`. Nothing on-chain reconciles them.
A 3000e6 USDC leg funding a WETH deposit is 3e-9 WETH while the borrow draws full.

**Why it is a lead.** Both halves are maker-signed and inside `ref = keccak256(data)`,
so no filler can choose either — a malformed-order footgun, not an attack.

**Why it still matters.** The whole stated point of the leg-reference form is that
"there is exactly ONE copy of the number". And the sibling shape guards —
`DeltaVerifySameToken`, `DeltaVerifyDuplicateLeg`, `OutputToSettlement` — were all
*promoted from lens advice to on-chain reverts* for this exact reason. This one was
not. `IFundingSource.fundingSource` exists so the lens can cross-check it; the lens
does so for the leg form and **not** for the balance form.

### B-4. ~~`_permitBatchHead` is the last returndata-to-scratch site~~ — **CLOSED**

Fixed as F25/G-9: `returndatacopy` now targets the calldata buffer the block just
built and no longer needs, matching `Core._execute` and `Base._callWithTail`. The
runtime was never wrong — the revert is immediate — but the `memory-safe-assembly`
annotation was a false promise to an optimizer that is entitled to believe it, and
the deploy profile is via-IR.

### B-5. `PackedArraysMem.count` is documented as a bounds source

**Verified.** `PackedArraysMem` has no memory-side `validateFixed`, and its header
says to "call `count` … before indexing". But `count` is the memory twin of
`countUnchecked`, which `PackedArrays` documents as *deliberately proving nothing
about the bytes that follow* and forbids as a bound: "the count must always come
from the validator, never from a caller-supplied number".

**Verified callers.** `UsdrifInventorySolver.sol:199-208` takes
`n = PackedArraysMem.count(order.legsOut)` and indexes `0..n-1`;
`AggregatorFillSolver.sol:267` uses `count(...) == 0` as its only guard before
indexing leg 0. A blob of `bytes.concat(hex"03")` reports 3 legs while holding zero.

**Open.** What a garbage token address actually buys an attacker in those solvers —
they are out of the audited scope and hold solver inventory, not maker funds.

---

## Tier C — ~~documentation drift~~ — **ALL CLOSED**

All five corrected as F25/G-10, together with the two byte maps from A-2. The table
of what each comment claimed versus what the code does is in F25; it is kept there
rather than duplicated here because the interesting part is the pattern, not the
individual lines: every one of them asserted an invariant that lived somewhere else
or nowhere at all, which is the F23 shape this repo has now hit three times.

## Tier D — blocked on information outside this repo

### D-1. Live allowance across a counterparty-chosen callback

`MidnightLendModule.makeOnBehalf` (and `MidnightSupplyCollateralModule`,
`MidnightRepayModule`). Six lenses raised it; none could close it.

`forceApprove(loanToken, midnight, amount)` is live across `midnight.take`, and
because `offer.buy == false` is asserted, `sellerCallback = offer.callback` — the
**counterparty's** contract gets control while the module holds both the unspent
budget and a matching allowance.

**Two in-repo documents contradict each other, and which is right decides this:**

- `ICallbacks.sol` says a non-zero `takerCallback` must return
  `keccak256("morpho.midnight.callbackSuccess")`. `MidnightLendModule` implements
  no `onBuy`, so a nested payer-nominated `take` would revert — blocked, but
  **incidentally, by an interface gap**.
- `MidnightSupplyCollateralModule`'s comment asserts the opposite: "any external
  account can call `take` designating THIS module as the payer, and a standing
  allowance is what would let that pull succeed."

**To resolve.** Read `morpho-org/midnight`'s `take`: does the buy-side pull precede
the seller callback, and does a `takerCallback` payer require `isAuthorized`? Also
unexamined: `repay(callback)` and `flashLoan(callback)`, which may pull from a
named payer *without* invoking it — that would route around the interface gap.

**Regardless of the answer**, the window is closable structurally: approve exactly
`buyerAssets` rather than the whole budget, or clear before returning from a
callback-bearing `take`. Recommended either way — the current safety is accidental.

---

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

## Phase 2 — invariant hardening; small, local, no signature changes

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

## Phase 3 — needs a decision before any code

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
