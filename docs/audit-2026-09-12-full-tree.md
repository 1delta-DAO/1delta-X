# Twelve-lens audit of the full tree — lending × matching × pre-fund (2026-09-12)

Scope: **120 files, 27,803 lines** — everything under `packages/*/src` except
`interfaces/`, `vendor/`, `script/` and the view-only `SettlementLens.sol`: core
settlement + Permit3, all 17 lending venue packages with every `*PreFundModules.sol`,
the fill/maker/nft/oco/pricing/transfer/redeem/bridge modules, solvers, validators
and periphery. Twelve independent lenses, each additionally briefed to weight (1)
the lending modules, (2) their combinations inside `Batch.sol`'s matching paths and
(3) the pre-fund / PUSH-MAKE / `TAKE_FOR` seams. Deduplicated to 32 unique
`(contract, function)` groups: **6 findings, 26 leads.**

**The three emphasised seams held.** Every lens inverted `Base._forSlice` ↔
`ctx.outs`/`outsUsed` ↔ `PreFundGuard.floorOf` (recipient, token, single-use and
override axes), every `takeForOnBehalf` spender pin, and the `matchSettle` ledger
(PRESEND-before-refund, over-producing items, same order twice, hoisted items,
lying leg tokens) and found nothing. What broke lived **outside** the seam: the one
push-funded MAKE that never adopted the descriptor, an escrow whose identity omits
its refund target, and three more "patch hit one sibling, missed the neighbour"
instances.

**All six fixed 2026-09-14.** Two findings carried executed PoCs.

---

## Findings

### 1 — `BridgedOrderInbox._credit`: the first credit owns the refund beneficiary and expiry — **FIXED**

Confidence 90 · agents 2/12 · PoC passes (`modules-bridge`)

`_credit` set `k.beneficiary` only on the first credit for an `orderHash` and took
`k.expiry = max(...)` over all credits. Neither field is part of the order hash,
and bridge deliveries are unauthenticated on the destination: any Across depositor
can author a commitment naming any hash and self-relay it. A 1-wei front-credit
`(H, attacker, dstChainId, 2^32-1)` therefore made the attacker the refund
recipient of the victim's entire unfilled / over-floor escrow at `settle(H)`, and
parked the fallback unlock in 2106 for an order that never activated. The README's
"authoring above the floor is fail-safe: the funds come back" was false under it.

**Fix.** Every later credit must carry the pinned beneficiary — the Across relay
reverts `BeneficiaryMismatch`, the LayerZero path orphans — and `expiry` is the
**minimum** over credits. A stranger can still copy the victim's beneficiary, so a
max would still let them park the unlock in 2106; the worst a minimum admits is an
*early* refund, to the pinned beneficiary. Regression: `InboxAccounting.t.sol`
(`laterCreditWithDifferentBeneficiaryReverts`, `laterCreditCannotRaiseExpiry`,
`sameBeneficiaryCreditsAccumulate`). The stronger shape — keying `commits` by
`(orderHash, beneficiary)` — was not taken: it changes `activate`/`settle`/`sync`
signatures for a property the mismatch check already gives.

### 2 — `NativeUnwrapModule`: signed constant vs auction-priced delivery — **FIXED**

Confidence 90 · agents 7/12 · two independent mainnet-fork PoCs pass

The module was the one push-funded MAKE outside the pre-fund seam: `data =
abi.encode(recipient)`, so `_isPreFundDesc` was false and `Base._runItem` sized the
unwrap as `_prorate(item.amount)` — a signed constant — while `Core._deliverOutputs`
delivered `Pricing.outputAt`. On any non-fixed WETH leg the two diverge: signing
`start` reverted in WETH9 once the tick moved; signing `end` (the only encoding that
fills at every tick) stranded `delivered − end` on the shared singleton, where a
zero-leg self-order naming the residue as its `amount` withdrew it to a stranger
(PoC: 0.1 ETH per 1 ETH Dutch order). Two more mechanisms at the same site: a
module-addressed leg escapes the `overrideBps` lift (only maker/0 recipients are
lifted), so an in-window outsider kept the maker's signed exclusivity premium
(PoC: 0.01 ETH per 1 ETH); and `Batch._assertMatchShape` admitted the item on the
netted path while excluding every other self-funding MAKE. The lens flagged none of
the shapes.

**Fix.** The module is now a pre-fund consumer: `data = abi.encode(forDesc,
recipient)` with `forDesc = forLegPreFund(j, WETH)`, `PreFundGuard.requireLegRef` +
`requireDelivered` in the body, `item.amount = 0`. The settler sizes the item from
its delivery ledger (`amount == ctx.outs[j]`, spent once), so the unwrap IS the
delivery whatever the leg priced to; the core refuses `overrideBps != 0` on this
shape; `floorOf` proves the WETH landed here before a wei moves; and the item is
on the pre-fund side of `_assertMatchShape`. **BREAKING** for any signed
native-out order: the old plain-address blob now reverts
`PreFundDescriptorRequired`. Side effect worth knowing: the per-fill SELL ceil
that used to accrue as "dust" on the singleton now reaches the maker as ETH.
Regression: `NativeUnwrapModule.t.sol` (Dutch leg unwraps exactly the delivery;
zero-leg claim order fails `ForLegMissing`; under-delivering leg unwraps only its
own wei; plain-address blob refused). `check-module-shapes.py` rule 3 now accepts
the inline `msg.sender` pin + `requireLegRef` as equivalent to `_gatePreFundMake`
for a module that needs no Permit3.

### 3 — `DolomiteOperatorModule._withdraw` (Exact): a withdraw past the supply is a borrow — **FIXED**

Confidence 90 · agents 1/12

`_withdrawAction` builds the identical negative-delta action for `Op.Withdraw` and
`Op.Borrow`, and Dolomite does not distinguish "take out my deposit" from "take out
a loan": below zero, the rest is debt against whatever else the sub-account holds.
Every other venue's Exact withdraw reverts on a short position (aToken transfer,
ERC-4626 burn, Morpho underflow); Comet — the one sibling with the same semantics
— guards it with `WouldBorrow`. So a `Withdraw` grant for X was economically a
`Borrow` grant for X once the supply dropped below X (partial liquidation is
permissionless; the filler picks the timing), and the module header's "a grant for
`Borrow` cannot be spent on a `Withdraw`" containment was broken by the venue
rather than by the ref.

**Fix.** The Exact branch reads `getAccountWei` and reverts `WouldBorrow(amount,
supply)` when `amount > supply`, mirroring Comet. `Op.Borrow` remains the only op
that may go negative.

### 4 — Five `Full`-mode withdraw branches lack the delivered bound — **FIXED**

Confidence 75 · agents 8/12 (3 as findings, 5 as leads)

`VenusTakerModule`, `AaveV4WithdrawModule`, `CompoundV2WithdrawModule`,
`CompoundV2NativeWithdrawModule` and `ListaNativeCollateralTakerModule` ran
`requireFullFillFromData` (so `amount == totalAmount`) and forwarded
`min(received, amount)` with no `FullFillGuard.requireDelivered(received, amount)`,
which the other 13 Full legs carry since the 2026-09-10 restoration. On a position
below the signed total, `Core._payInputsToSolver` pulled `owed − proceeds` from the
maker's **wallet** via the standing Settlement allowance at a price signed for a
position exit; the same order on Aave v3 reverts `ShortWithdraw`. The cause was in
the prose: I-8b exempted these venues because "there `amount` IS a slice" — true of
their Exact branches, false of the Full branches that assert `amount == totalAmount`
one line earlier — and `check-module-shapes.py` encoded that reading.

**Fix.** The bound is added after each `received` measurement (Lista-native
remembers the mode across its shared tail). I-8b is rewritten to decide by branch,
not by venue. **Shapes rule 9** now fails the build when a `takeOnBehalf` /
`takeForOnBehalf` reaches `requireFullFillFromData` without
`FullFillGuard.requireDelivered` — verified to fire by removing the Venus bound.

### 5 — `CompoundV2RepayModule._pullAndRepay`: dangling approval to an order-chosen cToken — **FIXED**

Confidence 75 · agents 5/12

`forceApprove(underlying, cToken, toRepay); repayBorrowBehalf(...)` was never
followed by the clear that every sibling — this file's own deposit module, its
Recycle branch and its pre-fund twin included — carries under F25/A-3. An
attacker-maker naming a fake `cToken` that consumes nothing had the pull swept back
for free and kept a permanent `toRepay`-sized claim on any future `underlying`
balance of the singleton. No honest path strands `underlying` there today, so prey
was limited to donations or a future residue bug — the class A-3 closed at six
Aave sites and missed here.

**Fix.** One `forceApprove(underlying, cToken, 0)` after the error check.
Regression: `compound-v2/test/security/DanglingApproval.t.sol`, mirroring the Aave
test with a `NonConsumingCToken`.

### 6 — Liquity / River repay: the measured token is not the burned token — **FIXED**

Confidence 75 · agents 3/12 · River burn-from-`msg.sender` fork-verified on BSC

`LiquityV2RepayModule`, `LiquityV2PreFundModule._repay`, `RiverRepayModule` and
`RiverPreFundModule._repay` decode the debt token from maker `data` and use it for
the pull / floor / sweep — while the venue burns the branch's **real** BOLD /
satUSD from the module with no ERC-20 approval and no token argument (Liquity's
`repayBold` by design; River's `repayDebt` fork-probed: succeeds with zero
allowance to the xapp, so the scoped approve there is inert). Requiring the
delivery in the named token ties delivery to measurement — it never tied
measurement to the **burn**. An attacker with a trove signs `data = (…, FAKE)`,
delivers FAKE, has FAKE swept back, and retires their own debt out of any real
BOLD / satUSD resident on the singleton. Residue-bounded today; the class the rest
of the tree closes with floors — and the class F27/H-2 recorded as closed. Two
in-tree comments were wrong: H-2's "closed by B", and F27's own correction that
River "pulls through the scoped approval" (it does not).

**Fix.** The named token is pinned to the trusted root before anything is
measured: Liquity reads `ICollateralRegistry.boldToken()` (mainnet-verified:
registry `0xf949…6684` → `0x6440…B01D`) via `LiquityV2TroveAuth.requireBold`, on
both repay legs and on the `withdrawBold` taker leg so a mis-named token cannot
strand real BOLD either; River reads `IRiverTroveManager.debtToken()` (BSC-verified:
TM `0x5EA2…9Ec` → satUSD `0xb481…6cB`). `tm` is itself order-supplied on River, but
a fake TM handed to the real diamond is rejected by the diamond — the same trust
the module already places in it for every other op. Errors: `BoldTokenMismatch`,
`DebtTokenMismatch`.

---

## Demoted to leads, and the rest

Two raw findings did not clear the gates. `ERC4626WithdrawModule.takeOnBehalf`
claimed the whole timelocked request on a 1-wei fill and returned the surplus to
the maker — a griefing shape (the order bricks, nothing is stolen, no filler
profit). **Fixed anyway** (2026-09-14): `data` gains a trailing `totalAmount` and
the claim runs `requireFullFillFromData` — the same guard every `Full` leg carries,
for the same reason. **BREAKING**: `abi.encode(vault, requestId, minAssets,
totalAmount)`; a three-word blob reverts `PartialFillUnsupported`.
`RangePriceModule.bump` samples at `prevFilled` rather than integrating over the
slice, so a START>END band clears a whole order at the maker's `end` in one fill —
bounded by the signed floor; left open (a design choice, documented).

Leads fixed alongside:

- **`ExactlyPreFundModule._repayFloating`** (4 lenses) clamped against `previewDebt`
  (floating + every fixed maturity) where the pull sibling had been corrected to
  the floating-only read. Aligned — and the alignment surfaced a **liveness bug in
  the pull sibling itself**: F26's correction declared a
  `floatingBorrowShares(address)` getter the Market does not have (the shares are
  the third field of `accounts(address)`; probed on exaUSDC, Optimism — `accounts`
  answers, `floatingBorrowShares` reverts), so `ExactlyRepayModule`'s floating
  branch had reverted on-chain since F26 and no fork test covered it. Both now read
  `accounts(borrower)`; `Leverage.t.sol::test_repay_make_floating_clampsAtLiveDebt`
  covers the pull path on the fork.

- **14 pre-fund deposit ops** (3 lenses) discarded the floor (`requireDelivered`
  only, no sweep) where `AaveV3PreFundModule._supply` had moved to `floorOf` +
  `sweepSurplus`. All 15 sites (Morpho Blue has two) now keep the floor and sweep
  the surplus to the maker — a venue that consumes less than instructed no longer
  leaves residue on the singleton. Compiles on every profile including the
  optimizer-less fork ones.
- **`AggregatorFillSolver` surplus policy evadable via exact-output routes** (1):
  the input residue was swept 100% to the filler as "a quoting artefact", so a
  caller's route shape decided whether the maker/protocol shares applied. Both
  sides are now split by the same policy (`_splitSurplus(token, before, …)` twice;
  `_sweepDelta` deleted), the residue in `tokenIn` units. Regression:
  `test_split_inputResidueIsSplitByTheSamePolicy`.

Open leads, by convergence:

- **Exactly fixed-maturity withdraw / deposit** (3) pass the raw full-order slippage
  bound against a per-fill slice — every partial fill reverts. Documented as
  deliberate in `ProratedBound` (a FLOOR applied unscaled fails closed); left.
  `_scaledFace` (1) uses `forAmount / total` as the fill fraction, which conflates
  price decay with progress on a decaying funding leg.
- **14 pre-fund deposit ops** (3) still discard the floor (`requireDelivered` only,
  no sweep) where `AaveV3PreFundModule._supply` moved to `floorOf` + `sweepSurplus`.
- **Fee-on-transfer funding token** (2): with residue ≥ fee the floor lets the venue
  be fed the full nominal `forAmount` out of the singleton. Previously documented;
  precondition sharpened — and narrowed further now that the deposit ops sweep,
  since honest fills no longer accrete the residue it needs.
- Single-lens: PULL/BALANCE funding shapes not token-bound (self-harm only);
  `AggregatorFillSolver` filler identity laundering through the permissionless
  `executeFill`, non-anchor input legs stranded; `Core.fillUpTo` proportional shrink after quote; `Batch._openGated`
  proportional-anchor griefing; `_creditItemProceeds` NatSpec overclaim;
  `BaseFlashSolver` residue claimable; `PositionFunnel.enableToken` permissionless
  unlimited grant; `ChainlinkPeggedPriceModule` anchor units on `fillTotal` orders;
  `NativeSettler` approval below the lifted pull; `AaveV3CreditModule._ratioSupplyLeg`
  per-slice ceil; `ProportionalSweepModule` marker compounding; `Pricing.inputOwed`
  fixed-BUY rounding; `NftSettlementModule` non-zero partial slice; negated
  `FLAG_TRY` leaf gas-flippable; `GuardedMatchSolver` PRESEND lands on the wrapper;
  stranded Fluid NFT drainable via a no-op `factory`.

## Comparables

Findings 1, 2 and 6 each have a named twin in the post-deployment corpus — see
[`reference-bounties.md`](reference-bounties.md) B12 (Across's loosely-keyed
off-chain ledger), B2 (1inch Aqua's TWAP `amountIn` vs `amountOut`) and B6 (0x
Settler Immunefi #88903, the sell token carried in `path[0]` and in the permit).

## What this run says about the last three

Three of six findings are the meta-pattern the 2026-09-08 audit named: a class
fixed at N sites and missed at the N+1th. The fixes this time are paired with
mechanical rules where one was expressible (shapes rule 9 for I-8; the existing
A-3 test shape ported to compound-v2) — a class that lives only in prose gets
missed on the next sibling. The other three are the same lesson from a different
angle: a comment that asserts an invariant ("same by construction", "closed by B",
"cumulative delivered ≥ cumulative unwrapped") is a claim, and two of the three
were wrong.
