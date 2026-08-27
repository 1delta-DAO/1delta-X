# The edge-case matrix

Three of the last four findings against this codebase were not bugs in a
function. They were bugs in a **combination** — a state that each half of the
code handled correctly on its own, reached by a path nobody had put together:

- [F13](reference-audits.md#f13--a-revoked-on-chain-order-approval-was-bypassed-by-any-non-empty-signature)
  — *on-chain approval* × *partially filled* × *a non-empty signature*. Each of the
  three is ordinary. The product was an authorisation bypass.
- [F15](reference-audits.md#f15--a-duplicate-pull-step-burned-maker-allowance-without-extra-fill-progress)
  — *duplicate `PULL` step* × *finite allowance*. Either alone is harmless; the
  infinite-allowance sentinel that every test granted was **masking** the pair.
- [F8](reference-audits.md#f8--a-proportional-anchor-plus-the-pegged-price-module-passed-preflight-and-never-filled)
  — *proportional anchor* × *pegged price module*. Two features that had never been
  asked to work together, and did not.

A per-feature test suite cannot find these, because each feature's suite is
written by someone holding one axis fixed. This note holds the axes **crossed**.
It has three jobs, in order:

1. **Enumerate** the axes and their values, so "all constellations" is a finite,
   written-down set rather than a feeling.
2. **Classify** each combination — *common*, *rare*, *never*, *must-not* — because
   the classification is what decides how much a missing test costs.
3. **Bind** each classified cell to the test that pins it, and name the ones that
   have none.

**Related:** [`reference-audits.md`](reference-audits.md) is the *external* view —
what other protocols in this class got wrong, as classes `C1…C15`, and our verdict
against each. This note is the *internal* view: our own state space, exhaustively.
The two meet in the findings ledger — every `F` entry there should be locatable as
a cell here, and if it is not, this note is missing an axis.

---

## The four verdicts

| Mark | Verdict | Meaning | What a missing test costs |
| --- | --- | --- | --- |
| **●** | **common** | On the normal path. Happens on most fills. | Nothing — the suite is full of these. A gap here would be visible immediately. |
| **◐** | **rare** | Legitimate, infrequent. A feature most orders never use, or a state most orders never reach. | **The most expensive gap.** Rare-but-legal is where F8 and F15 lived: reachable, unexercised, and nobody notices the regression. |
| **⊘** | **never** | Structurally unreachable. The mechanism that makes it so must be *named* in the cell. | A test is not the control — the *mechanism* is. But if the mechanism is a convention rather than the compiler, it needs a regression net (cf. [C2](reference-audits.md#c2--hand-rolled-calldata-arithmetic-without-a-bounds-proof)). |
| **✕** | **must-not** | An actor can present it. The settler must refuse. | A security gap. Every ✕ cell is a revert, and every revert needs a test that proves it fires. |

The line between **⊘** and **✕** is the one that matters and the one that is
easiest to get wrong. *Never* means the input cannot be constructed; *must-not*
means it can be constructed and is rejected. Downgrading a ✕ to a ⊘ in your head —
"nobody would send that" — is how the check gets deleted in a size pass.

> **The ◐ discipline.** When a cell is rare, ask the F15 question before accepting
> it as covered: *does the test's setup mask the property?* A test that grants
> `uint160.max` allowance cannot observe allowance consumption; a test with round
> numbers cannot observe rounding; a test at `decayStartTime` cannot observe decay.

---

## Part 1 — the axes

Ten axes. Each value names where it is set in the code, so a cell can be
constructed from the table without reading the settler.

### A — Authorisation credential

How the fill proves the maker authorised this order.
[`Signatures._verifySignature`](../packages/core/src/settlement/Signatures.sol)

| # | Value | Selected by | Freq |
| --- | --- | --- | --- |
| A1 | EOA, 65-byte `r‖s‖v` | default | ● |
| A2 | EOA, 64-byte EIP-2098 compact | `sig.length == 64` | ◐ |
| A3 | Malleable twin (`s → N−s`) of A1/A2 | filler's choice of encoding | ◐ |
| A4 | Bulk / Merkle envelope | `len ≥ 98 ∧ (len−66)%32 == 0 ∧ sig[len−1] == 0xB0` | ◐ |
| A5 | Delegated **EOA** signer | recovered key ≠ maker, `orderSignerExpiry[maker][signer]` live | ◐ |
| A6 | Delegated **contract** signer | `address ‖ innerSig`, non-standard length, maker has no code | ◐ |
| A7 | EIP-1271 contract maker (Safe, smart account) | maker has code, falls through to `SignatureVerification.verify` | ◐ |
| A8 | EIP-7702 raw-key maker | maker has code **and** ECDSA recovers to it | ◐ |
| A9 | Empty `sig` → `approveOrder` record | `sig.length == 0` | ◐ |

**The property that couples A to everything else:** for A1–A8 the check is
**skipped once `filled[orderHash] != 0`**. For A9 it is re-checked on every fill.
That asymmetry is deliberate, load-bearing, and the direct subject of matrix
[M1](#m1--credential--fill-progress).

### B — Order lifecycle state

| # | Value | Representation | Freq |
| --- | --- | --- | --- |
| B1 | Fresh | `filled == 0` | ● |
| B2 | Partially filled | `0 < filled < total` | ● |
| B3 | Complete | `filled == total` | ● |
| B4 | Cancelled by hash | `filled == type(uint256).max` (sentinel) | ◐ |
| B5 | Fill-once | no counter — the consumed **nonce** is the state (`timing` bit 100) | ◐ |
| B6 | Nonce cancelled | `nonceBitmap` bit set | ◐ |
| B7 | Below the rollback floor | `nonce < minValidNonce` | ◐ |
| B8 | Expired | `block.timestamp > timing[160:208)` | ● |
| B9 | Not yet started | `nowTick() < decayStartTime` | ◐ |

### C — Entry point

| # | Value | Where | Freq |
| --- | --- | --- | --- |
| C1 | `fill` (3-arg / 4-arg with `takerData`) | `Core.sol` | ● |
| C2 | `fillWithCallback` × 4 `CallbackMode`s | `Core.sol` | ● |
| C3 | `fillWithPermit` | `Core.sol` | ◐ |
| C4 | `fillWithPermitTake` | `Core.sol` | ◐ |
| C5 | `fillSelf` | `Core.sol` | ◐ |
| C6 | `batchFill` (± `revertIfIncomplete`) | `Core.sol` | ◐ |
| C7 | `fillUpTo` | `Core.sol` | ● |
| C8 | `matchSettle` | `Batch.sol` (own gate sequence: `_openGated`) | ◐ |

C1–C7 share `_fillCore`. **C8 does not** — `_openGated` is a second, parallel
implementation of the same gate sequence. That is the single most important
structural fact in this document, and the reason [M3](#m3--entry-point--lifecycle-gate)
exists: [`OrderGates`](../packages/core/src/settlement/OrderGates.sol) opens with
the record of two lens copies of these gates having **already drifted silently**.

### D — Pricing mode

| # | Value | Selected by | Freq |
| --- | --- | --- | --- |
| D1 | Fixed | `end == 0` on every leg | ● |
| D2 | Linear decay | `decayDuration != 0` | ● |
| D3 | Piecewise curve | non-empty `curve` blob | ◐ |
| D4 | Block clock | `timing` bit 102 | ◐ |
| D5 | Gas bump | `params[16:32)`, `params[32:96)` | ◐ |
| D6 | Priority auction | `timing` bit 103 + `priorityScale` | ◐ |
| D7 | External price module | `pricingModule != 0` | ◐ |
| D8 | Soft-exclusivity override | `params[0:16)` — a price *modifier*, composes with D1–D7 | ◐ |

D6 pins the bump **once per fill**; D1–D5 resolve lazily per leg. D7 pins once
per fill. That pinning is what makes granularity × pricing
([M4](#m4--fill-granularity--pricing-mode)) a real interaction rather than a
product of independents.

### E — Withdrawal (kill switches)

Every way a maker (or the world) takes authority back.

| # | Value | Binds via |
| --- | --- | --- |
| E1 | `cancelOrder(order)` | `filled` sentinel |
| E2 | `cancelOrders(nonces)` | nonce bitmap |
| E3 | `invalidateNonceWord(word)` | 256 nonces at once |
| E4 | `rollbackNonces(floor)` | `minValidNonce` |
| E5 | `revokeOrderApproval(hash)` | `orderApproved` + sentinel escalation when touched |
| E6 | `setOrderSigner(d, 0)` / expiry lapse | `orderSignerExpiry` |
| E7 | Order expiry | `timing[160:208)` |
| E8 | Permit3 allowance revoke / `lockdownAll` / nonce invalidation | funding fails |
| E9 | An EIP-1271 wallet starting to return `false` | *not a settler primitive* |

E6 and E9 are the two that **do not bind mid-order**, by the A-axis skip. That is
documented in three places in the source and is the subject of
[M2](#m2--kill-switch--fill-progress).

### F — Fill granularity

| # | Value | Freq |
| --- | --- | --- |
| F1 | Whole order in one fill (`ctx.fullFill`) | ● |
| F2 | Opening partial (`prevFilled == 0`, `newFilled < total`) | ● |
| F3 | Middle partial | ● |
| F4 | Closing partial (`newFilled == total`) | ● |
| F5 | Many small slices (N ≫ 2) | ◐ |
| F6 | Over-request clamped (`fillUpTo`) | ● |
| F7 | `delta < minFillAnchor` | ✕ `FillTooSmall` |
| F8 | `newFilled > total` | ✕ `OverFill` |
| F9 | `delta == 0` | ✕ `ZeroFill` |

### G — Leg shape

| # | Value | Freq |
| --- | --- | --- |
| G1 | Fixed input leg | ● |
| G2 | Rising input leg (relayer fee, `start < end`) | ◐ |
| G3 | Falling output leg (dutch) | ● |
| G4 | Fixed output leg | ● |
| G5 | Fee/originator output leg (`recipient != 0`, ≠ maker) | ◐ |
| G6 | Explicit `recipient == maker` | ◐ |
| G7 | Empty `legsOut` (gasless deposit) | ◐ |
| G8 | Duplicate `token` across legs | ◐ |
| G9 | Zero-amount leg | ◐ (skipped) |
| G10 | Proportional anchor (balance-relative marker) | ◐ |
| G11 | Output addressed to Settlement | ✕ `OutputToSettlement` (netted path) |
| G12 | Falling **input** / rising **output** | ✕ `InvalidAuctionParams` |
| G13 | Empty fixed-side blob **and** no `fillTotal` | ✕ `NoAnchorLeg` |

### H — Items

| # | Value | Freq |
| --- | --- | --- |
| H1 | No items (pure leg swap) | ● |
| H2 | `MAKE` | ◐ |
| H3 | `TAKE` (`recipient` = 0 / maker) | ◐ |
| H4 | `SETTLE` (filler-aware) | ◐ |
| H5 | Policy `ANY` / `ORDERED` / `ATOMIC` | ◐ |
| H6 | Op byte > `SETTLE` | ✕ |
| H7 | Codeless module target | ✕ `ItemTargetHasNoCode` |
| H8 | `SETTLE` under a partial fill | ✕ `SettleSliceZero` / guard |

### I — Exclusivity

| # | Value | Freq |
| --- | --- | --- |
| I1 | Open (`exclusiveFiller == 0`) | ● |
| I2 | Hard single filler, in window | ◐ |
| I3 | Soft single filler, outsider pays `overrideBps` | ◐ |
| I4 | Filler **set** (`address(1)` + `curve` blob), hard | ◐ |
| I5 | Filler set, soft | ◐ |
| I6 | Window lapsed → open | ● |
| I7 | Malformed set | ✕ `MalformedFillerSet` |
| I8 | `overrideBps > 10000` | ✕ `InvalidOverrideBps` |

### J — Token behaviour

| # | Value | Freq |
| --- | --- | --- |
| J1 | Standard ERC-20 | ● |
| J2 | Fee-on-transfer **with** delta-verify (`timing` bit 104) | ◐ |
| J3 | Fee-on-transfer **without** delta-verify (nominal push) | ◐ |
| J4 | Missing-return / non-standard | ◐ |
| J5 | Amount > `uint160.max` (Permit3's cap) | ✕ `AmountOverflow` |

---

## Part 2 — the interaction matrices

The Cartesian product of the ten axes is ~10¹¹ cells and is not a useful
object. What follows is the set of **axis pairs the code actually couples** —
where a value on one axis changes the behaviour of the other. A pair that is not
listed here is a claim of independence, and that claim is itself reviewable.

### M1 — credential × fill progress

The F13 matrix. Columns: does the credential get re-checked, and does withdrawing
it bind?

| Credential | Fresh fill | Later fill (`filled != 0`) | Withdrawn before any fill | Withdrawn **after** a partial |
| --- | --- | --- | --- | --- |
| A1 EOA 65 | ● checked · `PlainSwap:test_plain_swap_full` | ● **skipped** · `PlainSwap:test_plain_swap_partialFills` | ⊘ a signature cannot be withdrawn | ⊘ same |
| A2 compact 64 | ◐ · `CompactSignature:test_fill_acceptsCompact64ByteSignature` | ● skipped | ⊘ | ⊘ |
| A3 malleable twin | ◐ · `SignatureEdgeCases:test_malleability_fourEncodings_stillOneFill` | ● skipped — **and this is why the twin is benign**: replay is bounded by `filled`, not by signature identity | ⊘ | ⊘ |
| A4 bulk / Merkle | ◐ · `BulkSignature:test_bulkSignature_fillsEveryLeaf` | ◐ **skipped — any 65 bytes pass** | ✕ leaf outside tree · `test_bulkSignature_orderOutsideTree_reverts` | ⊘ root is signed, not withdrawable — **but see gap [G-1](#g-1)** |
| A5 delegate EOA | ◐ · `DelegatedOrderSigner:test_delegate_canSignForTheMaker` | ◐ skipped | ✕ binds · `test_revocation_bindsOnAnUnfilledOrder` | ◐ **does NOT bind** — documented; **[G-2](#g-2) no test** |
| A6 delegate contract | ◐ · `test_contractDelegate_signsViaEnvelope` | ◐ skipped | ✕ binds · `test_contractDelegate_revoked` | ◐ does NOT bind — **[G-2](#g-2)** |
| A7 EIP-1271 maker | ◐ · `PlainSwap:test_plain_swap_contractSigner_eip1271`, `SafeMakerFork:test_fork_gnosisSafe_maker_eip1271` | ◐ skipped | ✕ binds · `SignatureEdgeCases:test_1271_wrongMagicValue_reverts` | ◐ does NOT bind (E9) — **[G-3](#g-3) no test** |
| A8 EIP-7702 raw key | ◐ · `PlainSwap:test_plain_swap_eip7702_rawKeyMaker` | ◐ skipped | ⊘ | ⊘ |
| A9 `approveOrder` | ◐ · `OnChainOrderApproval:test_approve_thenFill_emptySig` | ◐ **RE-CHECKED every fill** | ✕ binds · `test_revokeOrderApproval_blocksFill` | ✕ **binds** via sentinel escalation · `test_revoke_blocksRemainder_evenWithNonEmptySig` **(F13 regression pin)** |

**The row to read twice is A9's last cell.** It is the only credential whose
withdrawal binds mid-order, and it only binds because F13 forced the sentinel
escalation. The generalised question — *does this fast path remember **which**
credential authorised it?* — is the
[re-audit sweep §1](reference-audits.md#re-audit-sweep--the-generalised-questions-from-f13f15).

### M2 — kill switch × fill progress

| Kill switch | On an untouched order | On a partially filled order |
| --- | --- | --- |
| E1 `cancelOrder` | ✕ binds · `CancelOrder:test_cancelOrder_cancelsOneNotTheSharedNonce` | ✕ binds · `CancelOrder:test_cancelOrder_onPartialFill` |
| E2 `cancelOrders` | ✕ binds · `NonceCancellation:test_cancel_blocksFill` | ✕ binds · `test_cancel_afterPartialFill_blocksRemainder` |
| E3 `invalidateNonceWord` | ✕ binds · `test_invalidateNonceWord_cancels256` | ✕ binds (same gate) — untested, **low risk: identical code path** |
| E4 `rollbackNonces` | ✕ binds · `test_rollback_cancelsBelowFloor` | ✕ binds (same gate) — untested, same note |
| E5 `revokeOrderApproval` | ✕ binds · `OnChainOrderApproval:test_revokeOrderApproval_blocksFill` | ✕ binds · `test_revokeOrderApproval_blocksRemainderAfterPartialFill` + F13 pin |
| E6 `setOrderSigner(d,0)` | ✕ binds · `DelegatedOrderSigner:test_revocation_bindsOnAnUnfilledOrder` | ◐ **does not bind** — **[G-2](#g-2)** |
| E7 expiry | ✕ binds · `MultiAssetAuthGates:test_multiOut_expired` | ✕ binds (checked per fill in `_fillCore`) |
| E8 Permit3 revoke | ✕ funding fails · `OrderRelevantState:test_state_underfunded_byAllowance` | ✕ same |
| E9 1271 → `false` | ✕ binds · `SignatureEdgeCases:test_1271_*` | ◐ **does not bind** — **[G-3](#g-3)** |

**Reading:** a maker holding a part-filled order has exactly seven working kill
switches, not nine. E6 and E9 are advertised as revocation and are not, for the
remainder of a touched order. That is a *correct, deliberate* trade (the
alternative is a cold SLOAD on every fill of every order), but it is a
**documentation-and-test obligation**, not a free one — and right now the
obligation is met only by prose.

### M3 — entry point × lifecycle gate

`matchSettle` (C8) runs `_openGated`, a **separate** gate sequence from
`_fillCore`. Every cell in its column is therefore an independent claim.

| Gate | `fill` (C1) | `fillUpTo` (C7) | `batchFill` (C6) | `matchSettle` (C8) |
| --- | --- | --- | --- | --- |
| Expired (B8) | ✕ `MultiAssetAuthGates:test_multiOut_expired` | ✕ shares `_fillCore` | ✕ shares `_fillCore` | ✕ `Batch.sol:109` — **[G-4](#g-4) no test** |
| Cancelled by hash (B4) | ✕ `CancelOrder:*` | ✕ `FillUpTo:test_fillUpTo_cancelledByHash_reverts_OrderCancelled` | ✕ skipped, not reverted · `BatchFill:test_batchFill_skipsUnfillable` | ✕ — **[G-4](#g-4)** |
| Nonce cancelled (B6/B7) | ✕ `NonceCancellation:*` | ✕ shares | ✕ shares | ✕ — **[G-4](#g-4)** |
| Empty sig / `approveOrder` (A9) | ◐ `OnChainOrderApproval:test_approve_thenFill_emptySig` | ◐ shares | ◐ `test_batchFill_approvedOrder_emptySig` | ◐ — **[G-4](#g-4)** |
| Fill-once (B5) | ◐ `FillOnceNonce:test_fillOnce_settlesAndConsumesTheNonce` | ◐ — **[G-5](#g-5)** | ◐ — **[G-5](#g-5)** | ◐ — **[G-5](#g-5)** |
| Exclusivity (I2–I5) | ✕ `AuctionAndExclusivity:*` | ✕ `test_fillUpTo_recipient_doesNotBypassExclusivity` | ✕ `SettlementGuards:test_batchFill_exclusivity_threadsFiller` | ✕ — **[G-4](#g-4)** |
| Proportional anchor (G10) | ◐ `ProportionalLeg:*` | ◐ `test_prop_fillUpTo_clampsToResolvedAnchor` | ◐ — **[G-6](#g-6)** | ◐ — **[G-6](#g-6)** |
| Delta-verify (J2) | ◐ `DeltaVerifyDelivery:*` | ◐ shares | ◐ shares | ⊘→✕ `DeltaVerifyNotBatchable` — **[G-7](#g-7) no test** |
| Contract maker (A7) | ◐ `PlainSwap`, `SafeMakerFork` | ◐ — untested | ◐ — untested | ◐ — untested |
| Reentrancy | ✕ `SettlementGuards:test_reentrancy_into_fill_reverts` | ✕ `..._into_fillUpTo_reverts` | ✕ shares | ✕ `test_reentrancy_viaCallback_reverts` |

### M4 — fill granularity × pricing mode

Where slicing and the clock interact. The question each cell answers: *does
splitting the fill change what the maker receives?*

| Pricing | Whole (F1) | Two partials (F2+F4) | Many slices (F5) |
| --- | --- | --- | --- |
| D1 fixed | ● `PlainSwap:test_plain_swap_full` | ● `test_plain_swap_partialFills` | ◐ **must not drift** · `RoundingDirection:test_fixedInput_isExactUnderAnySlicing`, `testFuzz_slicing_neverFavoursTheSolver` |
| D2 linear decay | ● `test_plain_swap_dutchDecay` | ● `test_plain_swap_partialFills_acrossDutchTicks`, `MultiAssetPartials:test_multiIn_dutchDecay_midpoint` | ◐ `FillAccountingFuzz:testFuzz_twoPartialFills_sumInvariant` |
| D3 curve | ◐ `AuctionAndExclusivity:test_curve_sell_interpolatesBetweenPoints` | ◐ `test_curve_partialFills_perTickPricing` | ◐ covered by the same |
| D4 block clock | ◐ `PricingModes:test_blockClock_decaysPerBlock` | ◐ — untested (low risk: clock source only) | ◐ — untested |
| D5 gas bump | ◐ `test_gasBump_sell_reducesOutputWithBasefee` | ◐ `test_gasBump_plusTimeDecay_sumsAndFills` | ◐ `testFuzz_gasBump_withinBounds` |
| D6 priority | ◐ `PricingModes:test_priorityAuction_bidMovesTickTowardStart` | ◐ **[G-8](#g-8)** — two partials at different tips price differently; nothing pins it | ◐ **[G-8](#g-8)** |
| D7 price module | ◐ `PricingModes:test_priceModule_bumpFollowsFillProgress` | ◐ same test (progress-linked) | ◐ `HostilePriceModule:testFuzz_anyAnswer_staysInsideTheSignedBand` |
| D8 soft override | ◐ `AuctionAndExclusivity:test_override_sell_nonExclusiveMustDeliverMore` | ◐ `test_override_onDecayedPrice` | ◐ `TypedCallback:test_clamped_partialFillSlice` |

**The invariant this matrix exists to protect** is stated in
[`RoundingDirection.t.sol`](../packages/core/test/swaps/RoundingDirection.t.sol):
fixed inputs use a cumulative-difference form (N slices sum to the signed total
exactly); outputs `ceilDiv` per slice (slicing can only pay the maker *more*).
A change that flipped either toward the solver is the Bunni value-leak shape and
would break that file loudly. `matchSettle`'s `BatchNotWhole` / `LegUnfunded`
checks do **not** catch it — they assert the pool balances, never the direction of
the rounding.

### M5 — fill granularity × leg / item shape

| Shape | Whole | Partial | Notes |
| --- | --- | --- | --- |
| G1 fixed in | ● | ● `MultiAssetPartials:test_thirds_inputsExact_outputCeil` | exact by cumulative difference |
| G2 rising in | ◐ `RisingInputFee:test_risingLeg_chargesAuctionTick` | ◐ `test_risingLeg_partialFills_perTick` | fee priced per tick, not amortised |
| G3 falling out | ● | ● `MultiAssetSwap:test_multiOut_dutchDecay_partialFill` | |
| G5 fee leg | ◐ `SourcingFee:test_feeLeg_paysRecipient` | ◐ `test_feeLeg_partialFills_proRata` | ◐ and: soft override is **not** applied to fee legs · `test_feeLeg_softExclusivity_notAppliedToFeeLeg` |
| G7 empty `legsOut` | ◐ `RisingInputFee:test_risingLeg_emptyTokenOut` | ◐ same | |
| G8 duplicate token | ◐ `MultiAssetSwap:test_fill_duplicateTokenIn_onlyChargesMaker`, `SettlementGuards:test_fill_duplicateTokenOut_deliversBothLegs` | ◐ | ✕ under delta-verify · `DeltaVerifyDelivery:test_deltaVerify_duplicateTokenRecipient_reverts` |
| G9 zero leg | ◐ `SettlementGuards:test_fill_zeroOutputLeg_skipped` | ◐ | |
| G10 proportional | ◐ `ProportionalLeg:test_prop_fullSweep_sellsEntireBalance` | ✕ `ProportionalNeedsFullFill` · `test_prop_partialRequest_reverts` | **⊘ by rule, ✕ by check** — the rule is enforced where the marker is consumed, not at the gate |
| H2 `MAKE` | ◐ `items/MultiAssetItems:test_make_depositFromOutput` | ◐ pro-rata slice | |
| H3 `TAKE` | ◐ `test_take_fundsInput_exact` | ◐ `SettleSlice:test_slice_partialFills_areProRata_andAccumulate` | ✕ flooring to zero · `test_slice_flooringToZero_reverts` |
| H4 `SETTLE` | ◐ `NftSettlement:test_nftSale_toOpenFiller` | ✕ `NftSettlement:test_settleGuard_partialFill_reverts` | indivisible by nature |

### M6 — exclusivity × entry point / pricing

| | `fill` | `fillUpTo` | `batchFill` | `matchSettle` |
| --- | --- | --- | --- | --- |
| I2 hard, outsider | ✕ `AuctionAndExclusivity:test_hardExclusivity_zeroBps_stillReverts` | ✕ `FillUpTo:test_fillUpTo_recipient_doesNotBypassExclusivity` | ✕ skipped · `SettlementGuards:test_batchFill_exclusivity_threadsFiller` | **[G-4](#g-4)** |
| I3 soft, outsider pays | ◐ `test_override_sell_nonExclusiveMustDeliverMore` | ◐ — untested | ◐ `test_override_batchFill_threadsFillerAndOverride` | **[G-4](#g-4)** |
| I4/I5 filler set | ◐ `FillerSetExclusivity:test_fillerSet_firstMemberFills`, `test_fillerSet_softOverride_outsiderPaysImprovement` | ◐ — untested | ◐ — untested | **[G-4](#g-4)** |
| I7 malformed set | ✕ `test_fillerSet_emptySet_isMalformed`, `_truncatedEntry_`, `_nonZeroCountByte_` | ✕ shares | ✕ shares | ✕ shares |
| I6 window lapsed | ● `test_fillerSet_outsiderFillsAfterWindow`, `test_fillerSet_malformedHealsAfterWindow` | ● | ● | ● |
| × D3 curve | ⊘ **mutually exclusive** — the set rides the `curve` blob, so a set order decays linearly · `test_fillerSet_decayIgnoresSetBytes` | | | |
| × D4 block clock | ◐ `test_fillerSet_blockClock_windowCountsBlocks` | | | |

### M7 — `matchSettle` step × repetition and omission

The F15 matrix. Rows are the five `MatchStep` kinds; columns are what a hostile
or careless schedule does to them. **This is the best-covered matrix in the
document**, and it got that way by being the one that broke.

| Step | Omitted | Duplicated | Out of policy order |
| --- | --- | --- | --- |
| `PULL` | ✕ `LegUnfunded` · `test_itemUnderproduces_legUnfunded` | ◐ **tolerated, and must cost nothing** · `test_duplicatePull_returnsSurplusToMaker` + **`MatchSettleCoW:test_dupPull_doesNotBurnExtraAllowance` (F15 pin)** | n/a |
| `DELIVER` | ✕ `test_omittedDeliver_reverts` | ✕ `test_doubleDeliver_reverts` | n/a |
| `ITEM` | ✕ `test_omittedItem_reverts` | ✕ `test_doubleItem_reverts` | ✕ `test_itemPolicy_ordered_refusesHoistedBorrow`, `test_itemPolicy_atomic_refusesInterleavedItems` |
| `PRESEND` | ● optional | ✕ bounded · `test_presend_boundedByOutstanding`, `test_presend_cannotTakeOwedFunds` | n/a |
| `CALL` | ● optional | ● by design (several interactions per plan) | n/a |
| bad kind | — | — | ✕ `test_badStep_reverts` |

**The F15 lesson, as a standing column this table does not have:** *what did the
step consume that a refund does not restore?* Tokens are refunded by Phase 3;
**allowance is not**. `test_dupPull_doesNotBurnExtraAllowance` is the only test in
the suite that asserts against a *finite* allowance for this reason — a
`uint160.max` grant masks the entire property. Any new step kind needs its own
row **and** its own finite-allowance assertion.

### M8 — side × leg direction

| | SELL | BUY |
| --- | --- | --- |
| Anchor | `legsIn[0].start` | `legsOut[0].start` |
| Auctioned side | outputs fall | inputs rise |
| Fixed side | inputs | outputs |
| Full fill | ● `PlainSwap:test_plain_swap_full` | ● `BuyOrders:test_buy_fullFill_fixedPrice` |
| Partial | ● `test_plain_swap_partialFills` | ● `BuyOrders:test_buy_partialFill_exactOutputConserved`, `testFuzz_buy_partials_conserveOutput` |
| Rounding direction | ● `RoundingDirection:test_slicing_neverFavoursTheSolver` | ● `test_buySide_slicing_neverFavoursTheSolver` |
| Fee leg | ◐ `SourcingFee:test_feeLeg_paysRecipient` | ◐ `test_feeLeg_onBuyOrder`, `_onBuyOrder_partialFill` |
| Soft override | ◐ pay **more** out · `test_override_sell_nonExclusiveMustDeliverMore` | ◐ charge **less** in · `test_override_buy_nonExclusiveChargesLess` |
| Proportional anchor | ◐ legal | ✕ `test_prop_onBuyOrderOutputAnchor_reverts` — an output is what the *solver* delivers |
| Not started | ✕ `MultiAssetPartials:test_auctionNotStarted_reverts` | ✕ `BuyOrders:test_buy_auctionNotStarted_reverts` |
| Delta-verify | ◐ `DeltaVerifyDelivery:test_deltaVerify_dutchOutput_tracksCurrentTick` | ◐ `test_deltaVerify_buyOrder_fixedOutput` |

### M9 — exotic denominators × everything they forbid

`Proportional` (G10) and `fillModule`/`fillTotal` change what the *denominator
means*, so they interact with almost every other axis. Each ✕ here is a real
revert, and F8 is the cell that was missing.

| Combination | Verdict | Test |
| --- | --- | --- |
| Proportional × partial fill | ✕ `ProportionalNeedsFullFill` | `test_prop_partialRequest_reverts` |
| Proportional × non-anchor input leg | ✕ `InvalidProportionalLeg` | `test_prop_onNonAnchorInputLeg_reverts` |
| Proportional × BUY output anchor | ✕ | `test_prop_onBuyOrderOutputAnchor_reverts` |
| Proportional × signed `fillTotal` | ✕ (the marker would never resolve) | `test_prop_withSignedFillTotal_reverts` |
| Proportional × uncapped (`end == 0`) | ✕ `ProportionalNeedsCap` | `test_prop_uncappedLeg_reverts` |
| Proportional × zero balance | ✕ | `test_prop_zeroBalance_reverts` |
| Proportional × balance grew past the solver's ceiling | ✕ | `test_prop_balanceGrewPastSolverCeiling_reverts` |
| Proportional × `fillUpTo` clamp | ◐ legal, clamps | `test_prop_fillUpTo_clampsToResolvedAnchor` |
| Proportional × pegged price module | ◐ **F8** — legal now | see [F8](reference-audits.md#f8--a-proportional-anchor-plus-the-pegged-price-module-passed-preflight-and-never-filled) |
| Proportional × typed callback | ◐ | `TypedCallback:test_typed_proportionalAnchorUnderPostInputs` |
| Proportional × batch paths | ◐ | **[G-6](#g-6)** |
| `fillModule` × overfill | ✕ cap stays in the core | `FillModule:test_overfillCap_moduleCannotExceedTotal` |
| `fillModule` × zero delta | ✕ `ZeroFill` | `test_zeroDelta_reverts` |
| `fillModule` × `minFillAnchor` | ✕ applies to the *delta* | `test_minFillAnchor_appliesToDelta` |
| `fillModule` × uniform scaling | ◐ one fraction, all legs | `test_singleFraction_scalesAllLegsUniformly` |
| `fillModule` × `fillUpTo` | ◐ proposal not clamped by the core | `test_fillUpTo_moduleOrder_proposalNotClamped` |
| Empty legs × no `fillTotal` | ✕ `NoAnchorLeg` | **[G-9](#g-9) no test** |

### M10 — token behaviour × delivery mode

| | Nominal push | Delta-verify (bit 104) |
| --- | --- | --- |
| J1 standard | ● everywhere | ◐ `DeltaVerifyDelivery:test_deltaVerify_partialFill_requiresOnlyTheSlice` |
| J3 FoT out, SELL | ◐ maker under-receives · `test_unmarked_fotOutput_deliversNominally` | ◐ settles net · `test_deltaVerify_fotOutput_settlesNetOfFee` |
| FoT in | ◐ solver bears it · `FeeOnTransfer:test_sellFoT_solverBearsFee` | n/a (inputs are measured) |
| FoT, BUY | ◐ `test_buyFoT_makerNetsLess_stillFills`, `test_buyFoT_minBalanceInvariant_protectsMaker` | ◐ `test_deltaVerify_buyOrder_fixedOutput` |
| Short receipt | — | ✕ `test_deltaVerify_shortReceipt_reverts` |
| Same token in **and** out | — | ✕ `test_deltaVerify_sameTokenInAndOut_reverts` |
| Duplicate (token, recipient) | ◐ legal · `SettlementGuards:test_fill_duplicateTokenOut_deliversBothLegs` | ✕ `test_deltaVerify_duplicateTokenRecipient_reverts` |
| Same token, different recipients | ◐ | ◐ `test_deltaVerify_sameTokenDifferentRecipients_ok` |
| Under `matchSettle` | ● | ✕ `DeltaVerifyNotBatchable` — **[G-7](#g-7)** |
| J4 missing return | ◐ `utils/SafeTransferLib` suite | ◐ same |
| J5 > `uint160.max` | ✕ `AmountOverflow` | **[G-10](#g-10) no test** |

---

## Part 3 — the completeness check, mechanically

The axis tables above are a human enumeration and can be incomplete. There is one
enumeration that cannot be: **every `revert` in the settler is a ✕ cell.** If an
error has no test, some must-not combination is unpinned, by definition.

As of 2026-08-27 the settlement layer declares **53 errors**, and **six have no
reference anywhere in `packages/core/test/`**:

| Error | Raised at | Reachable by | Gap |
| --- | --- | --- | --- |
| `NoAnchorLeg` | `OrderGates.sol:139,153` | an order with an empty fixed-side blob and no `fillTotal` | **[G-9](#g-9)** |
| `DeltaVerifyNotBatchable` | `Batch.sol:108` | a bit-104 order presented to `matchSettle` | **[G-7](#g-7)** |
| `AmountOverflow` | `Base.sol:367,376` | a leg slice above `uint160.max` | **[G-10](#g-10)** |
| `PricingNeedsContext` | `DutchAuction.sol:541,584` | the context-free pricing view called on a module / priority order | **[G-11](#g-11)** |
| `TokenNotInUniverse` | `Batch.sol:803` | a `matchSettle` internal-consistency failure | **[G-11](#g-11)** |
| `InvalidPermit3` | `Base.sol:238` | constructor guard — deploy-time | **[G-11](#g-11)** |

`NoAnchorLeg` deserves a note beyond its row. [`OrderGates`](../packages/core/src/settlement/OrderGates.sol)
opens by explaining that this specific guard is what the lens copy was **missing**
when the 2026-08 audit found the drift — a packed blob is not an array, so an
out-of-range read pads with zeros instead of reverting. The guard that answers a
found bug is currently pinned by nothing.

**Re-run this check** whenever an error is added or a test is deleted:

```bash
cd packages/core
for e in $(grep -rho 'error [A-Z][A-Za-z0-9]*(' src/settlement/*.sol | sed 's/error //; s/(//' | sort -u); do
  grep -rq "$e" test/ || echo "UNPINNED: $e"
done
```

---

## Part 4 — the gap register

Ranked by what a regression would cost, not by effort.

### G-1
**Bulk signature × later fills.** After the first fill of a Merkle-bundled order,
the first-fill skip accepts **any** 65 bytes — the proof is never re-folded. This
is the A4 row of [M1](#m1--credential--fill-progress) and is the *same shape* as
F13, differing only in that a signed root cannot be withdrawn, so there is no
bypass today. Write the test that pins the behaviour, so that if a future
revision makes roots revocable (a root-invalidation registry has been discussed
for quote refresh) the bypass surfaces as a failing test rather than a finding.
→ `BulkSignature.t.sol`.

### G-2
**Delegate revocation does not bind after a partial fill.** Documented in three
places (`OrderState.orderSignerExpiry`, `Signatures._verifySignature`,
`reference-audits.md`), pinned nowhere. `test_revocation_bindsOnAnUnfilledOrder`
covers only the half that binds. Add its negative twin — partial fill, revoke,
fill again, **succeeds** — so the accepted semantics are a green test rather than
a comment. Repeat for A6 (contract delegate) and for expiry lapse.
→ `DelegatedOrderSigner.t.sol`.

### G-3
**An EIP-1271 maker that starts returning `false` mid-order.** Same shape as G-2,
for the credential most likely to actually be revoked in production — a Safe
rotating owners. No mock in the suite can currently flip its answer. Add one,
assert the remainder still fills, and assert that `cancelOrder` **does** stop it.
That second assertion is the one that makes the documented advice ("a contract
maker that needs signature revocation to bind mid-order must use `cancelOrder`")
true by test rather than by claim.
→ `SignatureEdgeCases.t.sol`.

### G-4
**`matchSettle` runs an unpinned gate sequence.** `_openGated` re-implements
expiry, signature, exclusivity, nonce and validator checks, and **no test drives a
cancelled, expired, nonce-cancelled, exclusivity-gated or empty-sig order through
it.** The gates are correct today by reading. `OrderGates`' own header is the
argument for why reading is not enough: two lens copies of these same gates had
already drifted silently. One parameterised test that walks each B/E/I state
through C8 closes the whole column.
→ `MatchSettle.t.sol`.

### G-5
**Fill-once (B5) outside `fill`.** `FillOnceMustBeFull` is pinned only on the
single-order path. `fillUpTo` clamps to the remaining size — which for a fill-once
order is the whole order, so it should succeed — and `batchFill` / `matchSettle`
consume the maker's nonce as their progress record, which interacts with every
other order sharing that nonce. Three cheap tests.
→ `FillOnceNonce.t.sol`.

### G-6
**Proportional anchor (G10) in the batch paths.** The marker resolves through a
`balanceOf` on a maker-chosen token, and the ordering of that read against the
reentrancy guard is explicitly load-bearing (`OrderState._gateFillState` carries a
"do not flip these two lines" comment). `matchSettle` reaches the same resolution
by a different route and nothing exercises it.
→ `ProportionalLeg.t.sol` or `MatchSettle.t.sol`.

### G-7
**`DeltaVerifyNotBatchable` never fires in a test.** A one-line test. It is on
this list rather than folded into G-4 because it is the only *deliberate feature
exclusion* in the batch path — the kind of check that reads like dead weight in a
bytecode-size pass.
→ `MatchSettle.t.sol`.

### G-8
**Priority auction (D6) × partial fills.** The priority bump is pinned once per
fill, so two partials submitted at different tips price at different ticks — the
maker's realised price depends on how the solver *sliced*, which is true of no
other pricing mode here. Whether that is intended should be decided and then
pinned. This is the cell most likely to contain an actual, currently-unknown
issue, because the interaction is genuinely novel rather than merely untested.
→ `PricingModes.t.sol`.

### G-9
**`NoAnchorLeg`.** The guard that answers a found audit finding, pinned by
nothing. Both raise sites (SELL and BUY) need a case.
→ `ValidateOrder.t.sol` or `PlainSwap.t.sol`.

### G-10
**`AmountOverflow` (J5).** A leg slice above `uint160.max` is refused because
Permit3's allowance type cannot carry it. Constructible with a large signed
amount; currently unexercised.
→ `PlainSwap.t.sol`.

### G-11
**The remaining unpinned errors** — `PricingNeedsContext`, `TokenNotInUniverse`,
`InvalidPermit3`. Lower value: the first two are internal-consistency guards on
view/batch paths and the third is a constructor check. Worth closing to make the
mechanical check in [Part 3](#part-3--the-completeness-check-mechanically) return
clean, so that a *new* unpinned error stands out.

---

## Part 5 — maintenance

**When a feature lands.** Ask which axis it extends. If it extends none, it is a
new axis, and it needs a row in Part 1 plus one matrix against whichever existing
axis it couples to. A feature that couples to nothing is rare enough to be worth
distrusting.

**When an error is added.** It is a ✕ cell. Add the test in the same PR, and the
mechanical check in Part 3 stays clean.

**When a finding lands.** Locate it as a cell. If it has no cell, this document is
missing an axis — add it before writing the fix, because the axis is what tells
you where the *siblings* of the bug are. F13 → M1. F15 → M7. F8 → M9.

**When a test is written.** Ask the ◐ question: does the setup mask the property?
Infinite allowances mask allowance consumption. Round numbers mask rounding.
Filling at `decayStartTime` masks decay. A test that cannot fail is a coverage
claim without coverage — which is worse than a gap, because the gap is at least
visible here.
