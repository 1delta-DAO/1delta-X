# Reference audits and common pitfalls

The published audit corpus for this exact class of protocol — signed limit orders
settled by a permissionless third party — is small enough to read end to end, and
it repeats itself. The same fifteen shapes account for essentially every High and
Medium finding across 1inch, 0x, CoW Protocol, UniswapX and Velora, plus both of
the live incidents.

This note is that corpus, distilled into failure **classes** rather than a list of
other people's bugs, with a verdict for each against this codebase and a ledger of
what we changed in response. It exists for three jobs:

- **Before writing a feature** — the classes are the design constraints. Most of
  them are already load-bearing decisions here (the price module returns a *bump*,
  not an amount, because of C5; the callback runs through a trampoline because of
  C1). Knowing which finding a piece of code is answering stops it being
  "simplified" back into the bug.
- **Before an external audit** — an auditor arrives with this corpus in their head.
  Everything here is a question they will ask; having the answer written and
  measured is the difference between a finding and a note.
- **When reviewing a PR** — the class keys `C1…C15` are a shared vocabulary.
  "That's a C4" is a complete review comment.

**Related:** [`/SECURITY.md`](../SECURITY.md) is the reporting policy and trust
model. This note is the adversarial reading of the design. The
[settlement README](../packages/core/src/settlement/README.md) is the API.
[`edge-case-matrix.md`](edge-case-matrix.md) is the other half of this note: where
this one asks *what has gone wrong elsewhere*, that one asks *what combinations
exist here* — the F-ledger entries below should each be locatable as a cell in it,
and the ones that are not mean the matrix is missing an axis.

---

## Glossary

The vocabulary is not shared across protocols — the same word means different
things in 0x, CoW and UniswapX, and this codebase borrows from all three. These
are the senses used throughout the repo.

| Term | Sense used here |
| --- | --- |
| **Maker** / *swapper* | The party who signs the order. Never sends the transaction. `swapper` in UniswapX. |
| **Filler** / *taker*, *solver*, *resolver* | The party who executes. `resolver` in 1inch Fusion, `solver` in CoW, `filler` in UniswapX. One role: supplies the counter-side, pays gas, keeps the surplus. |
| **Settler** | The contract that verifies the signature and moves funds. The most privileged address in the system, because every maker approves it. |
| **Intent** | A signed statement of *outcome* ("I want ≥ X out"), not a route. |
| **Dutch decay / bump** | A price moving against the maker over time. Normalised here to one shared `bumpBps ∈ [0, 10000]` per order, mapped through each leg's own signed `start`/`end`. |
| **Anchor** | The fill denominator — the fixed side's leg 0, or a signed `fillTotal`. `filled[orderHash]` counts in anchor units. |
| **Partial fill** | Executing a fraction of a signed order. The source of a disproportionate share of real findings — gates and rounding written for the whole often break on the slice. |
| **Overfill** | Executing more in aggregate than the maker signed for. 0x v4's audit carried non-overfillability as a stated invariant. |
| **Interaction / callback / hook** | An arbitrary call the settler makes mid-settlement. The richest vulnerability surface in this class. |
| **Amount getter / price module** | An external contract consulted for the price. In 1inch LOP an amount getter **is** the price; here an `IPriceModule` returns only a clamped bump. |
| **Validator / invariant** | A read-only precondition (pre-items) or postcondition (post-items) the maker attaches. AND-composed. |
| **Exclusivity window** | A period in which only a nominated filler may execute. *Hard* blocks everyone else; *soft* admits them against a price improvement paid to the maker. |
| **Coincidence of wants / netting** | Matching N orders against each other so no filler capital is needed. `matchSettle` here. |
| **Allowance hub** | Permit2 / Permit3 — a shared approval registry. Concentrates convenience and blast radius alike. |
| **Witness permit** | A permit signature that also commits to an application payload (here, the order hash), so one signature authorises both the pull and the trade. |
| **Nonce invalidator / rollback** | Bulk cancellation. 0x's `minValidSalt`, `rollbackNonces` here. |
| **Delta verification** | Requiring a measured balance increase rather than pushing a nominal amount. The correct answer for fee-on-transfer outputs. |
| **Surplus / residue** | What is left in the settler after every obligation is met. Whoever it is swept to is being paid, so that must be a deliberate decision. |
| **Priority auction** | Bidding for the fill in priority fee rather than in time, relying on the sequencer to order by tip. |

---

## The fifteen classes

Each is anchored to a specific published finding or a live exploit, not to a
generic checklist item.

### C1 — Arbitrary call made from the settler's own identity

> **CoW Protocol, February 2023 — ~$180k.** `GPv2Settlement.settle()` permitted
> solver-supplied interactions with no validation of the interaction data. The
> attacker made the settlement contract approve their own contract, then pulled DAI
> out of it. iosiro raised the same shape against 1inch Settlement — resolvers'
> lingering allowances were stealable through the arbitrary-call surface — and the
> fix was to move execution out to a dedicated `IResolver`.

**Mechanism.** The settler holds standing approvals from everyone. Any call it
makes with attacker-chosen `(target, data)` executes with that authority,
including calls back into the allowance hub.

**Here: structurally prevented.** Solver callbacks and `matchSettle` `CALL` steps
both run through [`SolverCallbackExecutor`](../packages/core/src/settlement/SolverCallbackExecutor.sol),
a stateless trampoline that is an approved spender for nobody — so
`target = PERMIT3` gains nothing. Module dispatch from Settlement itself is
selector-pinned to `makeOnBehalf` / `settle`; a scan of every compiled artifact for
`0xb5d2b67f` and `0x99bb07b8` finds no collision on Permit3 or anywhere else. TAKE
never gets a direct call at all — it routes through `Permit3.take`, whose book is
keyed by spender **and** module.

**Re-checked for `TAKE_FOR` (2026-08-28).** The composite op widens the dispatch
surface by two selectors and the verdict survives both. Settlement's own call is to
`PERMIT3.takeFor` (`0xceaeaa96`) — a **fixed** target, so no maker-chosen address is
reached from the settler's identity at all; Permit3 then calls the maker-chosen
module with `takeForOnBehalf` (`0xec0eb1a9`). Scanning `Permit3`, `Settlement`,
`SettlementLens` and `SolverCallbackExecutor` for all four module-dispatch selectors
returns one hit — `takeFor` on Permit3, which is the intended target — and no
collision. A maker naming `module = PERMIT3` or `module = Settlement` in a `TAKE_FOR`
item therefore reaches a non-existent function and reverts.

*Do not* make the solver's call from `Settlement` "to save the extra CALL". That
CALL is the security property.

### C2 — Hand-rolled calldata arithmetic without a bounds proof

> **1inch Fusion v1, March 2025 — ~$5M.** A length field inside the low-level
> `_settleOrder` suffix arithmetic could be driven past the end of the buffer,
> relocating where the order suffix was read from and letting the attacker
> impersonate legitimate resolvers.

**Mechanism.** Moving off the ABI decoder for gas gives up its automatic bounds
checking. If the replacement is missing, wrong, or simply not re-applied by a later
call site, adjacent calldata is read as protocol data.

**Here: correct, with a standing maintenance hazard.**
[`PackedArrays`](../packages/core/src/settlement/PackedArrays.sol) replaces the
decoder's checks with an explicit **validate-once** contract, stated in its header:
*call `validateFixed`/`validateRecords` once per blob, keep the returned count, and
only then use the accessors.* Every current call site was traced and every index is
bounded by a validated count.

The exposure is a *future* call site that indexes from a caller-supplied number.
This is the one class where the codebase's safety depends on a convention rather
than on the compiler — so the header contract is not documentation, it is the
control, and `PackedArrays.t.sol` is the regression net.

### C3 — Signed-payload fields that do not bind execution

> **1inch LOP, OpenZeppelin H01 and M01.** H01: `_makeCall` was handed `makerAsset`
> where `makerAssetData` was intended. M01: a signed *dynamic* field preceded static
> amount values in the encoded call, letting a malicious maker append bytes that
> shifted or replaced the amounts downstream.

**Mechanism.** A field influences execution but is absent from the typehash, or the
encoding lets a signed dynamic member move a static one that follows it.

**Here: prevented.** The typehash covers all fifteen fields, and every dynamic
member is a `bytes` blob hashed as one keccak — there is no array-of-struct
encoding for a dynamic member to shift a static one through. The assembly hasher
re-masks each copied address, because a raw `calldatacopy` does not clean the upper
twelve bytes. `HashGolden.t.sol` plus the SDK cross-check pin the layout
byte-for-byte.

**One real instance was found and fixed** — see [F2](#f2--itemop-was-decoded-as-a-raw-byte)
below. `op` was decoded as a raw byte and the dispatcher folded every out-of-range
value into SETTLE, which quietly weakened a guard one layer up.

### C4 — Authorization gates that only run on the first fill

> **1inch LOP, OpenZeppelin H02 — high.** The `allowedSender` check sat inside
> first-fill-only logic. Once an order was partially filled the branch became
> unreachable and a private order silently became public to every filler.

**Mechanism.** Per-fill policy checks placed in a path partial fills skip. The
order is authorised once, then gradually loses the restrictions the maker signed.

**Here: correct, and the direct analogue passes.** `exclusivityOverride` runs inside
`_gateOrderPost`, which every entry executes on every fill — a partially-filled
private order stays private.

Signature re-verification **is** skipped once `filled != 0`, deliberately, matching
1inch LOP v4. The rule that makes it sound: a non-zero counter proves some earlier
fill presented valid authorization for that maker-committing hash. Every
*revocable* authorization is still re-read each fill — the `approveOrder` record,
the nonce bitmap and rollback floor, the expiry, and the Permit3 allowances that
fund the pull.

The documented consequence: an EIP-1271 maker cannot withdraw a *signature*
mid-order. `cancelOrder` is the kill switch that binds. This is stated at
[`Signatures._verifySignature`](../packages/core/src/settlement/Signatures.sol) and
again at [F5](#f5--fillwithpermittakes-nothing-survives-it-was-imprecise).

### C5 — The maker supplies the function that *is* the price

> **1inch LOP, OpenZeppelin H03 — high.** With malicious `getMakerAmount` /
> `getTakerAmount` implementations and partial fills, a maker could front-run a
> taker into exchanging its full threshold for a negligible return; the threshold
> protections covered only one side of the swap.

**Mechanism.** An external, maker-chosen contract returns the amount rather than a
bounded modifier of it, so the signed numbers stop being limits at all.

**Here: structurally prevented, and this is the design's strongest single answer to
the corpus.** An [`IPriceModule`](../packages/core/src/interfaces/IPriceModule.sol)
returns only a shared **bump**, clamped to `[0, 10000]` and then mapped through each
leg's own maker-signed `start`/`end`. It can move the tick anywhere inside the
signed band and nowhere outside it. `fillModule` is bounded the same way: it chooses
only the *delta*, while the denominator, the over-fill cap and the uniform per-leg
scaling stay in the core.

Both are `view`, so both compile to `STATICCALL`, and the return is read into
scratch capped at one word so a hostile module cannot bomb caller memory. The filler
gets the matching guard from the other side: `fillUpTo`'s `minBumpBps` is an *exact*
price floor, because every leg price is monotone in the one shared bump.

See [pricing-modes.md](pricing-modes.md) for the full argument.

### C6 — Overfill and cumulative-slice accounting

> **0x v4, ConsenSys Diligence** carried "orders should not be able to be
> overfilled" as an explicit security property. Trail of Bits separately noted the
> inverse nuisance: a taker filling 1 wei of a fill-once order invalidates it.

**Mechanism.** Per-fill rather than cumulative slice arithmetic, or a missing
`filled + delta ≤ total` cap, lets the sum of the parts exceed the whole.

**Here: correct.** Two layers. `_gateFillState` rejects `prevFilled >= total` before
anything else runs (which doubles as the cheap loser-exit for priority auctions),
and `_openFill` keeps the universal `newFilled > total` cap regardless of what a
fill module proposed. The 1-wei-invalidation nuisance is bounded by the
maker-signed `minFillAnchor`, checked against the resolved **delta**, not the
requested amount.

### C7 — Rounding direction and split-fill dust

> **1inch LOP, OpenZeppelin L12.** Amount calculations rounded in the maker's favour
> without explicit taker acceptance, amplified on tokens with unusual decimals.

**Mechanism.** Whichever way the division rounds, someone pays it. If the slice is
per-fill rather than cumulative, the payer can be charged it once per fill by an
adversary who splits.

**Here: applies, in the benign direction.** The invariant, stated plainly:

> **Fixed legs are exact and cumulative. Auctioned legs round toward the maker,
> per fill.**

Fixed legs use cumulative slices and sum exactly, preserving the exact-in and
exact-out guarantees. The auctioned side does not: a SELL output is
`ceil(delta · outTick / anchor)` and a BUY input is `floor(delta · inTick / anchor)`,
both per-fill. Splitting one fill into N therefore costs the **filler** up to one
wei per leg per fill, in both directions — self-inflicted, since the filler chooses
the split, and bounded by `minFillAnchor`. Same posture 1inch accepted at L12.

**Two further surfaces carry the same arithmetic, and both were assessed on
2026-08-28.**

*Netted matching.* `matchSettle` is the case where the single-order argument does not
carry on its own: two makers clear against a shared pool, `BatchNotWhole` only
asserts the pool ends level across all of them, and the filler may have signed one of
the orders. The verdict holds for a structural reason — `Pricing` has **no
cross-order term**, so a counterparty cannot reprice a maker, and the slack lands in
the pool and is swept to `msg.sender`, making a finer grind pay the victim *more* and
cost the grinder more. Swept over every matchable shape and item configuration; see
[match-combinations.md](match-combinations.md).

*`TAKE_FOR` leg-reference funding.* The composite item's value-IN amount, in its
leg-reference form, **is** `Pricing.outputAt(ctx, j)` — the same call
`_deliverOutputs` just made. So a SELL leg's per-fill ceil now also drives a PULL from
the maker's wallet. The maker's net in that token is exactly zero per fill (they
receive and fund the same number), so this is not a value leak; but the *cumulative*
sum of per-fill ceils can exceed the leg's signed total, so a Permit3 token allowance
sized exactly to that total makes the last slice revert `InsufficientAllowance`. A
liveness footgun rather than a loss, and it is documented at `Base._forSlice`.

*The BUY dust slice.* `floor(delta · inTick / anchor)` with an output leg numerically
larger than the input leg rounds a one-unit slice to a **zero** charge while the
cumulative ceil still owes a unit out. Bounded at one unit per fill, paid by the
filler, and removed outright by a signed `minFillAnchor`.

### C8 — Degenerate auction parameters resolving the wrong way

> **UniswapX, OpenZeppelin L-03.** When `decayStartTime == decayEndTime` the decay
> function returned `endAmount` rather than `startAmount`, so a misconfigured
> zero-duration Dutch order silently became a limit order at the price worst for the
> swapper. Zero-duration orders were subsequently disallowed.

**Mechanism.** The degenerate configuration falls through to the
counterparty-favourable end of the band instead of reverting or clamping to the
signer's side.

**Here: inverted, in the safe direction.** `decayDuration == 0` leaves the bump at
0, which is the `start` price — best for the maker, where UniswapX's degenerate case
landed on `endAmount`. The other degenerate shapes revert rather than resolve:
`priorityScale == 0` under a priority auction, a priority auction carrying a gas
bump, a non-increasing curve segment, an override above 100%, and an empty anchor
leg all raise named errors.

**The rule to keep:** when a signed parameter is degenerate, resolve toward the
**signer**, or revert. Never toward the party who chose the transaction.

### C9 — One side spends the other side's gas

> **UniswapX M-01** (acknowledged, unresolved): the `executeWithCallback` ordering
> plus token callbacks let a swapper run gas-intensive work funded by the filler,
> after the filler's last chance to revert. **1inch diff audit, Low:** a maker's
> `makerPermit` extension can name any target and do the same. **1inch MixBytes W5:**
> `notifyFillOrder` carried no gas ceiling.

**Mechanism.** The signer chooses a call target the executor pays for, with no gas
cap and, in the worst ordering, no opportunity to unwind.

**Here: applies — accepted class, industry-wide.** The maker chooses
`pricingModule`, `fillModule`, validators, invariants and every item module, and the
filler pays for all of them with no gas cap. Four of the five are `STATICCALL` with
a one-word return cap, so the damage ceiling is burnt gas; item modules are ordinary
calls under the maker's own Permit3 authority. Fillers must simulate — see
[filler-strategy.md](filler-strategy.md#7-every-maker-supplied-target-is-gas-unbounded).

### C10 — Hard-coded gas stipends on value transfer

> **UniswapX M-02:** a 6,900-gas ceiling in `CurrencyLibrary` excluded
> smart-contract wallets and multisig fee recipients from any native-currency swap.
> **1inch diff audit, Low:** the same shape at 5,000 gas.

**Mechanism.** A fixed stipend is a bet on opcode pricing that goes stale across
upgrades and does not hold across chains.

**Here: not applicable to the core.** No native-value path exists in the settlement
core — no `payable` entry point, and `SafeTransferLib` carries no ETH transfer at
all. Native assets are wrapped inside modules, which is where this check belongs
instead: **any module that forwards native value must not cap the gas.**

### C11 — The permit as a liveness bomb

> **1inch LOP, OpenZeppelin L02.** A permit sitting in a public order can be executed
> by anyone straight out of the mempool. Once its nonce is spent, the order that
> carried it reverts forever and has to be re-signed.

**Mechanism.** The permit is treated as mandatory rather than opportunistic, so a
costless front-run permanently bricks the order.

**Here: correct, and designed around this finding.** `fillWithPermit` uses
`permitBatchWithWitnessIfNeeded`: the signature is still verified every time, but a
nonce already spent — by an earlier partial fill, or by a griefer front-running the
permit out of this very calldata — is **skipped** rather than reverting. Without
that, one cheap front-run would permanently brick an order whose maker signed a
`PermitBatchWitness` and therefore has no other entry to rescue it.

### C12 — Revocation that does not revoke

> **1inch MixBytes**, "user can decrease allowance" (accepted as a gas trade-off),
> and **iosiro's lingering-allowance finding**. The generalised form is now the
> dominant risk in allowance-hub designs.

**Mechanism.** Two paths can fund the same transfer. Revoking one leaves the other
standing — and the user is told they revoked.

**Here: applies, and it was the highest-ranked item in this review.**
`Permit3TransferLib.transferFromWithFallback` falls through to a direct
`transferFrom` whenever the Permit3 leg fails for **any** reason, including because
the payer revoked, capped or expired it. See [F1](#f1--revoking-permit3-is-not-a-kill-switch-on-its-own)
for what changed.

### C13 — Preflight logic drifting from the settler

> **1inch diff audit, Medium** — "forged event emission": `cancelOrder` emitted
> `OrderCancelled` with a hash that had not been cancelled, so anyone could feed
> off-chain systems false cancellations. **OpenZeppelin L05:** events missing indexed
> `orderHash` and amounts, so indexers could not reconstruct state.

**Mechanism.** Any second implementation of the fill rules — a lens, an SDK, an
orderbook filter — that disagrees with the settler fails quietly, in either
direction, and nothing catches it.

**Here: addressed, and it has bitten once.** The 2026-08 review found the lens's
`_anchorTotal` and `_verifySignature` copies had silently drifted; the shareable
rules moved into [`OrderGates`](../packages/core/src/settlement/OrderGates.sol) so
both callers read one implementation. That file's header is the incident report.

**The rule:** a rule that both the settler and the lens must apply belongs in
`OrderGates`, not in two places. The lens may be *stricter* only where it is
explicitly advisory (it flags `recipient is settlement (burn)` and duplicate
`(token, recipient)` pairs); it must never be stricter about **fillability**, or an
orderbook drops live size — nor **looser**, or it blesses orders that revert.

A second review pass (2026-08-25b) found three more instances of exactly this, which
is the strongest argument for the rule above: the class recurs even in a codebase
that has already written the incident down. All three are fixed — see
[F7](#f7--matchsettle-paid-a-self-addressed-output-leg-to-the-solver),
[F8](#f8--a-proportional-anchor-plus-the-pegged-price-module-passed-preflight-and-never-filled),
[F9](#f9--the-lens-conflated-the-settlers-two-lifecycle-axes) and
[F10](#f10--remaining-panicked-for-a-cancelled-order).

### C14 — Assumptions about how tokens behave

> **UniswapX N-06:** the sample executor used bare `approve()`, which fails silently
> on non-standard ERC-20s. **UniswapX M-01** turned on ERC-777 transfer callbacks.
> **1inch M03:** Chainlink calculators assumed 18 decimals without validation, which
> the audit called an unintentional loss-of-funds path.

**Here: scoped, with a real answer on the output side.** Fee-on-transfer and
rebasing *inputs* are out of scope on the netted path and fail closed
(`BatchNotWhole` / `LegUnfunded`) rather than mis-settling. For *outputs*,
`deltaVerifyOutputs` (timing bit 104) requires a measured recipient balance
increase, and its two soundness preconditions — no duplicate `(token, recipient)`
leg, no maker-bound output token that is also an input token — are enforced
**on-chain**, not left to the lens. `SafeTransferLib` handles missing return values
and codeless tokens. The reflection-token caveat is documented rather than solved,
deliberately: the maker chose the token.

### C15 — The settler's balance treated as a shared pot

> **The CoW incident again**, plus the general 0x-Settler posture. Paying a
> counterparty from `balanceOf(this)` rather than from a delta measured inside the
> current settlement lets one fill spend a pre-existing balance, a donation, or
> funds another order in the same batch is owed.

**Here: correct.** Every payout is bounded by a delta measured inside the current
fill. `_payInputsToSolver` pays the solver only from proceeds produced since this
fill's own snapshot; `_sweepSurplus` floors every touched token at its pre-context
balance, so a donated balance is unreachable; and `_creditItemProceeds` closes the
one gap the floor could not, by refunding un-attributed item proceeds to the
**maker** rather than letting the final sweep hand them to the solver.

**Swept combinatorially (2026-08-28).** The "donated balance is unreachable" half is
no longer asserted only where someone thought to test it: Settlement is seeded with a
standing balance in every tracked token and re-checked in every cell of the shape and
item matrices ([match-combinations.md](match-combinations.md)) — 64 + 49 shape cells
and the two item sub-matrices. The `_creditItemProceeds` half has a negative control:
rerouting that refund to `msg.sender` fails all four item sweeps, each short by
exactly the strayed amount.

---

## Findings ledger

**F1–F6** came out of the 2026-08-25 crosswalk. **F7–F12** came out of a second,
independent review pass against the same corpus later that day; two of those arrived
with executed PoCs, and all six were re-derived here before being acted on. **F13–F15**
arrived as three reported findings and were each verified against the code before
being acted on — two confirmed with executed PoCs and fixed, one (F14) reviewed and
judged NOT a vulnerability, with only its misleading comment corrected. **F16** came
out of the `TAKE_FOR` build itself and is recorded here rather than left in a commit
message. **F17** was a known, accepted caveat that a re-assessment promoted to a
finding: its remedy existed, but as a caller convention rather than an enforced
property. **F17–F20** came out of a clean full re-audit of the core plus the aave-v3
and fluid module packages on 2026-08-29 — F17 with an executed PoC, F18 reviewed and
**withdrawn** as already covered (kept for the lesson), F19 and F20 confirmed by
reading. See
[Re-audit sweep](#re-audit-sweep--the-generalised-questions-from-f13f15) for the
generalised questions they imply. Every item below is resolved.

### F1 — Revoking Permit3 is not a kill switch on its own

**Class C12 · Medium · by design, mitigated off-chain**

`Permit3TransferLib.transferFromWithFallback` attempts the Permit3 leg with a
low-level call and, on **any** failure, falls through to a direct
`token.transferFrom`. Because the failure is not discriminated, the direct
allowance is consulted when the Permit3 grant is missing, too small, expired, *or
deliberately revoked*. For a payer holding both, per-order Permit3 caps are not
binding, and `revokeToken` / `lockdown` / an expiry do not stop fills.

This is intentional — a direct approval genuinely *is* the broader grant, and the
library header has always said so. It is nonetheless exactly the shape that produced
iosiro's lingering-allowance finding, and an external auditor will raise it at
Medium or above regardless of the comment above it. `setStrictMode` closes it
completely but defaults to off, so the safe configuration was the one nobody was in.

**Not changed on-chain.** The fallback is load-bearing for makers who fund by direct
approval, and `SettlementLens` is hard against EIP-170 (a 237-byte addition put it
over once already), so the fix belongs where the user actually is.

**Changed:**
- `buildStrictOnboarding` (SDK) — the recommended account setup: enable strict mode
  **then** grant through Permit3, so the hub is the only funding path from the
  start and revocation is real thereafter.
- `buildRevokeAll` (SDK) — now takes `directApprovals` and `strictMode`. Strict mode
  is emitted **first**, so a fill landing between separately-sent calls cannot use
  the fallback. Direct approvals are zeroed with `approve(spender, 0)` addressed to
  the **token**, since the hub has no authority over an allowance it was never part
  of.
- `readFundingPosture` (SDK) — reads both surfaces and returns
  `fallbackIsLoadBearing`, which is the exact state a "revoked" badge in a wallet UI
  would otherwise get wrong. An SDK read rather than a lens method, for the size
  reason above.
- [account-onboarding.md](account-onboarding.md#strict-mode-and-the-two-funding-surfaces).

**Standing rule for integrators:** a UI that offers "revoke" MUST clear both
surfaces, or enable strict mode, or say plainly that it did neither.

### F2 — `ItemOp` was decoded as a raw byte

**Class C3 / C6 · Low · fixed**

`PackedArrays.itemAt` returns `op` as a raw byte, deliberately unnarrowed.
`Base._runItem` dispatched MAKE, else TAKE, else SETTLE — so any `op >= 3` executed
the SETTLE branch. Meanwhile `Batch._assertMatchShape` enforced the netted path's
SETTLE prohibition by testing `op == uint256(ItemOp.SETTLE)` exactly. An item signed
`op = 3` therefore passed the shape assertion and then ran a SETTLE inside
`matchSettle` — the one thing that path declares it cannot account for, because
SETTLE routes the maker's asset to the filler rather than to the pool.

Never a theft path: the byte is inside the maker's own signature, and both shipped
SETTLE modules (`NftSettlementModule`, `ProportionalSweepModule`) move only the
maker's assets, pulled from the `maker` argument Settlement supplies. But it turned
a named, deliberate path restriction into an advisory one.

**Fixed, both halves:**
- `Base._runItem` now reverts `PackedArrays.MalformedPackedArray` on an unknown op
  rather than folding it into SETTLE. The existing error is reused rather than a new
  one declared — its selector is already in the runtime, and Settlement had 67 bytes
  of EIP-170 headroom.
- `Batch._assertMatchShape` asks `op >= ItemOp.SETTLE`, keying on how the dispatcher
  actually behaves rather than on the enum value.
- `packages/core/test/items/ItemOpRange.t.sol` — six tests including a fuzz over the
  whole invalid range, and a control proving a well-formed SETTLE still dispatches.

**Measured:** +14 bytes of Settlement runtime (24,509 → 24,523 of 24,576).

**The generalisable rule:** an enum read out of a signed blob is a `uint8`, not an
enum. Range-check it at the dispatcher, and write every guard over it as `>=`/`<=`
against the dispatcher's behaviour, never `==` against the enum value.

### F3 — Maker-supplied targets are gas-unbounded

**Class C9 · Low · documented**

Same accepted posture as 1inch L11 and UniswapX M-01. Now stated explicitly for
fillers rather than left as an inference, including which surfaces are static and
which are stateful:
[filler-strategy.md §7](filler-strategy.md#7-every-maker-supplied-target-is-gas-unbounded).

### F4 — Rounding is maker-favourable and non-cumulative on the auctioned side

**Class C7 · Informational · documented**

The invariant is now written down where the pricing lives —
[pricing-modes.md](pricing-modes.md#rounding-who-pays-the-wei) — and restated under
C7 above. No code change: the direction is correct and the magnitude is bounded by
`minFillAnchor`.

### F5 — `fillWithPermitTake`'s "nothing survives it" was imprecise

**Class C4 · Informational · comment fixed**

The entry point claimed the maker's authority "is consumed by this fill and NOTHING
survives it". True of the **permit**; not of the **order**. A successful fill writes
`filled[orderHash]`, and `_verifySignature`'s first-fill skip keys on exactly that,
so any remaining size is thereafter fillable with an arbitrary `sig`, funded by the
maker's standing *token* allowances.

That is correct rather than a gap — the permit's witness IS the order hash, so an
earlier fill did present valid authorization — and close to unreachable, because
`_takeByPermit` requires `permit.amount == slice` and a pro-rata slice below the
permit's amount cannot match, making the entry implicitly full-fill. The comment now
says what actually holds, and points at `cancelOrder` as the switch that binds.

### F6 — Signature malleability is accepted

**Class C3 · Informational · no change**

`tryRecoverSigner` accepts 65-byte and EIP-2098 compact signatures and does not
reject a high `s`, matching Permit2 from which it is ported. No on-chain
consequence: all fill state is keyed on the **order hash**, never on the signature
bytes, so a malleated variant authorises the same order and consumes the same
counter. The off-chain risk — an orderbook deduplicating on signature bytes — does
not apply either: `@1delta-x/orderbook` keys, sorts and paginates on `orderHash`.

**Rule:** never key state, cache entries or dedup logic on signature bytes.

### F7 — `matchSettle` paid a self-addressed output leg to the solver

**Class C15 / C13 · Low (maker-authored, solver-opportunistic) · fixed**

An output leg whose `recipient` is Settlement itself is the documented maker
"self-burn": on the single-order path the filler pays it into Settlement, which has
no sweep and no admin, so it is stranded forever. Three places said so —
`docs/originator-fees.md`, the settlement README, and `SettlementLens.validateOrder`.

The netted path could not honour that promise. `_stepDeliver` performed a real
pool→pool **self-transfer**, which leaves the balance untouched while `outstanding`
records the obligation as discharged — so the amount sat above the pre-context floor
and `_sweepSurplus` handed it to the **solver**. Same signed order, opposite outcome.
`BatchNotWhole` does not compensate: it floors each token at its *pre-batch* balance,
and this amount arrives during the context.

Reproduced end to end: 2,000 USDC burned via `fill`, the same 2,000 paid to the
solver via `matchSettle` on a plain `[PULL, PULL, DELIVER, DELIVER]` schedule. The
realistic shape is worse than the toy one — a 5% originator fee leg mis-addressed at
Settlement leaves the maker's own leg paying out correctly at 1,900 while the solver
quietly pockets the 100, so nothing looks wrong to the maker.

Not solver-createable — `legsOut` is inside the EIP-712 typehash — but it is
maker authoring plus **solver opportunism**, which gives solvers positive-EV reason
to hunt mis-authored orders and bundle them with anything touching the same token.
This is the sibling of the stray-TAKE-proceeds hazard `_creditItemProceeds` already
closes, and it is broader: an item's proceeds token may be absent from the token
universe, but a `legsOut` token is always in it.

**Fixed.** `Batch._stepDeliver` reverts `OutputToSettlement` on a leg addressed at
the settler. Refused rather than refunded: unlike item proceeds there is no honest
destination — the maker deliberately signed the amount away. The single-order burn is
unchanged and pinned by a control test. The three doc sites now describe both paths.
`packages/core/test/swaps/OutputToSettlement.t.sol`, 5 tests.

**Measured:** +25 bytes (24,523 → 24,548 of 24,576). The error carries **no
arguments**, deliberately — naming `(order, leg)` the way the sibling plan errors do
measured +37 bytes against a 53-byte budget, and the lens already reports the
offending leg off-chain.

### F8 — A proportional anchor plus the pegged price module passed preflight and never filled

**Class C13 · Low (liveness) · fixed, and the combination now works**

`ChainlinkPeggedPriceModule._band` re-read `legsIn[0].start` out of the packed blob
for its anchor. On a `Proportional` order that word is a **marker** (≈1.15e77), not
an amount, so `anchor · answer` overflowed for every feed answer ≥ 2, the module's
`staticcall` panicked, and `DutchAuction.priceBump` — which has no fallback —
reverted `PriceModuleFailed`. The order was signable, `validateOrder` approved it,
and no one could ever fill it. The non-overflowing cases were worse than the revert:
they priced the *sentinel* rather than the maker's balance, silently ignoring the peg.

The core's own `DutchAuction.amountInAt` guards the identical read, and its comment
names this exact hazard — the module simply never inherited it.

**Fixed, and better than a guard.** The core already passes the module `total`: the
denominator resolved *before* any funds move, with the proportional marker already
resolved against the maker's live balance and pinned in `FillCtx.anchor`. The module
ignored it. It now uses it, so "sell 100% of my stETH at the Chainlink rate" works,
and preview and fill agree by construction rather than by two implementations
happening to match. Only this one module read legs raw; the other three pricing
modules were checked and do not.
`packages/modules/pricing/chainlink/test/ProportionalPeggedPrice.t.sol`, 5 tests.

### F9 — The lens conflated the settler's two lifecycle axes

**Class C13 · Informational (off-chain reporting) · fixed in one direction, documented in the other**

The settler tracks lifecycle on two axes: the per-hash `filled` counter (with its
`type(uint256).max` cancellation sentinel) and the nonce bitmap. `_orderState` read
only the bitmap, so an order cancelled by **hash** fell through to the `done >= anchor`
compare — where the sentinel is trivially ≥ any denominator — and was reported as
**Filled**. `validateOrder` carried the same conflation in its reason string.

**Fixed:** both now check the sentinel first and report `Cancelled` / `"order
cancelled"`. Neither direction was ever a fillability error — both reject — so the
impact was confined to indexers and maker dashboards showing a cancelled order as
executed.

**The inverse is NOT fixable, and is now documented rather than faked.** A fill-once
order (`useNonceInvalidator`) deliberately keeps no per-order counter — its progress
*is* the consumed nonce — so an order that FILLED and one whose nonce the maker
CANCELLED leave byte-identical chain state. No view can separate them. The
`OrderStatus` enum now says so, and points consumers at the `OrderFilled` event,
which the settler emits on the fill and not on the cancel.
`packages/periphery/test/LensLifecycleAndOpen.t.sol`.

### F10 — `remaining()` panicked for a cancelled order

**Class C13 · Informational · fixed**

`remaining` subtracted the stored fill value with no sentinel check and outside
`unchecked`, so a per-hash-cancelled order produced a bare `Panic(0x11)` instead of
the `OrderCancelled()` the same contract declares and its sibling `_resolveState`
already raises — whose docstring says it exists so the quote paths "can never
disagree about the cancel semantics". `remaining` had been left out of that
consolidation.

**Fixed** to revert `OrderCancelled()`. Reverting rather than answering `0` is
deliberate: `0` is already the truthful answer for a *fully filled* order, and
collapsing the two would hand callers the same number for "done" and "revoked". The
docstring now points batch callers at `getOrderRelevantState`, which returns a status
enum and never throws.

### F11 — `open` announced an ERC-7683 order without the signature check `openFor` performs

**Class C13 · Informational · fixed**

`OriginSettler7683.openFor` verifies the signature and states the invariant the pair
maintains: `Open` is never emitted for an order nobody can fill. `open` checked only
`maker == msg.sender`, liveness and the hash — which proves *who is opening*, not
that the embedded credential is one the settler will accept. The eventual fill does
require it, so an `Open` could advertise an order that reverts at fill time. Bounded
to wasted solver simulation (same-chain, atomic, escrow-free), but a broadcast nobody
can act on is what the invariant exists to prevent.

**Fixed** by adding the same `LENS.checkSignature` call. This costs the
signature-less maker nothing, which is why it is not a trade-off: `checkSignature`
routes an empty `sig` to the settler's own `orderApproved` record, so the
`approveOrder`-then-`open` sequence in `open`'s own docstring passes by construction.
What it rejects is a stale or malformed credential — the case the maker cannot detect
and the solver pays for. Four tests cover both directions, including the sigless path.

### F12 — "Complete kill switch" overstated what Permit3 nonce invalidation cancels

**Class C13 · Informational · docs**

`UnorderedNonces` described `invalidateUnorderedNonces` as "a complete kill switch
for a nonce range regardless of what was signed against it". Read narrowly that is
true of *permits*; a maker could reasonably read it as covering the **order** a
witness-bound permit is attached to, and it does not.
`permitBatchWithWitnessIfNeeded` verifies the signature and then returns *silently*
on a spent bit rather than reverting — the S-1 remediation, without which one
front-run permanently bricks any gasless order — so `fillWithPermit` proceeds with
the grants simply not applied, and still succeeds if a standing allowance or a direct
ERC-20 approval covers it.

Not a code defect: the order-level cancels all bind on this path (`_gateFillState`
runs *before* the permit call), and `docs/soft-cancel.md` already tabulates them
correctly. **Fixed in the three doc sites** (`UnorderedNonces`, `IPermit3`, the
permit3 README) as the converse of the existing "Revoking a Permit3 allowance is NOT
a kill switch" caveat in `SECURITY.md`.

### F13 — A revoked on-chain order approval was bypassed by any non-empty signature

**Class [C12](#c12--revocation-that-does-not-revoke).** PoC'd, fixed.

`Signatures._verifySignature` skips re-verification once `filled != 0` — a signature
over a fixed digest cannot be withdrawn, so re-checking it is pure cost (~2,860 gas
per later fill). But that skip is reached by **any** non-empty `sig`, and nothing
records *how* the earlier fill was authorised. An order authorised by the
`approveOrder` record therefore set `filled`, and a filler passing 65 arbitrary bytes
then took the signature branch, hit the skip, and settled the remainder of a
**revoked** order — for a maker with no EIP-1271 at all, for whom no signature can
ever be valid. The file's own comment claimed the skip "applies ONLY to the signature
branch"; it does, but the filler picks the branch.

**Fix.** `revokeOrderApproval` now parks the `cancelOrder` sentinel when the order is
already partially filled, gated on `wasApproved` (the flag proves the caller is the
maker, since `approveOrder` enforces it — without that gate a bare hash would let
anyone cancel a stranger's touched order). Zero hot-path cost: `filled` is already
read by every fill. The alternative — reading `orderApproved` on the signature path
too — puts a cold SLOAD on every fill of every order to protect the rare sigless one.
Revocation of a *touched* order is now one-way; an untouched one still round-trips.

### F14 — "Invalidated nonce ⇒ grants already applied" was a false inference

**Class [C11](#c11--the-permit-as-a-liveness-bomb) / [C12](#c12--revocation-that-does-not-revoke).**
Reviewed, **not a vulnerability**; comment corrected.

`SignedPermits.permitBatchWithWitnessIfNeeded` returns silently on a spent nonce bit,
commented "authorization still proven; grants already applied". The second clause is
false: a bit is set by `invalidateUnorderedNonces`/`lockdownAll` just as much as by a
prior application, and in that case the grants were never applied and never will be.

No authority is granted that should not be — the signature is verified *before* the
nonce check, and the spent-bit path applies **nothing**, so the failure direction is
fail-safe. The silent return is the deliberate S-1 remediation (without it one
front-run permanently bricks a gasless order), and the consequence is already
documented in `UnorderedNonces`, `SECURITY.md` and `docs/soft-cancel.md`, and ledgered
as [F12](#f12--complete-kill-switch-overstated-what-permit3-nonce-invalidation-cancels).
Only the misleading inline comment was wrong. Kept as a ledger entry because the
*inference* is the reusable trap, not the code.

### F15 — A duplicate `PULL` step burned maker allowance without extra fill progress

**New shape: a refund that restores the asset but not the authority spent to move it.**
PoC'd, fixed.

`Batch._stepPull` moved the nominal `owed` unconditionally, justified in-file as "a
duplicate PULL needs no exactly-once guard … it costs the solver gas and the maker
nothing", because Phase 3 refunds the surplus to the maker. The **tokens** are indeed
refunded — net spend stayed exactly one fill — but the **Permit3 allowance** spent to
move them is not restored. Against a finite, amount-gated allowance (the model
`IPermit3` is built around) a padded schedule consumed 2× the allowance for 1× the
fill and left the maker unable to fund the next one; `matchSettle` is permissionless,
so any solver could do it. Makers on an infinite (`uint160.max`) allowance were never
affected — Permit3 treats that sentinel as "do not decrement".

**Fix.** Pull the **shortfall** (`owed - credit`) rather than the nominal amount. This
keeps the tolerant, guard-free shape the schedule wants — a second PULL of a leg now
needs nothing, moves nothing and spends no allowance — and additionally makes
ITEM-then-PULL exact instead of over-pull-then-refund. A `credit != 0` guard would
have been wrong: `_creditItemProceeds` also credits input legs.

### F16 — A balance-relative `TAKE_FOR` funding leg failed OPEN when the wallet was empty

**New shape: a premise that silently evaluates to "fund nothing" while the other half
of a composite op still runs in full.** Found and fixed during the `TAKE_FOR` build;
recorded here because the ledger, not the commit, is where a finding is supposed to
live.

The balance form of a composite funding descriptor resolves
`forAmount = min(balanceOf(token, maker), cap)`. When the maker held **none** of the
token the read returned 0, the module supplied nothing — and the value-OUT leg still
drew its full amount. "Deposit what I hold and borrow against it" silently became a
bare, uncollateralised borrow. Reachable with no malice at all: an earlier fill of one
of the maker's *own* orders can spend the balance, and the filler chooses which order
goes first. `SafeTransferLib.balanceOf` multiplies by the staticcall's success, so a
descriptor naming a codeless address read as a zero balance rather than reverting, and
took the same path.

**Fix.** A zero resolved balance reverts `ForBalanceBelowFloor`. The premise failing must
stop the fill, not silently change its shape. A LITERAL or LEG funding slice that
floors to zero on a dust fill is deliberately *not* covered by this rule — those
accumulate exactly across slices, so a zero slice is arithmetic rather than a broken
premise. Pinned by `TakeForItem:test_balance_emptyWallet_reverts` and
`..._codelessToken_reverts`.

**The generalised question, and it belongs on the sweep below:** *when a composite op's
two halves are gated separately, can one half's premise fail while the other still
executes?* Ask it of every op that fuses value-in with value-out.

**Re-checked in the CoW case (2026-08-31), and the fix is NOT sufficient there.**
`ForBalanceEmpty` catches a resolved *zero*; it does not bound how far below the
maker's intent the resolution can be pushed. On the single-order path that does not
matter, because the ordering is a property of the code — `_settleForward` is
deliver → items → pay-inputs, and the one mode that reorders it forbids items
(`ReverseModeRequiresNoItems`). Under `matchSettle`, `ITEM` and `DELIVER` are
independently schedulable, so a filler could resolve the same descriptor against the
maker's pre-delivery wallet and fund the position with a wei while the value-OUT leg
drew in full — passing the zero check. `Batch._assertMatchShape` already refuses every
`TAKE_FOR` item outright, so this is **not reachable**; it is recorded because the
guard's stated reason used to be an ordering *inconvenience*, which would have
justified relaxing it. The reason is now written down as a security property, per
descriptor form, in [match-combinations.md §2.1](match-combinations.md#21-why-take_for-in-particular-stays-out).

---

### F17 — an unrelayed delegate-nomination permit could cancel a live order

`setOrderSignerWithSig` consumed the maker's **order** nonce bitmap at the bare
`nonce`, so relaying a nomination permit ran `_cancelNonce(maker, nonce)` and killed
every live order carrying it. The permit is relayable by anyone at any point before
its `deadline`, and the bitmap bit stays clear until then — so the natural off-chain
"is this nonce free?" check reads free right up to the moment an order signed
against it dies.

Two things made it more than theoretical. Nonce **reuse is a feature** here — a
shared nonce is how an OCO bracket is built — and the SDK leaves allocation to the
caller (`amend.ts`), so neither layer was watching for the collision. The docs
described the cost as "one nonce out of a 2²⁵⁶ space", which is true of the
coordinate and false of the consequence.

**Fixed** by reserving a namespace: the permit now consumes
`nonce | SIGNER_NONCE_NS` (bit 255), while the maker still signs the bare value, so
no tooling changes. Order nonces below 2²⁵⁵ — every nonce any builder allocates —
are now unreachable from that function. Costs **7 bytes** of Settlement, against a
15-byte EIP-170 budget; two inline `or`s measured 9, so the local is load-bearing.

The residual constraint is stated on `NonceManager.SIGNER_NONCE_NS`: an order must
not use a nonce with bit 255 set. Deliberately **not** enforced on the fill path — a
range check there taxes every fill forever to guard a range no allocator picks.

Pinned by `test_signerPermit_cannotCancelALiveOrder` plus the two disjointness tests
either side of it.

**The generalised question.** The bitmap is one space shared by two kinds of signed
artifact. Any *third* consumer added to it inherits this bug by default, because the
failure is silent in both directions and only shows once the two artifacts collide.
Namespace first, then add the consumer.

### F18 — WITHDRAWN: the `TAKE_FOR` leg-reference zero check was not missing

Reported during the 2026-08-29 re-audit and **wrong**. The observation was that
`SettlementLens._takeForItemAt` rejects a zero LITERAL descriptor
("take_for funds nothing") but has no equivalent for a leg reference pointing at an
output leg whose `start` is 0 — which prices to 0 on every fill, so the composite
degrades to a bare `TAKE` with nothing funding it.

The settler behaviour is real and is now pinned
(`test_zeroOutputLeg_fundsNothing_butTheTakeStillDraws`), but the preflight gap is
not: `validateOrder` rejects `start == 0` on **every** output leg of every order,
on both sides, and that rule runs before the `TAKE_FOR` walk. The case was already
covered — by a general rule with a different message rather than a
descriptor-specific one. A second check there would have been dead code.

Recorded rather than deleted because the mistake is instructive: the descriptor
branch has its own zero check, which makes the neighbouring form look unguarded.
**When one branch of a validator carries a bespoke check, confirm the sibling is not
already covered upstream before adding a matching one.**
`test_lens_flagsZeroAmountOutputLeg_viaTheGeneralRule` now asserts the coverage so
the question does not get re-opened.

### F19 — module residual disposal swept the module's whole balance

`AaveV3RepayModule._disposeResidual` and `FluidOperateModule._close` read
`IERC20(token).balanceOf(address(this))` as "this call's residual", and
`AaveV3WithdrawModule`'s `BalanceMode.Full` calls `withdraw(asset, max, this)`,
which burns the module's entire aToken balance for that reserve. Modules are
pull-exact, so the whole balance and the delta are normally equal — but when they
are not, "sweep everything to `onBehalfOf`" pays the difference to whoever happens
to be filling.

Not a privilege escalation: the destination is always the order's maker, never a
caller-chosen address. It is still **claimable rather than merely lost**, which is
the part worth fixing — anyone can send tokens to a module address, and anyone can
be the maker of a one-unit order against that module and asset.

Two asymmetries made it worse than the headline. `DustHandler.disposeResidual`
re-reads the balance after a partial recycle, so it swept the pre-existing amount
even for a caller that measured its own residual correctly. And
`FluidOperateModule._open` / `FluidTakeForModule` had **no** residual handling at
all where Close has always had one, so a short pull stranded the difference
permanently along with a live vault allowance over it.

**Fixed** by measuring a delta over a `floor` snapshotted before the pull:
`DustHandler.disposeResidual` gains a floor-aware overload (the old signature is
retained and delegates with `floor = 0`, so the ten sibling packages compile
unchanged), Fluid gains `FluidBase._returnUnused`, and Open/`takeFor` gain the
sweep they lacked. The invariant enforced is now "the module ends where it
started", not "the module ends empty".

**Swept across all twelve packages** (2026-08-31): aave-v2/v3/v4, compound-v2/v3,
morpho-blue, venus, silo, exactly, euler-v2, dolomite and fluid now snapshot a
`floor` before the pull and dispose of the delta over it. Compound v2 keeps its
inline recycle and gained a second floor for the **cToken** receipt, which the mint
is the only in-call source of but which a donation would otherwise have forwarded.
Dolomite's helper needed its locals re-scoped and an `_depositCall` frame to stay
under the legacy stack limit at seven parameters.

**And the `BalanceMode.Full` variant, which is narrower than it looks.** Fourteen
packages implement `Full`, and all fourteen measure `received` as an underlying
delta around the withdraw — correct. What matters is whether the withdraw is scoped
to the MODULE's receipt balance or the USER's position:

| shape | packages | verdict |
|---|---|---|
| `withdraw(asset, type(uint256).max, address(this))` after pulling the user's receipt tokens | **aave-v2, aave-v3** | **defective** — donated receipts inflate `received` and are swept to `onBehalfOf` |
| withdraw scoped to the user (`supplied`, `vBal`, `maxWithdraw(onBehalfOf)`, `collateralBalanceOf(onBehalfOf)`, `getAccountWei(onBehalfOf)`, `redeem(cBal)`) | aave-v4, compound-v2, compound-v3, venus, euler-v2, silo, morpho-blue, exactly, dolomite, lista, gearbox-v3, midnight | clean |

Both defective sites now subtract the module's pre-existing receipt balance before
the sweep, saturating so a rounding wei cannot underflow-panic — the `require` stays
the fail-closed gate.

**The generalised question.** "The module ends empty" and "the module ends where it
started" are different invariants, and only the second is safe to enforce with a
transfer. Any `balanceOf(address(this))` that is *read as* this call's output — as a
residual, as a redeemed amount, as a receipt to forward — needs a floor. The tell is
a full-balance read with no matching snapshot before the operation that produced it.

### F20 — `make test-all` skipped three packages' real coverage

`PACKAGES` in the Makefile listed `modules-aave-v3`, whose profile compiles only
`test/unit` — 6 tests. The package's other 56 tests, including
`leverage/TakeForLeverage.t.sol` and `security/TakerModuleAuth.t.sol`, live under
the separate `modules-aave-v3-fork` profile, which no make target referenced.
`modules-compound-v3-fork` and `modules-morpho-blue-fork` were in the same position.
`test-all` reported green while running a small fraction of those three packages.

**Fixed:** `FORK_PACKAGES` is now a second list, `ALL_PACKAGES` is the union that
`test-all` and the per-package shortcuts iterate, and `make test-fork` runs the fork
suites alone. Keep the two lists in sync when a `-fork` profile is added to
`foundry.toml`.

**The generalised question.** A profile that exists in `foundry.toml` but in no make
target is invisible coverage. Whenever a package's tests are split across profiles,
the split has to be represented in the runner too, or the runner silently redefines
what "the package's tests" means.

### F21 — every `MAKE` item's funding grant was invisible to the preflight

An item that funds anything pulls it with `permit3.transferFrom(maker, MODULE, asset,
…)`, so the grant it spends is keyed `(maker, module, asset)`. Neither preflight read
that book. `_makerFillableCap` walks `legsIn` with the **settler** as spender;
`previewTakerAllowances` reads the **taker** book, which gates what LEAVES a position,
not what funds it. And the funding asset need not appear in `legsIn` at all.

The consequence is a silent, total liveness failure: an order passes `validateOrder`,
passes `previewTakerAllowances`, and reverts on **every** fill for want of one
`approveToken` — with the revert surfacing from inside Permit3 two calls deep, naming
no missing grant. An orderbook cannot tell such an order from a fillable one.

Scope is the point. This was first noticed on `TAKE_FOR`'s funding leg, but `MAKE` is
the same pull and is the *common* case: every deposit and every repay on every venue
(`AaveV3DepositModule.makeOnBehalf` is the canonical shape). `TAKE_FOR` merely made an
old gap newly load-bearing.

**Fixed:** {IFundingSource} — a module declares `(asset, available)` for whatever its
funding path actually consults — and `SettlementLens.previewItemFunding`, which walks
`MAKE` and `TAKE_FOR` and reports `required` vs `available` per item.

**Not an ERC-20 assumption.** `asset` is whatever the module draws from. A module
funding a position with an NFT reports the ERC-721 and an `available` of 0 or 1; the
lens compares `asset` for identity and `available` as a magnitude and assumes nothing
else. `address(0)` means "I pull nothing external".

**The generalised question.** *For every book that can stop a fill, which preflight
reads it?* Enumerate the books, not the functions. A settler with three
authorisation books and two preflights is under-covered by construction, and the gap
is invisible precisely because each preflight is individually correct.

### F22 — an item could deliver a token no leg could consume, stranding it forever

Proceeds are credited by **measurement**: `Core._payInputsToSolver` reads the balance
delta of `legsIn[i].token` across the item run. The token a module actually delivers
is named only inside `data`, in a per-module layout the core deliberately never
decodes, and nothing cross-checked the two.

Point a `TAKE` at token X while every input leg is token Y and the maker pays twice:

1. every leg measures `proceeds = 0`, falls to the `owed > proceeds` branch, and the
   **full** `owed` is pulled from the maker's own wallet;
2. token X is credited to nobody, and the single-order `fill` path **has no sweep**.
   It is not stolen — it simply stays in the settler forever. Nothing can retrieve it,
   because `Settlement` grants no ERC-20 approval to anyone, which is the same
   invariant that makes the proceeds measurement sound in the first place (§C15).

No attacker is involved. It is a maker-signed misconfiguration — precisely the class
`ItemOp.TAKE_FOR` was introduced to make unrepresentable on the *funding* side, which
had gone unaddressed on the *proceeds* side. `TAKE_FOR` de-duplicated the funding
AMOUNT; neither asset identity was ever checked.

**Fixed:** {IProceedsAsset} — a module declares the token it delivers — and a
`validateOrder` rule: proceeds routed to the settler (`item.recipient == 0`) must be a
token **some** input leg can consume.

Both halves of that rule are load-bearing. *Some* leg, never leg 0: a rising
relayer-fee leg in a different token is legitimate. And only when `recipient == 0`: a
signed recipient routes the proceeds away from the settler on purpose (to the maker,
or chained into a later item), so the settler never holds them.

**The generalised question.** *Where a value is credited by MEASURING a balance, what
proves the thing measured is the thing that moved?* A measurement-based credit is only
as sound as the binding between the measured token and the declared one. Wherever
those are two independent statements — one in a signed leg, one in an opaque blob —
they need an equality check or the gap swallows value silently.

### F23 — three invariants documented but unenforced (all now closed)

Not defects, but the same shape three times: a rule that held only because every
current integrator happened to follow it. All three now have an enforcement point,
and none of them is runtime code — the contract had no gas or bytes to spare, and
none was needed.

| invariant | where it rests | what breaks |
| --- | --- | --- |
| ~~a module implements `ITakerModule` **or** `ITakerForModule`, never both~~ **CLOSED** | `make modules-check` | the taker book keys both on `(user, spender, module, keccak256(data))`, so one `approveTaker` would authorise either shape and the grant cannot tell the maker which |
| ~~an ORDER nonce must not set bit 255~~ **CLOSED** | `packOrder` → `assertOrderNonce` | see below |
| ~~Permit3 nonces are allocated **per owner**, not per message type~~ **CLOSED** | `permitBatch`/`permitTake` → `assertPermit3Nonce` | all three signed flows share one bitmap. `permitBatchWithWitnessIfNeeded` is idempotent on a spent nonce (the S-1 remediation), but `permitTake` and `permitTransferFrom` both revert — so anyone holding an unrelayed signed message can burn its nonce and DoS a *different* message the owner signed at the same coordinate. Exactly §F17's shape, one layer down |

**The bit-255 row was worse than "documented but unenforced", and is now fixed.**
`assertOrderNonce` existed in the SDK, was exported, and its own docstring said *"call
this wherever order nonces are allocated"* — and **nothing called it**. Meanwhile
`NonceManager`'s prose asserted "the SDK caps order nonces below this value". So the
contract pointed at the SDK, the SDK pointed at the caller, and the invariant was
enforced nowhere, while both texts read as a guarantee. It is now wired into
`packOrder`, which every order the SDK builds passes through, alongside the `timing`
bit checks already there — and the contract comment names that enforcement point
instead of asserting a cap. Covered by `delegation.test.ts`.

**The other two are now closed as well, in the homes this row named for them —
neither cost a byte of runtime.**

*One module, one shape* is [`tools/check-module-shapes.py`](../tools/check-module-shapes.py),
wired as `make modules-check`. It scans every `packages/*/src/**/*.sol` for a
contract declaring both `takeOnBehalf` and `takeForOnBehalf` (or inheriting both
interfaces) and fails the build. 77 taker contracts scanned, each implementing
exactly one; verified to bite by planting a violating contract and watching it exit
1. It reads SOURCE rather than artifacts deliberately: a full-tree `forge build` does
not currently succeed (a bridge module is stack-too-deep under the default profile),
so an ABI scan would silently cover a subset — and a gate with unknown coverage is
worse than no gate. The pattern it must catch is syntactic anyway.

*Permit3 nonce namespacing* is [`permit3nonce.ts`](../packages/sdk/src/permit3nonce.ts).
The message kind takes the top byte and the sequence the remaining 248 bits, so two
messages of different kinds can never share a coordinate whatever each allocator
picks. `Batch` is kind `0` on purpose, which keeps every legacy small nonce valid
while still making it un-collidable with a properly allocated `Take` or `Transfer` —
and those two are exactly the flows that REVERT on a spent bit, so they are the ones
that had to become explicit.

Crucially it is asserted in `permitBatch` and `permitTake`, the constructors every
message passes through — **not** merely exported. That is the bit-255 row's lesson
applied rather than restated.

**The generalised question, and it is the lesson of this row.** *A guard that exists
but is never invoked is indistinguishable from no guard — except that it reads as
one.* Whenever a contract comment delegates an invariant to off-chain code ("the SDK
ensures…", "builders must…"), grep for a call site. If the named enforcement point has
no callers, the comment is not documentation, it is a false claim, and it is more
dangerous than silence because it stops the next reader looking.

### F17 — Revoking a delegate did not invalidate an outstanding nomination permit

**New shape: a safety property whose only enforcement was that the caller made a
second call.** Known, accepted and documented as a caveat since the delegated-signer
work; closed 2026-08-31.

A gasless `OrderSignerPermit` burns its bitmap coordinate only when **relayed**. So a
maker who signed one, never had it landed, and then revoked with
`setOrderSigner(d, 0)` was still exposed: the registry read as clear, but whoever held
the message could relay it up to its `deadline` and the delegate came back — its
signature then settling orders the maker never signed. No malice needed; a relayer
that simply dropped the transaction is enough.

The documented remedy was to make revocation **two calls**, clearing the registry and
then burning the coordinate with `cancelOrders`. The SDK emitted the pair. Every other
client — a wallet, a block explorer, a script — emitted the obvious single call and got
the hole. That is the [C2](#c2--hand-rolled-calldata-arithmetic-without-a-bounds-proof)
posture in a different costume: correct code, upheld by convention rather than by the
compiler.

**Fix, in two halves that only work together.**

1. `OrderState._setOrderSigner`'s revoke branch burns the delegate's entire permit
   word: `nonceBitmap[maker][SIGNER_NONCE_NS >> 8 | d] = type(uint256).max`. One
   `SSTORE`, no new storage slot, no typehash change.
2. `Signatures.setOrderSignerWithSig` now **requires** `nonce >> 8 == uint160(signer)`
   (`SignerPermitNonceMalformed`). Without this the burn would be worthless: a permit
   at a freely-chosen coordinate sits in another word and survives the revocation. The
   derivation had been an SDK convention; it is now an invariant.

Half 2 also closes a smaller residual for free — it forces `nonce < 2^168`, so a bare
permit nonce can never carry `SIGNER_NONCE_NS` itself, and `n` / `n | NS` can no longer
be two distinct maker-signed permits sharing one coordinate.

**Cost.** +67 bytes of Settlement (24,159 → 24,226 of 24,576, clean build). And one
deliberate behaviour loss: gasless *re*-nomination of a revoked delegate is now
impossible, because every coordinate it could use is spent. Direct `setOrderSigner`
still works, and the right move after revoking a key is to nominate a different one.
Buying it back needs a per-delegate epoch in the permit typehash — a storage slot and a
breaking permit type, spent on making a compromised key reusable.

**The generalised question:** *is any security property here upheld only by a caller
doing two things in the right order?* If the second call can be skipped by anyone
reading the ABI rather than the docs, it is not enforcement.

---

### F24 — from-scratch re-audit of core + Permit3 (2026-08-31), four findings closed

A deliberately unbiased sweep: five independent passes over `settlement/` and
`permit3/`, each reading the source fresh against seven stated principles
(signature-gating, state integrity, solver reordering with variable spends,
efficiency, intent, fill-strategy side effects, rounding-driven drain). No Critical or
High. The reordering class came back structurally closed on the single-order path
(items walk a cursor in signed order; TAKE proceeds are measured in aggregate against
a snapshot taken *after* delivery and the callback; surplus routes only to the maker),
and the rounding architecture came back systematically maker-protective (fixed sides
telescope exactly, auctioned sides round maker-ward per fill, so fragmenting a fill is
strictly unprofitable for the solver). Four items were worth changing.

| # | finding | severity | fix |
| --- | --- | --- | --- |
| B-1 | `matchSettle` credited item proceeds only around a `TAKE`; a `MAKE` that left a token in the pool was swept to the FILLER | Low/Med | snapshot + `_creditItemProceeds` for **every** item op |
| F-2 | a balance-relative `TAKE_FOR` with an unset `floorBps` funded on any non-zero balance — one wei against a full-size borrow | Low | unset now resolves to `10_000` (full cap); leniency must be signed |
| F-3 | "an order nonce must not set bit 255" was enforced only by the SDK | Low | `Base._gateOrderPost` rejects it (`OrderNonceReserved`) |
| F-4 | strict mode was one global per-payer boolean, so hardening one token surrendered the fallback on all of them | Low | added per-token strict mode; `isStrict(user, token)` ORs the two |

**B-1 is the one that mattered, and its shape is the interesting part.** The netted
path had already been taught this exact lesson for `TAKE` — `_creditItemProceeds`
exists because proceeds arriving mid-context sit *above* the pre-context floor that
`_sweepSurplus` checks, so a mis-authored order's money reaches the solver rather than
merely being stranded the way the single-order path strands it. The fix was applied to
`TAKE` and not to `MAKE`, guarded by a comment reasoning that "a MAKE only consumes the
maker's own funds, so it needs no snapshot". That is a claim about *module* behaviour,
not a property the core enforces: a repay handed an overpayment refund to `msg.sender`,
or a deposit minting its receipt token to the caller, breaks it — and this repo ships
repay modules with dust handling. The op test also silently coupled `_stepItem` to
`_assertMatchShape`'s refusal list, so widening that list would have leaked proceeds
again. Removing the branch closes both and is *smaller* code.

**F-2 and the unset-field rule.** `floorBps == 0` selected the dangerous mode, and `0`
is what an unfilled descriptor field holds. Safety rested on the SDK defaulting to
10000 and the lens rejecting 0 — the F23 pattern exactly, one layer along: an
invariant living in the builder. It is reachable without protocol malice, because a
maker's balance is lowered by anyone who can sequence fills (filling another of the
maker's live orders in the same token is ordinary and profitable, and the *filler*
picks the order), so a solver could drain the funding token through one order and take
a near-uncollateralised borrow through the next. Orders already signed with an unset
floor now **fail closed**. The lens stopped flagging `0`, which is a change of fact
rather than policy: it is now the strictest encoding available.

**Cost.** +170 bytes of Settlement (24,220 → 24,390 of 24,576, clean build), and the
lens got 88 bytes smaller. `matchSettle` pays `2·|tokens|` extra balance reads per
`MAKE` step; the single-order hot path is untouched by B-1 and pays one `AND` for F-3.

**The generalised question, and it is F23's restated with teeth:** *when a guard is
applied to one branch of a dispatch, what argues the other branches do not need it?*
If the answer is a sentence about how the callee behaves rather than a check, it is an
assumption wearing a comment's clothes. Both B-1 and F-2 were exactly that, and both
were cheaper to fix than to keep reasoning about.

---

### F25 — 12-lens parallel re-audit of core + four lending modules (2026-09-01)

Twelve independent attacker passes over `packages/core/src` and the aave-v3 /
aave-v4 / morpho-blue / morpho-midnight modules (36 files, 10,083 lines): nine
single-specialty lenses (math-precision, access-control, economic-security,
execution-trace, invariant, periphery, first-principles, asymmetry, boundary) and
three gap-hunters that look for bugs living at the SEAM between two lenses
(numerical-gap, trust-gap, flow-gap). No Critical. Four findings fixed.

The headline is not any single finding. **Every one is a break in a discipline this
repo already established elsewhere** — two of them are missed instances of findings
already in this ledger. The failure mode is not "we did not know the rule"; it is
"the rule was applied to N-1 of N call sites".

| # | finding | severity | fix | ancestor |
| --- | --- | --- | --- | --- |
| G-1 | `MidnightLendModule.makeOnBehalf` swept `balanceOf(this)` with no floor | Med | pre-pull `floor`, sweep `bal - floor` | **missed instance of F19** |
| G-2 | Morpho auth block and the `FullFillGuard` total both read `data` offset 224 | Med | branch-scoped offsets (Full: total@224, auth@256) | new |
| G-3 | same collision in `CometTakerModule` at offset 128 | Med | branch-scoped (Full: total@128, allow@160) | variant of G-2 |
| G-4 | the `TAKE_FOR` balance floor divided before it scaled | Med | exact remainder term + `floorBps` clamp | **arithmetic hole in F16/F-2's fix** |
| G-5 | `MidnightLoopCallback.onSell` never checked it was the fill's `receiver` | Low | assert `receiver == address(this)` | new |
| G-6 | five more unfloored residual sweeps, found by variant analysis | Med | pre-pull `floor` in each | **F19 again, ×5** |
| G-7 | Aave v3's three borrow paths forwarded a nominal amount, never a measured delta | Med | `balBefore`/`received` + `require`, matching Aave v4 | **H-3 River shape** |
| G-8 | six Aave approvals to an order-supplied spender were never cleared | Low | `forceApprove(..., 0)` after each protocol call | hardening |
| G-9 | `Core._permitBatchHead` was the last `returndatacopy` into scratch under a `memory-safe-assembly` annotation | Low | copy into the calldata buffer, as `_execute` does | hardening |
| G-10 | seven comments asserted invariants the code does not hold | — | corrected (see below) | **F23 again** |

**G-1 is F19 with one call site missed.** F19 established "the module ends where it
started, not empty" and `DustHandler.disposeResidual` grew a `floor` overload whose
doc-block *is* this bug. Eleven of the twelve lenses independently found that
`MidnightLendModule` never took it — the single unfloored residual path in the
bundle, against ten sibling packages that all do it correctly (`grep floor` returns
0 hits in `MidnightModules.sol`, 3 each in the Aave/Morpho module files). **G-6 closed the same bug in five more places**, found by asking the
variant question rather than by re-auditing: `LiquityV2Modules.sol`,
`RiverModules.sol`, `TellerModules.sol`, `ListaModules.sol` (all repay-leg BOLD /
debt / principal / loan token sweeps) and `CompoundV2Modules.sol` (which forwarded
its whole **cToken** balance as a mint receipt). Six instances of one rule, in one
sweep, in packages that each had the correct pattern elsewhere in the same file —
`LiquityV2Modules.sol:274-280` and `ListaModules.sol:183-185` both use before/after
deltas a few functions away.

The regression tests are in `morpho-midnight/test/security/StrandedBalance.t.sol`
and assert the invariant directly — *the module ends where it started* — rather
than asserting a particular refund amount. Against the pre-fix code the module ends
at 0 instead of holding the stranded balance.

**G-7 is the same story in the other direction: a guard that exists in the newer
package and never got back-ported to the older one.** All three Aave **v3** borrow
paths (`AaveV3BorrowModule.takeOnBehalf`, and both leverage modules in
`AaveV3FusedModules.sol`) did `pool.borrow(...)` followed by
`safeTransfer(asset, receiver, amount)` — forwarding the *requested* amount with no
measurement. `AaveV4BorrowModule` carries the delta check and names the class
in-line as "the H-3 River shape". Every other value-out hop in the audited set had
it; these three did not. No mainnet v3 reserve is known to under-deliver, so the
precondition stays unproven — but the guard costs one `balanceOf` pair and the
alternative is an open-ended assumption about every present and future reserve.

**G-2 is the one worth reading closely, because eleven of twelve lenses got its
severity WRONG.** Four called it fail-closed (a bricked order, funds safe); one saw
the fail-open and was right. `FullFillGuard.requireFullFill` passes iff
`amount == totalAmount && totalAmount != 0`. With both readers at offset 224 the
"total" it compares against is really the Morpho auth `nonce` — and Morpho nonces
are sequential from 0, so a maker's second gasless auth carries `nonce == 1`. The
slice is `Base._prorate(total, ctx)`, whose `newFilled` comes from the FILLER's
`fillAmount`. A filler can therefore steer the slice to equal the nonce, satisfy the
guard on a **dust slice**, and force `_withdrawFull` to unwind the maker's entire
position — precisely the outcome the guard exists to prevent. The majority verdict
missed only one thing: that the slice is filler-chosen.

Scope of G-2, stated precisely, because it bounds the severity: the collision needs
`Full` mode AND an embedded auth block. Without the block, `replayMorphoAuth`
returns early on its length check and the guard reads the real total — the common
path was always correct. And `_withdrawFull` returns the excess to `onBehalfOf`, so
the harm is **forced position closure plus a bricked order at a filler-chosen
moment, not theft**.

The fix mirrors `AaveV3WithdrawModule`, which had the same two readers at offset 128
and was never vulnerable because they sit on mutually exclusive branches. Morpho
cannot copy that exactly — Aave's Exact-mode permit is only needed in one branch,
while Morpho's authorization is needed in both — so the offsets are branch-scoped
instead: `Full` carries the total at 224 and the auth at 256, `Exact` keeps the auth
at 224. Nothing on the wire breaks: the only encoding that moves is `Full` + auth,
which could never fill.

**G-4 is F16/F-2 finished.** F16 closed "empty wallet fails open"; F-2 made an unset
`floorBps` mean the full cap. Both left the floor's *arithmetic* as
`cap / 10_000 * floorBps` — divide-first, to dodge an overflow on an unconstrained
maker-signed cap. That truncates `cap` to a multiple of 10,000 before scaling, so
the threshold falls short by up to `floorBps` **raw** units. The error is absolute,
not relative, so its significance is set entirely by the token's decimals: a
2-decimal token (EURS, GUSD) puts an ordinary $50 cap at 5,000 raw units, where the
floor evaluates to **zero** and `bal != 0` is once more the only bound — F16's
original hole, reopened one layer down. Every existing floor test used a `10 ether`
cap, where the truncation is invisible; the three added in `TakeForItem.t.sol` fail
against the old expression (two reach `InsufficientAllowance`, proving the fill got
*past* an inert floor; the third panics `0x11`, the unclamped-`floorBps` overflow).

**G-5**: `ISellCallback` hands the callback a `receiver`, and the implementation
declared it as a bare unnamed `address`. Its own doc-comment asserted the
assumption — "we are `receiverIfMakerIsSeller`" — that nothing checked. Since
`offer.callback` is authored by the counterparty and `_swap` spends `sellerAssets`
out of this contract, an offer could name the contract as callback while routing
proceeds elsewhere. Bounded by whatever residue the contract holds, which is
designed to be zero — hence Low, but the check is one line.

**Method note.** The two disagreements above were both settled by reading the source
rather than by counting lenses, and the majority was wrong both times (G-2 severity;
G-4, which one lens downgraded to "dust" on an implicit 18-decimal assumption).
Convergence is good evidence for *existence* and poor evidence for *severity*.

**G-8 through G-10 are the hardening pass**, landed together because none of them
changes behaviour a caller can observe. G-8 clears the `forceApprove` in the four
Aave deposit/repay modules **and the two fused leverage modules** — six sites, not
the four the lead predicted; the variant question paid again. `pool` is decoded
from order `data` on a shared singleton, so the spender is attacker-choosable, and
while `forceApprove` writes an exact amount rather than accumulating (so there is
no direct theft), what it leaves is a standing third-party claim on any FUTURE
balance of that token — exactly what turns a later residual-stranding bug into a
theft. G-1 and G-6 were six such bugs, in sibling packages, in this same audit.
Regression tests in `aave-v3/test/unit/DanglingApproval.t.sol` use a pool that
pulls *nothing*, which is the worst case and the one that proves the clear does not
depend on the target having consumed anything.

**G-10 is the F23 pattern once more, and worth listing explicitly** because each
comment was load-bearing for someone:

| where | claimed | actual |
| --- | --- | --- |
| `UnorderedNonces` | the nonce-namespace rule is "ASSERTED in `permitBatch` / `permitTake`" | no on-chain assertion exists; the named "constructors" are the **SDK builders** |
| `Structs.sol` | `params` bits `[160:256)` free | `baselinePriorityFeeWei` occupies `[160:208)` — and this map is where a new field gets placed from |
| `OrderGates.anchorTotal` | `0` "leaves the leg uncapped" | `Proportional.resolve` reverts `ProportionalNeedsCap`; a `0` makes every fill revert |
| `Core.fillUpTo` | "time moves the bump filler-ward" | true only on a rising curve; a descending segment is a fourth maker-ward mover, and the advice steered fillers into skipping the floor that protects them |
| `MidnightLoopCallback` | a thin `minCollateralOut` "simply fails Midnight's solvency check" | the check is against the WHOLE position, so a borrower with headroom can be sandwiched for it while the fill succeeds |
| Aave v3 / v4 withdraw byte maps | no `totalAmount` field | `FullFillGuard` requires one and fails closed without it — a maker encoding `Full` from those maps signed an unfillable order |

The last row is the one with a live consequence: the maps are what an integrator
encodes from, and the SDK ships no module-`data` encoder at all (`grep` for
`totalAmount` / `BalanceMode` across `packages/sdk/src/` returns nothing), so those
headers are the only specification there is.


## Re-audit sweep — the generalised questions from F13–F15

F13–F15 are three instances of two reusable mistakes. Sweep these questions rather
than the specific functions.

**1. "Authorised once" is not "authorised by what".** Any cache, skip or fast path
that remembers *that* a check passed, without remembering *which* credential passed
it, is F13. The credential that can be **withdrawn** is the one that matters: a
signature cannot be, an on-chain record and an EIP-1271 answer can. Where to look:

- every early `return` in `Signatures._verifySignature` and anything reading `filled`
  as an authorisation proxy;
- the **batch paths** — `batchFill`, `matchSettle`, `_openGated` — which take a `sigs[]`
  array per order. Does each element go through the same branch selection, and can a
  caller mix an empty and non-empty `sig` for the same order across calls?
- the 7683 entrypoints (`open`/`openFor`), which authorise by a different route than
  `fill` — cf. [F11](#f11--open-announced-an-erc-7683-order-without-the-signature-check-openfor-performs);
- delegated signers (`orderSignerExpiry`): an expiring delegate is a *withdrawable*
  credential, so ask whether expiry binds mid-order or is skipped after a first fill;
- contract signers generally — the file already flags that a 1271 wallet turning
  `false` no longer blocks a part-filled order. That is documented and accepted for
  signatures; confirm no *other* revocable credential inherits the same skip silently.

**2. "Refunded ⇒ harmless" ignores non-refundable side effects.** F15's real lesson:
when a step over-consumes and a later phase gives it back, ask what was spent that the
refund does **not** restore. Allowance is the obvious one; also nonces, one-shot
permits, rate-limit budgets, expiries, and any ledger keyed off cumulative spend.
Where to look:

- every repeated-step tolerance in `matchSettle`. `DELIVER` and `ITEM` have
  exactly-once guards; `PULL` did not. Re-derive the argument for any step added later,
  and state it in terms of *authority consumed*, not tokens moved.
- anywhere the code says a duplicate/surplus is "returned to the maker" — that phrase
  is about assets, and is not an argument about allowances;
- `Permit3TransferLib.transferFromWithFallback`: a failed Permit3 leg that falls back
  to a direct approval spends the *approval* instead — check which budget each path
  draws down;
- the `uint160.max` infinite-allowance sentinel is a **masking** condition. Any test
  that grants max allowance cannot observe this class of bug; assert against a finite
  allowance when the property under test is "how much authority did this consume".

---

## Signature validation — the published corpus vs. our position

Compiled 2026-08-27 after [F13](#f13--a-revoked-on-chain-order-approval-was-bypassed-by-any-non-empty-signature),
because two of the three findings in that round were in signature handling and the
area clearly deserved a systematic pass rather than another one-off. Every row was
checked against the code; the ones that need a behavioural guarantee are pinned in
`packages/core/test/swaps/SignatureEdgeCases.t.sol`.

| # | Class | Our exposure |
|---|---|---|
| S1 | **ECDSA malleability** — `s` and `N − s` recover the same signer (EIP-2), and accepting BOTH the 65-byte and 64-byte EIP-2098 forms compounds it (the OpenZeppelin 4.7.3 advisory) | **Present by construction, benign.** `SignatureVerification.tryRecoverSigner` applies no lower-half-`s` check and accepts both lengths, so one authorisation has **four** valid byte encodings. Not exploitable: on-chain replay is bound by `filled[orderHash]`, and the off-chain book is a map keyed by `orderHash`, never by signature. Pinned by `test_malleability_fourEncodings_stillOneFill`. **The standing hazard is any NEW consumer that treats a signature as an identity** — a dedup cache, a "seen" set, a rate limiter keyed on `keccak256(sig)`. |
| S2 | **Cross-account EIP-1271 replay** (ERC-7739) — a digest that does not name the account is replayable across accounts sharing a validation rule | **Order & settlement paths immune via the WITNESS; standalone permit entrypoints carry raw Permit2's residual.** See the scoped assessment below — the earlier draft of this row overstated it as an open gap on the settlement path. Short version: none of Permit3's permit type strings bind an owner (owner is a verified argument, spender is bound — the exact Permit2 design), so at the RAW permit layer the ERC-7739 exposure is real for naive 1271 wallets. BUT the settlement path signs a `PermitBatchWitness` whose witness is the **order hash**, and {Order} binds `address maker`, so the digest is account-specific and a permit for wallet A cannot be replayed to a sibling wallet B. That is precisely the app-side binding Permit2 recommends (put the account in your witness), and we already do it. Pinned by `CrossAccountReplay.t.sol` (settlement path) and `test_crossAccountReplay_ordersBindTheMaker` (plain orders). |
| S3 | **Domain separator vs. chain id** — a cached separator survives a fork and enables cross-chain replay | **Clean.** `EIP712.DOMAIN_SEPARATOR()` serves the cached value only while `block.chainid` matches construction, else recomputes. Pinned by `test_domainSeparator_followsChainId`. |
| S4 | **Zero-address recovery** — `ecrecover` returns `address(0)` on failure, and a comparison without a zero check promotes every malformed signature to valid | **Clean.** `verify` requires `signer != address(0)` before matching; `setOrderSigner` separately rejects a zero delegate for the same reason. Pinned by `test_reject_invalidV` / `test_reject_zeroComponents`. |
| S5 | **Length-dispatch confusion** — deciding what a signature IS from its length | **Present and documented.** The bulk (Merkle) envelope is detected by shape (`length ≥ 98`, `(length − 66) % 32 == 0`, trailing `0xB0`). `Signatures` already argues why this is a liveness edge and never a bypass: any signature matching the predicate is re-read against a root the maker never signed and reverts. Wallets with attacker-influenceable trailing bytes are the residual exposure. |
| S6 | **EIP-1271 callee misbehaviour** — wrong magic value, revert, empty return | **Clean.** Pinned by the three `test_1271_*` cases. |
| S7 | **"Authorised once" caching** | **Was broken — [F13](#f13--a-revoked-on-chain-order-approval-was-bypassed-by-any-non-empty-signature).** See the sweep above for the generalised question. |

### S2 in full — where the account IS bound, and where it is not

Grounded in the code 2026-08-27, correcting an earlier overstatement.

**What Permit2 does (and we inherit verbatim).** None of Permit2's — or Permit3's —
signed permit structs contain an owner/`from` field. The owner is a function
argument the signature is *verified against*; what the struct binds is the
**spender** (`Permit3Hash.hash(permit, msg.sender)`), so a permit can only be
consumed by its intended spender. Cross-account replay for naive 1271 wallets is a
known, accepted residual whose defence Permit2 delegates two ways: **nonces**
(intra-account) and either **the wallet** (ERC-7739 defensive rehashing) or **the
app, via the witness** — `permitWitnessTransferFrom` exists so an app can commit the
account into the digest itself.

**The settlement path: closed, the Permit2-recommended way.** `_fillWithPermitCore`
calls `permitBatchWithWitnessIfNeeded(order.maker, batch, orderHash, …)`. The witness
is `orderHash`, and {Order} binds `address maker`, so the signed digest is
account-specific: reaching a sibling wallet B would require an order with
`maker == B`, a different witness, a different digest — one only B's owner could
produce. A permit signed for A therefore cannot drain B. The witness is doing the
exact job ERC-7739 asks an app to do, and `CrossAccountReplay.t.sol` pins it with a
vacuity guard proving the wallets really are the naive/replayable shape.

**The residual: standalone permit entrypoints.** Calling
`SignatureTransfer.permitTransferFrom` / `permitWitnessTransferFrom` or
`SignedPermits.permitBatchWithWitness` DIRECTLY — off the settlement path — passes an
attacker-choosable `owner`, and the non-witness variant commits no account at all.
That is identically Permit2's residual, further bounded by spender-binding: a drain
needs a **naive 1271 wallet** AND **multiple same-owner accounts** AND a
**malicious/compromised spender** all at once. Our stance matches Permit2's: this is
delegated to the wallet (ERC-7739); Safes and any wallet that rehashes with its own
domain are immune. Binding the account into the standalone structs would CLOSE it but
is a *divergence* from Permit2 — a breaking wire change, new golden hashes, and
hot-path hashing growth against a ~50-byte EIP-170 budget — worth it only if
naive-1271 makers are expected on the standalone entrypoints specifically.

**What S1 and S2 have in common, and the rule to carry forward:** neither is a bug in
the verifier. Both are cases where *the digest does not commit to something the
security argument depends on* — the encoding in S1, the account in S2. When adding
any new signed message, write down what the digest commits to and check that against
what the code then assumes. `Order` gets this right by naming `maker`; the Permit3
batch types do not, and inherit Permit2's posture along with its code.

**Sources.** [ERC-7739: Readable Typed Signatures for Smart Accounts](https://eips.ethereum.org/EIPS/eip-7739) ·
[OpenZeppelin ECDSA / Cryptography docs](https://docs.openzeppelin.com/contracts/5.x/api/utils/cryptography) ·
[Zellic — "The ecrecover function allows malleable signatures"](https://reports.zellic.io/publications/orderly-network/findings/medium-signature-the-ecrecover-function-allows-malleable-signatures) ·
[Smart Contract Security Field Guide — signature attacks](https://scsfg.io/hackers/signature-attacks/) ·
[Zokyo — Signature Malleability](https://zokyo.io/blog/signature-malleability/) ·
[Dedaub — 0x Settler audit](https://dedaub.com/audits/0x/0x-settler-crosschainreceiverfactory-june-10-2025/) ·
[Auditor's Digest — the risks of EIP-712](https://medium.com/@chinmayf/auditors-digest-the-risks-of-eip712-5a0fc57e3837) ·
[*One Signature, Multiple Payments* (arXiv 2511.09134)](https://arxiv.org/pdf/2511.09134) ·
[*Demystifying and Detecting Cryptographic Defects* (arXiv 2408.04939)](https://arxiv.org/pdf/2408.04939)

---

## Second corpus — v4 / EVK / RFQ (2026-08-27)

The original C1–C15 taxonomy was built from 1inch, 0x, CoW, UniswapX and Velora.
This round adds **Uniswap v4**, **Euler v2 (EVC/EVK)**, **Native** and **Bebop**,
chosen because the first two attack the parts of our design the first corpus never
covered: v4's flash accounting is our netted `matchSettle` credit ledger, and the
EVC's batch-with-deferred-checks is our `MatchPlan` schedule. CoW and Velora were
already in [Sources](#sources) and are not re-derived here.

**Bebop publishes nine audits**, indexed at
[docs.bebop.xyz/audits](https://docs.bebop.xyz/audits#security-and-audits) — a
correction to an earlier draft of this section, which recorded "no public audit
report" because a keyword search surfaced only their docs. The lesson is worth
keeping: **a search that finds nothing is not evidence of nothing; check the
protocol's own docs for an audit index before recording a negative.** The MixBytes
report is markdown and is summarised as B1–B4 below; the other eight are PDFs that do
not survive automated fetch.

**Native** has one ([Symbolic Software NAT-001](https://symbolic.software/pdf/nat-001.pdf));
its published finding (NAT-001-001, immediately-overwritten variables) is a
code-quality issue with no analogue here, and its architecture (AquaVault treasury +
`NativePool` verifying maker quote signatures) is the same PMM-quote shape our
`CosignedQuotePriceModule` already implements.

| # | Class | Source | Our position |
|---|---|---|---|
| V1 | **Accounting bugs that still satisfy the settlement invariant.** The PoolManager only checks that a session's currency deltas resolve to zero; it never validates a hook's *internal* accounting, so a wrong sign, a rounding step or a mixed balance bucket leaks value while every transaction stays "valid" | [Trail of Bits — v4 hooks](https://blog.trailofbits.com/2026/07/30/building-secure-uniswap-v4-hooks/) #3; Bunni drained through 44 individually-valid txs | **This is precisely [F15](#f15--a-duplicate-pull-step-burned-maker-allowance-without-extra-fill-progress).** `BatchNotWhole` proves the POOL nets and `LegUnfunded` proves each leg reached its `owed` — neither says anything about how `owed` was rounded, nor about authority consumed on the way. Rounding direction is now pinned by `RoundingDirection.t.sol`: slicing an order must never favour the solver, fixed inputs are exact under any slicing (cumulative-difference form), outputs round toward the maker. |
| V2 | **Unrestricted hook callbacks / missing caller checks** — the Cork exploit (~$12M) | [ToB](https://blog.trailofbits.com/2026/07/30/building-secure-uniswap-v4-hooks/) #1 | **Clean, and load-bearing.** Every module entrypoint gates on its caller as its first statement: `msg.sender != address(permit3)` for `ITakerModule`, `msg.sender != settlement` for `IMakerModule`. Verified across all ten entrypoints in the aave-v3/v4 and morpho-blue packages during the 2026-08 module audit. |
| V3 | **Untrusted key/route selection** — attacker-created pools let untrusted `PoolKey` data reach logic that treats it as trusted | [ToB](https://blog.trailofbits.com/2026/07/30/building-secure-uniswap-v4-hooks/) #2 | **Structurally absent.** Our equivalent of a `PoolKey` is the maker-SIGNED order: modules, validators and the pricing module are all fields inside the EIP-712 hash, so a filler cannot substitute a route the maker did not sign. The one attacker-supplied channel is `takerData`, which is documented as adversarial and must be verified by whoever reads it. |
| V4 | **Logic in the wrong callback / stale cross-callback state** — values cached before an external call are stale after it | [ToB](https://blog.trailofbits.com/2026/07/30/building-secure-uniswap-v4-hooks/) #4, #7 | **Watch item.** `ctx.bump` is pinned once at `_openFill` and reused for every leg — correct, and deliberately so — but it means any future price input that CAN move mid-fill must not be read through `ctx`. `matchSettle` measures item proceeds as balance deltas around each module call rather than caching, which is the right shape. |
| E1 | **Deferred checks that can be skipped or forgiven.** The EVC lets a batch break invariants mid-flight so long as everything passes at the end; the danger is a path where the end-check does not run | [OpenZeppelin — EVK](https://www.openzeppelin.com/news/euler-vault-kit-evk-audit), [Electisec](https://reports.electisec.com/2024-03-EulerV2) | **Clean by construction.** `_matchFlush` is CONTRACT-owned and loops every order: completeness (`PlanIncomplete`), `_matchReconcileInputs`, then `_runInvariants`. The solver's schedule cannot skip it, reorder it, or address an order out of it — unlike the EVC, where which vaults get checked depends on what the batch touched. |
| E2 | **Reentrancy during an in-batch transfer**, where checks are forgiven before control returns; mitigated in the EVC by making `checkAccountStatus` a STATICCALL so a share transfer cannot execute attacker code | [OpenZeppelin — EVK](https://www.openzeppelin.com/news/euler-vault-kit-evk-audit) (low) | **Same mitigation, independently arrived at.** Validators, invariants and price modules are all `staticcall`-ed with a one-word return cap, so none can reenter or bomb memory; `matchSettle` is additionally `nonReentrant`. |
| E3 | **Rounding in loop/self-referential ops** — "expecting 10 units, receiving 11" | [OpenZeppelin — EVK](https://www.openzeppelin.com/news/euler-vault-kit-evk-audit) (low) | Covered by the V1 row's tests for the fill path. |

### Bebop (MixBytes, Jul 2023) — 1 High, 4 Medium, 1 Low

Their findings land almost entirely on the signature surface we hardened this week,
which is a useful independent check on that work.

Read via local `pdftotext` extraction after WebFetch failed on the binaries — the
same trick works for every PDF in the index, so "PDF" is not a reason to leave a
report unread.

| # | Their finding | Our position |
|---|---|---|
| B1 | **HIGH — EIP-712 `DOMAIN_SEPARATOR` replay.** Chain id cached in an immutable instead of read per call, so signatures stay valid on a forked network | **Clean, and now pinned.** `EIP712.DOMAIN_SEPARATOR()` serves the cached value only while `block.chainid` matches construction and recomputes otherwise — the Permit2 behaviour, inherited deliberately. `test_domainSeparator_followsChainId` asserts it. This is [S3](#signature-validation--the-published-corpus-vs-our-position) confirmed by an external High. |
| B2 | **MEDIUM — unsafe `ecrecover`: the return value used as a MAPPING INDEX rather than only for comparison** | **Clean, guarded twice.** This is the sharper form of the zero-address class, and it applies to us: `Signatures._verifySignature` indexes `orderSignerExpiry[expected][signer]` for maker-delegated signing. Guarded by `signer != address(0)` *before* the lookup, and independently by `setOrderSigner` refusing a zero delegate so the slot can never be written. Pinned by `test_zeroRecovery_cannotAuthorizeViaDelegateRegistry`, deliberately run with a delegation ACTIVE — with no delegate the branch is unreachable and the test would pass whether the guard existed or not. |
| B3 | **MEDIUM — nonce truncation.** A `uint256` nonce cast to `uint64`, silently discarding high bits and colliding | **Structurally absent.** `NonceManager` splits the full `uint256` as `nonce >> 8` (word) and `nonce & 0xff` (bit); nothing is narrowed, so two distinct nonces cannot collide. |
| B4 | **MEDIUM — excess `msg.value` not refunded**, locking user funds | **Worth a look when native-input lands.** Not applicable to the current core: makers never send native value into a fill (see the native-asset assessment — maker-native-input needs escrow and was kept out of core). Re-check this row if that changes. |

### Bebop (Cyfrin, Router v2.0, Jun 2026) — 1 High, 2 Medium, 18 Low

The richest report in the index, and the one whose High is closest to our own shape.

| # | Their finding | Our position |
|---|---|---|
| C-H1 | **HIGH — the signed order authorises the input pull, but UNSIGNED relayer calldata decides the realised output.** The user's digest covered the order fields, not `bebopPmmCalldata`; validation checked token identity and non-zero amounts but not that the delivered amount matched the quote, that the receiver was the router, or that delivery was ERC-20 rather than native. With `limitAmount == 0` there was no output floor either. Three vectors: dust under-fill, receiver redirect, native-delivery accounting bypass — all total loss of the swap | **Same shape, structurally bounded.** Untrusted input reaches our realised price too: a cosigned-quote module derives its answer from filler-supplied `takerData`. The defence is not a check but a clamp — `DutchAuction.priceBump` forces the answer into `[0, BPS]` and maps it through the maker's OWN signed endpoints, so the worst a hostile module achieves is the maker's floor, a price they already declared acceptable. **Bebop's exploitable case was precisely the one with no floor.** Pinned by `HostilePriceModule.t.sol`, including a fuzz over every `uint256` answer. The redirect half is pinned by `FillUpTo.t.sol` — output-leg recipients live inside the signed `legsOut` blob. |
| C-L02 | **LOW — absolute balances.** `_executeSwapCore` reads the router's whole token balance, so tokens already held from an under-consumed fill, hook overproduction or a direct transfer get folded into the current swap | **Clean — this is [C15](#c15--the-settlers-balance-treated-as-a-shared-pot).** `matchSettle` measures against `st.beforeBal[t]` snapshots and `_sweepSurplus` floors every touched token at its pre-context balance, so a donated balance is unreachable. `_stepPresend` says so explicitly. |
| C-L05 | **LOW — dust-fill nonce burn.** `exactAmount` is a function argument, not a signed field, so a relayer could partial-fill for dust and permanently consume the user's nonce. *Recommended: include a minimum fill size in the signed order* | **Already implemented, twice.** `Order.minFillAnchor` is exactly that maker-signed floor ({FillTooSmall}), and it gates the CLAMPED delta on `fillUpTo` too. Separately, a fill-once order (`useNonceInvalidator`) rejects partials outright with {FillOnceMustBeFull} — for the identical reason, since there the nonce IS the progress counter. |
| C-M1 / C-M2 | Leg scaling on maker refunds; relayer-supplied values stranding user input | Our refund path is fixed by construction: `_matchReconcileInputs` returns any surplus to the **maker**, never the solver, and the amount is the `owed` resolved at open rather than a recomputation. |

### Bebop — Decurity (JAM, Nov 2023) and Nethermind (Dec 2024)

Decurity's JAM review (their batch settlement, the closest external analogue to
`matchSettle` after the EVC) reports one Medium — a taker-loss path in
`JamBalanceManager` — plus two acknowledged Lows on signing and solver
observability. Nethermind's single point of attention is more interesting to us:

**Nethermind 7.1 — nonces shared between JamSettlement orders and Permit2.** One
nonce field feeds three independent invalidation systems (regular orders, limit
orders, Permit2), so off-chain allocation must satisfy all three at once and an
unrelated protocol consuming a Permit2 nonce can brick an order.

**Our position: the same sharing exists, but scoped and documented.** Permit3 shares
ONE bitmap per owner across both signed flows — deliberately, so
`invalidateUnorderedNonces` is a complete kill switch whichever flow signed, with the
stated cost that allocation is per-owner rather than per-message-type
({UnorderedNonces}). Crucially the ORDER nonce space ({NonceManager}) is **separate**
from the Permit3 space, so we have two clearly-bounded systems rather than three
implicitly coupled ones. Worth re-reading that header if a third signed flow is added.

### Bebop — Offside Labs (RFQ, Dec 2025)

**Solana**, not EVM (PDAs, signer seeds), so most of it does not transfer. The one
portable finding is 4.2 (Low, fixed): `output_amount * filled_taker_amount /
input_amount` overflowed the intermediate product on large quotes, causing a DoS.
Our pro-rata slice math has the same shape (`delta * tick / anchor`), but in checked
Solidity 0.8 an overflow reverts rather than wrapping, and reaching it needs
maker-signed amounts around 1e38 — a self-inflicted DoS on that maker's own order,
not a lever against anyone else. Noted, not actioned.

**The thread joining V1 and E1**, and the question to carry into the next batching
feature: *a wholeness check is not an accounting check.* Ours prove the pool nets and
every leg was funded. They do not prove that the per-order arithmetic was right, that
no authority was over-consumed reaching it, or that rounding went the intended way —
each of those needs its own assertion. F15 slipped through precisely because the
wholeness check passed.

---

## Third corpus — modular signature-validating order protocols (2026-08-27)

A deliberate sweep rather than an opportunistic one: every EVM protocol that (a)
settles signed orders and (b) is modular in the way we are — pluggable validators,
hooks, or an allowance hub. Ordered by how closely the architecture maps onto ours.

### Read this round

| Protocol | Why it maps | What it gave us |
|---|---|---|
| **Seaport** (OpenSea) — [Code4rena](https://code4rena.com/reports/2022-05-opensea-seaport), OpenZeppelin + Trail of Bits (no majors) | The closest architectural sibling we had not read: EIP-712 **bulk/Merkle signatures**, **zones** (≈ our validators), **conduits** (≈ Permit3), partial fills, counter-based cancellation | **[C4 #168](https://github.com/code-423n4/2022-05-opensea-seaport-findings/issues/168) — an INTERNAL NODE passed off as a leaf.** Criteria trees took the leaf as a caller-supplied `tokenId` with no check that it was a leaf, so a fulfiller could submit an intermediate hash and trade an unlisted NFT. **We are structurally immune and it is now pinned**: `_foldProof(orderHash, …)` derives the leaf from the ORDER BEING FILLED, so a filler controls only the proof and has no field in which to submit a node; the root is additionally wrapped in its own `ORDER_ROOT_TYPEHASH`. See `test_bulkSignature_internalNodeCannotBeUsedAsALeaf`. |
| **ERC-4337 EntryPoint** — [OpenZeppelin](https://blog.openzeppelin.com/eth-foundation-account-abstraction-audit), [incremental](https://blog.openzeppelin.com/eip-4337-ethereum-account-abstraction-incremental-audit) | Signature validation inside a **batched** execution, plus modular validation and aggregators | Their finding: `validateUserOp` must RETURN `SIG_VALIDATION_FAILED` rather than revert, because a reverting validation inside a bundle takes the whole bundle down. **Our answer is different but sound**: `batchFill` wraps each fill in `try/catch` via `this.fillSelf`, so a bad signature yields `success[i] = false` instead of DoSing the batch, with `revertIfIncomplete` as the caller's explicit all-or-nothing opt-in. Containment at the batch boundary generalises better than a return-code convention, because it works for arbitrary sub-call failures, not just signatures. |
| **Across / ERC-7683** — [OpenZeppelin](https://www.openzeppelin.com/news/across-v3-incremental-audit), [deposit flow](https://www.openzeppelin.com/news/deposit-flow-audit) | We ship `OriginSettler7683` / `DestinationSettler7683` | A LOW: signed executions lacking single-use replay protection, repeatable until their deadline against a clone that later receives funds. Compare [F11](#f11--open-announced-an-erc-7683-order-without-the-signature-check-openfor-performs) — our own 7683 finding was in the same family (an entrypoint announcing without the check its sibling performs). They also flag **no unit tests for the 7683 depositor contracts**; ours are covered by `Erc7683.t.sol`. |
| **Balancer V2** — the 3 Nov 2025 exploit ([Trail of Bits](https://blog.trailofbits.com/2025/11/07/balancer-hack-analysis-and-guidance-for-the-defi-ecosystem/), [Check Point](https://research.checkpoint.com/2025/how-an-attacker-drained-128m-from-balancer-through-rounding-error-exploitation/), [OpenZeppelin](https://www.openzeppelin.com/news/understanding-the-balancer-v2-exploit)) | Not an order protocol, included because it is **this taxonomy's largest realised loss** | **~$128M, and the single most instructive item in this document.** Root cause: **asymmetric rounding between the two directions of one conversion** (upscale rounded down, downscale up/down), **amplified by batch atomicity** — 65 tuned micro-swaps in a single `batchSwap` compounded wei-level truncations into a deflated invariant. Each swap was individually negligible and individually valid. It had been audited by Trail of Bits, Spearbit AND Certora. See the lesson below. |

### Surveyed, audited, NOT yet read — queued with rationale

Recorded so the next round starts here instead of re-deriving the list. None is
believed urgent; each note says what would make it worth the time.

| Protocol | Audits | Why it might matter |
|---|---|---|
| **Aori** — [Zellic (v0.3.1)](https://reports.zellic.io/publications/aori-031-upgrade/sections/component-aori-contract-version-031-upgrade-aori-diff/), [Dedaub](https://dedaub.com/audits/aori/aori-margin-prime-may-08-2023/) | **Highest-value of the queue.** An RFQ order book whose deposits and fills support **hooks** — external calls during the fill, i.e. our `Item`/module design. Read before the next module-surface change. |
| **Valantis** — [Statemind (Core + HOT AMM)](https://docs.valantis.xyz/resources/audits), [Sherlock (Arrakis SOT)](https://github.com/sherlock-protocol/sherlock-reports) | Modular DEX: several AMM modules against one pool, with an **RFQ module** built in. The closest external analogue to our pluggable-module architecture. |
| **Balancer v3** — Trail of Bits, Spearbit, Certora | Modular **hooks + vault accounting**. Given V2's fate, the v3 hook/accounting reviews are worth reading specifically for how they bound rounding in composite ops. |
| **Clipper** — Quantstamp, Solidified, Immunefi | RFQ/PMM quote signatures. Smaller surface; low priority. |
| **Hashflow** — [Cyberscope](https://www.cyberscope.io/audits/coin-hashflow) | Signed RFQ quotes. Vendor-tier audit; low priority. |
| **Safe** | Not an order protocol, but the 1271 wallet our contract-signer path must interoperate with — relevant if S2 (owner-binding) is ever revisited. |

### The lesson from Balancer, and what we did about it

Three of the best firms in the industry reviewed that code and the bug still shipped,
because **the defect was not in any one operation** — every swap was individually
correct and individually valid. It existed only in the *composition*: a rounding
asymmetry that compounded under batching.

That is the same structure as [V1](#second-corpus--v4--evk--rfq-2026-08-27) (Bunni,
44 valid transactions) and as our own [F15](#f15--a-duplicate-pull-step-burned-maker-allowance-without-extra-fill-progress)
(a duplicate step that satisfied every wholeness check). Three independent instances
of one shape is a pattern, not a coincidence:

> **A per-operation review cannot find a composition bug. State the invariant over
> the SEQUENCE and test it directly.**

Concretely, `RoundingDirection.t.sol` now asserts the sequence-level property rather
than any single computation: slicing an order into N fills must never favour the
solver. Balancer's specific twist — *asymmetry between the two directions of the same
conversion* — is why that file now covers the **BUY** side as well as SELL: BUY
inverts which leg is anchored and which is auctioned, so it runs a different branch
of {Pricing}, and testing one direction proves nothing about the other.

---

## Fourth pass — the forked source's own audit (Permit2, 2026-08-27)

The one we should have read FIRST. `Permit3` ports Permit2's `SignatureVerification`,
`EIP712`, and the unordered-nonce bitmap close to verbatim (each file says so in its
header), so [ChainSecurity's Permit2 audit](https://old.chainsecurity.com/wp-content/uploads/2022/11/ChainSecurity_Uniswap_Permit2_audit.pdf)
is an audit of OUR code's ancestor. Read via `pdftotext`. Every transferable finding
turned out already handled and already pinned — the value of the pass is the
*confirmation*, and one strong external precedent for a row I had rated on my own.

| # | ChainSecurity finding | Our position |
|---|---|---|
| **6.1** | **HIGH — `Permit2Lib` argument casting.** A `uint256 amount` silently cast to `uint160` for the Permit2 leg: `uint160(2**170) == 0`, the call "succeeds" moving nothing, and the caller believes the transfer happened. Fixed in Permit2 with a SafeCast that reverts | **Clean, and handled more gracefully than the upstream fix.** `Permit3TransferLib.transferFromWithFallback` does NOT cast — it GATES: `amount <= type(uint160).max` uses the Permit3 leg with the in-range value, and anything larger skips Permit3 entirely (`ok` stays false) and falls through to a full-`uint256` direct `safeTransferFrom`. No truncation path exists. Pinned by `test_amountExceedsUint160_skipsPermit3`, which asserts the recipient receives the FULL `2**160` amount — the value assertion, not just the skip. A future "optimisation" to `uint160(amount)` would reintroduce 6.1 and break that test. |
| **7.1** | **NOTE — nonce overflow via unchecked increment** of the sequential allowance nonce (`uint16`/`uint48`) | **Structurally absent.** Permit3 REMOVED the sequential allowance nonce (`AllowanceTransfer.sol:38`): grants zero the field instead of incrementing it, and replay is stopped by the unordered bitmap alone. `invalidateNonces` / `ExcessiveInvalidation` have no analogue, so neither does the overflow. |
| **7.2** | **NOTE — signature malleability if misused.** The library accepts EIP-2098 compact AND 65-byte forms and performs no Appendix-F low-`s` check (`0 < s < n/2+1`); *"any reuse of the SignatureVerification library must be done with this attack in mind. OpenZeppelin had such an incident before."* Permit2 is safe only because it binds replay to NONCES, not to the signature | **This is the direct external precedent for [S1](#signature-validation--the-published-corpus-vs-our-position).** It describes our forked library exactly — the missing low-`s` check is inherited, not introduced. We are safe for the same structural reason Permit2 is: order replay binds to `filled[orderHash]` and the book keys by `orderHash`, never by signature bytes. `SignatureEdgeCases.t.sol`'s four-encoding test is the assertion. Having the SOURCE auditor independently name the exact hazard, and the exact reason it is benign, is the strongest confirmation S1 could get. |
| **7.3** | **NOTE — `invalidateUnorderedNonces` accepts `wordPos` up to `uint256.max`, but a usable nonce only reaches `uint248.max`**, so one can invalidate nonces that can never be used | **Same note applies, same harmless verdict.** Our `nonce >> 8` word derivation caps a usable word at `2**248 - 1`, while `invalidateUnorderedNonces(wordPos, mask)` takes a full `uint256` word. Self-invalidation only (keyed by `msg.sender`), so the worst case is a user wasting gas on their own unreachable words. Inherited verbatim; recorded so it is not "rediscovered" as a finding. |
| **5.1** | **MEDIUM (risk-accepted) — approval race**, the ERC-20 `approve` front-run, with `lockdown` offered as the batch mitigation | Same posture, already in our ledger: this is the [C12](#c12--revocation-that-does-not-revoke) / [F1](#f1--revoking-permit3-is-not-a-kill-switch-on-its-own) family, and Permit3 carries the same `lockdown` / `lockdownAll` escape hatch (`permit3-audit-fixes` memory). |
| **6.2** | LOW — `Permit2Lib` reads `DOMAIN_SEPARATOR()` via `CALL` not `STATICCALL`, allowing reentrancy | N/A — we have no `Permit2Lib` analogue; `EIP712` exposes `DOMAIN_SEPARATOR()` as `view` and `_hashTypedData` reads it internally. |

**The takeaway for the process, not just the code:** when a component is forked, its
upstream audit is the highest-value document in the corpus and should be read before
any peer protocol — it audits *your* logic, not an analogue. Reading it last was the
mistake; the finding that it changed nothing is the good outcome.

### Queue additions from this pass

| Protocol | Audits | Note |
|---|---|---|
| **deBridge DLN** | [Halborn ×9](https://github.com/debridge-finance/debridge-security) (DLN Taker, EVM Bridge, CrosschainForwarder Allowances, …) | Intent-settlement with a **taker/filler** role like our solver, and a *CrosschainForwarder Allowances* audit specifically — the allowance-hub surface. Highest-value unread in the intent category. |
| **0x Settler** | [Dedaub](https://dedaub.com/audits/0x/0x-settler-crosschainreceiverfactory-june-10-2025/) (already in Sources) | The closest analogue to our `fillUpTo` aggregator entry; read its findings when that path next changes. |
| **Aggregator routers** (1inch AggregationRouterV6, KyberSwap MetaAggregationRouter, Odos) | various | Permissionless-router allowance-drain class ([C1](#c1--arbitrary-call-made-from-the-settlers-own-identity)); only worth the time if we add a generic-call surface beyond the current gated modules. |

---

---

## Checked and clean

Things worth re-checking whenever the relevant code moves.

- **Selector collision on module dispatch.** Settlement calls a maker-chosen address
  directly for MAKE and SETTLE while being a universal Permit3 spender — the C1
  shape, contained only because the selector is fixed. Re-run the scan if either
  interface signature changes:
  ```
  cast sig "makeOnBehalf(address,uint256,bytes)"                        # 0xb5d2b67f
  cast sig "settle(address,address,uint256,bytes)"                      # 0x99bb07b8
  cast sig "takeOnBehalf(address,uint256,address,bytes)"                # 0xddbb4b79
  cast sig "takeForOnBehalf(address,uint256,uint256,address,bytes)"     # 0xec0eb1a9
  ```
  None may collide with anything on Permit3 (the last two are dispatched *by*
  Permit3 to a maker-chosen module, so Permit3 calling itself is the shape to
  exclude). Last re-run 2026-08-28, clean.
- **`forAmount` is ungated in `Permit3.takeFor`, by design.** The taker book bounds
  what LEAVES a position; the composite's funding leg moves value **IN** and is
  bounded instead by the maker's ordinary Permit3 **token allowance to the module** —
  the same gate a `MAKE` item's funding leg passes. The chain that makes this safe is
  worth stating because each link is load-bearing: the funding descriptor is the head
  of `data`, `data` is maker-signed, and `ref = keccak256(data)` keys the taker
  allowance — so a filler can move neither the token nor the amount, and the pull is
  capped independently. Verified end-to-end against
  `AaveV3TakeForLeverageModule`, which pulls exactly
  `permit3.transferFrom(onBehalfOf, …, collateralAsset, forAmount)`. **This is a rule
  for new composite modules:** the funding pull must go through the maker's token
  allowance, never through an allowance the module holds on someone else.
- **Any narrowing of the `matchSettle` item-op guard.** `_assertMatchShape` refuses
  `op >= SETTLE`, which bundles three different reasons under one compare. `TAKE_FOR`
  is the one to be careful with: its LITERAL and LEG-reference funding forms are
  schedule-independent and could in principle be allowed, but its **BALANCE** form
  must not be — see F16's CoW re-check above. A narrowing must therefore discriminate
  by descriptor *form*, which means decoding `data` inside the guard. Do not relax
  this on the "it is only an ordering constraint" reading.
- **The witness-typehash overloads accept an arbitrary `bytes32`.**
  `permitBatchWithWitnessHashIfNeeded` and `permitTakeWithWitnessHash` take the
  already-concatenated typehash where the string forms derive it. No new power: the
  caller already chose the typehash indirectly through the string, and a wrong hash
  simply fails signature recovery. The reachable digest set does widen to typehashes
  that no valid EIP-712 type string produces — exploiting that would need a
  pre-existing user signature over an identically-encoded struct under **Permit3's own
  domain separator**, and Permit3's two witness structs differ in arity
  (`PermitTake` 8 words, `PermitBatch` 6), so neither can be replayed as the other.
  Accepted; re-check if a third witness struct is added with a matching layout.
- **SETTLE modules pulling from the filler.** If a SETTLE module ever moved the
  *filler's* assets, an attacker acting as maker could drain fillers. Both current
  implementations pull only from the `maker` argument Settlement supplies, and both
  gate on `msg.sender == SETTLEMENT`. **This is a rule for new SETTLE modules**, not
  just an observation.
- **Duplicate input tokens on the single-order path.** `matchSettle` rejects them;
  `fill` does not. Each leg restores the balance to its snapshot before the next leg
  reads it, so the second leg measures zero proceeds rather than underflowing.
- **The pre-guard `STATICCALL`.** Four entry points arm the reentrancy guard by hand
  and run a read-only gate first, which for a proportional anchor includes a
  `balanceOf` on a maker-chosen token. Safe because it is static, and because
  `_gateFillState` reads `filled` *after* resolving the denominator. Both properties
  are load-bearing and both are asserted above `Base._enter`.
- **Item-bit / delivered-bit collision in `matchSettle`.** `DELIVERED_BIT` is bit
  255 and the packed count is a `uint8`, so the maximum item index is 254.
- **Reentrancy from the executor into a fill.** Both the single-order callback and
  the `CALL` step run while `_locked == 2`. The unguarded external functions
  reachable from there — `approveOrder`, `cancelOrder`, `setOrderSigner`, the nonce
  cancellations — are all keyed on `msg.sender`.

---

## Sources

Reports and post-mortems this note is built from. Two vendor pages (ConsenSys
Diligence's 0x v4 report, Hacken's Portikus report) return 403 to automated fetch;
their findings enter here only through accessible secondary coverage, flagged where
it matters.

**This table is the de-duplication ledger — check it before starting a research
round.** A protocol listed here has been read; one listed with "no public audit
report" has been searched for and found not to have one. Both are answers. The
2026-08-27 round added Uniswap v4, Euler v2 and the RFQ venues (Native, Bebop); CoW
and Velora were already present and were NOT re-derived.

| Source | What it contributes |
| --- | --- |
| [OpenZeppelin — 1inch Limit Order Protocol](https://www.openzeppelin.com/news/1inch-limit-order-protocol-audit) | The richest single source: H02 (partial fills leak private orders), H03 (malicious amount getters), M01 (static-after-dynamic encoding), L02, L12. |
| [OpenZeppelin — 1inch LOP diff audit](https://www.openzeppelin.com/news/limit-order-protocol-diff-audit) | Forged cancellation events; maker-permit gas griefing; hard-coded 5,000-gas raw calls. |
| [MixBytes — 1inch LOP](https://github.com/mixbytes/audits_public/blob/master/1inch/Limit%20Order%20Protocol/README.md) | `fillOrder` reentrancy (acknowledged), `notifyFillOrder` DoS, the accepted allowance-decrease note. |
| [iosiro — 1inch Limit Order Settlements](https://iosiro.com/audits/1inch-limit-order-settlements-smart-contract-audit) | The lingering-resolver-allowance finding and the `IResolver` remediation — direct precedent for C1 and F1. |
| [OpenZeppelin — UniswapX](https://www.openzeppelin.com/news/uniswapx-audit) | M-01 filler gas griefing, M-02 gas stipend, L-03 zero-duration decay, L-02 fee-controller DoS. |
| [CoW Swap settlement exploit analysis](https://blog.solidityscan.com/cow-swap-hack-analysis-arbitrary-callable-swapguard-6a6ee3de346f/) | The canonical C1 incident: unvalidated solver interactions, forced approval, ~$180k. |
| [Decurity — Yul calldata corruption, 1inch post-mortem](https://blog.decurity.io/yul-calldata-corruption-1inch-postmortem-a7ea7a53bfd9) | The Fusion v1 buffer-overflow mechanism behind the March 2025 ~$5M loss. Also [Halborn](https://www.halborn.com/blog/post/explained-the-1inch-hack-march-2025), [1inch's disclosure](https://blog.1inch.com/vulnerability-discovered-in-resolver-contract/). |
| [ConsenSys Diligence — 0x Exchange v4](https://diligence.consensys.io/audits/2020/12/0x-exchange-v4/) | The stated non-overfillability invariant. *403 to automated fetch.* |
| [Hacken — ParaSwap / Velora Portikus](https://hacken.io/audits/paraswap/sca-paraswap-portikus-contracts-sep2024/) | The intent-execution architecture behind Velora Delta: agent registry, module/adapter factories, 100% branch coverage, no severe findings published. *403 to automated fetch.* |
| [CoW Protocol — GPv2Settlement reference](https://docs.cow.fi/cow-protocol/reference/contracts/core/settlement) | The permissioned-solver-plus-bond model — CoW's structural answer to C1, and the contrast case for our permissionless one. |
| [Trail of Bits — Building secure Uniswap v4 hooks](https://blog.trailofbits.com/2026/07/30/building-secure-uniswap-v4-hooks/) | The seven recurring hook failure patterns. #3 (accounting bugs that still satisfy the settlement invariant — Bunni, 44 valid txs) is the closest external analogue to F15. Added 2026-08-27. |
| [OpenZeppelin — Uniswap v4 Core](https://www.openzeppelin.com/news/uniswap-v4-core-audit) / [v4 Periphery + Universal Router](https://www.openzeppelin.com/news/uniswap-v4-periphery-and-universal-router-audit) | Flash-accounting and delta-settlement review; the singleton + transient-delta model our netted `matchSettle` credit ledger parallels. Added 2026-08-27. |
| [OpenZeppelin — Euler Vault Kit (EVK)](https://www.openzeppelin.com/news/euler-vault-kit-evk-audit) / [Electisec — Euler v2](https://reports.electisec.com/2024-03-EulerV2) | Batch-with-deferred-checks: which checks run at the end of a batch, the STATICCALL mitigation for in-transfer reentrancy, and rounding in looped ops. The EVC batch is the closest external analogue to our `MatchPlan` schedule. Added 2026-08-27. |
| [Symbolic Software — Native DEX (NAT-001)](https://symbolic.software/pdf/nat-001.pdf) | RFQ/PMM quote-signature architecture (AquaVault + `NativePool`). Published finding is code-quality only; no analogue here. Added 2026-08-27. |
| [Bebop — audit index](https://docs.bebop.xyz/audits#security-and-audits) | **Nine audits**, all now read. [MixBytes](https://github.com/mixbytes/audits_public/tree/master/Bebop) (B1–B4), [Cyfrin Router v2.0](https://bebop-public-images.s3.eu-west-2.amazonaws.com/2026-06-12-cyfrin-bebop-router-v2.0.pdf) (C-H1 etc. — the richest), [Decurity JAM](https://bebop-public-images.s3.eu-west-2.amazonaws.com/DecurityAudit_November2023.pdf), [Nethermind](https://bebop-public-images.s3.eu-west-2.amazonaws.com/Nethermind-Bebop-Dec%202024.pdf) (shared nonces), [Offside Labs RFQ](https://bebop-public-images.s3.eu-west-2.amazonaws.com/Bebop-RFQ-Dec-2025-OffsideLabs.pdf) (Solana). PDFs were extracted with local `pdftotext` after WebFetch returned raw binary — **use that route, not a fetch, for any vendor PDF**. Added 2026-08-27. |
| [ChainSecurity — Uniswap Permit2](https://old.chainsecurity.com/wp-content/uploads/2022/11/ChainSecurity_Uniswap_Permit2_audit.pdf) | **The forked source's own audit** — `Permit3` ports Permit2's SignatureVerification / EIP712 / unordered-nonce code. 6.1 casting (clean, pinned), 7.2 malleability (external precedent for S1), 7.1/7.3 nonce notes (absent/harmless). Read via pdftotext. Added 2026-08-27. |
