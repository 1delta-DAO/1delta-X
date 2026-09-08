# Twelve-lens audit of the pre-fund-module family (2026-09-03)

Scope: the 15 new `*PreFundModules.sol` files (24 contracts, 2,866 lines) plus
`packages/core/src/settlement/Base.sol` — 16 files, 3,942 lines. Twelve
independent lenses, deduplicated to 14 unique `(contract, function)` groups.

**Four Criticals, three with executed PoCs.** The family as shipped is drainable
by any EOA with no order, no signature, and no capital.

---

## Why this run was necessary

`docs/audit-2026-09-modules-plan.md`'s REASSESSMENT section — written before this
run — ranked the pre-fund shape's one known gap at **Medium** and proposed a one-line
recipient check in `_forSlice`. That assessment was wrong in the way that matters:
the primary attack channel does not go through `_forSlice`, or through Settlement,
or through a signed order at all. The proposed fix would have read as closed while
leaving the drain fully open.

The fix direction moved **four times** during the run:

| # | Proposed | Defeated by |
| --- | --- | --- |
| 1 | require `legRecipient == module` | leg token never bound to `data.asset` (invariant) |
| 2 | Teller's `balanceOf(this) - forAmount` floor | attacker sets `forAmount = residue` (math-precision, then 4 more) |
| 3 | recipient **and** token binding | one leg funds N items (asymmetry) |
| 4 | any core-side binding | primary channel never enters the core (execution-trace, trust-gap) |

Only the fourth reading survives all twelve lenses.

---

## C-1 — `forAmount` is an unauthenticated argument of a permissionless entrypoint

**CONFIRMED — PoCs executed, 6/6 passing.** Agents: 10 of 12.
Group: `PreFundModules | takeForOnBehalf | unattested-funding-amount`

```solidity
// TakerAllowance.sol — approveTaker's `spender` is unrestricted
_takerAllowance[msg.sender][spender][module][ref].grant(amount, expiration);
// takeFor meters `amount`, forwards `forAmount` verbatim
_takerAllowance[user][msg.sender][module][ref].spend(amount);
ITakerForModule(module).takeForOnBehalf(user, amount, forAmount, receiver, data);
```

`user == msg.sender == attacker` self-grants one unit. `forAmount` is metered by
nothing. The modules' sole gate is `msg.sender == permit3`, so **Settlement, the
order and the maker's signature are all out of the path.**

`takeFor`'s own comment justifies leaving `forAmount` ungated because it is
*"bounded by the user's token allowance to the module"* — a **pull-module**
premise. Pre-fund modules never call `transferFrom`, so nothing bounds it.

Two zero-capital drain primitives:

- **(a) zero-debt sweep, no attacker venue at all.** Name a `debtToken` / `spoke` /
  `silo` / `comet` / `tm` reporting zero debt → `toRepay = 0` → the venue block is
  skipped entirely → `safeTransfer(asset, onBehalfOf, forAmount - 0)`.
- **(b) scoped approval.** Name an attacker-controlled `pool` / `comet` / `morpho`
  → `forceApprove(asset, venue, forAmount)` → the venue pulls it. The F25/A-3
  scoping mitigation bounds the approval at `forAmount`, which is the attacker's
  own number.

**28 contracts across 14 venues.** Midnight and Liquity are *not* protected by
their immutable venues — Midnight's `market` tuple and Liquity's `collateralToken`
still ride in `data`.

Falsifies two prose guarantees in `ITakerForModule.sol`: *"deposits instructed
always equal deliveries enforced"* and *"mis-pairing fails closed"* (true only at
exactly zero balance), and defeats the F19 floor discipline all 11 repay modules
document.

### Fix options (distinct, preserved verbatim)

**Option A — bind the caller (sound).** Pin an immutable Settlement in each push
module and have `Permit3.takeFor` forward its `spender`, so the module can require
`spender == SETTLEMENT`. Attacks the actual root: `takeFor`'s spender is
`msg.sender` and anyone can be it.

**Option B — measured receipt (module-local).** Snapshot on entry and require the
*increase*, not a subtraction the attacker keeps non-negative:
`require(balanceAfterDelivery - entrySnapshot >= forAmount)`.

**Option C — core-side binding (partial).** `_forSlice` requires
`legRecipient == module` for a pre-fund descriptor. **Closes only the order-borne
channel**; C-1's primary path never reaches the core. Not sufficient alone.

---

## C-2 — `Base._runItem` strands a delivered leg on a zero slice

**CONFIRMED — PoC executed, 2/2 passing** (`packages/core/test/zzpoc/ZZZeroSliceStrand.t.sol`).
Agents: 6 of 12. Group: `Base | _runItem | zero-slice-strand-after-delivery`

The only Critical with an **honest victim** — it harms a maker who signed a
correct order.

```
anchor = 1e18, item.amount = 1, legsOut[0] = 1000e6 USDC → pre-fund module
fill(anchor - 1):
  amt   = ceilDiv((1e18-1) * 1000e6, 1e18) = 1000e6  → DELIVERED in full
  slice = 1*(1e18-1)/1e18 - 0              = 0       → item SKIPPED
  maker pays 999999999999999999 of tokenIn, receives nothing
```

Ordering is fixed: `_deliverOutputs` (Core.sol:972) precedes `_executeItems`
(Core.sol:981). The zero-test is applied to `item.amount`'s floor-differenced
slice while the value that moves is `outputAt`'s **ceil**-rounded delivery — two
quantities, two denominators, opposite rounding, one gate.

The skip's justification (*"dust slices accumulate exactly across fills"*) is true
for `MAKE`/`TAKE`, where `amount` **is** the value that moves, and false for
`TAKE_FOR`, whose value-in side the core has already paid out.

`item.amount = 1` is not exotic — every push header describes `amount` as
*"vestigial"*, *"a pacing figure"*, *"an `amount` these modules never spend"*.

**This is the residue generator that supplies C-1's precondition.** The second
test in the same file drains the strand, so a filler manufactures the pot from a
chosen maker's order and empties it in the same block.

**Fix:** treat a zero slice on `TAKE_FOR` as `SETTLE` does —
`if (op == uint256(ItemOp.SETTLE) || op == uint256(ItemOp.TAKE_FOR)) revert SettleSliceZero();`
`item.amount == anchor` (the SDK convention) prorates to exactly `fillAmount` and
is unaffected.

---

## C-3 — the venue is paid twice

**CONFIRMED — PoC executed** (the boundary lens's Morpho double-pay case, since
folded into the regression suite).
Agent: boundary. Group: `PreFundRepayModules | _repay | trusted-return-value`

`MorphoBluePreFundRepayModule` and `ExactlyPreFundRepayModule` size their sweep from the
**venue's own return value**, and the venue rides in `data`:

```
takeFor(forAmount = 50,000e6)
  → forceApprove(USDC, LyingMorpho, 50,000e6)
  → LyingMorpho pulls the full approval, returns repaid = 0
  → module computes forAmount - 0 → safeTransfer(USDC, attacker, 50,000e6)
→ 2 × forAmount extracted
```

Module 100,000e6 → 0; attacker 0 → 100,000e6, from a `forAmount` of 50,000e6.

Every sibling is immune to this variant: Aave/Comet/Silo/Venus/CompoundV2 size the
sweep from their own `toRepay`; Lista/River/Liquity measure a balance delta. Only
these two trust a return value from a caller-chosen address.

**Fix:** measure the delta across the venue call, as three siblings already do.

### C-3b — approval granted before a maker-chosen external call

**PLAUSIBLE.** Agent: periphery. Same `(contract, function)`, distinct mechanism.

`MorphoBluePreFundRepayModule._repay` grants `forceApprove` *before* `_debtAssetsUp`
calls the maker-chosen `morpho.accrueInterest()`. The attacker pulls through the
live allowance during that call, returns `repaid = 0`, and collects a second
`forAmount` through the sweep.

---

## C-4 — Teller's floor is not a receipt check

**CONFIRMED — PoC executed** (the boundary lens's Teller under-ask case).
Agents: 5 of 12. Group: `TellerPreFundRepayModule | _repayAndSweep | incomplete-guard`

```solidity
uint256 floor = IERC20(principalToken).balanceOf(address(this)) - forAmount;
```

Documented as making a mis-paired leg *"fail closed"*. It underflows only when
`forAmount > balance` — an **over**-request, which an attacker never needs. Set
`forAmount == balance` (floor = 0) or under-request repeatedly:

```
seeded 100,000e6 → takeFor(99,000e6) → takeFor(999e6) → attacker 99,999e6
```

A floor cannot be a delivery proof when the attacker chooses the subtrahend. This
is why fix Option B must check the **increase** against an entry snapshot, not a
subtraction.

**Note on our own PoC.** Our staged Teller "is immune" case
asserts immunity and passes — it tests `forAmount (100,000e6) > balance
(50,000e6)`, the irrelevant case. Both tests now pass simultaneously, which is the
contradiction that exposes it. **Delete or invert it.**

---

## H-1 — `_forSlice` binds neither recipient, token, nor consumption

**CONFIRMED by code read.** Agents: 6 of 12. Group: `Base | _forSlice | missing-binding`

Three distinct mechanisms, all live:

1. **Recipient.** `if (legRecipient != address(0) && legRecipient != order.maker && legRecipient != module) revert ForLegNotMakers();`
   admits `address(0)` and `order.maker`. `Core.sol:1063` resolves `0 → maker`, so
   both admitted non-module recipients route the delivery to the wallet while
   `forAmount` still reaches the module.
2. **Token.** The leg's token is never compared to `data.asset`. `Pricing.outputAt`
   returns a bare `uint256`; the token never leaves the core. So even with
   `legRecipient == module`, an attacker satisfies the recipient with a
   self-minted token sized at 10^24 while `data.asset` names USDC.
3. **Consumption.** `_forSlice` is a pure re-pricing with no bookkeeping, and
   `_executeItems` walks every item unconditionally — so N items may each carry
   `desc & 0xffff == j` and each receive the full `outputAt(ctx, j)`. One delivery,
   N claims. `Batch`'s `PlanBadStep` covers repeated *schedule units*, not two
   items naming one leg.

Mechanism 3 survives fixes for 1 and 2, which is why the recipient-only proposal
was insufficient.

**Fix:** reserve a descriptor bit for the PRE-FUND shape and require
`legRecipient == module` when set; forward the leg's token so the module can
assert it equals `data.asset`; track referenced `legsOut` indices in a `FillCtx`
bitmask and revert on a second reference.

---

## H-2 — root-derived dispatch, `data`-derived accounting

**PLAUSIBLE.** Agents: economic-security, first-principles.
Group: `LiquityV2/RiverPreFundRepayModule | _repay | accounting-token-not-root-derived`

Both derive their *dispatch target* from a trusted root — `authorizeTrove` off the
immutable `collateralRegistry` (the F26/C-1 fix), River's diamond delegate check —
then read the *accounting token* straight from `data`:

```solidity
balBefore = IERC20(boldToken).balanceOf(address(this));   // boldToken ← data
```

Liquity's `repayBold` burns BOLD from `msg.sender` with **no ERC20 approval**, so
the burn is not gated by the named token. Substituting `boldToken = USDC` makes
`burned` read 0 while real BOLD leaves, and the sweep pays out `forAmount` of USDC.

**F26/C-1 rerooted the target and left the token behind.** Half the pair is now
trustworthy, which makes the disagreement exploitable in a way it was not when
both halves were equally untrusted. The add-collateral sibling is *accidentally*
safe — `addColl` needs an approval, scoped to the wrong token, so it fails closed.

**Rule:** derive the accounting token from the same root as the dispatch target.

---

## H-3 — Phase 1's unscaled-bound fix never reached the pre-fund family

**PLAUSIBLE.** Agent: numerical-gap.
Group: `ExactlyPreFundRepayModule | _repayAndSweep | unscaled-bound-partial-fill`

On the fixed branch, `positionAssets` rides **unscaled** in `data` while
`forAmount` is this fill's pro-rated delivery. That is the F26/H-1 class closed in
Phase 1 with `@lib/ProratedBound`. The pre-fund modules were written afterwards and
reintroduced it.

The header argues fail-closed because an under-covering slice reverts
`Disagreement`, but with a large early-repay discount the full face's
`actualRepayAssets` can fall under a *partial* slice's `forAmount`: the first slice
retires 100% of the fixed position and later slices re-present the same
`positionAssets` against an empty one.

**Process finding:** a fix applied to 22 sites does not hold when a 15-file family
lands afterward without the detectors being re-run. Phase 4 (AST detectors) should
gate new files, not just sweep existing ones.

---

## M-1 — clamp-based sweeps strand the difference (residue generator #2)

**PLAUSIBLE — needs a fork run.** Agents: 5 of 12.
Group: `AavePreFundRepayModules | _repay | unmeasured-venue-consumption`

Aave v2/v3 size the sweep from the pre-call clamp, not the measured pull.
`rateMode` and `debtToken` are independent maker-signed words with no cross-check,
and Aave's `executeRepay` pulls `min(amount, debtOfThatRateMode)`:

```
debtToken = variableDebt (1000), rateMode = 1 (stable, 300), forAmount = 3000
toRepay = 3000 → Aave pulls 300 → sweep guard 3000 > 3000 is false → 2700 stranded
```

Aave reverts only when `paybackAmount == 0`, so most mismatches pass quietly. Same
shape in Aave v4 (`getUserTotalDebt` vs the giver PM's actual pull), Comet,
CompoundV2, Venus, Silo, Midnight. The siblings that measure across the call
(Liquity, River, Lista, Teller) do not have it.

---

## Leads (not gated to findings)

- **`MidnightPreFundRepayModule` unit mixing.** `debtUnits` is in zero-coupon credit
  units, `forAmount` in loan tokens; `toRepay = min(forAmount, debtUnits)` mins
  across dimensions, then feeds both `forceApprove` (tokens) and `repay` (units),
  and sweeps `forAmount - toRepay` (tokens − units). Rests on *"1 unit == 1 loan
  token at repayment"*, asserted in a comment and confirmed by no on-chain read. A
  5% early-repay discount strands 50 per 1000. **Needs a fork check on Midnight's
  pre-maturity pricing.**
- **`AaveV4PreFundRepayModule` ignores the returned `assets`** from the position
  manager (invariant lens).
- **Preflight is structurally blind.** Every pre-fund module's
  `IFundingSource.fundingSource` returns `available = type(uint256).max`, and
  `SettlementLens._takeForItemAt`'s only mis-pairing detector is `available == 0`.
  Its comment reasons about a *pull* module under a module-addressed leg and never
  the reverse. So an order that spends a singleton's balance passes
  `validateOrder`, `previewTakerAllowances` and `previewItemFunding` clean — the
  F21 class with the answer switched off for this family.
- **Fee-on-transfer funding tokens.** The module spends `forAmount` while
  receiving `forAmount·(1−fee)`; the deficit draws down the singleton on every
  fill, with no fail-closed signal.

---

## Checked and clean

Recorded so nobody re-chases them:

- `Base._callWithTail`'s hand-rolled encoder — offset/length/`calldatacopy`
  verified for n = 2/3/4/5; the a4 slot is provably overwritten for n ≤ 4.
- `ForBalanceBelowFloor`'s `need` arithmetic cannot overflow inside `unchecked`
  given the `floorBps <= 10_000` clamp (the F25/G-4 fix holds).
- `Pricing.outputAt` is deterministic within a transaction (`ctx.bump` pinned at
  `_openFill`), so `_deliverOutputs` and `_forSlice` cannot be made to disagree by
  an interleaved item — the price-manipulation line of attack is closed.
- `ctx.fullFill` is exactly `prevFilled == 0 && newFilled == total`
  (`OrderState.sol:436`); the `_prorate` shortcut is correct.
- **`Batch` rejects `TAKE_FOR` outright** (`Batch.sol:430`), closing every
  netted-schedule variant. This is contained to the single-order path.
- `extcodesize` is inserted on every venue call; Solady's `safeTransfer` /
  `forceApprove` re-check on failure, so a codeless target reverts.
- `IExactlyMarket.repayAtMaturity`'s single-word return matches the deployed
  Market; the 2026-09-03 interface fix is in the tree.
- `CompoundV2PreFundDepositModule` floors cToken receipt forwarding at the pre-mint
  balance — correct, and the only deposit module that measures anything.

---

## Method notes

- **Corroboration, not authority.** The first-principles agent hallucinated a
  system notice and then wrote a paragraph reconciling its two mentions as if it
  were real. Its audit content survives only because every substantive claim was
  independently reached by other lenses. Treat single-agent, single-mechanism
  findings as leads until corroborated or PoC'd.
- **Agents that ran `forge` against the default profile all failed**, hitting a
  pre-existing unrelated `Stack too deep` at
  `packages/modules/bridge/src/out/AcrossBridgeOutModule.sol:119`. The per-package
  profiles work: `FOUNDRY_PROFILE=core` and `modules-aave-v3-fork` (the non-fork
  aave-v3 profile scopes `test` to `test/unit` and finds nothing under `zzpoc`).
- **A passing PoC is not a proved invariant.** Our staged Teller "is immune"
  case passed while asserting the opposite of the truth.

---

## Fixes applied (2026-09-04)

**C-1 — Option A + B, as chosen.** The two compose; neither stands alone.

*A (caller binding).* `Permit3.takeFor` now forwards its own `msg.sender` as a
`spender` argument on `ITakerForModule.takeForOnBehalf`, and every push contract
pins an immutable `settlement` and calls `PreFundGuard.requireSettlement`. Note the
ABI of `takeFor` itself is unchanged, so **Settlement's bytecode was untouched by
this half** — the 54-byte EIP-170 headroom was never at risk. 28 pre-fund contracts
gated; the 4 pull/fused `TakeFor` modules take the parameter and ignore it.

**The 28 figure is the finding's own count, and I had it wrong at first.** Four
pre-fund contracts (`AaveV3PreFundLeverageModule`, `DolomitePreFundTakeForModule`,
`FluidPreFundTakeForModule`, `EulerV2PreFundTakeForModule`) live inside files whose
*other* `TakeFor` module is pull-shaped, so a per-file classification missed them.
One contract per file is not a safe assumption in this tree.

*B (receipt floor).* `@lib/PreFundGuard` — `requireDelivered` on the deposit shapes,
`floorOf` + `sweepSurplus` on the repay shapes. The floor is Teller's line, which
was drained on its own; under A it becomes a real mis-pairing detector, and it
covers all three of H-1's unbound axes in practice (wrong recipient → no balance;
wrong token → no balance; second claim on one delivery → first claim consumed it).

**C-2.** `Base._runItem` now reverts `SettleSliceZero` on a zero-slice `TAKE_FOR`
as it already did for `SETTLE`. Cost: **20 bytes** — Settlement 24,522 → 24,542 of
24,576, clean-built. All 779 core tests pass unchanged, which says no existing
test depended on the silent skip.

**C-3 / C-3b / M-1, closed together by construction.** Every repay sweep now calls
`PreFundGuard.sweepSurplus(asset, maker, floor)` — return everything above the
pre-delivery floor. That IS `forAmount - consumed`, without anyone computing or
being *told* what `consumed` was, so it is immune to a lying venue's return value
(C-3) and to a pre-call clamp that over-states the pull (M-1) in one stroke. The
`consumed` / `repaid` / `burned` / `spent` locals are gone from all 13 repay
modules. Morpho additionally moved `_debtAssetsUp` above the `forceApprove`, so no
allowance is live across the maker-chosen `accrueInterest` call (C-3b).

**C-4.** Fixed by A: Teller's floor was never the problem, its unpinned
`forAmount` was.

**H-2.** Closed by B rather than by re-rooting the token: the floor requires the
delivery in the *named* `boldToken`, which ties the accounting token back to the
burned one. Re-deriving it from the TroveManager was rejected for now — the
interface notes `boldToken()` REVERTS on mainnet BorrowerOperations, and I could
not fork-verify whether TroveManager exposes it. Liquity also had to authorize
*before* measuring, so a foreign trove still reports `InvalidCaller` rather than an
arithmetic panic.

**H-1 — core-side binding, the recipient axis.** Descriptor **bit 253** declares
the PRE-FUND shape; `_forSlice` then requires `legRecipient == module` instead of the
loose `{0, maker, module}`. All 15 one-sided pre-fund modules *require* the bit, so a
maker cannot opt back into the loose check.

It only fit on the second try. The natural two-branch form measured **24,579 —
three bytes OVER EIP-170**; folding it to a single revert site saved 11 and landed
at **24,568 / 24,576**. Both numbers are from a wiped `out/core-deploy`.

The token and consumption axes stay module-side, where B already covers them:
forwarding the leg's token would change `ITakerForModule` again, and a consumption
bitmask needs a `FillCtx` field — neither fits in 8 bytes. Recorded rather than
pretended-away.

*Cost of the bit:* pull and push variants can no longer share one signed blob.
Three fused packages (fluid, euler-v2, dolomite) had comparison tests built on
exactly that, and their taker grants are keyed on `keccak256(data)`, so they now
build two. That is the fix working — the shape is part of what the maker signs
precisely because the core cannot infer it.

**H-3 — `ExactlyPreFundRepayModule`'s unscaled face.** The pull sibling gets scaling
for free (its face IS the pro-rated item `amount`); the pre-fund shape has no such
number, so the face rode unscaled and every slice presented the whole position.
Now scaled by `forAmount / totalForAmount`, with the total as a new trailing word
(**BREAKING** for this module's blob), floored so slices under-retire rather than
over-retire.

**The Midnight unit-mixing lead — materially closed, not by a fork check.** There
is no deployed Midnight anywhere in the tree, so the check was never performable;
the test double asserts the very equality in question. What actually mattered was
the strand, and `sweepSurplus` removed it: the leak was `forAmount - toRepay`,
loan tokens minus debt units. Both directions now fail safe — a discount is swept
back to the maker, and a unit costing more than a token leaves the scoped approval
short and reverts. Only the cap stays imprecise. Documented at the site.

### Corrections made while fixing

- The templated floor comment I scripted onto Lista and River claimed the venue
  moves a root-derived asset without an approval. False for both — they pull
  through a scoped approval, which binds the token by construction. **H-2 is
  specific to Liquity**, whose `repayBold` burns directly from `msg.sender` with no
  approval at all.
- Liquity had to authorize *before* measuring, or a foreign trove reported an
  arithmetic panic instead of `InvalidCaller`.

### Still open

- H-1's **token** and **consumption** axes, module-side only (8 bytes left).
- Midnight's units-per-loan-token equality, if a deployment ever exists to read.

### Verification

Full suite green except where noted: the last complete run was 35/36 with a single
Liquity failure, which the ordering fix above resolved (liquity 28/28 in
isolation, and no other source changed after that run). `make size-check` clean on
a wiped `out/core-deploy`. New regression test
`aave-v3/test/security/PreFundSpenderAuth.t.sol` — both drain variants now revert
`OnlySettlement`, plus a positive control proving the gate is spender-shaped and
not a blanket freeze.

The eight `zzpoc/` PoCs are deleted, their content folded into that file.
The Teller "is immune" case is gone rather than kept: it asserted immunity
to the one case an attacker never uses, and it passed the whole time.

---

## Post-fix assessment (2026-09-04)

Asked whether the family is now correctly assembled and free of drain vectors, I
audited it mechanically rather than by inspection — and the audit found seven
holes my own fix scripts had left.

### The three-guard census

A push contract is any implementing `takeForOnBehalf` that never calls
`permit3.transferFrom`. There are **34** (plus 4 pull-shaped `TakeFor` modules).
Each must carry all three of:

| | guard | closes |
| --- | --- | --- |
| **S** | `PreFundGuard.requireSettlement(spender, settlement)` | the direct-`takeFor` channel (C-1) |
| **F** | `PreFundGuard.floorOf` / `requireDelivered` | wrong recipient, wrong token, double-claim (H-1) |
| **B** | descriptor bit 253 required | stops a maker opting back into the loose core check |

First run: **7 gaps.** Two were false positives (Teller and Fluid held correct
floors written inline rather than through the library). Five were real:

- **`MorphoBluePreFundSupplyCollateralModule`**, **`MidnightPreFundSupplyCollateralModule`**
  — no floor. My deposit-floor script used `re.search`, which matches the FIRST
  approve site per file. Both files hold two or three contracts, so only the first
  was patched. A `finditer` would have caught it; a per-file assumption did not.
- **`AaveV3PreFundLeverageModule`**, **`DolomitePreFundTakeForModule`**,
  **`EulerV2PreFundTakeForModule`** — no floor, and none of the four fused push
  contracts required bit 253. These live in files whose *other* `TakeFor` module is
  pull-shaped, and my `*PreFund*.sol` glob never reached them. **This is the second
  time the same blind spot bit** — it is also how I first miscounted the family.

  Checking the retained audit bundles afterwards sharpened this considerably: none
  of the four appears in EITHER run's source snapshot. They were written after the
  last bundle was built, so **no lens has ever read them** — the census is the only
  thing that has. Recorded in [audit-runs.md](./audit-runs.md).

`AaveV3PreFundLeverageModule` carried the audit's disproven claim in its header
verbatim: *"An unfunded balance (a mis-paired maker-addressed leg) makes the supply
revert — fail closed."* True only at EXACTLY zero balance.

Census now reads **34 / 34 with S, F and B. Zero gaps.**

### Second pass — ordering and value movement

Guard presence is necessary, not sufficient, so a second scan checked that the
floor *precedes* the first value movement, that no sweep is sized from a venue's
report or a pre-call clamp, that payouts go to `onBehalfOf`, and that every scoped
approval is cleared. Two hits, both false positives, both worth recording because
the reasoning is not obvious:

- **`AaveV3PreFundLeverageModule` pays `receiver`, not `onBehalfOf`.** Correct: it is
  a composite, and the borrow proceeds fund the order's input legs through
  Settlement. The amount is the taker-metered slice and is delta-verified
  (`require(received >= amount)`) against the borrow this call performed.
- **`FluidPreFundTakeForModule` appears to leave an approval live.** `_returnUnused`
  returns early when `bal <= floor`. But `allowance == bal - floor` identically —
  the vault's only path out is that approval — so the early return happens exactly
  when the allowance is already zero.

A third scan looked for value movement outside `safeTransfer`/`forceApprove`. One
result: Fluid's just-in-time NFT custody, which pulls from and returns to
`onBehalfOf` only, so it carries no cross-maker path.

### The four drain vectors, and why each is closed

| Vector | Closed by |
| --- | --- |
| Direct `takeFor` with an invented `forAmount` | **S** — all 34 |
| Order-borne leg addressed to the maker/`address(0)` | **B** + core bit 253 + **F** |
| Leg denominated in a token the module never received | **F** — must hold `forAmount` of its OWN decoded asset |
| One delivery claimed by N items | **F** — the first claim consumes the balance, the second underflows |

Residue harvesting needed one of those four, and the two in-protocol residue
generators (the zero-slice strand, the clamp-sized sweep) are themselves closed.

### What this does NOT establish

- **Deployment.** No script in the tree constructs a pre-fund module, so the
  `settlement` pin is the integrator's responsibility. A wrong or zero pin bricks
  the module rather than opening it — fail-closed, but it will not be caught here.
- **Preflight.** `fundingSource` still returns `type(uint256).max` for the whole
  family, so `SettlementLens` cannot flag a mis-paired pre-fund item. Bit 253 now makes
  the shape readable, and the lens has 2.8KB spare.
- **The venue contracts themselves**, which are integrations, not this code.
- Absence of proof is not proof of absence: this is a census against four known
  vector classes plus three mechanical scans, not a claim that no fifth class
  exists.

### Verification

23 packages, 0 failures. `size-check` 24,568 / 24,576 clean-built. `modules-check`
113 taker contracts, each exactly one shape. `docs-check` clean. `gas-check` clean
after `rm -rf cache/test-failures` — the five diffs before that were all
`testFuzz_*`, the known fuzz-cache false alarm, with no deterministic test moved.

---

## Module consolidation (2026-09-04)

The pre-fund family shipped as one contract per venue per op — 30 contracts across 14
files, 19% of their code an identical hand-rolled guard preamble. That duplication
is what let five contracts ship without a floor. Consolidated:

**30 pre-fund contracts → 14.** One per venue, ops dispatched on a discriminator.

- `@lib/PreFundModuleBase` — the three guards INHERITED rather than re-typed, so "a
  pre-fund module without the gate" stops being a thing that compiles.
- The op rides in descriptor bits **[244,252)**, which `Base._forSlice` provably
  never reads (it reads 255, 254, 253 and [0,16)). No new `data` field, no layout
  change — and because it is inside `keccak256(data)`, **the taker grant binds the
  op**: a grant signed for Supply cannot be replayed as Repay.
- Measured on aave-v3: **4,239 B in 2 contracts → 2,774 B in 1**, a 35% bytecode
  drop on top of halving the deployment count.

### The one-shape rule was relaxed correctly, not dropped

`take` and `takeFor` may now live in one contract, but only because the two data
spaces are provably disjoint at word 0: a pre-fund blob is `>> 253 == 5`, a plain-take
blob opens with an address / `MarketParams` head / `uint8` op, all below `2^160`
(`>> 253 == 0`). Assert both halves — `PreFundGuard.requireLegRef` and
`PreFundGuard.requirePlainTake` — and no blob is accepted by both entrypoints, so no
`ref` can be valid for both shapes.

`tools/check-module-shapes.py` now enforces exactly that: dual-shape permitted,
**only with both guards present**, naming the missing one otherwise. Negative-tested
in both directions. The invariant changed shape; it did not become prose.

### What the mechanised merge got wrong, and how it surfaced

The transformer dropped things that were per-contract rather than per-function:
constants (`DYNAMIC_LOAN`, Morpho's virtual offsets), a `using ... for` directive,
and two immutables. All caught by the compiler.

**One class the compiler could not catch**: it kept only the FIRST contract's
`fundingSource`. Three modules were genuinely wrong —

| module | why |
| --- | --- |
| Midnight | SupplyCollateral carries a trailing `collateralIndex`; Repay does not → out-of-bounds read |
| Lista | SupplyCollateral's third field is a `MarketParams` STRUCT, BrokerRepay's a plain `address` → head offset into nonsense |
| Morpho Blue | all three ops share one layout but fund DIFFERENT members of it — SupplyCollateral moves collateral, the others the loan token |

Only Midnight's was caught by a test. My first audit compared decode *shapes* and
passed Morpho; the defect was in the extracted *field*. A second audit on the
funded-asset expression found it, and flagged three more (Liquity, River, Teller)
that proved false positives — same slot, different variable name. All three real
cases now dispatch `fundingSource` on the op.

The lesson is narrow and worth keeping: **a mechanical merge is only as good as the
property you audit it against, and shape is not the same property as content.**

### Where it stands

| shape | before | now | still mergeable |
| --- | --- | --- | --- |
| MAKE | 50 | 50 | 22 |
| TAKE | 32 | 32 | 9 |
| TAKE_FOR | 38 | **23** | 4 |
| all | 120 | **105** | 35 |

The 4 remaining TAKE_FOR pairs are the fused files, and they should NOT merge: each
holds a pull-funded and a pre-funded `TakeFor`, and one contract must keep one
FUNDING shape — the balance floor is only sound in a contract that never pulls.

MAKE and TAKE consolidation is the same pattern but a more invasive change: their
`data` has no descriptor word with free bits, so the op needs a `uint8` prefix
(the `MorphoBlueTakerModule` layout), which shifts every tail offset —
`DustHandler`, `FullFillGuard`, `PermitHelper`, `DelegationHelper` — and every SDK
encoder. Cheap for preFund, not for these.

## Open tasks

1. Re-run every F25/F26 detector over the pre-fund family — H-3 exists because a fix
   applied to 22 sites did not gate the 15 files that landed after it. This is the
   process gap, and it is the one still unaddressed. Its twin is now recorded in
   [audit-runs.md](./audit-runs.md): four pre-fund contracts have never been read by any
   lens run, because a scope fixed at bundle-build time cannot cover code written
   afterwards. A lens run over `AaveV3FusedModules.sol`, `DolomiteModules.sol`,
   `EulerV2Modules.sol` and `FluidModules.sol` is the concrete next audit.
2. SDK: the pre-fund descriptor now carries bit 253, and `ExactlyPreFundRepayModule`'s
   blob has a new trailing word. Both are breaking for off-chain encoders.
3. The preflight remains blind to a mis-paired pre-fund item — every pre-fund module's
   `fundingSource` returns `type(uint256).max`, so `SettlementLens`'s only detector
   (`available == 0`) cannot fire. The lens has 2.8KB of headroom; the recipient
   rule is now expressible there for free, since bit 253 makes the shape readable.

### Regression tests, each verified to fail against the pre-fix code

| Test | Pre-fix result |
| --- | --- |
| `PreFundSpenderAuth` (2 drain variants + positive control) | attacker ends with the singleton's balance |
| `test_preFundDescriptor_requiresModuleAddressedLeg` | `unfunded` from deep in the module, not `ForLegNotMakers` |
| `test_preFundRepay_fixed_partialSlices_scaleTheFace` | `Disagreement` — one half-slice retires the whole face |

The middle row is the interesting one: pre-fix the *module's* floor was the only
thing stopping it, which is exactly the layering A + B was chosen for.
