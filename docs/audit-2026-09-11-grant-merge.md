# Differential security review — grant-class module merge (2026-09-11)

**Scope:** the uncommitted working tree against `HEAD` (`a6c784b`): 47 files, +794 / −1,872,
three new contracts, two deleted files. The change merges per-op module contracts into one
contract per venue, grouped by the standing grant a maker gives that venue, and moves the op
discriminator INSIDE `data` (word 0 on the MAKE / plain-TAKE seams, descriptor bits [244,252)
on `TAKE_FOR`).

**Method:** the `differential-review` skill's six phases. Phases 0–4 (triage, control census
against the deleted sources, per-op test-execution coverage, blast radius, deep context) by
the author; Phase 5 (adversarial modeling) by an independent agent given the old and new
sources, the seam libraries, the core, and the F-numbered finding catalogue, and asked to
build exploits or line-referenced disproofs. Its full report is Appendix A.

# Executive Summary

| Severity | Count | Status |
|---|---|---|
| 🔴 CRITICAL | 0 | — |
| 🟠 HIGH | 0 | — |
| 🟡 MEDIUM | 1 | **RE-ASSESSED → not load-bearing; removed with proof** (see finding) |
| 🟢 LOW | 1 | **FIXED** — Dolomite `Full` withdraw missing I-8 guard (pre-existing, carried through) |
| ℹ️ INFO | 3 | 1 **FIXED** (stale-encoder collision), 1 **RESOLVED** (Euler/Aave guard dependency → I-16), 1 accepted by design |

**Overall risk of the change as it now stands: LOW.**
**Recommendation: APPROVE.** Every finding is closed or accepted-by-design; the one
structural dependency is now invariant I-16 with a machine check and an executable proof.

**Key metrics**
- Files analyzed: 47/47. All three new contracts read in full against all four deleted/trimmed
  sources; every security control in the old code located in the new code or its absence
  justified (Phase 1 table below).
- Test-execution gaps found: 3 ops on Dolomite had zero executing tests (`Full` withdraw,
  `Recycle` repay, `BatchClose`) — exactly the branches whose byte offsets the merge shifted.
  **Closed:** 8 new tests pin each shifted offset by execution.
- Blast radius: contained to the three venue packages and their tests. No SDK, solver, lens
  or deploy script names these contracts; Settlement and Permit3 reach them only through the
  generic module interfaces.
- Security regressions detected: **1** (the guard), fixed. Prior findings re-introduced
  (F27/C-1..C-4, H-1, M-1, F25/A-3, F26/2c, H-3, F-2, F-3): **none**.
- Tests: aave-v3 99+13, euler-v2 25 (was 20), dolomite 23 (was 14), morpho-blue 15+36,
  core 809 — **1,020 passing, 0 failing**. Both `tools/` checkers clean (8 rules).

# What Changed

| File | Δ | Risk | Why |
|---|---|---|---|
| `aave-v3/src/AaveV3CreditModule.sol` (new) | +411 | HIGH | holds the maker's credit delegation; 3 ops, 2 seams |
| `euler-v2/src/EulerV2OperatorModule.sol` (new) | +440 | HIGH | holds an unscoped EVC account-operator flag; 5 ops, 2 seams |
| `dolomite/src/DolomiteOperatorModule.sol` (new) | +630 | HIGH | holds an unscoped `setOperators` flag; 7 ops, **3 seams** incl. MAKE |
| `aave-v3/src/AaveV3FusedModules.sol` | deleted | — | → CreditModule |
| `dolomite/src/DolomiteModules.sol` | deleted | — | → OperatorModule (all five) |
| `aave-v3/src/AaveV3Modules.sol` | −60 | — | `AaveV3BorrowModule` removed |
| `euler-v2/src/EulerV2Modules.sol` | −530 | — | four value-out contracts removed; makers stay |
| `tools/check-module-shapes.py` | +149 | MEDIUM | rule 7 (unknown-op reject), reachability-scoped floor attribution, rule 4 unsliced-only + fail-closed default |
| `packages/core/src/interfaces/ITaker*.sol`, 6 docs | comments | LOW | doctrine + references |
| 27 test files | — | LOW | encoders, fixtures, +14 new tests |

# Findings

### [MEDIUM] Reentrancy guard dropped from Dolomite's repay path — RE-ASSESSED, REMOVED

**File:** `packages/modules/lending/dolomite/src/DolomiteOperatorModule.sol`
**Historical context:** `DolomiteRepayModule.makeOnBehalf` carried a 1/2-SSTORE `_locked`
guard ("guards weird-token transfer hooks", `HEAD:DolomiteModules.sol:151-184`). The first
cut of the merge did not carry it. Detected in Phase 1 by control census; first response
was to restore it contract-wide. The author was then asked whether it is *absolutely* needed.

**Re-assessment.** A module-level guard is load-bearing only if some custody window on the
module can be re-entered through a path no outer lock covers, AND the re-entrant call can
disturb what the in-flight fill pays out. Both halves were checked:

1. *Coverage.* Settlement locks every fill path (`Base.sol:262-306`, four hand-armed bodies
   + the modifier). Permit3 locks `take`/`takeFor`/the signed permits
   (`TakerAllowance.sol:56-62`). The ONE un-locked window is `AllowanceTransfer.transferFrom`
   (`AllowanceTransfer.sol:74-100`, "DELIBERATELY NOT nonReentrant" — a guard there would
   silently degrade to the payer's ERC20 allowance via `transferFromWithFallback`). So a
   MAKE repay's pull hands control to a maker-chosen token, whose hook can call
   `Permit3.take` — but only for a user who granted the *hook contract* a taker bucket,
   i.e. the attacker, never the victim (`test_reentrancy_transferFrom_cannotReachTheSpendersBucket`).
2. *Disturbance.* Every custody path pays a same-call delta: repay disposes `bal − floor`,
   `Full` withdraw pays `min(received − snapshot, amount)`, pre-fund open sweeps `bal − floor`,
   batch reads no balance. A census found **all 77** `balanceOf(address(this))` reads across
   every module in the tree delta- or floor-measured; none paid raw.

**Executable proof:** `dolomite/test/audit/ReentrancyWindow.t.sol` builds the exact
interleaving — a hook token that, on receiving the victim's repay pull, calls
`Permit3.take(attacker, …)` → `takeOnBehalf(attacker, Withdraw Full)` on the same module,
between the victim's pull and its `Recycle` disposal. With the guard **present**, the nested
call reverts (test discriminates: `nestedOk == false`). With the guard **removed**, the nested
call succeeds, the attacker withdraws exactly their own position, and the victim's debt,
recycled surplus and wallet are **byte-identical** to an un-attacked reference fill.

**Decision:** guard removed. The invariant it was standing in for — "no module pays out a raw
self-balance" — is now **rule 8** of `tools/check-module-shapes.py` (negative-tested: fires
on a raw `received` payout) and **I-16** in `docs/module-security-model.md`. The guard was
defence-in-depth written before the delta discipline was universal; the discipline is now
universal *and enforced*, which is the stronger form. Saves ≈1.3k gas per Dolomite call and
makes Dolomite consistent with Euler and Aave, whose value-out paths never had one.

**What would bring it back:** any module path that must pay from a balance it only read.
Rule 8 would reject that path; the fix is the guard plus a written checker exemption.

### [LOW] Dolomite `Full` withdraw never carried the I-8 `requireDelivered` — FIXED (pre-existing)

**File:** `DolomiteOperatorModule.sol:_withdraw` (was `HEAD:DolomiteModules.sol:338-348`,
identical — **not a regression of this change**).
**Found by:** the adversarial agent (Appendix A §8.1), as an unrequested extra.
**Description:** `docs/module-security-model.md` I-8 requires every `Full` leg to assert
`received >= amount` after the one-venue-withdraw-then-split ("restored 2026-09-10; do not
remove either half"). Euler's and Aave's `Full` legs carry it; Dolomite's never did — the I-8
restoration itself missed this sibling. Without it, a maker whose live position is short of
the signed total gets a *successful* fill that delivers less, and `Core._payInputsToSolver`
pulls the shortfall from their **wallet** at the signed price.
**Exploitability:** MEDIUM per the agent — any filler, single tx, needs the victim's position
to be short (a filler can wait for it). Impact is an unintended wallet debit at the signed
price, not a below-market loss.
**Fix:** `FullFillGuard.requireDelivered(received, amount)` added; pinned by
`test_withdraw_full_shortPosition_failsClosed_I8` (reverts `ShortWithdraw`).

### [INFO] Stale-encoder op collision on Euler and Dolomite `Borrow` — FIXED

`Op.Borrow` kept wire value 0 for byte-compatibility — which was also the old
`BatchMode.Open`. A stale 9-word (Dolomite) / 5-word (Euler) `BatchData` blob decoded
cleanly as a Borrow from what was its collateral vault/market, because `abi.decode` tolerates
trailing bytes. (The agent reported this for Euler only; verified it applies to Dolomite
identically.) Maker-authored only and the merged contracts are **new addresses**, so no
already-signed order can reach them — the hazard is a stale off-chain encoder. Closed anyway
for one compare: `Borrow` has no optional tail, so `data.length` is pinned exactly (64 / 160).
Pinned by `test_borrow_rejectsAStaleBatchDataBlob` on both venues. Aave was already
fail-closed (its old blobs open with an address, which `_plainOp` rejects as `BadOp`).

### [INFO] Dolomite test asserted deployment layout, not behaviour — reworked

`test_preFundFunded_samePosition_zeroReceiveSideApprovals_andCostsNoMore` asserted the
pre-fund module's Permit3 allowance was zero — true only because that shape had its own
address. On a shared address it now records the allowance and asserts it **unconsumed**
across the push fill, which a fall-through to `transferFrom` would fail. Stronger, and a
changed assertion — flagged so it is reviewed as such.

### [INFO] Reentrancy on Euler/Aave — RESOLVED by I-16

Originally recorded as "structurally delegated to Permit3's lock; a future MAKE seam must bring
its own guard." The re-assessment above shows the dependency is not on Permit3's lock at all
(that lock does not even cover the one open window) but on the delta discipline, which is
venue-independent, holds on every module today, and is now machine-checked (rule 8) and
proven executable on the un-locked window. A future MAKE seam on Euler or Aave needs no guard
as long as rule 8 passes — and rule 8 is what tells you if it does not.

# Phase 1 — control census (deleted → merged)

Counted by regex, then verified semantically where counts diverged (helpers were factored):

| Control | Aave | Euler | Dolomite | Note |
|---|---|---|---|---|
| `msg.sender == permit3` on TAKE/TAKE_FOR | ✓ | ✓ | ✓ | |
| `requireSettlement(spender)` on TAKE_FOR | ✓ | ✓ | ✓ | |
| `requireSettlement(msg.sender)` on MAKE | n/a | n/a | ✓ | |
| `requirePlainTake` on TAKE | ✓ | ✓ (new) | ✓ (new) | Euler/Dolomite's old single-shape takers did not need it; the merge does |
| `requireFundingDescriptor` on TAKE_FOR | ✓ | ✓ (**tighter** — old pull variant accepted LITERAL) | ✓ (new) | |
| pre-fund floor kept + swept | ✓ | ✓ (**upgraded** from `requireDelivered`) | ✓ (**upgraded**) | F27/C-3, M-1 |
| approve → venue → clear, every site | 1 helper | 2 sites | 3 sites | all paired, all guarded on `funded != 0` |
| `Narrow160` on data-derived pulls | ✓ | ✓ (2→1 shared site) | ✓ | F-2 |
| `FullFillGuard` on composite ops | n/a | ✓ | ✓ | |
| I-8 `requireDelivered(received, amount)` on `Full` | ✓ | ✓ | **✗ → ✓** | pre-existing miss |
| I-8b delta-measured, capped payout on borrow | ✓ | ✓ | ✓ | H-3 |
| 1/2 reentrancy guard | none (as before) | none on value-out (as before); repay maker keeps it | **dropped → restored → re-assessed → removed** (I-16, rule 8, proof test) | |
| unknown op → `revert BadOp` | ✓ | ✓ | ✓ | new rule 7 enforces |
| delegation / EVC-permit replay | 3 sites | 1 site, **both shapes** now | n/a | |

# Phase 2 — test-execution coverage of the shifted offsets

Reading an offset is not verifying it. Every branch whose bytes moved now has a test that can
only pass if the byte is read from the right word:

| Field | Offset | Pinned by |
|---|---|---|
| Dolomite Withdraw `BalanceMode` | 160 | `test_withdraw_full_readsModeAt160_andTotalAt192` — signs half the position, asserts the WHOLE position left (`accountNumber` at 128 is also `1`, so only the tagged word at 160 can produce `Full`) |
| Dolomite Withdraw `total` | 192 | `test_withdraw_full_slicedFill_failsClosedOnTotalAt192` — `PartialFillUnsupported(slice, total)` |
| Dolomite Repay `DustAction` | 160 | `test_repay_recycle_readsActionAt160_resuppliesSurplus` — surplus appears as a positive debt-market balance, a state `SweepToUser` cannot produce; control test for the default |
| Dolomite `BatchClose` | — | first executing test |
| Euler Withdraw `BalanceMode`/`total` | 64 / 96 | existing `PositionSized` `Full` test |
| Euler `Open` EVC-permit tail | 128 | existing `EvcPermitSignatureOnly` |
| Aave delegation blocks | 128 / 224 / 192 | existing sig-delegation test (128); 224/192 verified by agent against ABI heads |

# Phase 4 — the checker changes: do they now MISS anything?

- **Reachability-scoped floor attribution.** Old behaviour scanned the whole contract; new
  scans what `makeOnBehalf` / `takeForOnBehalf` transitively call by name. Could miss: a floor
  in a modifier body, or in an inherited base contract. Instrumented: zero makers use a custom
  modifier on `makeOnBehalf`; inherited-helper floors were never in scope of the old
  contract-only scan either, so no regression. The pre-fund pin (rule 3) was negative-tested
  by removing `_gatePreFundMake` from `AaveV3PreFundModule` — fires.
- **Rule 4 unsliced-only.** A `data[64:]` tail decode cannot say anything about word 0; the
  old match on it produced two false positives on `rateMode`. Negative-tested by changing the
  Dolomite `_single` decode's first field to `bytes32` — fires.
- **Rule 4 default.** The old code (and my first cut) defaulted to "address" when no decode
  was found — a silent pass for any maker reading word 0 in a way the regex cannot see.
  Instrumented: zero such makers today. Now fails closed (`<no unsliced abi.decode reachable>`
  is not in `SAFE_FIRST_FIELD`).
- **`SAFE_FIRST_FIELD` gains `uint8`/`uint16`/`bool`.** Bounded by width, and `abi.decode`
  reverts on dirty upper bits, so a crafted word 0 fails at the module even if the core
  classified it as pre-fund. Strictly safer than `address`.
- **Rule 7** negative-tested by deleting both `revert BadOp` sites in `AaveV3CreditModule` —
  fires.

# Residual risk

1. ~~Euler/Aave reentrancy posture~~ — resolved, see the INFO above and I-16.
2. **Accepted by design:** the grant *scope* widened. A Permit3 token allowance to a merged
   address is spendable by every op on it, and the standing venue flag covers every op. Each
   remains gated by a victim signature and a victim-written taker bucket keyed on
   `ref = keccak256(data)` with the op inside `ref` (Appendix A §1), so no cross-op path
   exists without the victim signing for that op. This is the intended trade — one grant
   instead of four — and is stated in each contract header and in
   `docs/approval-surface.md`. Not a defect; listed because it is the one property of the old
   layout the merge deliberately gives up.

# Coverage limits

- Fork tests run against pinned mainnet state; venue-side behaviour under conditions those
  blocks do not exhibit (e.g. Dolomite risk-override modes, Euler vault caps) is not exercised.
- The adversarial pass is one agent's reasoning over source, not a formal proof; every
  "NOT EXPLOITABLE" cites the lines that close it, and those lines are what a second reviewer
  should check.
- Gas was measured on tests, not benchmarked per op.


---

# Appendix A — adversarial modeling report (Phase 5, independent agent)

# Phase 5 — Adversarial modeling: grant-merged modules (Aave v3 Credit / Euler v2 Operator / Dolomite Operator)

Date: 2026-09-11. Scope: the three merged contracts in `audit/new/` (byte-identical to the live
`packages/modules/lending/{aave-v3,euler-v2,dolomite}/src/*` files — verified with `diff -q`),
against the pre-merge contracts in `audit/old/`, plus the seams they depend on:
`packages/lib/src/PreFundModuleBase.sol`, `packages/lib/src/PreFundGuard.sol`,
`packages/lib/src/DustHandler.sol`, `packages/lib/src/FullFillGuard.sol`,
`packages/lib/src/DelegationHelper.sol`, `packages/core/src/settlement/Base.sol`,
`packages/core/src/settlement/Core.sol`, `packages/core/src/permit3/TakerAllowance.sol`,
`packages/core/src/permit3/AllowanceTransfer.sol`.

Path shorthand used below:

| alias | file |
| --- | --- |
| `NEW_A` | `audit/new/AaveV3CreditModule.sol` |
| `NEW_E` | `audit/new/EulerV2OperatorModule.sol` |
| `NEW_D` | `audit/new/DolomiteOperatorModule.sol` |
| `OLD_A` | `audit/old/AaveV3Modules.sol` (AaveV3BorrowModule) / `audit/old/AaveV3FusedModules.sol` (AaveV3LeverageModule) |
| `OLD_E` | `audit/old/EulerV2Modules.sol` |
| `OLD_D` | `audit/old/DolomiteModules.sol` |
| `PMB` | `packages/lib/src/PreFundModuleBase.sol` |
| `PFG` | `packages/lib/src/PreFundGuard.sol` |
| `BASE` | `packages/core/src/settlement/Base.sol` |
| `TA` | `packages/core/src/permit3/TakerAllowance.sol` |
| `AT` | `packages/core/src/permit3/AllowanceTransfer.sol` |

---

## 0. Attacker model (fixed for every vector below)

**WHO:** an unprivileged EOA (plus any contracts it deploys). Not an admin, not a signer
for the victim, not a Settlement/Permit3 owner.

**ACCESS:**
- (a) author + sign orders naming **itself** as `order.maker`; fill its own or anyone's orders
  (`Core.fill`, `batchSettle`, `matchSettle`, `fillWithPermitTake`);
- (b) call `Permit3.approveTaker(spender=self, module, ref, amount, exp)` (`TA:67-73`, no auth),
  `Permit3.take(...)` (`TA:91-107`, permissionless, keyed by `msg.sender` as spender),
  `Permit3.takeFor(...)` (`TA:142-166`, permissionless), `Permit3.approveToken` (`AT:67`) and
  `Permit3.transferFrom` (`AT:101`, keyed by `msg.sender` as spender, `AT:207`);
- (c) deploy arbitrary contracts: malicious ERC20s with transfer hooks / attacker-controlled
  `balanceOf`, and fake venues. **Every venue address on these three modules is decoded from
  order `data`** (`NEW_A:240-241, 267-268, 286-287`; `NEW_E:162, 177, 227, 329`;
  `NEW_D:218, 249, 323, 337, 365, 435`), so an attacker who is maker of their own order picks it;
- (d) front-run any pending transaction (lift signatures/permits from calldata).

**VICTIM:** another maker who has granted the merged module its standing venue grant
(`approveDelegation` / `EVC.setAccountOperator` / `Dolomite.setOperators`) and Permit3
token/taker allowances keyed to the merged module address, who may have a live signed order,
and whose fill may leave residue on the module address.

**Trust anchors the attacker cannot forge** (used throughout):
1. `onBehalfOf` on every entrypoint is either `order.maker` (MAKE, dispatched only by Settlement
   under the maker's signature — `BASE:539-541`, `NEW_D:202`) or the `user` key of a taker-book
   bucket `[user][msg.sender][module][keccak256(data)]` that only `user` can write
   (`TA:67-73, 104-105, 155-156`; `Allowance.spend` reverts on insufficient —
   `packages/core/src/permit3/libraries/Allowance.sol:93`). So the attacker can only ever reach
   a module with `onBehalfOf == attacker`.
2. The account acted upon is always `onBehalfOf`, never a `data` field: Aave `supply(...,onBehalfOf)`
   / `borrow(...,onBehalfOf)` (`NEW_A:250, 332`); Euler `deposit(x, onBehalfOf)`, `repay(x, onBehalfOf)`,
   `withdraw(x, receiver, onBehalfOf)`, `EVC.call(vault, onBehalfOf, ...)` (`NEW_E:164, 187, 207, 263-272, 375-382`);
   Dolomite `AccountInfo(onBehalfOf, accountNumber)` (`NEW_D:296, 394, 466, 571`).
3. Reentrancy locks: Settlement (`BASE:262-304`, on every fill entry — `Core.sol:393, 425, 515`,
   `Batch.sol:324`); Permit3 `take` **and** `takeFor` share one `_locked` (`TA:55-62, 91-94, 148`);
   Dolomite module contract-wide (`NEW_D:183-188, 197, 311, 410`).

---

## 1. CROSS-OP GRANT REUSE — NOT EXPLOITABLE

**Attacker Model:** WHO: attacker EOA. ACCESS: (a)(b). INTERFACE: `Permit3.take`, `Permit3.takeFor`,
`Core.fill` with an attacker-authored order.

**Claim under test:** a Permit3 TOKEN allowance the victim granted to the merged address for op X
(e.g. Dolomite `Deposit` of WETH) can be spent by op Y (`BatchOpen collToken=WETH`, `Open` pull
shape); or a TAKER allowance for ref R can drive a different op.

**Disproof (token allowance):**
- Every `permit3.transferFrom(onBehalfOf, address(this), token, …)` on the three contracts pulls
  from `onBehalfOf` (`NEW_D:219, 259, 376, 385, 457`; `NEW_E:249, 368`; `NEW_A:277, 312`), and
  `onBehalfOf` is trust-anchor 1 above. The attacker can reach the module only with
  `onBehalfOf == attacker`, so the victim's token bucket `[victim][module][WETH]` (`AT:207`, spender
  = module) is never the `from` of an attacker-driven pull.
- The only callers that can put `onBehalfOf = victim` are Settlement (needs a victim-signed order
  whose `data` names op Y — the op word is inside the signed item blob, `BASE:416-418`) or
  `Permit3.take/takeFor` with `msg.sender` = a spender the victim approved (`TA:104-105, 155-156`).
  A victim who approved `Settlement` as spender still only reaches op Y through a Settlement fill of
  a victim-signed order.
- **What DID widen (INFO, not exploitable):** the victim's *venue* grant (Dolomite operator flag,
  EVC operator flag, Aave credit delegation) and *token* allowance to this one address now back
  every op the contract implements, where before they backed only the ops of the single old
  contract. `OLD_D:113-139` (`DolomiteDepositModule`) could only ever run one `Deposit` action with
  the operator flag; `NEW_D:308-332` can run `Borrow/Withdraw/Batch*` with the same flag. The gate
  that prevents abuse is unchanged — a victim-signed order + a victim-written taker bucket — and a
  `PermitTake` cannot be signed by a delegated order signer (it is verified against `owner` in
  `packages/core/src/permit3/SignedPermits.sol:225-230`), so a compromised session key does not
  unlock the wider surface either. The contracts document the widening honestly (`NEW_D:35-67`,
  `NEW_E:28-68`, `NEW_A:24-55`).

**Disproof (taker allowance):**
- Bucket key is `[user][spender][module][keccak256(data)]` (`TA:53-54, 104, 155`); the op is word 0
  of `data` on MAKE/plain-TAKE (`NEW_D:635-641`, `NEW_E:505-511`, `NEW_A:413-419`) and bits
  [244,252) of word 0 on TAKE_FOR (`PMB:107-112`). Changing the op changes `ref`, so a grant for
  ref R spends nothing under any other op. Settlement additionally passes the exact signed item
  `data` (`BASE:945-957`).
- The old contracts sat at different addresses, and `module` is part of the key (`TA:44-51`), so a
  pre-merge grant for `DolomiteTakerModule` is unusable against `DolomiteOperatorModule` even for a
  byte-identical `Borrow` blob (`NEW_D:85-88`).

**Exploitability:** none. **Baseline:** invariant "grant binds op via ref" (`NEW_D:61-67`,
`PMB:89-100`) holds; F27/C-1 spender pin present on all three `takeForOnBehalf`
(`NEW_A:196`, `NEW_E:306`, `NEW_D:415`).

---

## 2. CROSS-SEAM BLOB (Dolomite MAKE vs plain-TAKE share `>>253 == 0`) — NOT EXPLOITABLE

**Attacker Model:** WHO: attacker EOA. ACCESS: (a)(b). INTERFACE: `Permit3.take`/`takeFor` with a
self-granted bucket; `Core.fill` with an attacker order.

**Construction attempt.** A single `data` blob must satisfy the op tables of ≥2 seams:

| seam | admission | accepted ops |
| --- | --- | --- |
| `makeOnBehalf` | `msg.sender == settlement` (`NEW_D:202`); `_plainOp` word 0 (`NEW_D:203`) | `{2 Deposit, 3 Repay}` else `BadOp` (`NEW_D:204-210`) |
| `takeOnBehalf` | `msg.sender == permit3` (`NEW_D:313`); `requirePlainTake` `>>253 == 0` (`NEW_D:318`, `PFG:114-116`); `_plainOp` | `{0 Borrow, 1 Withdraw, 4 BatchOpen, 5 BatchClose}` else `BadOp` (`NEW_D:321-331`) |
| `takeForOnBehalf` | `msg.sender == permit3`; `spender == settlement` (`NEW_D:415`); `requireFundingDescriptor` word0 ≥ 2^255 (`NEW_D:419`, `PFG:140-142`); `_preFundOp` bits [244,252) | `{6 Open}` else `BadOp` (`NEW_D:421-425`) |

MAKE ∩ TAKE op sets = ∅; TAKE_FOR requires bit 255 set, which `requirePlainTake` rejects
(`>>253 != 0`) and which `_plainOp` would read as an integer ≥ 2^255 ∉ {0..5} on the MAKE seam.
No blob is admitted by two seams. Verified the length guard too: sub-word blobs revert
`MalformedData` (`NEW_D:636`) / `PreFundDescriptorRequired` (`PFG:151`) rather than reading a
neighbouring item's calldata.

**What the attacker would gain if a collision existed:** nothing on the MAKE side anyway — a MAKE
item consumes no taker grant (`BASE:539-541`), so there is no allowance to redirect
(`NEW_D:69-76`). The residual concern would be a Settlement pre-fund MAKE (`BASE:497-498`,
`_isPreFundDesc` `>>253 == 5`) reaching `makeOnBehalf` with a descriptor word: `_plainOp` returns
the descriptor, which is not 2 or 3 → `BadOp` (`NEW_D:208-209`). Fail-closed.

**Exploitability:** none. Same disjointness argument applies to Aave (`NEW_A:155, 202`) and Euler
(`NEW_E:158, 312`), which have no MAKE seam at all.

---

## 3. SHARED-BALANCE RESIDUE — NOT EXPLOITABLE (every payout is delta-measured; floors are same-call)

**Attacker Model:** WHO: attacker EOA as maker of its own order (and optionally its own filler),
with a fake venue and/or its own tokens. ACCESS: (a)(b)(c). INTERFACE: any op on the merged
contract, via Settlement or via a self-granted `Permit3.take`.

**Precondition:** victim residue `R` of token `T` sits on the module (from a broken venue on the
victim's own order, a donation, or a stale fill). I enumerated every path that pays tokens OUT of
the module and what each floor is measured against:

| path | floor taken | payout | bound |
| --- | --- | --- | --- |
| Aave `_borrowLeg` (`NEW_A:249-254`) | `balBefore` immediately before `borrow` | `min(received, amount)` to receiver, `received-amount` to onBehalfOf | ≤ what arrived during the venue call |
| Aave `_fundedSupplyLeg` pre-fund (`NEW_A:306, 321`; `PFG:194-197, 241-244`) | `bal_entry - forAmount` | `bal_after - floor` to onBehalfOf | ≤ `forAmount` + anything donated during the call; approval capped at `forAmount` (`NEW_A:331-333`) |
| Euler `_withdrawFull` (`NEW_E:205-216`) | `floor` before withdraw | `min(received, amount)` / excess to onBehalfOf | delta only; `requireDelivered` (`NEW_E:214`) |
| Euler `_open` pre-fund (`NEW_E:363, 393`) | `bal_entry - forAmount` | `bal_after - floor` | ≤ `forAmount`; approval capped (`NEW_E:370, 388`) |
| Dolomite `_repay` (`NEW_D:233, 283-289`) | `floor` before pull | `bal - floor` → `DustHandler.disposeResidual(…, floor, …)` (`packages/lib/src/DustHandler.sol:164-194`), Recycle re-reads `bal - floor` (`:184-186`) | delta only; recycle approval = `residual` and cleared (`:176-178`) |
| Dolomite `_withdraw` Full (`NEW_D:353-357`) | `snapshot` before withdraw | `min(received, amount)` / excess | delta only |
| Dolomite `_open` pre-fund (`NEW_D:453, 472`) | `bal_entry - forAmount` | `bal_after - floor` | ≤ `forAmount`; approval capped (`NEW_D:459, 469`) |
| pull shapes: Aave `_ratioSupplyLeg` (`NEW_A:277-278`), Euler `_batch` (`NEW_E:249-250, 281`), Dolomite `_batch`/`_open` pull (`NEW_D:376-377, 385-386, 457-459`) | n/a — no sweep | none | approval = exactly the amount just pulled from **onBehalfOf's own wallet**, cleared after |

**Can a floor be stale?** Every floor is read in the same external call as its payout; between the
read and the payout the module makes only (i) `permit3.transferFrom` from `onBehalfOf`, (ii) the
venue call, (iii) the token transfers. During (i)-(iii) no other module entrypoint can run
(trust-anchor 3: Permit3's `take`/`takeFor` lock covers every Aave/Euler entry, `NEW_A:150, 191`,
`NEW_E:153, 301`; Dolomite adds its own guard, `NEW_D:197, 311, 410`), and Settlement is locked, so
no victim delivery (`Core._deliverOutputs`) can land mid-measurement. A hook/fake-venue can only
*add* balance (donation → paid back to `onBehalfOf` = the donor's own counterparty, the attacker)
or pull up to the scoped approval (the attacker's own amount). It cannot remove `R`.

**Interleaved fills (`matchSettle` schedules items of two orders):** the victim's pre-fund
delivery may sit on the module when the attacker's item runs. Every attacker path above measures a
floor that includes it and pays only the delta, and every approval is sized to the attacker's own
pulled/delivered amount. Verified there is no un-cleared `forceApprove` on any path
(`NEW_A:331/333`; `NEW_E:250/281, 370/388`; `NEW_D:377/396, 386/396, 459/469, 590/592`;
DustHandler `:176/178`). Bit-253 pairing is enforced by the core (`BASE:723-816`) so the victim's
delivery cannot be mis-addressed to the module under a pull descriptor and stranded.

**Exploitability:** none. **Baseline:** F19 floor rule, F26/2c (cleared approvals), F27/C-3 and
M-1 (sweep measured from pre-delivery floor, not a return value or pre-call clamp) all hold; the
merge in fact *upgraded* three sites from `requireDelivered` to a kept floor + `sweepSurplus`
(`NEW_A:300-306`, `NEW_E:357-363`, `NEW_D:448-453` vs `OLD_E:697`, `OLD_D:507`).

---

## 4. REENTRANCY (Euler / Aave have no module-level guard) — NOT EXPLOITABLE (but structurally dependent on Permit3's lock)

**Attacker Model:** WHO: attacker EOA controlling a hook token `H` and/or a fake venue.
ACCESS: (a)(b)(c). INTERFACE: `Permit3.take` with a self-granted bucket, called from inside a hook
that fires during a victim's fill.

**Attempt 1 — re-enter the module during a victim's TAKE/TAKE_FOR.** The victim's item is
executing inside `Permit3.take`/`takeFor`, which set `_locked = 2` (`TA:58-62, 94, 148`). The
module's only entrypoints require `msg.sender == permit3` (`NEW_A:150, 191`; `NEW_E:153, 301`), so
the only way in is another `take`/`takeFor`, which reverts `Reentrancy()`. `Permit3.transferFrom`
is *not* locked (`AT:74-100`) but it moves the attacker's own tokens (spender-keyed, `AT:207`) into
the module — a donation the delta logic returns to the counterparty.

**Attempt 2 — re-enter during a Settlement phase outside `take`** (`_deliverOutputs` for the
victim's pre-fund leg, `_payInputsToSolver`). Settlement is locked, Permit3 is not, so a hook could
call `Permit3.take(self-grant)` into the Euler/Aave module on the **attacker's own** account. But
the token being moved there is the victim's signed real token (no attacker hook), and even if it
had one, the attacker's op runs to completion on the attacker's account with delta measurement; the
victim's item has not started (no floor is live) or has finished (no floor is live). No
measurement is straddled.

**Attempt 3 — attacker token `H` is also the victim's fill token.** Then `H.balanceOf` and
`H.transfer` are attacker-controlled regardless of the module; the attacker can already do
anything to the victim's `H`. The question is whether control gained in an `H` hook lets the
module move a *different* token of the victim. Every non-`H` token movement is either from
`onBehalfOf`'s wallet under `onBehalfOf`'s own allowance or through a venue approval scoped to a
single (token, amount) that is cleared before the next external call; and no module entrypoint is
reachable (Attempt 1). So no.

**Attempt 4 — Dolomite MAKE (runs under Settlement's lock but NOT Permit3's).** During
`_repay`/`_deposit` the attacker's fake `dolomite` (`NEW_D:249`) or hook token gets control while
Permit3 is unlocked. Calling `Permit3.take` into `DolomiteOperatorModule` hits the module's
contract-wide guard (`NEW_D:183-188`). Calling into the Euler/Aave modules touches a different
balance/address. No cross-contamination.

**Exploitability:** none today. **Robustness note (INFO):** the Aave/Euler contracts' non-reentrancy
rests entirely on `TakerAllowance._locked` being shared by `take` and `takeFor` and on both
contracts having no Settlement-dispatched (MAKE) seam. If a MAKE seam is later merged into either
(e.g. Euler Deposit/Repay, explicitly declined at `NEW_E:46-51`), the Dolomite-style guard must
come with it. The old value-out contracts had no guard either (`OLD_A:416`, `OLD_E:272, 381, 512,
663`), so this is not a regression.

---

## 5. OFFSET REGRESSIONS (+32 shift of trailing optional fields) — NOT EXPLOITABLE (all offsets verified)

Each trailing read was checked against the actual `abi.encode` head length:

| contract / op | head layout | head bytes | trailing field read | line | ok |
| --- | --- | --- | --- | --- | --- |
| Dolomite Withdraw | `(uint8, address, uint256, address, uint256)` | 160 | `readBalanceMode(data,160)`; `requireFullFillFromData(data,192)` | `NEW_D:338, 345` | yes (old: 160/192 with the same 5-word head, `OLD_D:325-331`) |
| Dolomite Repay | same 5 words | 160 | `readAction(data,160)` ×2 | `NEW_D:258, 302` | yes (old 4-word head → 128, `OLD_D:173`; the +32 is real and matched) |
| Aave Borrow | `(op, pool, asset, rateMode)` | 128 | delegation @128 | `NEW_A:161` | yes (old 96, `OLD_A:424`) |
| Aave Leverage (ratio) | `(op, pool, borrowAsset, rateMode, collateralAsset, collTotal, borrowTotal)` | 224 | delegation @224 | `NEW_A:167` | yes (old 192, `AaveV3FusedModules.sol:299`) |
| Aave Leverage (TAKE_FOR) | `(forDesc, forCap, pool, borrowAsset, rateMode, collateralAsset)` | 192 | delegation @192 | `NEW_A:215` | yes (unchanged) |
| Aave `_borrowLeg` | `(pool, borrowAsset, rateMode)` at 32 (plain) / 64 (funding) | — | `abi.decode(data[32|64:])` | `NEW_A:240-241` | yes, matches both heads |
| Euler Withdraw | `(uint8, address)` | 64 | `readBalanceMode(data,64)`; total @96 | `NEW_E:179, 183` | yes (unchanged) |
| Euler Open | `OpenData` 4 words | 128 | EVC permit tail @128 | `NEW_E:343` | yes (unchanged) |

Additional properties that make a mis-read fail closed rather than silently: `readBalanceMode`
requires the tagged word `0xB0DE0001` for `Full` (`DustHandler.sol:107-120`), `readAction`
reverts on any word > 1 (`:73-78`), `requireFullFillFromData` reverts when the total is absent or
0 (`FullFillGuard.sol:76-81`), and a stale pre-merge blob handed to the new module puts an
address / mode value in the op word and is rejected by `BadOp` on Aave and Dolomite
(pool/dolomite address ≠ small op) — see §8.2 for the one venue where that is not true.

**Exploitability:** none — and in any case the trailing fields are inside `ref = keccak256(data)`
and the order signature, so only the maker can author a mis-offset blob.

---

## 6. `requireDelivered` → `floorOf` + `sweepSurplus` on pre-fund Open (Euler, Dolomite) — NOT EXPLOITABLE

**Attacker Model:** WHO: attacker EOA as maker (and filler) of its own TAKE_FOR pre-fund order
naming a fake venue. ACCESS: (a)(c). INTERFACE: `Core.fill` on the attacker order.

**Attack sequence attempted:**
1. Attacker signs order: `legsOut[j] = (T, forAmount, recipient = module)`, item `TAKE_FOR` with
   `data = OpenData{forDesc = 0b101…|token T in [16,176)|op 6 in [244,252)|j, …, dolomite = FAKE}`.
2. Attacker fills it. `_deliverOutputs` moves `forAmount` of `T` to the module; `_forSlice` binds
   recipient == module and legToken == desc token, marks the leg used (`BASE:724-835`).
3. `Permit3.takeFor` → `takeForOnBehalf(spender = Settlement …)` passes `requireSettlement` and
   `requireFundingDescriptor` (`NEW_D:415, 419`), op 6 → `_open`.
4. `floor = balanceOf(T) - forAmount` = `R` (victim residue) (`NEW_D:453`, `PFG:194-197`).
5. `forceApprove(T, FAKE, forAmount)` (`NEW_D:459`); `FAKE.operate` pulls nothing (or ≤ forAmount).
6. `sweepSurplus(T, attacker, floor)` pays `balanceOf(T) - floor` = `R + forAmount - R` =
   **`forAmount`** (`NEW_D:472`, `PFG:241-244`) — the attacker's own delivery, minus whatever
   `FAKE` pulled (capped by the approval). `R` stays.
7. The borrow action delivers nothing to `receiver`, so `_payInputsToSolver` bills the attacker's
   own wallet for `owed` (`Core.sol:1203-1208`). Net: attacker ≤ 0.

Same arithmetic for Euler (`NEW_E:363, 370, 384, 393`) and Aave (`NEW_A:306, 331-333, 321`).
The only way to pay out more than `forAmount` would be for `balanceOf(T)` to rise during the venue
call by non-attacker funds; nothing but a donation can do that (see §3/§4). The old
`requireDelivered` form (`OLD_D:507`, `OLD_E:697`) proved the same underflow and then left a
short-consuming venue's remainder stranded (the M-1 generator); the new form returns it to
`onBehalfOf`, which is strictly better.

**Comparison to F27/C-3 (sweep sized from a lying venue's return value):** not re-introduced —
no return value is used; the sweep is a balance delta. **M-1 (pre-call clamp over-states):** not
re-introduced — no clamp is used. **F27/C-4 (floor with attacker-chosen subtrahend):** closed
because `forAmount` is core-sized under the spender pin (`NEW_D:415`).

**Exploitability:** none.

---

## 7. DESCRIPTOR OP BITS [244,252) vs core reads — NOT EXPLOITABLE (no overlap; classifications agree)

Bit map of word 0 on the TAKE_FOR seam:

| bits | reader | meaning |
| --- | --- | --- |
| 255 | `BASE:720` (`desc < 1<<255` → literal) ; `PFG:141` | leg-ref/balance vs literal |
| 254 | `BASE:723` | balance form |
| 253 | `BASE:797-816` (`pre := and(shr(253,desc),1)`), `PMB:85`, `BASE:702-706` | pre-fund shape |
| [244,252) | `PMB:110` only | module op |
| [160,176) | `BASE:879` (balance form only) | floorBps |
| [16,176) | `BASE:808` (`shr(96, shl(80, desc))`, leg-ref pre-fund only), `PFG:177` | funding token |
| [0,160) | `BASE:850` (balance form) | balance token |
| [0,16) | `BASE:724` (leg-ref) | leg index j |

[244,252) intersects none of the core's read ranges. Classification cross-check, by `desc >> 253`:
- 0..3 (literal): core would prorate `desc` (`BASE:720-721`); module rejects
  `LiteralDescriptorNotAllowed` (`PFG:141`) → fill reverts. Consistent, fail-closed.
- 4 (leg-ref pull): core requires recipient ∈ {0, maker} (`BASE:813`); module `_fundingShape`
  = false → `transferFrom(onBehalfOf)` (`NEW_A:312`, `NEW_E:368`, `NEW_D:457`). Consistent.
- 5 (leg-ref pre-fund): core requires recipient == module and legToken == desc token
  (`BASE:805-810`); module floor + `fundingToken` check (`PFG:195`). Consistent.
- 6/7 (balance): core reads maker balance, full-fill only (`BASE:839-897`); module
  `_fundingShape` = false (only `== 5` is push, `PMB:85`) → pull. Consistent (7 has bit 253 set
  but the core dispatches on bit 254 first, `BASE:723`, and the module compares the whole 3-bit
  value).

The attacker as **filler** cannot alter `desc` at all (inside signed `data` and `ref`); as
**maker** they can only misclassify their own order. **Exploitability:** none.

---

## 8. ANYTHING ELSE

### 8.1 [LOW] Dolomite `Full` withdraw lacks `FullFillGuard.requireDelivered` — the I-8 sibling the 2026-09-10 restore missed (PRE-EXISTING, carried through the merge, not a regression)

**Attacker Model:**
- WHO: any filler (attacker EOA) of a victim's live Dolomite `Withdraw` order in `BalanceMode.Full`.
- ACCESS: (a) — fill a public order; no grant from the victim needed beyond what the order carries.
- INTERFACE: `Core.fill(victimOrder, sig, fillAmount == totalAmount)`.

**Attack Vector:**
1. Victim signs `Withdraw` item, `Full` mode, `total = amount` (e.g. 1,000 USDC), input leg
   1,000 USDC → filler, output leg X → victim.
2. Victim's Dolomite balance in that market drops below 1,000 (partial liquidation, a separate
   withdraw, interest accounting) so `bal < amount` (`NEW_D:346-347`).
3. Filler fills the whole item. `_operate(withdraw bal → module)`; `received = bal`
   (`NEW_D:354-355`); module forwards `min(received, amount) = bal` to Settlement (`NEW_D:356`).
   **No `requireDelivered(received, amount)`** — compare Euler `NEW_E:214`, Aave
   `packages/modules/lending/aave-v3/src/AaveV3Modules.sol:327`, and every other `Full` leg in the
   tree (grep in `packages/modules/lending/*/src`).
4. `Core._payInputsToSolver`: `proceeds < owed` → `transferFromWithFallback(PERMIT3, tokenIn,
   maker, payTo, owed - proceeds)` (`Core.sol:1203-1208`) — the shortfall is pulled from the
   **victim's wallet** under their standing Permit3/ERC20 allowance.

**Exploitability:** MEDIUM — public order, single transaction, but needs the victim's position to
be short of the signed total at fill time (a state the filler can also *wait* for; the order stays
live).

**Concrete Impact:** the victim is charged `amount - bal` from their wallet on an order they
signed as "sell what is in my Dolomite position". They still receive the signed output, so this is
an unintended wallet debit at the signed price, not a loss of value below market. Exactly the harm
`docs/module-security-model.md` I-8 (line 160) cites as the reason `requireDelivered` was restored
on every other `Full` leg on 2026-09-10 ("do not remove either half").

**Root Cause:** `NEW_D:353-357` (same code as `OLD_D:338-348`); the restore sweep did not reach
Dolomite. The merged file's own comment (`NEW_D:349-352`) cites H-3 but not I-8's second half.

**Blast Radius:** 1 path (`Op.Withdraw`+`Full`) on 1 contract; every Dolomite `Full` close-flow
order.
**Baseline Violation:** I-8 ("requires `received >= amount`") — the "patch hit one sibling, missed
the neighbour" meta-pattern the merge header itself warns about (`NEW_D:168-171`).

### 8.2 [INFO] Euler op-value collision for stale encoders (maker-authored only)

`EulerV2BatchModule.BatchMode.Open/Close = 0/1` (`OLD_E:360-363`) now equal
`EulerV2OperatorModule.Op.Borrow/Withdraw` (`NEW_E:108-114`). A stale SDK encoder that emits a
BatchData blob against the **new** address produces a well-formed `Borrow`/`Withdraw` blob whose
`vault = collateralVault` (`NEW_E:162, 177` decode the first two words). Not attacker-reachable:
the blob is signed by the maker, the taker bucket is keyed to the new module, and old orders name
the old address. But unlike Aave/Dolomite (where word 0 of a stale blob is an address and reverts
`BadOp`), Euler fails *open* into a different op. Suggest the SDK shape-pinning tests cover the new
`Op` numbering (memory: `sdk-packed-order-sync`).

### 8.3 [INFO] `AaveV3CreditModule.takeOnBehalf` has no spender pin — correct, and worth stating why

Plain `take` carries no `spender` (`TA:91`), and the merged contract does not add one
(`NEW_A:144-150`). This is safe because every plain op moves value **out of `onBehalfOf`'s own
position/wallet** to a `receiver` the caller chooses, and the caller can only reach the module with
`onBehalfOf == self` (trust-anchor 1). A self-granted `take` with a fake pool on the attacker's
account gives the attacker back at most their own funds (`NEW_A:249-254, 277-278, 331-333`).
Same for Euler (`NEW_E:149-172`) and Dolomite (`NEW_D:308-332`).

### 8.4 [INFO] EVC-permit replay now on the pull shape too (`NEW_E:339-343`)

Best-effort `try/catch` (`DelegationHelper.sol:172-178`), any-sender permit, maker-signed,
nonce-bound. A front-runner landing it leaves exactly the grants the fill wanted. Adding it to the
pull shape widens nothing: the replay runs BEFORE the floor is taken (`NEW_E:343` vs `:363`) so a
maker-signed self-call that moves the maker's own funds into the module only raises the floor.

### 8.5 [INFO] No standing approvals survive any path; no `data`-decoded account/owner

Verified every `forceApprove(x)` has a paired `forceApprove(0)` before the function returns
(§3 table), and every venue call names `onBehalfOf` as the account (trust-anchor 2). This is what
makes the "attacker-chosen fake venue" capability inert against third-party balances on a shared
singleton (F25/A-3, F26/2c not re-introduced; F-2 `Narrow160` present at every data-derived pull:
`NEW_A:277`, `NEW_E:249`, `NEW_D:376, 385`).

---

## Summary

| # | vector | verdict | severity |
| --- | --- | --- | --- |
| 1 | cross-op grant reuse | NOT EXPLOITABLE (grant-scope widening documented, gated by maker signature + maker-written taker bucket) | — |
| 2 | cross-seam blob (Dolomite MAKE/TAKE/TAKE_FOR) | NOT EXPLOITABLE (op tables disjoint; bit-255 pin) | — |
| 3 | shared-balance residue extraction | NOT EXPLOITABLE (all payouts delta/floor-measured in-call; approvals scoped + cleared) | — |
| 4 | reentrancy on unguarded Euler/Aave | NOT EXPLOITABLE (Permit3 `take`/`takeFor` share one lock; no MAKE seam) — robustness note | INFO |
| 5 | +32 offset regressions | NOT EXPLOITABLE (all 8 offsets verified against layouts) | — |
| 6 | floorOf + sweepSurplus with fake venue | NOT EXPLOITABLE (payout ≤ own `forAmount`; C-3/M-1/C-4 not re-introduced) | — |
| 7 | descriptor op bits vs core | NOT EXPLOITABLE (no bit overlap; all four `>>253` classes agree) | — |
| 8.1 | Dolomite `Full` withdraw missing `requireDelivered` (I-8) | **EXPLOITABLE by any filler when the position is short — pre-existing, carried, not a regression** | LOW |
| 8.2 | Euler stale-encoder op collision | maker-authored only | INFO |
| 8.3–8.5 | plain-take spender pin, EVC replay on pull, approval hygiene | clean | INFO |

No regression of F27/C-1, C-2, C-3, C-4, H-1, M-1, F25/A-3, F26/2c, H-3, F-2 or F-3 was found in
the merged contracts. No CRITICAL/HIGH/MEDIUM finding. No NEEDS-MORE-INFO items: every vector
above closed on code alone.
