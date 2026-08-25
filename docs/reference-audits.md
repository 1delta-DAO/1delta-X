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

---

## Findings ledger

**F1–F6** came out of the 2026-08-25 crosswalk. **F7–F12** came out of a second,
independent review pass against the same corpus later that day; two of those arrived
with executed PoCs, and all six were re-derived here before being acted on. Every
item below is resolved.

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

`recoverCalldata` accepts 65-byte and EIP-2098 compact signatures and does not
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

---

## Checked and clean

Things worth re-checking whenever the relevant code moves.

- **Selector collision on module dispatch.** Settlement calls a maker-chosen address
  directly for MAKE and SETTLE while being a universal Permit3 spender — the C1
  shape, contained only because the selector is fixed. Re-run the scan if either
  interface signature changes:
  ```
  cast sig "makeOnBehalf(address,uint256,bytes)"   # 0xb5d2b67f
  cast sig "settle(address,address,uint256,bytes)" # 0x99bb07b8
  ```
  Neither may collide with anything on Permit3.
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
