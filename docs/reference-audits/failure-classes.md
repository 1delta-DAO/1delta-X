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
both run through [`SolverCallbackExecutor`](../../packages/core/src/settlement/SolverCallbackExecutor.sol),
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
[`PackedArrays`](../../packages/core/src/settlement/PackedArrays.sol) replaces the
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

**One real instance was found and fixed** — see [F2](findings-ledger.md#f2--itemop-was-decoded-as-a-raw-byte)
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
[`Signatures._verifySignature`](../../packages/core/src/settlement/Signatures.sol) and
again at [F5](findings-ledger.md#f5--fillwithpermittakes-nothing-survives-it-was-imprecise).

### C5 — The maker supplies the function that *is* the price

> **1inch LOP, OpenZeppelin H03 — high.** With malicious `getMakerAmount` /
> `getTakerAmount` implementations and partial fills, a maker could front-run a
> taker into exchanging its full threshold for a negligible return; the threshold
> protections covered only one side of the swap.

**Mechanism.** An external, maker-chosen contract returns the amount rather than a
bounded modifier of it, so the signed numbers stop being limits at all.

**Here: structurally prevented, and this is the design's strongest single answer to
the corpus.** An [`IPriceModule`](../../packages/core/src/interfaces/IPriceModule.sol)
returns only a shared **bump**, clamped to `[0, 10000]` and then mapped through each
leg's own maker-signed `start`/`end`. It can move the tick anywhere inside the
signed band and nowhere outside it. `fillModule` is bounded the same way: it chooses
only the *delta*, while the denominator, the over-fill cap and the uniform per-leg
scaling stay in the core.

Both are `view`, so both compile to `STATICCALL`, and the return is read into
scratch capped at one word so a hostile module cannot bomb caller memory. The filler
gets the matching guard from the other side: `minBumpBps` is an *exact* price
floor, because every leg price is monotone in the one shared bump. Since 2026-09-30
(PERIPH-1.v3) it exists on `fillUpTo`, `fillWithPermit` (one 6-argument entry),
`fillWithPermitTake` and `batchFill` (per order); plain `fill` has none — use
`fillUpTo`. A fill module's delta is also capped by the filler's own `fillAmount`
(`OverFill`, CORE-FILLER-2).

See [pricing-modes.md](../pricing-modes.md) for the full argument.

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
[match-combinations.md](../match-combinations.md).

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
a one-word return cap, so they cannot move the filler's assets; their damage is
burnt gas, a reverted fill, or a price/size anywhere inside what the maker signed and
the filler requested (a fill module can no longer return more than the filler's
`fillAmount`, CORE-FILLER-2; a module can tell the lens probe from the real call by
`msg.sender`, so a preview is advice). Item modules are ordinary calls under the
maker's own Permit3 authority. Fillers must simulate — see
[filler-strategy.md](../filler-strategy.md#7-every-maker-supplied-target-is-gas-unbounded).

### C10 — Hard-coded gas stipends on value transfer

> **UniswapX M-02:** a 6,900-gas ceiling in `CurrencyLibrary` excluded
> smart-contract wallets and multisig fee recipients from any native-currency swap.
> **1inch diff audit, Low:** the same shape at 5,000 gas.

**Mechanism.** A fixed stipend is a bet on opcode pricing that goes stale across
upgrades and does not hold across chains.

**Here: not applicable to the core.** No native-value path exists in the settlement
core — no `payable` entry point, and `SafeTransferLib` carries no ETH transfer at
all. Native assets are wrapped inside modules, which is where this check belongs
instead: **any module that forwards native value must not cap the gas.** Modules that
unwrap deliver WETH rather than raw ETH wherever the recipient is not the maker:
`CompoundV2Native*`, `ListaNative*` and, since 2026-09-30 (L-FSE-3), the Fluid
custody modules (`FluidCustodyBase._operateOut`) — a native Fluid leg is a WETH leg.

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
`PermitBatchWitness` and therefore has no other entry to rescue it. ("No other
entry" holds only before the first fill: after a partial first fill, a spent nonce
is a verified no-op even past `batch.deadline`, so `fillWithPermit` keeps working —
2026-09-30 P3-4.)

### C12 — Revocation that does not revoke

> **1inch MixBytes**, "user can decrease allowance" (accepted as a gas trade-off),
> and **iosiro's lingering-allowance finding**. The generalised form is now the
> dominant risk in allowance-hub designs.

**Mechanism.** Two paths can fund the same transfer. Revoking one leaves the other
standing — and the user is told they revoked.

**Here: applies, and it was the highest-ranked item in this review.**
`Base._pullViaPermit3` (formerly `Permit3TransferLib.transferFromWithFallback`, deleted 2026-09-30) falls through to a direct
`transferFrom` whenever the Permit3 leg fails for **any** reason, including because
the payer revoked, capped or expired it. See [F1](findings-ledger.md#f1--revoking-permit3-is-not-a-kill-switch-on-its-own)
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
rules moved into [`OrderGates`](../../packages/core/src/settlement/OrderGates.sol) so
both callers read one implementation. That file's header is the incident report.

**The rule:** a rule that both the settler and the lens must apply belongs in
`OrderGates`, not in two places. The lens may be *stricter* only where it is
explicitly advisory (it flags `recipient is settlement (burn)` and duplicate
`(token, recipient)` pairs); it must never be stricter about **fillability**, or an
orderbook drops live size — nor **looser**, or it blesses orders that revert.

A second review pass (2026-08-25b) found three more instances of exactly this, which
is the strongest argument for the rule above: the class recurs even in a codebase
that has already written the incident down. All three are fixed — see
[F7](findings-ledger.md#f7--matchsettle-paid-a-self-addressed-output-leg-to-the-solver),
[F8](findings-ledger.md#f8--a-proportional-anchor-plus-the-pegged-price-module-passed-preflight-and-never-filled),
[F9](findings-ledger.md#f9--the-lens-conflated-the-settlers-two-lifecycle-axes) and
[F10](findings-ledger.md#f10--remaining-panicked-for-a-cancelled-order).

The 2026-09-30 audit found six more (G-LENS_PARITY-1..6, PERIPH-5, G-BYTE_MAP-6,
PRICE-15), all fixed, and the lens now mirrors: the reserved bit-255 order nonce in
preview and state; pre-fund + soft-override `ForLegInvalid` in `previewFill`; the
`minFillAnchor` tail (a stranded remainder reads 0 and is named); the ERC-20
approval to Permit3 behind a Permit3 book entry (`FundingPreflight.pullable`);
structurally dead shapes (Invalid); the BALANCE floor; `floorBps > 10000` accepted as
the settler does; the resolved-recipient duplicate rule (`0` and the maker are the
same recipient); and MAKE-only pre-fund classification for item funding. Pinned by
`test_audit_G_LENS_PARITY_6_deadShapesReadInvalid`,
`test_audit_PERIPH_5_reservedNonce_invalidAndUnquotable` and siblings.

### C14 — Assumptions about how tokens behave

> **UniswapX N-06:** the sample executor used bare `approve()`, which fails silently
> on non-standard ERC-20s. **UniswapX M-01** turned on ERC-777 transfer callbacks.
> **1inch M03:** Chainlink calculators assumed 18 decimals without validation, which
> the audit called an unintentional loss-of-funds path.

**Here: scoped, with a real answer on the output side.** Fee-on-transfer and
rebasing *inputs* are out of scope on the netted path: they revert (`BatchNotWhole` /
`LegUnfunded`) or the fee is absorbed by the MATCHER's own residual — it does not
always fail closed, but an honest maker is never short-changed (2026-09-30
X-SPEC-6). **Double-entry-point tokens** are out of scope for `matchSettle` and
delta-verify too (X-TOKENS-2, accepted: a dedup costs EIP-170 bytes and the loss is
bounded to the matcher's residual). For *outputs*,
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
item matrices ([match-combinations.md](../match-combinations.md)) — 64 + 49 shape cells
and the two item sub-matrices. The `_creditItemProceeds` half has a negative control:
rerouting that refund to `msg.sender` fails all four item sweeps, each short by
exactly the strayed amount.

---
