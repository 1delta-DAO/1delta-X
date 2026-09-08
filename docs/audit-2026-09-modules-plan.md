# Audit 2026-09 (modules) — remediation plan

Findings from the twelve-lens read of the 14 previously-unaudited lending
packages. Companion to **F25** ([reference-audits.md](./reference-audits.md)) and
[audit-2026-09-leads.md](./audit-2026-09-leads.md), which cover core + the first
four module packages.

This plan is written to be *reliable*, not just complete. The previous round's
remediation (G-13) was neither, and the reasons are the design inputs here.

---

## Why the last sweep was unreliable — and what that dictates

G-13 claimed "21 sites fixed, zero remaining." The read found more sites in every
class it had already swept. Three distinct causes, each with a rule attached:

| what happened | rule this plan adopts |
| --- | --- |
| The detector matched `SafeTransferLib.forceApprove(a,b,c)` and missed Venus's `underlying.forceApprove(v,a)` member-call form — venus was **invisible**, not clean | **Never enumerate by call shape.** Enumerate by *effect*, and prove the detector sees a known-positive before trusting a zero. |
| The "is it floored?" lookback spanned a branch boundary, so `balBefore` in the `Full` branch marked the `Exact` branch clean | **No line-window heuristics.** Scope must come from structure (branch/function), not proximity. |
| `SafeTransferLib.balanceOf(tok, this)` was missed because the detector only knew `IERC20(tok).balanceOf(this)` | Same as row 1. Two spellings of one effect is the normal case, not the exception. |
| The native sweeps were left alone because a source comment argued for them | **Audit the premise, not just the conclusion.** That comment reasoned "a donor's ETH is a gift to the maker" — true only if the maker is a legitimate counterparty. Anyone can be the maker of a one-wei order. The conclusion was wrong because the premise was unexamined. |
| `LiquityV2Modules.sol` needed a second fix in a file already fixed | **Fixing a file is not fixing a class.** Re-run the class detector over the *whole tree* after each fix, never over the diff. |

---

## Phase 0 — CRITICAL: the forged auth root

**`LiquityV2TroveAuth.authorizeTrove`.** PoC verified, 2/2 passing:
`ZZPoCForgedRoot.t.sol` drains a victim trove of 3,000 BOLD and 5e18 collateral
with no order, no maker signature and no Settlement.

The library reads its ownership oracle *and* its dispatch target off one
caller-supplied address, and its header claims that makes a split impossible:

```solidity
address troveNFT = ILiquityV2TroveManager(troveManager).troveNFT();        // oracle
if (ITroveNFT(troveNFT).ownerOf(troveId) != principal) revert InvalidCaller();
borrowerOps = ILiquityV2TroveManager(troveManager).borrowerOperations();   // dispatch
```

A common root only forces consistency when the root is *trusted*. This one is
unvalidated calldata, so its two getters are two independent return statements —
the puppet lies about ownership while handing back the **real** BorrowerOperations,
which permits the op because the module genuinely is the victim's registered
remove manager.

**Fix.** Stop taking the root from `data`. Either an immutable Liquity
`CollateralRegistry` in the constructor with
`troveManager == registry.getTroveManager(signedIndex)`, or an immutable
per-deployment TroveManager allowlist.

**Constraint that rules out the obvious shortcut:** the attack reaches
`Permit3.take` directly (`approveTaker` lets a caller name themselves spender), so
**any fix that validates on the Settlement side does not close it.** It has to be
inside the module or its constructor.

**Verification.** `ZZPoCForgedRoot.t.sol` must go from 2/2 PASS to 2/2 revert, kept
as a permanent regression test. Then sweep the same axis across every package —
"is the auth oracle derived from an address the caller supplied?" — with the two
known-good shapes as the reference: Gearbox (root *is* the dispatch parameter, so
the real facade re-validates) and Fluid (real vault consults its own immutable
factory).

---

## Phase 1 — the maker-harm class: unscaled slippage bounds

The only class here that hurts a maker who signed a **correct** order. No stranded
balance, no fake contract, no self-harm: the maker signs "borrow 10,000, never owe
more than 11,000", and the *filler* chooses to fill it in N slices. Each slice
re-presents the full ceiling against a 1/N borrow.

| site | bound | direction |
| --- | --- | --- |
| `ExactlyTakerModule.takeOnBehalf` (`borrowAtMaturity`) | `maxAssets` | **max → fails OPEN** |
| `LiquityV2TakerModule._withdrawAndForward` (`withdrawBold`) | `maxUpfrontFee` | **max → fails OPEN** |
| `ExactlyTakerModule` (`withdrawAtMaturity`), `ExactlyDepositModule` (`depositAtMaturity`) | `minAssetsRequired` | min → fails CLOSED (liveness only) |
| `ListaTakerModule` (`broker.borrow`) | *none at all* | unbounded — verify whether `termId` pins the rate |

**Only the max-ceilings are exploitable.** A min-floor applied to a slice is
*stricter* than intended, so it reverts. Do not "fix" those two by scaling — that
would loosen a guard that currently fails safe. Fix the direction that fails open.

**Fix, in preference order:**
1. Re-encode as a **rate**, not an absolute. `RiverTakerModule`'s
   `maxFeePercentage` is the model — scale-free, so slicing cannot dilute it.
2. Carry the item's `totalAmount` in `data` and pass
   `ceil(bound * amount / totalAmount)`.
3. Gate the at-maturity legs with `FullFillGuard.requireFullFillFromData`.

Option 1 is structurally correct and the others are patches; prefer it where the
protocol accepts a ratio. Note `FullFillGuard`'s own header states this exact
defect for *amounts* — the guard was simply never extended to *bounds*.

**Verification.** A test that fills one order in N slices and asserts the realised
cost never exceeds the signed ceiling. It must fail against today's code.

---

## Phase 2 — value-safety classes, fixed as classes

Everything below is the F19 / A-3 / H-3 family this repo has already litigated
three times. Each is Medium: the fixes are one-liners, and — per the correction in
the section above — the exploit needs a balance at the module that is not the
attacker's. That is a real precondition, not a formality, and it is why these are
hardening rather than emergencies.

### 2a. Unfloored sweeps (F19)
`CompoundV2WithdrawModule` exact branch (`leftC`) · `RiverOpenModule` (`leftColl`) ·
`CompoundV2NativeModules` `_sweepWeth` and `_sweepNativeAsWeth`.

The Compound one runs on **every** fill, not in an edge case: the pull is
`ceil(amount·1e18/rate)` and Compound's burn truncates, so the remainder is always
non-zero. `ZZPoCStrandedCTokens.t.sol` already proves the claim.

For the native pair, see the premise correction above — floor the WETH side
unconditionally. For the raw-ETH side the "stranded forever" concern is real, so
the honest resolution is a floor **plus** an explicit rescue path, not a sweep.

### 2b. Unmeasured proceeds forward (H-3 River shape)
`VenusTakerModule` Borrow + Exact-Withdraw · `CompoundV2WithdrawModule` exact ·
`AaveV2WithdrawModule` exact (lead).

Each has a sibling branch in the *same function* that measures correctly. Copy it:
snapshot, `require(received >= amount)`, forward.

Additionally assert `underlying == IVToken(vToken).underlying()` (and the cToken
equivalent). The headers currently decline that call to save gas; it is what
decouples the cost of the attack from the size of the prize.

### 2c. Dangling approvals to a `data`-decoded spender (A-3)
Nine sites, from the form-agnostic census: `lista:58` · `venus:75` · `venus:148` ·
`euler:346/373/450` · `dolomite:404/413/474`.

Plus `FluidDepositModule` / `FluidRepayModule`, which call `_pullAndApprove` and
never `_returnUnused` — leaving both the allowance *and* the unconsumed funds.
`FluidOperateModule._open`'s own comment says that asymmetry was already found and
fixed, and calls the pair "symmetric now". It is not.

⚠ Two of these are **unbacked**: `CompoundV2RepayModule` and `VenusRepayModule`
refund the pulled funds via `_disposeResidual` while the allowance survives, so the
attacker parks no capital. That is strictly worse than the fifteen sites fixed in
G-8/G-13, where the claim was bounded by abandoned tokens.

### 2d. `uint160`-clipped pull vs unclipped approve
23 pull/approve pairs share this shape, **but most are safe**: `Base._runItem`
width-checks `slice` and `_dispatchTake` checks `forSlice`, so any site approving a
core-supplied amount is already bounded.

**Enumerate by provenance of the amount, not by call shape.** The exploitable set
is the sites whose amount is decoded from `data` and never passes a core check —
`ExactlyRepayModule`'s `maxAssets` and the composite paths' `sideAmount`. Fix with
`uint160 pull = uint160(x); require(pull == x);` and approve `pull`.

Getting this wrong in either direction is the trap: fix all 23 and you add noise
and churn; fix the 6 an agent listed and you miss one.

---

## ⟲ REASSESSMENT (2026-09-03) — the pre-funded module family

**A second module family landed after this plan was written, and it changes what
the remaining phases are worth.** 15 `*PreFundModules.sol` files, 2,866 lines, all
still untracked, created ~19:32 on 2026-09-02 — *after* the twelve-lens bundle was
built at ~18:20. **The audit read the pull family; the new preferred path was never
in it.**

### What pre-fund-funding removes, structurally

The maker signs `legsOut[j].recipient = module` and the module supplies `forAmount`
from its own balance. `Base._forSlice` admits the item's own module as the
referenced leg's recipient, so there is no pull at all:

```
grep -c "permit3.transferFrom" */src/*PreFund*.sol   →  ZERO across all 15 files
```

That is not a patch, it is class removal — and it lands on classes this plan spends
whole phases on:

| class | status in the pre-fund family |
| --- | --- |
| 2d `uint160`-clipped pull vs unclipped approve | **unrepresentable** — there is no pull to clip |
| 2c approvals to a `data`-decoded spender | already scope-and-clear; and the maker's Permit3 token allowance is gone entirely |
| 2b unmeasured proceeds forward | **inapplicable** — the value-OUT side moves nothing |
| B-3 unbound funding-leg token | **closed by construction** — `LegRefOnly` is enforced, so the balance-descriptor form cannot be reached |

All three of this plan's detectors return **0** across the whole pre-fund family.

The decisive win is the one the header claims: no on-chain ERC20 approval of a
token the maker may never have held — the delivered collateral on a cross-asset
open, the debt token on every deleverage.

### What it does NOT remove

Pull and push **coexist** — every package ships both, because push carries the
one-sided ops while the full composite (deposit+borrow in one item) still pulls. So
Phase 0/1/2 were not wasted work on a dead path. But the audited surface has
roughly doubled, and only half of it has been read.

### The one thing to probe first

`ITakerForModule` states the load-bearing invariant:

> Pooled balances cannot be consumed across orders because every module-addressed
> delivery is paid by that fill's solver and every `forAmount` is core-sized to
> that same order's own leg — deposits instructed always equal deliveries
> enforced. … mis-pairing fails closed — a pre-fund module under a maker-addressed leg
> finds no balance and reverts.

**The pairing rule is documented, not enforced.** `_forSlice` accepts a referenced
leg whose recipient is `address(0)`, the maker, *or* the module — the maker case
exists for the pull shape. Nothing stops a PRE-FUND module being paired with a
MAKER-addressed leg: it passes `ForLegNotMakers`, and the module itself checks only
the descriptor FORM (`LegRefOnly`), never the recipient. No pre-fund module reads
`legRecipient` at all.

"Finds no balance and reverts" is then true only while the module is **empty**.
With a stranded or donated balance it silently consumes it instead — the same F19
precondition as everything in Phase 2, so this is Medium and not a Critical, and in
a well-formed `matchSettle` batch the second order's own item reverts and takes the
batch with it. But an invariant this load-bearing should not rest on the module
happening to be empty.

The enforcement is one line, and it belongs in the module (which knows its own
shape) or in the core keyed on a module-declared flag: a pre-fund module should require
the referenced leg's recipient to be `address(this)`.

### What this does to the remaining phases

- **Phase 3 (shared helpers) — DEMOTE.** `ScopedApproval` / `MeasuredForward` were
  designed to make the *pull* classes unrepresentable. Pre-funding already does that
  structurally, and better. Building them now hardens the older path while the
  newer one goes unread. `ProratedBound` and `Narrow160` stay — they are already
  landed and they serve real pull-side sites.
- **NEW Phase 3 — audit the pre-fund family.** It is the preferred path, it is
  unaudited, and it introduces a genuinely new accounting model (fund-from-own-
  balance) whose safety rests on one documented-but-unenforced pairing rule. Same
  twelve-lens treatment the pull family got.
- **Phase 4 (AST detectors) — PROMOTE.** There are now two module families with
  different shapes. A detector that only knows the pull idiom will report clean on
  push code it cannot see — which is precisely the failure mode that made the G-13
  sweep lie twice. Build the detectors before the next sweep, not after.

## Phase 3 — make the class unrepresentable

Every finding above is a hand-rolled repetition of a pattern that already exists as
a shared helper elsewhere. Patching 30 sites leaves the 31st to be written next
quarter. After Phase 2 lands, collapse the patterns into internal libraries whose
*shape* forbids the defect:

- **`ScopedApproval.approveAndClear(token, spender, amount)`** — cannot leave a
  standing grant, because clearing is inside the helper.
- **`MeasuredForward.forward(token, receiver, amount, balBefore)`** — cannot forward
  an unmeasured nominal.
- **Extend `DustHandler`** so the floor is a required parameter at every sweep site
  rather than an overload callers may skip.

Plain internal libraries only — same shape as `DustHandler`, `FullFillGuard`,
`PermitHelper`. No delegatecall, no facets, no external-library splits.

---

## Phase 4 — detection you can trust

The greps that produced G-13 are not fit to verify this plan. Replace them:

1. **Semgrep rules over the AST**, one per class, matching on effect rather than
   spelling. Every rule must be validated against a known-positive *before* its zero
   is believed.
2. **Run `variant-analysis`** (installed, unused) after each fix — it is built for
   exactly the "where else does this occur?" question that has now found more sites
   four times running.
3. **Run `token-integration-analyzer`** over the modules: this whole audit assumed
   fee-on-transfer and under-delivering tokens matter, and never systematically
   checked which listed markets actually have them. That assumption is load-bearing
   for 2b's severity.
4. Add each class to `docs/edge-case-matrix.md` as a must-not cell so it is checked
   by construction on the next module.

---

## Verification gates (every phase)

1. Regression test that **fails against the pre-fix code** — demonstrated three
   times this round as the only thing separating a real fix from a vacuous one.
2. Class detector re-run over the **whole tree**, not the diff.
3. `make test-all` — read `make`'s own `$?`, never a piped `tail`/`grep -c` exit
   code, and classify every failure as environmental or real before calling it.
4. `make size-check` on a clean `out/core-deploy` for any core change. Settlement
   has **91 bytes** of headroom.

---

## What this plan deliberately does not do

- **No architectural rework.** Every finding is a break in a rule the codebase
  already has. The answer is more instances and better enforcement, not new
  structure.
- **No fix for the min-direction bounds.** They fail closed today; scaling them
  would loosen a safe guard.
- **No severity inflation.** One Critical (PoC'd). One class that harms honest
  makers. The rest are Medium hygiene whose exploit requires a balance at the
  module that is not the attacker's — real, worth closing, not an emergency.
