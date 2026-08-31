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

**Status, 2026-08-27.** The first pass found eleven gaps and six settlement errors
that fired in no test at all. All are closed: the suite went **552 → 603** tests
with no contract change, and the mechanical sweep in
[Part 3](#part-3--the-completeness-check-mechanically) returns clean. Two residual
combinations are recorded as *accepted*, with the reason, in
[Part 4](#part-4--the-register). One of the closed items (G-8, the priority auction
under partial fills) turned out to be a genuine open question about behaviour rather
than a missing test, and is now a decision on the record.

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
| **◐** | **rare** | Legitimate, infrequent. A feature most orders never use, or a state most orders never reach. | **The most expensive gap.** Rare-but-legal is where findings F8 and F15 lived: reachable, unexercised, and nobody notices the regression. |
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

One axis is deliberately not in this list: **who controls a destination address**.
It is not a property of the order, it is a property of each *value sink*, so it
gets its own table — [M11](#m11--value-sink--who-controls-the-destination).

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

⚠ **Axis letters are not finding numbers.** This axis's `F1…F9` are fill-granularity
*values*; [`reference-audits.md`](reference-audits.md)'s `F1…F15` are *findings*. They
overlap in exactly one place — **`F8` is `newFilled > total` here and the
proportional-anchor × pegged-module finding there** — so every reference to the
finding is written as "finding F8" or linked. `F13`–`F15` have no axis meaning and are
always findings.

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
| H5 | Policy `ANY` / `ORDERED` / `ATOMIC` / `CANONICAL` | ◐ |
| H5a | `CANONICAL`: item hoisted ahead of its own `DELIVER` | ✕ `ItemPolicyViolated` |
| H5b | `CANONICAL`: `PULL` ahead of the item that funds the leg | ✕ `ItemPolicyViolated` |
| H5c | Two live orders of one maker whose items size from the SAME live state | ● degrades — the second caps to what is left while its value-out leg runs in full; use an OCO group or fill-once |
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
| J5 | An **item slice** wider than `uint160` (Permit3's book width) | ✕ `AmountOverflow` |

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
| A4 bulk / Merkle | ◐ · `BulkSignature:test_bulkSignature_fillsEveryLeaf` | ◐ **skipped — any 65 bytes pass** | ✕ leaf outside tree · `test_bulkSignature_orderOutsideTree_reverts` | ⊘ root is signed, not withdrawable · `test_bulkSignature_afterFirstFill_anyBytesAreAccepted` pins the skip, `..._untouchedSibling_stillRefusesGarbage` its bound |
| A5 delegate EOA | ◐ · `DelegatedOrderSigner:test_delegate_canSignForTheMaker` | ◐ skipped | ✕ binds · `test_revocation_bindsOnAnUnfilledOrder` | ◐ **does NOT bind** · `test_revocation_doesNotBindAfterAPartialFill`; `cancelOrder` does · `test_revocation_cancelOrderBindsWhereRevocationDoesNot` |
| A6 delegate contract | ◐ · `test_contractDelegate_signsViaEnvelope` | ◐ skipped | ✕ binds · `test_contractDelegate_revoked` | ◐ does NOT bind · `test_contractDelegate_revocationDoesNotBindAfterAPartialFill` |
| A7 EIP-1271 maker | ◐ · `PlainSwap:test_plain_swap_contractSigner_eip1271`, `SafeMakerFork:test_fork_gnosisSafe_maker_eip1271` | ◐ skipped | ✕ binds · `SignatureEdgeCases:test_1271_wrongMagicValue_reverts` | ◐ does NOT bind (E9) · `test_1271_revokedMidOrder_doesNotBindOnTheRemainder`; bounded by `..._revokedBeforeAnyFill_stillBinds` |
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
| E3 `invalidateNonceWord` | ✕ binds · `test_invalidateNonceWord_cancels256` | ✕ binds — same gate as E2, which is pinned on a touched order |
| E4 `rollbackNonces` | ✕ binds · `test_rollback_cancelsBelowFloor` | ✕ binds — same gate; also pinned on the netted path · `MatchSettleGates:test_gate_rolledBackNonce_reverts` |
| E5 `revokeOrderApproval` | ✕ binds · `OnChainOrderApproval:test_revokeOrderApproval_blocksFill` | ✕ binds · `test_revokeOrderApproval_blocksRemainderAfterPartialFill` + F13 pin |
| E6 `setOrderSigner(d,0)` | ✕ binds · `DelegatedOrderSigner:test_revocation_bindsOnAnUnfilledOrder` | ◐ **does not bind** · `test_revocation_doesNotBindAfterAPartialFill`, `test_expiry_doesNotLapseMidOrderOnceTouched` |
| E7 expiry | ✕ binds · `MultiAssetAuthGates:test_multiOut_expired` | ✕ binds (checked per fill in `_fillCore`) |
| E8 Permit3 revoke | ✕ funding fails · `OrderRelevantState:test_state_underfunded_byAllowance` | ✕ same |
| E9 1271 → `false` | ✕ binds · `SignatureEdgeCases:test_1271_*` | ◐ **does not bind** · `test_1271_revokedMidOrder_doesNotBindOnTheRemainder` |

**Reading:** a maker holding a part-filled order has exactly seven working kill
switches, not nine. E6 and E9 are advertised as revocation and are not, for the
remainder of a touched order. That is a *correct, deliberate* trade (the
alternative is a cold SLOAD on every fill of every order), and as of 2026-08-27 it
is a **tested** one in both directions: each non-binding cell has a test asserting
the remainder still fills, paired with one asserting that `cancelOrder` — the
switch the source tells a maker to reach for — does bind. The advice is now true by
test rather than by claim.

### M3 — entry point × lifecycle gate

`matchSettle` (C8) runs `_openGated`, a **separate** gate sequence from
`_fillCore`. Every cell in its column is therefore an independent claim.

| Gate | `fill` (C1) | `fillUpTo` (C7) | `batchFill` (C6) | `matchSettle` (C8) |
| --- | --- | --- | --- | --- |
| Expired (B8) | ✕ `MultiAssetAuthGates:test_multiOut_expired` | ✕ shares `_fillCore` | ✕ shares `_fillCore` | ✕ `MatchSettleGates:test_gate_expiredOrder_reverts` |
| Cancelled by hash (B4) | ✕ `CancelOrder:*` | ✕ `FillUpTo:test_fillUpTo_cancelledByHash_reverts_OrderCancelled` | ✕ skipped, not reverted · `BatchFill:test_batchFill_skipsUnfillable` | ✕ `MatchSettleGates:test_gate_cancelledByHash_reverts` |
| Nonce cancelled (B6/B7) | ✕ `NonceCancellation:*` | ✕ shares | ✕ shares | ✕ `MatchSettleGates:test_gate_nonceCancelled_reverts`, `..._rolledBackNonce_reverts` |
| Empty sig / `approveOrder` (A9) | ◐ `OnChainOrderApproval:test_approve_thenFill_emptySig` | ◐ shares | ◐ `test_batchFill_approvedOrder_emptySig` | ◐ `MatchSettleGates:test_gate_emptySig_authorizesViaOnChainApproval` + `..._withoutApproval_reverts`, `..._revokedApproval_reverts` |
| Fill-once (B5) | ◐ `FillOnceNonce:test_fillOnce_settlesAndConsumesTheNonce` | ◐ `test_fillOnce_fillUpTo_overRequestClampsToTheWholeOrder`, `..._underRequest_reverts` | ◐ `test_fillOnce_batchFill_partialFailsSoftlyAndBurnsNoNonce` (+2) | ◐ `MatchSettleGates:test_gate_fillOnce_partialInAPlan_reverts`, `..._fullFillConsumesTheNonce` |
| Exclusivity (I2–I5) | ✕ `AuctionAndExclusivity:*` | ✕ `test_fillUpTo_recipient_doesNotBypassExclusivity` | ✕ `SettlementGuards:test_batchFill_exclusivity_threadsFiller` | ✕ `MatchSettleGates:test_gate_hardExclusivity_outsiderReverts` + the two complements |
| Proportional anchor (G10) | ◐ `ProportionalLeg:*` | ◐ `test_prop_fillUpTo_clampsToResolvedAnchor` | ◐ `test_prop_batchFill_resolvesTheAnchorPerOrder` (+2) | ◐ `MatchSettleGates:test_gate_proportionalAnchor_resolvesInAPlan`, `..._partialInAPlan_reverts` |
| Delta-verify (J2) | ◐ `DeltaVerifyDelivery:*` | ◐ shares | ◐ shares | ✕ `MatchSettleGates:test_gate_deltaVerifyOrder_isNotBatchable` + `..._sameOrderWithoutTheFlag_matches` |
| Contract maker (A7) | ◐ `PlainSwap`, `SafeMakerFork`, `SignatureEdgeCases:test_1271_*` | ◐ — untested | ◐ — untested | ◐ — untested (accepted — see R-1) |
| Reentrancy | ✕ `SettlementGuards:test_reentrancy_into_fill_reverts` | ✕ `..._into_fillUpTo_reverts` | ✕ shares | ✕ `test_reentrancy_viaCallback_reverts` |

### M4 — fill granularity × pricing mode

Where slicing and the clock interact. The question each cell answers: *does
splitting the fill change what the maker receives?*

| Pricing | Whole (F1) | Two partials (F2+F4) | Many slices (F5) |
| --- | --- | --- | --- |
| D1 fixed | ● `PlainSwap:test_plain_swap_full` | ● `test_plain_swap_partialFills` | ◐ **must not drift** · `RoundingDirection:test_fixedInput_isExactUnderAnySlicing`, `testFuzz_slicing_neverFavoursTheSolver` |
| D2 linear decay | ● `test_plain_swap_dutchDecay` | ● `test_plain_swap_partialFills_acrossDutchTicks`, `MultiAssetPartials:test_multiIn_dutchDecay_midpoint` | ◐ `FillAccountingFuzz:testFuzz_twoPartialFills_sumInvariant` |
| D3 curve | ◐ `AuctionAndExclusivity:test_curve_sell_interpolatesBetweenPoints` | ◐ `test_curve_partialFills_perTickPricing` | ◐ covered by the same |
| D4 block clock | ◐ `PricingModes:test_blockClock_decaysPerBlock` | ◐ — untested (accepted — see R-2) | ◐ — untested |
| D5 gas bump | ◐ `test_gasBump_sell_reducesOutputWithBasefee` | ◐ `test_gasBump_plusTimeDecay_sumsAndFills` | ◐ `testFuzz_gasBump_withinBounds` |
| D6 priority | ◐ `PricingModes:test_priorityAuction_bidMovesTickTowardStart` | ◐ **slices price INDEPENDENTLY** · `test_priorityAuction_partialFills_priceIndependentlyPerSlice` | ◐ bounded by the band · `testFuzz_priorityAuction_everySliceStaysInsideTheBand` |
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

**The netted half of the same invariant** is
[`MatchComboMatrix.t.sol`](../packages/core/test/swaps/MatchComboMatrix.t.sol) and
[`MatchSettleRoundingAttack.t.sol`](../packages/core/test/swaps/MatchSettleRoundingAttack.t.sol):
`RoundingDirection` pins the *direction* of the arithmetic, and those two pin that
**matching cannot change it** — every matchable shape against every other, whole and
sliced, must produce the maker the same ledger the single-order path would. The
axis pair is written up at full depth in
[match-combinations.md](match-combinations.md) — which also crosses the **item**
axis into it ([`MatchItemMatrix.t.sol`](../packages/core/test/swaps/MatchItemMatrix.t.sol),
item config × shape and item config × item config), records the four order shapes
`matchSettle` refuses outright, and names the one residual (a BUY dust slice
charging zero, paid by the filler) and the one deliberate divergence between the
two paths (stray `TAKE` proceeds: stranded by `fill`, refunded to the maker by
`matchSettle`).

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
| I2 hard, outsider | ✕ `AuctionAndExclusivity:test_hardExclusivity_zeroBps_stillReverts` | ✕ `FillUpTo:test_fillUpTo_recipient_doesNotBypassExclusivity` | ✕ skipped · `SettlementGuards:test_batchFill_exclusivity_threadsFiller` | ✕ `MatchSettleGates:test_gate_hardExclusivity_outsiderReverts` |
| I3 soft, outsider pays | ◐ `test_override_sell_nonExclusiveMustDeliverMore` | ◐ — untested | ◐ `test_override_batchFill_threadsFillerAndOverride` | ◐ — untested (accepted — see R-1) |
| I4/I5 filler set | ◐ `FillerSetExclusivity:test_fillerSet_firstMemberFills`, `test_fillerSet_softOverride_outsiderPaysImprovement` | ◐ — untested | ◐ — untested | ◐ — untested (accepted — see R-1) |
| I7 malformed set | ✕ `test_fillerSet_emptySet_isMalformed`, `_truncatedEntry_`, `_nonZeroCountByte_` | ✕ shares | ✕ shares | ✕ shares |
| I6 window lapsed | ● `test_fillerSet_outsiderFillsAfterWindow`, `test_fillerSet_malformedHealsAfterWindow` | ● | ● | ● `MatchSettleGates:test_gate_exclusivity_lapsedWindowOpensUp` |
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
revert, and finding F8 is the cell that was missing.

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
| Proportional × batch paths | ◐ | `ProportionalLeg:test_prop_batchFill_*` (3), `MatchSettleGates:test_gate_proportionalAnchor_*` (2) |
| `fillModule` × overfill | ✕ cap stays in the core | `FillModule:test_overfillCap_moduleCannotExceedTotal` |
| `fillModule` × zero delta | ✕ `ZeroFill` | `test_zeroDelta_reverts` |
| `fillModule` × `minFillAnchor` | ✕ applies to the *delta* | `test_minFillAnchor_appliesToDelta` |
| `fillModule` × uniform scaling | ◐ one fraction, all legs | `test_singleFraction_scalesAllLegsUniformly` |
| `fillModule` × `fillUpTo` | ◐ proposal not clamped by the core | `test_fillUpTo_moduleOrder_proposalNotClamped` |
| Empty legs × no `fillTotal` | ✕ `NoAnchorLeg` | `ErrorSurface:test_noAnchorLeg_sellWithNoInputLegs_reverts`, `..._buyWithNoOutputLegs_reverts`, `..._signedFillTotalNeedsNoLegs` |

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
| Under `matchSettle` | ● | ✕ `MatchSettleGates:test_gate_deltaVerifyOrder_isNotBatchable` |
| J4 missing return | ◐ `utils/SafeTransferLib` suite | ◐ same |
| J5 item slice > `uint160` | ✕ delivery-mode independent — the ceiling is Permit3's book width, not the token's behaviour · `ErrorSurface:test_amountOverflow_makeItemAboveUint160_reverts`, `..._takeItemAboveUint160_reverts`, `..._exactlyUint160Max_isAccepted` | ✕ same |

### M11 — value sink × who controls the destination

The C15 matrix — *the settler's balance treated as a shared pot* — asked the way
an attacker asks it. Every token movement in a fill has a **destination** and an
**amount**, and the whole safety argument is that a filler never controls both
halves for money that is not its own.

| Value sink | Destination chosen by | Amount bounded by | Pinned by |
| --- | --- | --- | --- |
| Output leg | **MAKER** — `LegOut.recipient`, in the typehash | the signed leg price | `SolverValueExtraction:test_repointingAFeeRecipient_breaksTheSignature` |
| Item proceeds | **MAKER** — `Item.recipient`, in the typehash | the signed item slice | `MultiAssetItems:test_take_recipientRouting_toMaker` |
| `payTo` (`fillUpTo`) | **FILLER** | `owed` — the filler's own signed price | `test_recipient_cannotCaptureTheMakersOutput`, `FillUpTo:test_fillUpTo_recipient_redirectsProceedsOnly` |
| `profitRecipient` (`matchSettle`) | **FILLER** | `balanceOf − beforeBal` | `test_profitRecipient_cannotReachAPreExistingBalance` |
| `PRESEND` → `msg.sender` | **FILLER** | unencumbered surplus only | `MatchSettle:test_presend_boundedByOutstanding`, `..._cannotTakeOwedFunds` |
| Callback `(target, data)` | **FILLER** | **nothing** — the executor is nobody's spender | `test_callbackCannotLiftTheSettlersBalanceMidFill`, `SolverCallback:test_fillWithCallback_cannotDrainViaPermit3` |
| `takerData` | **FILLER** | reaches no destination at all | `test_takerData_reachesNoDestination` |

**The rule the whole column rests on:** every amount a filler can receive is a
**measured delta** over a snapshot taken *inside this settlement* — `balanceOf −
before`, never a raw `balanceOf`. That is what makes a pre-existing or donated
Settlement balance unreachable, and it holds on both paths.

| Attack | Verdict | Pinned by |
| --- | --- | --- |
| Redirect the maker's output via `fillUpTo(recipient)` | ✕ routes the filler's own proceeds only | `test_recipient_cannotCaptureTheMakersOutput` |
| Re-point a fee leg at the filler | ✕ forgery, not accounting — the recipient is in the typehash | `test_repointingAFeeRecipient_breaksTheSignature` |
| Smuggle a destination through `takerData` | ⊘ it reaches no destination decision | `test_takerData_reachesNoDestination` |
| Take a donated `tokenIn` balance as "proceeds" | ✕ the snapshot floors it | `test_donatedBalance_isNotPaidOutAsProceeds` |
| Let a donated `tokenOut` balance stand in for delivery | ✕ delivery is a pull from the filler | `test_donatedOutputBalance_doesNotFundTheDelivery` |
| Lift the settler's balance mid-callback | ✕ the executor holds no allowance | `test_callbackCannotLiftTheSettlersBalanceMidFill` |
| Donate mid-callback, get it back as "proceeds" | ✕ the input snapshot is taken **after** the callback | `test_callbackDonationIsNotCountedAsThisFillsProceeds` |
| Name a third-party `profitRecipient` to widen the sweep | ✕ still `balanceOf − beforeBal` | `test_profitRecipient_cannotReachAPreExistingBalance` |
| Inject a filler-signed order to drain the pooled inputs | ✕ `PlanIncomplete` / `BatchNotWhole` | `test_injectedSelfOrder_cannotDrainThePooledInputs` |
| …the same order, paying its own way | ● legal, and nets only what it funded | `test_injectedSelfOrder_thatPaysItsOwnWay_isFine` |

**Two findings from writing these, neither a vulnerability, both worth knowing.**

*Order of operations is doing security work.* The input snapshot in
`Core._settleForward` is taken **after** the solver callback returns. A callback
that pushes tokens into Settlement therefore lands *below* the floor and counts as
nothing — the maker still funds the full shortfall and the donation is stranded.
Move that snapshot one line earlier and a filler could pay the maker's side with
its own money and take it straight back while the maker keeps their input. Nothing
in the code says "this line must come first"; the test does.

*Value parked in Settlement is unrecoverable, and that is the point.* Because every
payout is `balanceOf − before`, a balance sitting in the settler raises the floor
for every future settlement and can never be swept out by a later filler. Naming
`address(settlement)` as `payTo` or `profitRecipient` is a filler's own funeral,
not an exploit — pinned by
`test_recipientIsSettlement_strandsTheFillersOwnProceeds`, which also shows a
subsequent ordinary fill hands out its own amounts and not one wei more.

---


---

## Part 3 — the completeness check, mechanically

The axis tables above are a human enumeration and can be incomplete. There is one
enumeration that cannot be: **every `revert` in the settler is a ✕ cell.** If an
error has no test, some must-not combination is unpinned, by definition.

The settlement layer declares **53 errors**. When this note was first written, six
had no reference anywhere in `packages/core/test/`. All six were addressed on
2026-08-27; the sweep now returns clean.

| Error | Raised at | Reachable by | Now pinned by |
| --- | --- | --- | --- |
| `NoAnchorLeg` | `OrderGates.sol:139,153` | an order with an empty fixed-side blob and no `fillTotal` | `ErrorSurface:test_noAnchorLeg_sellWithNoInputLegs_reverts` · `..._buyWithNoOutputLegs_reverts` · `..._signedFillTotalNeedsNoLegs` |
| `DeltaVerifyNotBatchable` | `Batch.sol:108` | a bit-104 order presented to `matchSettle` | `MatchSettleGates:test_gate_deltaVerifyOrder_isNotBatchable` · `..._sameOrderWithoutTheFlag_matches` |
| `AmountOverflow` | `Base.sol:367,376` | a MAKE/TAKE **item slice** above `uint160.max` | `ErrorSurface:test_amountOverflow_makeItemAboveUint160_reverts` · `..._takeItemAboveUint160_reverts` · `..._exactlyUint160Max_isAccepted` |
| `PricingNeedsContext` | `DutchAuction.sol:541,584` | the context-free pricing view called on a module / priority order | `ErrorSurface:test_pricingNeedsContext_priceModuleOrder_hasNoClockTick` · `..._priorityOrder_hasNoClockTick` · `..._clockOrderStillPreviews` |
| `InvalidPermit3` | `Base.sol:238` | constructor guard — deploy-time | `ErrorSurface:test_invalidPermit3_codelessHubRejectedAtConstruction` |
| `TokenNotInUniverse` | `Batch.sol:803` | **nothing** — see below | `MatchSettleGates:test_tokenUniverse_coversEveryLegTokenAcrossOrders` (invariant, not revert) |

`NoAnchorLeg` deserves a note beyond its row. [`OrderGates`](../packages/core/src/settlement/OrderGates.sol)
opens by explaining that this specific guard is what the lens copy was **missing**
when the 2026-08 audit found the drift — a packed blob is not an array, so an
out-of-range read pads with zeros instead of reverting. The guard that answers a
found bug was, until now, pinned by nothing.

**The one honest exception, stated plainly so the clean sweep does not overclaim.**
`TokenNotInUniverse` is the fall-through of `Batch._tokenIndex`, and its own source
says nothing can raise it today: the universe is the on-chain union of exactly the
legs being indexed, so every lookup hits. It is a loud backstop for a future caller
that widens the universe. **An error that cannot be raised cannot be pinned by
expecting it** — so what is pinned instead is the *property that makes it
unreachable*: a three-token, three-order plan settles, which is only possible if
every leg token resolved to a universe slot. The mechanical sweep below passes on
that test's reference to the error, not on a `vm.expectRevert`. That is a
deliberate, documented exception and the only one; a *new* unpinned error still
stands out.

**Re-run this check** whenever an error is added or a test is deleted:

```bash
cd packages/core
for e in $(grep -rho 'error [A-Z][A-Za-z0-9]*(' src/settlement/*.sol | sed 's/error //; s/(//' | sort -u); do
  grep -rq "$e" test/ || echo "UNPINNED: $e"
done
```

### The second sweep — do the cited tests still exist?

The check above pins *errors*. It says nothing about the other direction, which is
the one this note's credibility actually rests on: **every cell above names a test,
and those names are hand-written prose.** Rename or delete a test and the table
goes on claiming the cell is covered. A coverage claim without coverage is exactly
what Part 5 warns against, and doc-drifting-from-code is the shape of
[F13](reference-audits.md#f13--a-revoked-on-chain-order-approval-was-bypassed-by-any-non-empty-signature)
itself — there, a comment promised the approval record was "re-checked on every
fill" long after that stopped being true of every branch.

```bash
make docs-check          # or: python3 tools/check-doc-citations.py
```

It resolves every backticked citation in `docs/*.md` against the test functions
declared in the tree, and exits non-zero on the first that does not resolve. The
citation forms it understands:

```
Suite:test_name          a specific test
test_name                a specific test, suite implied by context
test_prefix_*            a family; at least one member must exist
..._suffix               prefix elided from the previous citation
```

Spans inside a fenced block — like the four above — are examples, not citations,
and are skipped. That is the escape hatch: **to name a test that does not exist,
fence it or drop the backticks**, otherwise the gate is right to object.

First run found two real ones. `item-aware-netted-settle.md` risk #5 cited
*test_wrongSequence_reverts* and *test_itemLeg_underfunded_reverts*, both renamed
long ago to `MatchSettle:test_badStep_reverts` and `..._itemUnderproduces_legUnfunded`.
The property was covered; the citation was not. Fixed there.

**Two ways this check can lie, both fixed, both worth knowing if you extend it.**
Markdown pairs backticks, and a ``` fence is an odd run of them — so a naive
whole-file pairing inverts every span after the first fenced block and silently
matches nothing. The first version did that and reported a clean sweep on a doc
that cited a deliberately bogus test. And the set of "tests that exist" must be
scoped to Solidity under `test/`: a bare recursive scan also matches `function
test…` inside `node_modules` bundles and stale Foundry artifacts, which is a
*superset* — and a superset makes this a false negative rather than a failure.
**A gate whose passing state you have not tried to break is not evidence.** Both
faults were found by appending a fake citation and watching for the failure that
should have come; do that after any change to the script.

---

## Part 4 — the register

Every gap this note opened was closed on **2026-08-27**. The entries are kept
rather than deleted: each one names a property that is now *asserted* rather than
merely *documented*, and the reasoning is what tells a future reader whether a
failing test is a bug or a deliberate change. Two residual items (`R-*`) are
recorded as accepted, with the reason.

The suite went **552 → 603** tests, all passing, with no change to any contract —
these are pins on existing behaviour, not fixes.

### G-1 — bulk signature × later fills · CLOSED
After the first fill of a Merkle-bundled order the first-fill skip accepts **any**
65 bytes; the proof is folded exactly once. Not a bypass, for one narrow reason: a
signed root, like a signed order hash, cannot be withdrawn.
`BulkSignature:test_bulkSignature_afterFirstFill_anyBytesAreAccepted` pins the
behaviour and `..._untouchedSibling_stillRefusesGarbage` pins its bound (the skip is
`filled != 0`, not per-tree or per-maker).
**⚠ This test is a tripwire.** Any future *root-level* revocation — a
root-invalidation registry for quote refresh has been discussed — makes the root a
withdrawable credential behind this skip, which is exactly F13. Should that land,
invert this test rather than delete it.

### G-2 — delegate revocation after a partial fill · CLOSED
Documented in three places, pinned nowhere; `test_revocation_bindsOnAnUnfilledOrder`
covered only the half that binds. Four negative twins added:
`test_revocation_doesNotBindAfterAPartialFill`,
`test_contractDelegate_revocationDoesNotBindAfterAPartialFill` (a separate branch,
so a separate case), `test_expiry_doesNotLapseMidOrderOnceTouched`, and
`test_revocation_cancelOrderBindsWhereRevocationDoesNot` — the last being the one
that makes the source's advice ("use `cancelOrder`") true by test.

### G-3 — an EIP-1271 maker that stops saying yes · CLOSED
The credential most likely to actually be revoked in production, and the suite's
three 1271 mocks were all fixed functions of their input — the caveat was
untestable *by construction*. A `FlippableWallet` closes that:
`test_1271_revokedMidOrder_doesNotBindOnTheRemainder`,
`test_1271_revokedBeforeAnyFill_stillBinds` (the bound), and
`test_1271_cancelOrderBindsWhereRevocationDoesNot`.

### G-4 — `matchSettle`'s unpinned gate sequence · CLOSED
The largest gap, and the one with the strongest structural argument behind it:
`Batch._openGated` is a **third** copy of the settler's gate rules, and
[`OrderGates`](../packages/core/src/settlement/OrderGates.sol) opens with the record
of two earlier copies drifting silently. New file
[`MatchSettleGates.t.sol`](../packages/core/test/swaps/MatchSettleGates.t.sol) —
21 tests — drives expired, cancelled-by-hash, nonce-cancelled, rolled-back,
already-filled, zero-fill, hard/soft exclusivity, empty-sig approval and its
revocation, and a wrong signer through `matchSettle` itself, each with the
complement that makes the assertion about the *gate* rather than about the order
being broken.

### G-5 — fill-once outside `fill` · CLOSED
Five tests. The path-specific finding worth keeping: under `batchFill` a partial
fill-once fails **softly** (`success[i] = false`) and the rolled-back sub-call
**burns no nonce** — without which one badly-sized batch entry would strand a
maker's order permanently. Pinned by
`test_fillOnce_batchFill_partialFailsSoftlyAndBurnsNoNonce`, plus the `fillUpTo`
clamp agreeing with the full-fill rule
(`test_fillOnce_fillUpTo_overRequestClampsToTheWholeOrder`) and the `matchSettle`
pair in `MatchSettleGates`.

### G-6 — proportional anchor in the batch paths · CLOSED
Five tests. Beyond "it resolves", two are about the shape's real hazard: `batchFill`
has **no clamp** (that is `fillUpTo`'s job), so a solver quoting against a balance
that then grows arrives with a request below the new anchor — a partial fill of an
order that can only fill whole. It must fail softly and stay fillable, which
`test_prop_batchFill_staleQuoteAfterBalanceGrows_failsSoftly` asserts;
`test_prop_batchFill_twoMakersResolveIndependently` pins that each anchor is read
against its own maker's balance.

### G-7 — `DeltaVerifyNotBatchable` · CLOSED
`MatchSettleGates:test_gate_deltaVerifyOrder_isNotBatchable`, paired with
`..._sameOrderWithoutTheFlag_matches` so the refusal is pinned to the *flag* and a
future edit cannot satisfy it by breaking the shape generally.

### G-8 — priority auction × partial fills · CLOSED, and it was a real question
This was flagged as the cell most likely to contain something unknown, and it did
contain something worth deciding. **Confirmed: two partial fills of the same order,
in the same block, at different tips clear at different ticks** — the maker's
realised average price depends on how the solver chose to slice, which is true of no
other pricing mode here.

That is correct and inherent rather than a defect: a priority auction prices a
*race*, each transaction is its own race, and a partial fill is a whole transaction.
Averaging across slices would require remembering a per-order bid — exactly the
storage the mode exists to avoid. So the decision is *keep it*, and
`test_priorityAuction_partialFills_priceIndependentlyPerSlice` puts it on the record
so a future "improvement" has to argue with a test.
**The maker's protection is the band, not slice-invariance**, and that is the part
worth carrying forward: every slice clears inside `[end, start]`, both signed, so the
worst case over any slicing is the floor an unbid single fill would have paid.
`testFuzz_priorityAuction_everySliceStaysInsideTheBand` fuzzes the slice point and
both bids against that bound. `minFillAnchor` is the lever a maker uses to limit how
finely the order can be cut up.

#### G-8 measured against the industry — two claims, two different answers

Checked against source, not reputation, because the repo's own notes call the
priority auction "the parity feature with UniswapX's `PriorityOrderReactor`" and
that claim turns out to be exact only under a condition worth naming.

**(a) "Slices of one order clear at different prices, and the signed band is the
only guarantee" — this IS the standard.** [CoW's
`GPv2Settlement`](https://github.com/cowprotocol/contracts/blob/main/src/contracts/GPv2Settlement.sol)
keeps a cumulative `filledAmount[orderUid]` for `partiallyFillable` orders and
enforces the limit price **per trade** against *that batch's* clearing prices
(`order.sellAmount * sellPrice >= order.buyAmount * buyPrice`). Clearing prices are
uniform *within* a batch and differ *across* batches, so a partially fillable CoW
order filled over N batches realises N different prices and the maker's only
guarantee is the limit price. That is our structure exactly, with `end` in the role
of the limit price. 1inch Fusion is the same shape on a time clock. Nothing novel
here, and nothing to fix.

**(b) "A priority-FEE auction with partial fills" — no precedent exists.**
UniswapX's `PriorityOrderReactor` is the only shipped auction of this shape, and it
is **all-or-nothing**: it carries no filled-amount accounting at all, marking orders
consumed through the Permit2 nonce bitmap (`OrderAlreadyFilled()`), and Uniswap's own
filler documentation states that *"only the fill transaction with the highest
priority fee will win the order, all other transactions will revert onchain."* CoW
has no priority auction (its competition is an off-chain batch auction). So on this
axis we are **extending the design, not matching it**.

**What the extension changes, precisely.** It is a change of auction *mechanism*,
and the mechanism has a name:

| | UniswapX priority | Ours, partially fillable |
| --- | --- | --- |
| Mechanism | single-unit **first-price** auction | multi-unit **pay-as-bid** (discriminatory) auction |
| Maker realises | the **top** bid, on the whole size | the quantity-weighted **average** of accepted bids |
| Losing bidder | reverts, pays gas on its own bid | may instead take a later slice at its own, lower bid |

Pay-as-bid multi-unit auctions are a well-understood mechanism (treasury auctions
run this way), so this is not pathological — but the expected clearing price is
lower than the first-price equivalent, because the maker's average is bounded above
by the top bid rather than equal to it. Against that, partial fills **broaden the
bidder pool**: a solver whose inventory covers half the order can bid at all, where
UniswapX excludes it. Which effect dominates is an empirical question about solver
inventory depth on the target chain, not something to settle here.

**No safety consequence, and the reason is worth stating** because it is what
separates this from the classic partial-fill hazard. In a *time* dutch auction a
solver can improve its own price by waiting, so slicing is a strategy. Here it is
not: each slice is priced at *that transaction's own tip*, so a solver's cheapest
schedule — every slice at zero tip — clears at the floor, which is exactly what one
unbid fill of the whole order would have paid. Slicing buys the solver nothing it
could not already have.

**The lever, and it already exists.** A maker who wants winner-takes-all semantics
sets the **fill-once** bit (`timing` bit 100) alongside the priority bit. The order
then admits no slicing, the top bid takes the whole size, and the behaviour is
`PriorityOrderReactor`'s exactly — the same all-or-nothing enforced by the same kind
of nonce record. The two bits are independent and compose;
`test_priorityAuction_fillOnce_restoresWinnerTakesAll` pins it, since it is the
recommended shape for any priority order that cares about its clearing price.

**Consequence for the parity claim.** [`pricing-modes.md`](pricing-modes.md) and
[`lop-parity.md`](lop-parity.md) have been qualified: parity with
`PriorityOrderReactor` is exact for a **fill-once** priority order; a partially
fillable one is a deliberate extension with different auction economics. Order
builders should default priority orders to fill-once unless they specifically want
the multi-unit behaviour.

### G-9 / G-10 / G-11 — the unpinned error surface · CLOSED
New file [`ErrorSurface.t.sol`](../packages/core/test/swaps/ErrorSurface.t.sol) —
10 tests covering `NoAnchorLeg` (both raise sites plus the `fillTotal` complement),
`AmountOverflow` (both branches plus the exact boundary), `InvalidPermit3`, and
`PricingNeedsContext` (both modes plus the clock-order complement). See
[Part 3](#part-3--the-completeness-check-mechanically) for the `TokenNotInUniverse`
exception.

One correction the work produced: `AmountOverflow` guards an **item slice**, not a
leg amount. The axis and matrix entries above were wrong about this and have been
fixed. It is reached only through a maker-signed `Item`, so it is not adversarially
reachable — which is exactly why it needed a test: the failure it prevents is
*silent truncation* (every shipped maker module narrows to `uint160` unchecked one
frame down), and nothing else in the suite would have noticed the check being
dropped in a size pass.

### R-1 — contract makers and exclusivity through non-`fill` entry points · ACCEPTED
`fillUpTo` / `batchFill` / `matchSettle` are untested with an EIP-1271 maker, and
soft exclusivity and filler sets are untested through `fillUpTo`. These share
`_fillCore` (or, for `matchSettle`, the now-pinned `_openGated`) and the credential
and exclusivity gates are per-order, not per-path — so the marginal value is low
and the combinatorial cost is high. Recorded rather than closed. Revisit if any
entry point stops routing through the shared opener.

### R-2 — block clock × partial fills · ACCEPTED
`fillUpTo` and multi-slice fills under the block clock (D4) are untested. The block
clock changes only the *source* of the tick (`block.number` for `block.timestamp`);
the slicing arithmetic is the same code the timestamp clock already exercises across
`MultiAssetPartials`, `RoundingDirection` and `FillAccountingFuzz`. Low value,
recorded for completeness.

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
you where the *siblings* of the bug are. Findings F13 → M1, F15 → M7, F8 → M9.

**When a test is renamed or deleted.** Run `make docs-check` before the PR lands.
Every cell in Part 2 names the test that pins it, and a rename silently converts
that binding into a false coverage claim — the drift is invisible precisely because
the table still reads correct.

**When a test is written.** Ask the ◐ question: does the setup mask the property?
Infinite allowances mask allowance consumption. Round numbers mask rounding.
Filling at `decayStartTime` masks decay. A test that cannot fail is a coverage
claim without coverage — which is worse than a gap, because the gap is at least
visible here.
