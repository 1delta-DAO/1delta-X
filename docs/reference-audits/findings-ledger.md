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
[Re-audit sweep](reaudit-sweep.md#re-audit-sweep--the-generalised-questions-from-f13f15) for the
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
- [account-onboarding.md](../account-onboarding.md#strict-mode-and-the-two-funding-surfaces).

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
[filler-strategy.md §7](../filler-strategy.md#7-every-maker-supplied-target-is-gas-unbounded).

### F4 — Rounding is maker-favourable and non-cumulative on the auctioned side

**Class C7 · Informational · documented**

The invariant is now written down where the pricing lives —
[pricing-modes.md](../pricing-modes.md#rounding-who-pays-the-wei) — and restated under
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

**Class [C12](failure-classes.md#c12--revocation-that-does-not-revoke).** PoC'd, fixed.

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

**Class [C11](failure-classes.md#c11--the-permit-as-a-liveness-bomb) / [C12](failure-classes.md#c12--revocation-that-does-not-revoke).**
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
descriptor form, in [match-combinations.md §2.1](../match-combinations.md#21-why-take_for-in-particular-stays-out).

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

The settler behaviour has since been TIGHTENED and is pinned
(`test_zeroOutputLeg_refusesTheBareTake`): a zero funding slice against a non-zero
draw is an uncollateralised slice, and the core now refuses it with
{Base.ForBalanceBelowFloor} rather than dispatching a bare `TAKE`. The test's
former name asserted the opposite outcome, which is why this entry changed. The preflight
gap remains not real: `validateOrder` rejects `start == 0` on **every** output leg of every order,
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

*One module, one shape* is [`tools/check-module-shapes.py`](../../tools/check-module-shapes.py),
wired as `make modules-check`. It scans every `packages/*/src/**/*.sol` for a
contract declaring both `takeOnBehalf` and `takeForOnBehalf` (or inheriting both
interfaces) and fails the build. 77 taker contracts scanned, each implementing
exactly one; verified to bite by planting a violating contract and watching it exit
1. It reads SOURCE rather than artifacts deliberately: a full-tree `forge build` does
not currently succeed (a bridge module is stack-too-deep under the default profile),
so an ABI scan would silently cover a subset — and a gate with unknown coverage is
worse than no gate. The pattern it must catch is syntactic anyway.

*Permit3 nonce namespacing* is [`permit3nonce.ts`](../../packages/sdk/src/permit3nonce.ts).
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
the hole. That is the [C2](failure-classes.md#c2--hand-rolled-calldata-arithmetic-without-a-bounds-proof)
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
| G-11 | `fillWithPermitTake`'s authorization was a post-condition of the whole fill | Low | assertion moved ahead of the maker's input pull | hardening |
| G-12 | `PackedArraysMem` documented an UNCHECKED count as its bounds source | Low | real validators; seven call sites repointed | hardening |
| G-13 | **systematic variant sweep of all 18 lending packages** for the four confirmed classes | Med | 21 further sites fixed | **the method, not a finding** |

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

**G-13 is the one to copy, because it is a method rather than a finding.** The
audit read 5 packages of 18. Three of the four fix classes had already turned out
to have more instances than the finding that surfaced them (6 vs 1, 6 vs 4, 7 vs
2), so the remaining 13 packages were swept mechanically for all four:

| class | new sites | packages |
| --- | --- | --- |
| unfloored residual sweep | 5 | compound-v2-native (×3), liquity-v2, gearbox-v3 (×2) |
| offset collision | **0** | — clean everywhere |
| nominal forward, no delta | 1 | aave-v2 |
| approval to an order-decoded spender, never cleared | 15 | aave-v2, compound-v2, compound-v3, dolomite, euler-v2, exactly, gearbox-v3, river, silo, teller |

Three things worth keeping from how it went.

**`LiquityV2Modules.sol` needed a SECOND fix in a file already fixed.** G-6 closed
the `boldToken` sweep at line 200; the `collateralToken` sweep at 148 was in the
same file and was missed. Fixing a file is not fixing a class.

**A deliberate design decision was left alone.** `CompoundV2NativeModules`'
`_sweepWeth` / `_sweepNativeAsWeth` sweep the module's whole native and WETH
balance, and the source says why: `receive()` is open, the module has no owner and
no rescue path, so a floor would strand a donation *forever* rather than merely
misdirect it. That is a real trade-off, argued in place, and it was not overridden
— only the cEther (ERC-20 receipt) sweeps in the same file were floored, matching
the non-native sibling. If the "always empty" posture is wrong, the fix is a rescue
path, not a floor.

**A test was asserting the vulnerable behaviour.**
`CreditRepayAuth.t.sol::test_repay_sweepsResidualToMaker` pre-minted 123e18 to the
module and asserted `balanceOf(module) == 0` — "module drained" — which is exactly
the invariant `DustHandler` calls the wrong one. It only passed before because its
Permit3 stub was a no-op, so a pre-mint was the only way to fake custody. The stub
now moves tokens for real, the test asserts the module ends where it *started*, and
a sibling test pins that a stranded balance is not claimable. A regression test that
encodes the bug is worse than no test: it converts the fix into a red build and
invites reverting it.

**G-11 and G-12 are the fragility half of the lead list, landed as Phase 2.**

`Core.fillWithPermitTake` verifies no signature up front — the `PermitTake` blob
IS the order's authorization — and the "was it consumed?" assertion used to run
only after `_settleForward` returned, i.e. after `_openFill` had written state,
items had dispatched to maker-supplied modules, and `_payInputsToSolver` had drawn
the maker's wallet. Four lenses attacked that and found no live exploit: the
deferred check plus atomic revert closes every path. It is nonetheless safe only
BECAUSE every item op is atomically revertible, and that stops being true the
moment one acquires an effect outliving the transaction — a cross-chain message, a
bridge-inbox item, an off-chain-consumed event. The assertion now sits immediately
after `_executeItems` and BEFORE the input pull, so authorization gates the pull
rather than being audited once the money has moved. Zero cost elsewhere: on every
other entry the blob is never set and this is a length test on empty `bytes`.

`PackedArraysMem`'s header told callers to "call {count} … before indexing", but
`count` was the memory twin of `PackedArrays.countUnchecked` — the function the
calldata library explicitly forbids as a bound ("deliberately proves nothing about
the bytes that follow"). `bytes.concat(hex"03")` reports three legs while holding
none. The unchecked reader is now named `countUnchecked`, `validateFixed` /
`validateLegsIn` / `validateLegsOut` mirror the calldata validator, and **seven**
call sites across five files were repointed — `BaseFlashSolver` (×2),
`UsdrifInventorySolver`, `AggregatorFillSolver`, and both ERC-7683 adapters (×2
each), the last two of which the lead had not identified.

`Batch._stepPresend` was deliberately left as a comment change rather than a code
change. Its bound is sound today, but not for the reason the comment gave: the
`outstanding` ledger excludes both Phase-3 refund paths, and what actually stops
the extraction is `_sweepSurplus`'s per-token floor plus the refund transfer
reverting on a drained pool. The guarantor is now named at the PRESEND site along
with the three changes that would reopen the hole. Seeding `outstanding` with the
reconciliation surplus would make the bound self-sufficient, but that is a change
to the netted hot path and should be justified on its own merits rather than
smuggled in as documentation.

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


### F26 — twelve-lens read of the 14 previously-unaudited lending packages (2026-09-02)

The complement of F25: those covered core + aave-v3/v4 + morpho-blue/midnight, this
covers everything else (15 files, 4,718 lines). One **Critical**, fixed below; the
rest is written up in
[audit-2026-09-modules-plan.md](../audit-2026-09-modules-plan.md).

**The headline is that a mechanical sweep could never have found this.** G-13 had
already grepped all 18 packages for the four known classes and pronounced them
clean. Reading them found a Critical, two novel classes, and — embarrassingly —
more instances of the four classes the sweep had just certified. The three reasons
the sweep lied are recorded at the top of the plan doc; they are properties of the
detector, not of the code.

#### C-1 — `LiquityV2TroveAuth.authorizeTrove` trusted a caller-supplied auth root

Any trove that had onboarded (granted the module `setRemoveManagerWithReceiver`)
was drainable by anyone, for gas, with **no order, no maker signature and no
Settlement** — `Permit3.approveTaker` lets a caller name itself spender, so
`take` is reachable directly.

The library derived both its ownership oracle and its dispatch target from one
address taken from `data`, and its header argued that this made forgery
impossible: *"a fabricated root sends the op into attacker-land, where there is no
real trove to drain."*

A shared root forces consistency only when the root is **trusted**. An
attacker-deployed root has two independent return statements:

```
troveNFT()           -> puppet answering ownerOf(anything) = attacker
borrowerOperations() -> the REAL BorrowerOperations
```

The op does not land in attacker-land. It lands on the real protocol, which
permits it because the module genuinely *is* the victim's registered remove
manager. PoC drained 3,000 BOLD and 5e18 collateral from a victim trove.

**Fix.** Root the chain at an immutable `ICollateralRegistry` set in each module's
constructor; `data` now carries a branch **index**, so a caller chooses which
branch to act on and cannot invent one. The index occupies the slot the address
did, so every downstream offset (permit blocks included) is unchanged. Registry
verified live on mainnet: `getTroveManager(0)` returns exactly the WETH-branch
TroveManager the fork test pins, `totalCollaterals() == 3` — and the fork test now
resolves through the real registry rather than a hardcoded address, which is a
strictly stronger assertion than it made before.

`authorizeTrove` also returns the resolved `troveManager` so the repay leg's debt
read uses the same trusted resolution instead of re-deriving its own.

**Why Settlement-side validation would not have worked**, and why this had to be an
immutable: the attack never touches Settlement.

**The contrast that makes the diagnosis precise.** `GearboxCreditAuth` survives the
identical attack — not because it is careful, but because its caller-supplied
`creditAccount` is *also* the dispatch parameter, so the real facade re-validates
it. Fluid survives because the real vault consults its own immutable factory.
Liquity was the one place where the oracle and the dispatch target could decouple.
**Where those two can decouple, a caller-supplied root is never sufficient.**

Regression: `liquity-v2/test/unit/ForgedRootAuth.t.sol` — the forged root is still
deployable and still lies; it simply has nowhere to go, because no field in `data`
points at it any more. Four tests pin the non-owner reject, the unknown-branch
reject, and that the trove's real owner is still served.

#### H-1 — a maker-signed slippage ceiling was applied per-slice, not per-order

The one finding here where the victim did nothing wrong. No stranded balance, no
fake contract, no self-harm: the maker signs a correct order and an input they
never consented to — the **slice count** — dilutes their protection.

`Base._executeItems` pro-rates an item's `amount` per fill but hands the module
`item.data` byte-for-byte. {FullFillGuard} was written for the case where a
constant in `data` is an AMOUNT; nobody applied the same reasoning when it is a
**bound**:

| module | bound | direction |
| --- | --- | --- |
| `ExactlyTakerModule` (`borrowAtMaturity`) | `maxAssets` | max — **fails OPEN** |
| `LiquityV2TakerModule` (`withdrawBold`) | `maxUpfrontFee` | max — **fails OPEN** |
| `ExactlyTakerModule` (`withdrawAtMaturity`), `ExactlyDepositModule` | `minAssetsRequired` | min — fails CLOSED |

Quantified by the regression test against the pre-fix code: a maker signing
"borrow 10,000, never owe more than 11,000" filled in 7 slices had **7× their
signed ceiling** admitted (`77000000000 > 11000000000`), and a single 10% slice
carried the whole 11,000 ceiling (`11000000000 != 1100000000`) — a 1,000 borrow
authorised to owe 11,000.

**Fix.** New shared library `@lib/ProratedBound`, and a MANDATORY maker-signed
`totalAmount` in both modules' `data`. Rounding is FLOOR so
`sum(floor(bound·aᵢ/total)) <= bound` — the ceiling holds however the filler
slices. In Exactly the new field also **removes a redundancy**: the `Full` withdraw
guard now reads that same total at 160 instead of carrying a second copy at 192.

**Three things the work itself taught, all worth keeping:**

**The min-direction bounds were deliberately NOT touched.** Applied unscaled to a
slice a FLOOR is *stricter* than the maker asked for, so a partial fill reverts —
fail-closed. Scaling them would loosen a guard that is currently safe, and would
separately enable partial fills on a leg that does not support them. The plan said
so before the code was written, and holding to it under the temptation to "fix all
four" is the point.

**`type(uint256).max` must pass through untouched.** It is the conventional "no
ceiling" sentinel, and scaling it overflows the multiply and reverts a legitimate
fill. The first version of the library got this wrong and
`liquity-v2/test/leverage/Leverage.t.sol` — which signs exactly that sentinel —
caught it. A library written for safety that bricks the unbounded case is not safe.

**The legacy profile has no stack to spare.** Adding `totalAmount` to Exactly's
decode tuple, and then even passing the scale as a call argument, both blew the
stack limit on the non-via-IR profile these packages build with. The total is read
from calldata in its own frame and the scaled value reuses `bound`'s slot.

#### F26 Phase 2 — the F19 / A-3 / H-3 hygiene family, closed as classes

Every site below is Medium: the exploit needs a balance at a shared module that is
not the attacker's. That precondition is real (these modules are pull-exact and end
empty on the honest path), which is why this phase is hardening rather than an
emergency — and why it ran after the Critical and the maker-harm class.

| class | sites | packages |
| --- | --- | --- |
| unfloored whole-balance sweeps | 5 | compound-v2 (cToken exact + 3 native), river |
| value-out forwarding a nominal amount | 3 | venus (×2), compound-v2 |
| approvals to a `data`-decoded spender, never cleared | 9 | venus ×2, lista, euler ×4, dolomite ×3, fluid ×2 |
| `uint160`-clipped pull vs unclipped approve | 5 | exactly, euler, dolomite, river, fluid |

Final census across all 18 packages: **0 remaining in every class.**

**The native sweeps were the interesting one, because the previous round declined
to fix them on the strength of a source comment.** That comment argued: `receive()`
is open, these modules have no owner or rescue path, so a floor would strand a
donation forever — "a donor's ETH is a gift to the maker, not a loss". The premise
is false. It assumes the maker is a legitimate counterparty, and **anyone can be
the maker of a one-wei order**; it was a gift to whoever called first. Worse,
`CompoundV2NativeRepayModule` reaches the sweep with NO pull at all when the live
debt is zero, so the claim cost only gas. Both sides are now floored, and the
honest cost is stated in the code: donated ETH is unrecoverable rather than
claimable, which is how every other module treats a donated ERC-20. *Auditing a
conclusion is not auditing its premise.*

**Two negative results worth keeping.** `AaveV2WithdrawModule`'s exact branch calls
`pool.withdraw(asset, amount, receiver)` — the pool pays the receiver **directly**,
so the module never holds the funds and there is nothing to measure; the reported
lead was wrong about the shape. And of the 23 pull/approve pairs sharing the
truncation syntax, only 5 are exploitable: the rest approve an amount the core has
already width-checked (`Base._runItem` on `slice`, `_dispatchTake` on `forSlice`).
**Enumerate that class by the provenance of the amount, never by the shape of the
call** — fixing all 23 is churn, trusting a hand-listed 6 misses one.

Two shared libraries came out of this and are the first instances of the Phase 3
shape: `@lib/ProratedBound` (F26/H-1) and `@lib/Narrow160`. Fluid's six call sites
funnel through one `_pullAndApprove`, so the narrowing landed once and covered all
of them.

Regression: `compound-v2/test/security/StrandedCTokens.t.sol` (converted from the
audit PoC; both tests fail against the pre-fix code, `0 != 500000000000000000000`).

### F27 — twelve-lens audit of the new pre-fund-module family (2026-09-03)

Scope: the 15 `*PreFundModules.sol` files (24 contracts) plus `Base.sol` — 3,942
lines. **Four Criticals, three with executed PoCs.** Full write-up in
[audit-2026-09-push-family.md](../audit-2026-09-push-family.md).

The pre-fund shape was introduced to minimise approvals, and it does. It also removed
the thing that had been bounding `forAmount` without replacing it. On a *pull*
module the value moved comes out of `onBehalfOf`'s own wallet, so a self-granting
attacker can only rob themselves; `Permit3.takeFor` leaves `forAmount` ungated for
exactly that reason, and says so in a comment. On the *push* shape the value comes
out of the **module's** balance, so the same self-grant robs a third party. One
`approveTaker(self, module, keccak256(data), 1, max)` plus one `takeFor` drains a
singleton — no order, no signature, no Settlement, no capital.

- **C-1** `forAmount` is unauthenticated (10/12 agents, PoCs). 28 contracts.
- **C-2** `Base._runItem` skips a zero-slice `TAKE_FOR` *after* `_deliverOutputs`
  paid the leg — the only finding with an honest victim, and the residue generator
  that supplies C-1's precondition (6/12 agents, PoC).
- **C-3** Morpho/Exactly size the sweep from a caller-chosen venue's return value —
  2× `forAmount` extracted (PoC).
- **C-4** Teller's `balanceOf(this) - forAmount` floor, the family's only guard,
  rejects only the over-ask an attacker never needs (5/12 agents, PoC).

**Two lessons worth more than the findings.**

*Our own plan doc was the counter-example.* Its REASSESSMENT section ranked this at
Medium and proposed a one-line `_forSlice` recipient check. The primary channel
never enters the core, so that fix would have read as closed while the drain
stayed open. The fix direction moved four times across the run; only the fourth
reading survived all twelve lenses.

*A passing PoC is not a proved invariant.* Our staged Teller "is immune" case
passes — it asserts immunity to `forAmount > balance`, the one case an attacker
never uses. It and its refutation now both pass, which is the contradiction that
exposed it.

Also: F26/H-1's `ProratedBound` fix never reached this family — `ExactlyPreFundRepay`
reintroduced the unscaled bound. Detectors must gate new files, not just sweep
existing ones.

**FIXED** (2026-09-04), C-1 through C-4 plus H-2. `Permit3.takeFor` forwards its
`msg.sender` as `spender`; 28 pre-fund contracts pin an immutable Settlement and take
a `@lib/PreFundGuard` balance floor. `takeFor`'s own ABI is unchanged, so Settlement's
bytecode was untouched by that half — only C-2's zero-slice revert cost anything,
20 bytes (24,522 → 24,542 of 24,576).

The nicest part of the fix is the sweep. Every repay module now returns everything
above the pre-delivery floor, which IS `forAmount − consumed` by construction —
so C-3 (a lying venue's return value) and M-1 (a pre-call clamp that over-states
the pull) both close without anyone computing `consumed` at all, and the local
disappears from all 13 modules. The measurement that cannot be wrong is the one
nobody performs.

H-1's core-side binding and H-3 followed. Descriptor **bit 253** declares the PUSH
shape and `_forSlice` then demands `legRecipient == module`; the 15 one-sided push
modules require the bit, so a maker cannot opt back into the loose check. The
obvious two-branch form measured **3 bytes OVER** EIP-170 — folding it to one
revert site saved 11 and landed at 24,568 / 24,576. The token and consumption axes
stay module-side: neither fits in the 8 bytes left, and saying so beats pretending.

A consequence worth knowing: pull and push can no longer share one signed blob,
because the shape is now part of what the maker signs. Three fused packages had
comparison tests built on byte-identical data and now build two blobs with two
taker grants.

H-3 scales Exactly's fixed-branch face with the slice (new trailing word,
BREAKING). The Midnight lead closed without its fork check — there is no deployed
Midnight to read, and `sweepSurplus` had already removed the strand that made the
unit mixing matter.

Coverage is now tracked separately in [audit-runs.md](../audit-runs.md), written
when the runs' bundle directories were cleaned up. It records what each round
actually READ, and it immediately paid for itself: **four pre-fund contracts
(`AaveV3PreFundLeverageModule`, `DolomitePreFundTakeForModule`, `EulerV2PreFundTakeForModule`,
`FluidPreFundTakeForModule`) appear in neither run's source snapshot.** They were
written after the last bundle was built, so no lens has ever read them — the
post-fix census is the only thing that has, and it found all four missing the
balance floor and the descriptor-bit requirement. Same defect as H-3 in a different
costume: a scope fixed at bundle-build time cannot cover code written afterwards.

Two of my own comments were wrong and are corrected in the tree: the templated
floor note I scripted onto Lista and River claimed an approval-free burn, which is
true only of Liquity's `repayBold`. Scripted comments inherit a claim they were
never checked against.

### F28 — twelve-lens audit of the full tree: lending × matching × pre-fund (2026-09-12)

Scope: 120 files, 27,803 lines — every `packages/*/src` file outside `interfaces/`,
`vendor/`, `script/` and the view-only lens. **Six findings, two with executed
PoCs; all fixed 2026-09-14.** Write-up in
[audit-2026-09-12-full-tree.md](../audit-2026-09-12-full-tree.md).

The emphasised seams — `_forSlice` ↔ `ctx.outs` ↔ `floorOf`, the `takeFor` spender
pins, the `matchSettle` ledger — cleared every lens. What broke was outside them:

- **BridgedOrderInbox** keyed the refund beneficiary and expiry to whichever bridge
  delivery for an order hash landed FIRST; a 1-wei front-credit hijacked the
  victim's whole escrow (PoC). Later credits now must match the beneficiary;
  expiry is the minimum.
- **NativeUnwrapModule** — the one push-funded MAKE outside the pre-fund seam —
  unwrapped a signed constant against an auction-priced delivery; the difference
  stranded on the singleton and a zero-leg self-order took it (PoC). It is now a
  pre-fund leg-ref consumer (**BREAKING** data shape).
- **Dolomite Exact withdraw** past the supply is a borrow on that venue — the
  `WouldBorrow` guard Comet had, Dolomite did not.
- **Five `Full` branches** (Venus, aave-v4, compound-v2 ×2, lista-native) lacked
  I-8's `requireDelivered`; a short position billed the maker's wallet. The I-8b
  prose that exempted them by venue was wrong for their Full branches, and the
  shapes checker had encoded it. Shapes rule 9 now enforces
  `requireFullFillFromData ⇒ requireDelivered`.
- **CompoundV2RepayModule** never cleared its scoped approval — A-3's seventh site.
- **Liquity / River repay** measured a `data`-named token while the venue burns the
  real one approval-free. Both now pin the named token to the trusted root
  (`registry.boldToken()`, `tm.debtToken()`, both chain-verified). ⚠ This corrects
  F27's closing paragraph: River's `repayDebt` does NOT pull through the scoped
  approval — fork-probed, it burns from `msg.sender` with zero allowance. The
  comment F27 "corrected" was right about the mechanism and wrong only in scope.

Three of six are the "patch hit one sibling, missed the neighbour" pattern again;
two of six were invariants asserted in a comment that nothing enforced.

### F29 — bounty-corpus screening: six lenses over B1…B14, first read of the periphery (2026-09-14)

Scope: the full tree plus `SettlementLens.sol`, `packages/sdk/src`,
`packages/orderbook/src`, `packages/orderbook-server/src`. **Eight findings (four
PoC'd), six periphery defects, 22 leads.** Write-up in
[audit-2026-09-14-bounty-screening.md](../audit-2026-09-14-bounty-screening.md).

The classes in [reference-bounties.md](../reference-bounties.md) were used as hunting
lenses rather than as verdicts, and two of the registry's own verdicts fell: B1
("there is no 1e18 quantity to truncate") — `ChainlinkTickFloorValidator.scale` is
one, and it is 0 for the WETH/USDC/8-dec shape, so the market limit never gates;
B3 ("byte maps checked by the shapes tool") — the tool checks pins and floors, not
offsets, and `ExactlyRepayModule`'s header puts the permit where the fixed branch
reads `totalAmount`. The OCO claim nonce is bound to `order.nonce` nowhere on-chain
(B6), so cancel-and-replace revives the predecessor. F28's inbox fix is reopened:
first-writer ownership of `commits[H]` remains (B12). The periphery — never read
before — yielded six defects, one of which (`verifyLayer2` passes an unpacked order
to the lens ABI) means the demo book cannot admit any order against a real lens.

Lesson: a registry verdict written from memory of the code is a claim; the lens
that hunts the class finds the exception. Keep the classes, re-run the hunt.

### F30 — re-audit against the 2026-09-24 corpus additions (2026-09-25)

Scope: the whole tree plus `packages/orderbook*`, read through seven lenses taken
from the fifth pass ([corpus-2026-incidents.md](corpus-2026-incidents.md)) and the
2026-09-24 third-corpus reads ([corpus-modular-protocols.md](corpus-modular-protocols.md)):
non-injective identifiers (Liquid, Injective), self-target / denylist / standing
allowance (multicall router, deBridge, Aquifer), width casts and signed subtraction
(Notional, Symbiosis), access control and caller-chosen destinations (Aori, Ankr,
Drift, KelpDAO), sequence-level rounding (Balancer v3, Valantis), signature shape
predicates and permit front-running (0x CCRF), and the Hacken order-book checklist.
Two lenses found nothing exploitable (casts, rounding), which is itself the result
for those classes: no narrowing cast wraps to a benign value, every fee subtraction
is bounded both ways, and every core rounding step leans maker-ward.

**Fixed here.**

- **`fillWithPermit` authorized an order on every Settlement sharing a Permit3.**
  The permit is that path's only authorization, Permit3's domain names Permit3,
  and `Order` has no settler field — so the bare order-hash witness, plus the
  spent-nonce skip, let a second settler (a redeploy reusing Permit3, which
  `Deploy.s.sol` does) re-fill an order the first had filled in full. The witness
  is now `SettlementOrder{address settlement, Order order}`
  (`OrderHash.SETTLEMENT_ORDER_TYPEHASH`, hashed in `Core._permitBatchHead`).
  **BREAKING** for off-chain signers: SDK `PERMIT_WITNESS_TYPES` updated.
  Pinned by `test_permitWitness_filledOnV1_cannotBeReplayedOnV2`,
  `test_permitWitness_signedForV1_neverFillsOnV2`, `test_permitWitness_signedForV2_fillsOnV2`
  and `test_settlementOrderTypeHash_matchesTheAssemblyLiteral`.
- **Delta-verify (`timing` bit 104) counted inflows the maker paid for elsewhere.**
  The balance window spans the filler's callback, and a permissionless filler can
  settle the maker's OTHER intent on another venue paying the same token inside it;
  that inflow passed as this order's delivery. No on-chain test separates the two,
  so a delta-verify order is now fillable ONLY by its named `exclusiveFiller`, for
  its whole life (`Core._snapshotOutRecipients`; zero and `FILLER_SET` fail closed).
  The app names its operator-gated solver, and the SDK's `packOrder` refuses the
  shape without one. Pinned by `test_deltaVerify_unnamedFiller_cannotPassOffAnotherIntentsPayment`,
  `test_deltaVerify_unnamedFiller_reverts_preDelivery`, `test_deltaVerify_noNamedFiller_neverFills`
  and `test_deltaVerify_fillerSet_failsClosed`.
- **Paid for under EIP-170 by merging the six `TAKE_FOR` funding errors into two**
  (`ForLegInvalid`, `ForBalanceInvalid`): −59 bytes, Settlement 24,570 / 24,576 on a
  clean `core-deploy` build. The on-chain revert no longer names the rule;
  `SettlementLens.validateOrder` still does.
- **`BridgedOrderInbox`: one owner key could fabricate credits.** A registered
  compose source's `amountLD` is credited as stated, and LayerZero relays a compose
  from any sender, so a compromised owner could register its own source and drain
  depositors through an inbox-made order. Adding a source is now timelocked
  (`COMPOSE_SOURCE_DELAY`, `applyComposeSource`); removal stays instant. Pinned by
  `test_composeSource_newSourceIsInertUntilDelay`, `test_composeSource_remapWaitsAndKeepsOldMapping`,
  `test_composeSource_removalIsInstantAndCancelsQueue`.
- **`PositionFunnel` was a naive 1271 wallet to Permit3** (S2, first-party): it
  checks the owner's signature on the raw digest, so the owner's permits for its own
  wallet verified for the funnel. Permit3 is no longer a built-in signature consumer
  (explicit owner opt-in only), and the factory refuses a zero owner, which accepted
  `bytes(65)`. Pinned by `test_1271_permit3IsNotABuiltInConsumer`, `test_factory_refusesZeroOwner`.
- **`UsdrifInventorySolver.sell` let one operator empty the inventory** (tokens,
  `minOut` and calldata all operator-chosen). Now owner-configured sell routes with
  a minimum rate and per-call budget, aggregator refusals, two-step ownership.
  Pinned by `test_sell_drainPoC_reverts`, `test_sell_junkTokenOut_reverts`,
  `test_sell_rateViolation_reverts`, `test_sell_spendAboveBudget_reverts`,
  `test_setAggregator_refusals`, `test_ownership_twoStep`.
- **Order book (Hacken's single-order-revert DoS).** `SettlementLens` checked each
  order in a `try` with no gas cap, so one gas-burning order starved its whole chunk
  into `Invalid` and the book evicted honest orders. Per-order cap
  (`ORDER_STATE_GAS`) with a new `Inconclusive` status, off-chain bisection, and
  eviction only after repeated solo failures; plus admission on the transport path,
  bounded caches, sticky soft cancels, WS limits, error redaction and
  `X-Forwarded-For` hardening. Pinned by `test_poisonOrder_doesNotEvictItsChunk`,
  `test_exhaustedCallBudget_marksRestInconclusive_noRevert` and the two
  `hardening.test.ts` suites.

**Test gaps closed.** Every `Narrow160` site and `ProportionalSweepModule`'s inline
guard is now driven with `type(uint160).max + 1` (`test_narrow160_*`). The
Balancer-shaped sequence properties the corpus claimed for `RoundingDirection.t.sol`
now exist in `RoundingSequence.t.sol`: prefix monotonicity over fuzzed UNEVEN
partitions for SELL and BUY, multi-leg, decaying, override, price-module,
`fillTotal`, `fillUpTo`, `batchFill` and 6-vs-18-decimal shapes
(`testFuzz_prefix_*`), item round-trips (`testFuzz_items_roundTrip`) and the
`filled[]` binding (`testFuzz_filledBinding_mixedEntryPoints`). The venue
share round-trip property is not yet expressible in core (no share-venue mock).

**Follow-up round, same day — the remainder closed.**

- **`LzOftBridgeOutModule` spent any payer's native credit (HIGH).** `feePayer`,
  `oft` and `maxNativeFee` are all maker-signed and `oft` quotes the fee it is paid,
  so a self-signed order naming a victim as `feePayer` and an attacker contract as
  `oft` took the victim's whole credit. Charging a payer other than the maker now
  needs that payer's amount-bounded `feeAllowance` to that maker
  (`approveFeeSponsorship`), debited per fill — the solver-sponsored fee the module
  advertises survives, as a consented, capped grant. Pinned by
  `test_fee_cannotChargeAnUnconsentingPayer`, `test_fee_sponsoredPayerIsChargedWithinAllowance`,
  `test_fee_sponsorshipBelowQuote_reverts`.
- **`AggregatorFillSolver` standing allowances were the caller's to spend (HIGH on
  an open instance).** The router allowlist pins where the call goes, not what it
  says; inside `onFill` the router's `msg.sender` is the solver, so caller-written
  calldata could spend the standing approval on any primed token. The constructor
  now refuses `standing` without an operator set (`StandingNeedsOperators`). Pinned by
  `test_standing_openInstanceIsRefused`, `test_standing_strangerCannotDriveARoute`.
- **`MidnightFlashSolver.onFlashLoan` ignored the initiator (LOW).** Now
  `caller == address(this)` (`ForeignInitiator`), as the Aave sibling does. Pinned by
  `test_midnight_foreignInitiator_reverts`.
- **The `2^160 − 1` Permit3 sentinel through `PositionFunnel.grant` (LOW).** The core
  admits exactly that slice and Permit3 treats it as a never-decrementing allowance;
  `grant` now refuses it. Pinned by `test_grant_infiniteSentinelIsRefused`.
- **Op words read mod 256 (LOW).** Real only for `FluidOperateModule`, whose `mode` is
  a `uint256` field: `mode = 256` ran Open. Now `Mode(p.mode)` (range-checked on the
  full word); `test_operate_modeWordAbove255_reverts` fails against the old cast. In
  River / LiquityV2 / Lista every branch already re-decoded the op as `uint8` and
  reverted, so the finding did not reach them; their dispatch now decodes it that way
  too (`test_opWordAbove255_reverts`), making the rejection a property of dispatch.

- **`UsdrifInventorySolver`'s per-call caps bounded nothing against a looping
  operator** (external report, 2026-09-28). The `sell` drain it described was
  already closed by the sell routes above; its "separate weakness" was not: the fill
  path measured only outflow, so a self-signed order paying the cap for a junk token
  could be looped — in one transaction by a contract operator. Fills now need an
  owner-priced FILL route (`fillMinRate`, one token out / one token in, measured
  rate), and both paths draw on one cumulative per-token `outflowLimit` per
  `OUTFLOW_WINDOW`. Pinned by `test_fill_inventoryForAnUnpricedToken_reverts`,
  `test_fill_belowTheOwnersRate_reverts`, `test_fill_mixedTokenShape_reverts`,
  `test_fill_loopInOneTxHitsTheWindowBudget`, `test_fill_zeroWindowBudget_refusesEverything`,
  `test_sell_drawsOnTheWindowBudget`.

**Left as accepted** (assessed, no code change): the Aave v2/v3 withdraw modules take
the aToken from item data — a self-granted taker can burn aTokens held by the module
itself, which holds only dust; the OCO claim is keyed `(maker, groupId, nonce)`
because the claim item lives inside the order it would have to hash, and only a
maker signing two same-nonce legs trips it (the SDK refuses that); the funnel's
permissionless `enableToken` can re-arm a revoked allowance, but revocation was never
the funnel's cancel primitive (`withdraw`, or `cancelOrder` via `execute`, are).

Lesson: the corpus's verdicts were written from the corpus side ("Here: correct")
and two of them were about code shapes, not code — the Liquid verdict called every
cache key "a fixed-width type-hashed struct" (the taker ref hashes an arbitrary
blob; it is injective only because it is ONE blob), and the Balancer section
credited `RoundingDirection.t.sol` with properties it did not test. A verdict is a
claim until a lens re-derives it from the tree.

### F31 — eight-lens audit of core + Permit3, optimization pass and fixes (2026-09-29)

Scope: `packages/core` (settlement, Permit3, utils), read through seven security
lenses — fill entrypoints, the items engine, the netted/batch paths, authorization
and lifecycle, pricing and gates, Permit3 and the transfer libraries, and a
differential review of the F30 diff — plus one measured-optimization lens. **No
Critical or High. Three Medium, all fixed.** The items-engine, netting,
authorization and Permit3 lenses found nothing above Info; their "verified clean"
lists re-derived the F7/F13/F15/F24 fixes from the tree.

**Optimization first, because the fixes needed the bytes.** Twelve measured
changes took Settlement from 24,570 to 23,755 bytes (−815) and made every
measured hot path cheaper on the via-IR bytecode (plain fill −296 gas,
`fillWithPermit` −500, `fillUpTo` −977, `batchFill` −1,092, bulk signatures
−1,036). The two levers worth remembering: via-IR emits a second inlined copy of a
function for a call site that passes a CONSTANT argument (`_payInputsToSolver`'s
`false` flag alone was −211 B; deriving it from data removed the copy), and every
use of an immutable is a 33-byte `PUSH32` (the Permit3 pull now reads `PERMIT3`
inside one shared `_pullViaPermit3`). Rejected-as-worse measurements are listed in
`foundry.toml`. The fixes below spent 518 of the 821 freed bytes: Settlement is
24,273 / 24,576.

**Medium — fixed.**

- **`fillUpTo` trimmed a Proportional fill down, and the filler paid for it.** A
  proportional fill pays every output in full whatever the anchor resolves to, and
  `_clampToRemaining` cut a solver's quoted size down to a balance that had shrunk
  since the quote — a maker who moved out all but 1 wei was paid in full for dust.
  The Proportional NatSpec pointed solvers at exactly this path. An oversized
  request on a proportional anchor is no longer trimmed (`OverFill`, as plain
  `fill`) unless it is the `type(uint256).max` any-size opt-in; +89 B. Pinned by
  `test_prop_fillUpTo_shrunkBalance_quotedSize_reverts`,
  `test_prop_fillUpTo_absoluteOrderStillClamps`,
  `test_lens_previewFill_proportionalOversized_revertsOverFill`.
- **Soft exclusivity was a no-op on orders whose legs cannot carry the premium.**
  The override lifts only maker-addressed SELL outputs and auctioned inputs, so on
  a swap-and-send, a deposit-only order, a BUY with no inputs, and every
  `BridgedOrderInbox` order an outsider filled in-window at the exclusive price —
  the general form of F28 #2, which had closed only the pre-fund shape. A soft
  window with no carrier is now hard (`OrderGates._overrideHasCarrier`, walked only
  for an in-window outsider); +275 B, because the gate is inlined at three call
  sites. Pinned by `test_moduleAddressedLeg_losesTheOverride` (now asserting the
  refusal), `test_thirdPartyAddressedLeg_softWindowIsHard`,
  `test_auctionedInput_keepsTheWindowSoft`,
  `test_lens_softExclusivity_noCarrier_refusedAndFlagged`.
- **The F30 delta-verify pin was only as strong as the named contract's access
  control.** An order naming an OPEN `AggregatorFillSolver` handed the pin to
  anyone; through a router that takes a caller-chosen executor the F30 attack
  returned. The solver now refuses direct orders unless gated
  (`DirectNeedsOperators`). Pinned by `test_direct_openInstanceIsRefused`.

**Low — fixed.** A relayed delegate nomination may now only EXTEND the stored
expiry (the F29-7 fix covered a permit relayed after its own expiry, not a shorter
one relayed before it): `test_relayedShorterPermit_cannotCutALiveDelegate`,
`test_relayedLongerPermit_stillExtends`. The SDK's gasless revocation reused the
nomination's default seq and always failed; revocations now use the reserved seq
`0xFF`. The lens batch could still OOG-revert on a poisoned row in a large batch —
now reserved per remaining row: `test_lens_poisonRow_largeBatch_returnsNotReverts`.
`OriginSettler7683` previewed filler-set orders as `address(1)` and broadcast
delta-verify orders no destination fill can deliver:
`test_deltaVerifyOrder_refusedByEveryEntry`. (The filler-set pair was revised by
the 2026-09-30 audit, PERIPH-7: the destination settler fills as ITSELF, never as a
set member, so an in-window hard set is now refused rather than opened —
`test_hardFillerSet_inWindow_refusedNotBroadcast` — and a soft set is quoted WITH
the outsider premium the destination fill actually pays —
`test_softFillerSet_quotesThePremiumTheInstructionPays`.) The deployed via-IR bytecode was never
tested — the core suite now runs against the shipped artifacts under
`DEPLOYED_BYTECODE=1`.

**Follow-up — the any-size sentinel on `fillWithCallback`.** With the no-trim
rule, an exact-size proportional fill is reverted by any balance drift before
inclusion — a stranger's 1-wei transfer to the maker included. `fillWithCallback`
now honours the `type(uint256).max` sentinel `fillUpTo` and `matchSettle` already
did (+52 B, Settlement 24,325). It is the right opt-in for a filler whose output is
funded by the input it measured, and `AggregatorFillSolver` is one: a shrunk anchor
fails its own route, a grown one is a bigger swap, and its fees (`SurplusPolicy`
shares, originator carve-out, maker-signed fee legs) scale with the real spread.
Pinned by `test_prop_fillWithCallback_maxSentinel_fillsResolvedAnchor`,
`test_sentinel_shrunkBalance_revertsAndTheSolverLosesNothing`,
`test_sentinel_oneWeiDonation_noLongerRevertsTheFill`,
`test_sentinel_grownBalance_fillsAndFeesScaleWithTheRealSize`,
`test_sentinel_makerSignedFeeLegIsPaid`. An inventory filler must still pass the
exact size.

**Info — fixed.** Two bump roundings leaned filler-ward by under 1 bp (the priority
improvement and a falling curve segment's decrement now round up, contract and
SDK): `test_priorityAuction_fractionalImprovementRoundsToTheMaker`,
`test_curve_fallingSegment_roundsToTheMaker`. An output leg addressed to the
`EXECUTOR` is refused on the netted path (the solver's own CALL step could take it
back) and flagged by the lens: `test_matchSettle_rejectsExecutorAddressedLeg`,
`test_lens_validateOrder_flagsExecutorRecipient`. The lens advertised partial
fills for proportional orders: `test_lens_orderState_proportionalBelowAnchor_fillableZero`.
`ChainlinkTickFloorValidator` read leg 0 of an empty blob: `test_tickFloor_emptyLeg_reverts`.
Four funding sub-rules merged into `ForLegInvalid` / `ForBalanceInvalid` in F30 had
never been pinned: `test_fundingRule_*`. About 25 stale comments and doc pages.

**Left as documented.** The fill-once + priority-auction loser pays ~14k gas, not
~5k (`pricing-modes.md`); a module with a non-reverting fallback accepts a
malformed MAKE/SETTLE as a no-op (maker-signed; filler due diligence); two TAKE
items on one module with equal slices cannot use `fillWithPermitTake` (fails
closed); the lens can still revert on a single ~130 KB+ order and can name a
different error than the fill on an already-full order.

Lesson: the optimization lens paid for the security lenses. Six bytes of headroom
had turned three fixes into doc notes; a measured pass over the codegen — not a
dial — bought them back, and the discipline that made it trustworthy was the same
one the security work uses: measure the real change, from a wiped build, against
the bytecode that ships.
