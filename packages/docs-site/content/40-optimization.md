---
title: Optimization
slug: optimization
eyebrow: Technical
description: Two scarce resources — gas per fill and bytes of deployed Settlement — and every technique used to buy them, what each one cost, and the optimizations that measured worse and were reverted.
---

## Two budgets, not one

A settlement contract is optimized against two independent limits, and they
frequently pull in opposite directions.

**Gas per fill** decides whether the protocol works at all. A filler fills only
when the price band covers gas plus capital cost plus margin, so every gas unit
removed from the hot path widens the range of orders that are fillable and
narrows the spread a maker pays for execution.

**Bytecode size** is a hard wall. Settlement sits within a few hundred bytes of
EIP-170's 24,576-byte limit, and a feature that does not fit cannot ship at any
price. The size constraint is the single strongest force on the architecture:
it is why exotic behaviour is a module rather than a branch, and why several
correct, finished features live outside the core.

Both are measured, never predicted. Estimates in this codebase have been wrong in
both directions — a change predicted to save gas cost +500, one predicted to be
marginal saved 495, one predicted at ~30 saved 875.

## The EIP-170 wall

Settlement does not fit under legacy codegen. Measured on the source as it
stands, the legacy profile produces roughly 33 KB against a 24,576-byte limit;
only the deploy profile — **via-IR**, `optimizer_runs = 400` — yields a
deployable artifact. via-IR is a requirement, not a preference.

The reason the first cut of the 2026-08 pricing features blew the budget is
worth stating, because it recurs:

```
baseline                                                  24,172   (404 free)
+ shape change + clocks + price hook inside bumpBps        27,254   (2,678 OVER)
```

At high optimizer settings the optimizer **inlines the pricing library at every
delivery, payout and pull site** — roughly eight copies. Branching the new modes
*inside* the innermost pricing function meant paying every byte eight times.
Three behaviour-preserving restructurings brought it back:

| Change | Bytes returned |
|---|---|
| Move the cold modes out of the inner function into a once-per-fill `resolveBump`, pinned in the fill context | **1,343** |
| Verify a bulk signature by swapping the digest into the existing signer set, rather than emitting a second copy of the recovery path | **~1,000** |
| `bytes pricing {target, data}` → a plain `address pricingModule` (a 7th dynamic member grows the `Order` decoder at *every* external entry point) | **~1,000** |

The same trap recurred later with the delta-verify guards: they first cost 1,201
bytes because a duplicate-leg scan added a second inline decode site; caching the
decoded pairs into memory gave one decode site and returned 958 of them.

### The `optimizer_runs` curve is not an escape hatch

```
runs      Settlement runtime      free
20,000        (over cap)         FAIL
1,500          24,522                54   fits, but one PR from failing
800            24,331               245
400            24,186               390   ← the deploy profile
200            24,179               397   floor; nothing below 400 buys more
```

The curve is **not monotonic in either direction** — a pristine source measured
24,172 at 20,000 runs but 26,149 at 6,000, because the setting moves inlining
decisions in steps. So a size change must always be measured; and because the
curve is flat below 400, lowering runs is not a way out of a size regression. The
low setting also costs runtime gas on the deployed contract — a deliberate trade
of speed for the ability to deploy at all, and it is confined to the deploy
profile so everything else stays at the fast setting.

**Rule: the gas baseline does not measure the deployed contract.** The committed
snapshot runs the legacy profile; production deploys via-IR at a different
optimizer setting. The two disagree, sometimes badly — one added comparison read
as +232 gas per fill in the snapshot and +40 under via-IR, because the legacy
number was a stack spill rather than opcodes. Never reject a change on the
snapshot figure alone.

## Techniques that landed

### Packed order arrays

The order's six arrays — input legs, output legs, items, validators, invariants,
curve points — are **packed count-prefixed `bytes` blobs** rather than struct
arrays. Fixed-stride members (legs, curve points) are indexed in O(1); records
with a trailing dynamic `bytes` (items, validators) are walked sequentially.

*Won:* roughly 2.4 KB of Settlement and a large cut in hashing and access cost —
EIP-712 hashes each blob as one `keccak256` instead of hashing every element.

*Cost:* three real ones, all accepted deliberately. **Wallet legibility** — a
signer prompt now shows opaque hex blobs rather than amounts and recipients, and
the ERC-7730 descriptor that would fix it is not built. **A 255-element cap** per
array. And **manual validation**: `calldataload` zero-pads past the end of
calldata rather than reverting, so each blob is validated once up front and the
count is then reused by unchecked accessors — a rule that is mutation-tested,
because deleting the length check is otherwise invisible.

A related move: `side` left the struct for a `timing` bit — −495 gas per fill and
−128 bytes. It is not derivable from the legs (a fixed-price order has `end == 0`
on both sides, and a SELL may carry a rising fee input), so it had to be signed
somewhere; a bit is the cheapest place.

### Hashing by walking calldata

Each array member used to allocate a `bytes32[]`, ABI-encode every element into
its own fresh buffer, then concatenate the whole array before hashing. All three
allocations are removable: element hashes accumulate into a **raw contiguous run
in scratch memory** above the free-memory pointer — never bumped, because the run
is consumed by the final `keccak256` — with a fixed element buffer parked just
past it. For static structs the calldata is already a flat run, so elements are
read with plain `calldataload`s: no decode and no re-encode at all.

*Won:* about two thirds of a −3,780-gas pass over a simple fill, and −23.8% on
`hashOrder` alone. The same technique applied to the permit hashers took another
1,259–2,532 off the permit paths.

*Cost, and the trap:* every non-`bytes32` word must be **masked to its declared
width**. `abi.encode` cleans addresses and zero-extends small integers; a blind
`calldatacopy` does not, and the calldata decoder does not reject dirty padding.
Getting it wrong is a *compatibility* failure rather than theft — a digest the
signer never produced authorizes nothing — but it would diverge from the SDK and
make orders fail to verify. Two guards make that safe to live with: a
**differential fuzz test** against a naive reference encoder over all array-length
shapes (plus a dirty-padding case), and a convention that every assembly block
carries an `EQUIVALENT SOLIDITY:` doc block whose body *is* the reference
implementation in that test — so the comment is executable spec rather than prose
that can rot.

### Skipping work that is already proven

- **Signature re-verification stops after the first fill.** A non-zero `filled` counter is itself proof that an earlier fill presented valid authorization for that exact hash. +150 gas on a first fill, **−2,860 on every fill after it** (−14,531 across a TWAP schedule). *Cost:* an EIP-1271 maker or a delegate can no longer revoke mid-order — `cancelOrder`, the nonce, the deadline and allowance revocation are the switches that still bind. It also created one real High finding (a revoked on-chain approval reachable through the skip), now fixed.
- **Fill-once mode** settles against the maker's nonce bitmap instead of a fresh storage slot: **−19,275 gas**, measured. *Cost:* requires a full fill, burns the nonce so siblings sharing it die too, and `remaining()` no longer reports — consumers must read the relevant-state view.
- **`fillCompact`** takes an EIP-2098 compact signature: exactly 96 fewer calldata bytes, as a distinct name rather than an overload (same arity would make off-chain libraries pick the wrong selector).
- **Cancellation is free on the hot path.** `cancelOrder` parks a sentinel in the `filled` slot every fill already reads, so the check is one compare rather than a new SLOAD.

### Pay-per-use seams

The fungible legs are settled inline. Everything else — item modules, fill
modules, price modules, validators — is a maker-signed dispatch that an order
which does not use it pays nothing for. The identity default (`fillModule == 0`,
`fillTotal == 0`) is byte-for-byte the classic fungible fill, and an order with
no price module pays a single calldata compare.

This is why the feature set is broad but the median cost is not: across the whole
suite, the 2026-08 parity features cost a median **+283 gas (+0.09%)**, and the
canonical plain swap **+369 (+0.07%)**.

A price module is also **resolved once per fill and pinned**, so a multi-leg
order pays one staticcall rather than one per leg.

### Funnelling duplicate entry points

Three entry points shipped as pairs of overloads (with and without `takerData`)
whose bodies were byte-for-byte duplicates apart from that argument. Each
overload emitted its own copy of the marshalling — and, for the permit entry, its
own copy of one of the largest ABI encoders in the contract.

Funnelling each pair into one private body: **−687 bytes** (headroom 235 → 922,
about 4×) for **+55…76 gas per fill** — 0.011% of a 505k fill — and −50k deploy
gas, with no ABI change.

The contrast with the failures below is the lesson: extracting bodies into a
*library* or a per-call-site private helper **adds** bytecode, because a private
function is emitted per call site and a library boundary pays for ABI encoders.
What works is funnelling two *external* entry points into one shared body, where
the compiler emits the body once and both selectors jump to it.

### Constant-folding a type string

Passing the allowance hub a **folded witness typehash** instead of the witness
type *string* removed **538 bytes** (24,997 → 24,459) and took the contract from
421 bytes over the limit to comfortably under.

The measurement that decided it is the method worth copying: stub each candidate
out, clean-build, diff. Hand-writing assembly at the obvious call site had a hard
325-byte ceiling — the string was the real cost, and dropping it at one site
saved nothing because the constant was shared with a second site.

*Cost:* the type text now appears twice in one file, so two tests re-derive both
constants from the type string and fail on drift. The constants must be written
as `keccak256(<literal>)` so the fold happens at parse time; writing them as a
runtime concatenation puts the bytes back *and* re-hashes on every fill.

### Push-funded module legs

One-sided modules were migrated from a pull-shaped funding seam to a
**push-funded** one with a delivery ledger in the fill context: the settler
delivers into the module rather than the module pulling from Permit3. Fifteen
modules moved, for **−39.8k gas** on the affected shapes and zero receive-side
approvals. The bytecode it cost was bought back by hand-rolling one
encode/decode round trip (−209 bytes), which is what kept the size gate green.

### Filler side: losing cheaply

In a permissionless market, most attempts lose a race. Two measured results shape
the reference fillers:

- **Guard on the `filled` counters before touching the plan.** A lost `matchSettle` race costs **3.9k gas instead of 34k** (−88%), and the gap widens with plan size. The guard is an exact-equality check rather than "is there room left", so a partially-filled plan fails fast instead of executing a plan that no longer prices.
- **Gate before the reentrancy guard.** On the priority-auction path a lost race fell from **11,244 to 5,616** gas by letting a read-only gate run before the guard is armed. Four entry families therefore arm the guard by hand instead of wearing the modifier, under a documented rule: nothing before the arming may call out.

Compact calldata was measured as a way to cut filler cost further and is a dead
end at this scale — the packed encoding already removed the bytes worth removing.

### Loop and calldata micro-rules

An audit of every loop in the core produced four rules that decide these cases
without re-measuring:

- A calldata array reached through a local is a stack value — hoisting its length buys nothing.
- A calldata **struct member's** length costs an offset load plus a length load per re-read — hoist it.
- A memory array's length is an MLOAD per re-read — hoist it.
- **Hoisting only pays if the loop actually iterates.** On loops that match or exit on the first iteration, the extra local costs more than it saves (+19…+45 measured).

The same pass replaced per-field re-resolution of calldata struct members with
one resolved pointer — the pricing path was re-resolving an output leg four times
— for −1,115 on a simple fill and −1,804 on a balanced netted match.

## Rejected, and why

Every row here was built or measured, and then reverted.

| Rejected | Measured | Why it lost |
|---|---|---|
| Transient storage for the reentrancy guard | −1,990…−3,832 gas/fill | **Portability.** Target chains predate Cancun, so TSTORE/TLOAD is not universally available. The gas was never the deciding factor. |
| A delegatecall "batch facet" to solve the size wall | worked; Settlement 22,680 + facet 20,384, all tests green | **Audit surface.** Proxy-class patterns add storage-layout coupling, immutable and domain pitfalls and direct-call bricking, which this codebase will not take on even when the implementation is sound. |
| External-library extraction of the netted-path bodies | only −506 bytes net | The ABI encoders for the rich `Order` struct at each library boundary cost as much as the extracted bodies. A dead end for struct-heavy code. |
| A private library helper for a cold pricing branch | **+2,430 bytes** | A private library function is emitted **per call site**, and that function is reached from three contracts. Keep cold branches inline. |
| One shared assembly encoder for the three item dispatches | **+1,862 bytes** | via-IR already emits the encoder once and shares it across all three sites; an internal assembly helper gets inlined three times instead. The technique pays for nested structs and strings — a shape this codebase does not have. |
| Merging the validator and invariant walks behind a flag | **+389 bytes** | Same reason: the compiler was already sharing the encoder. |
| `uint128` leg amounts sharing one word | calldata −38%, but **+457…+685 gas/fill**, 335 of 423 tests worse | The shift-and-mask to split the word costs more than the `calldataload` it saves, and a leg is decoded several times per fill. (Note the measurement blind spot: contract-to-contract calls pay no per-byte calldata cost, so the harness shows only the cost side.) |
| Memoizing the bump in the fill context | +34…+170 on ordinary fills | An extra memory word and a branch on every fill, for a payback only curve-priced multi-leg orders see. |
| A half-measure on the hashing rewrite (reuse one buffer, keep the structure) | −603 vs −1,115 for the full rewrite | Per-field function calls and an unfreed allocation ate the gain. **Go all the way or not at all.** |
| Raw-hashing the order struct | would have been the cheapest hash available | **Unsound.** A calldata struct has no recorded encoded size, so deriving an end from the caller's offsets is a signature-replay vector: shorten the hashed range and two distinct orders share a digest. Prefixing the typehash does not help. |
| Metadata stripping | −54 bytes | Not worth the loss of source verification metadata. |

### What the byte budget refused

Two finished, correct features do not live in the core because of size, and both
show what the constraint actually buys:

- **Multi-token proportional legs.** Balance-relative markers on legs beyond the first were implemented and sound, but cost **+2,106 bytes** because the balance read inlines at every pricing site. Buying that back by lowering the optimizer setting would have charged roughly **+4,300 gas to every fill of every order**. Expressed instead as a `SETTLE` module: zero settler bytes, gas only when used.
- **Hoisting the gate's order re-encode.** Re-encoding the whole order once per validator and once per invariant is the largest single cost left on the gate path — priced at 3,152 gas for a one-leg order rising to 4,903 with four legs and four items, *per gate*. A hoisted encode-once-and-patch variant is a flat 1,603, i.e. −1,549…−3,300 per **extra** gate — but **+136 on a single-gate order**, which is the common shape, and it puts hand-rolled ABI tail-patching on the security-gate path with a buffer that must survive item execution. Deliberately not shipped: worth doing eventually, with its own design and review, not as a drive-by.

## How anything gets measured

The method matters more than any individual number, because the traps below
produced confidently wrong results before they were understood.

- **A committed gas baseline plus a per-change diff.** Change one thing, measure, keep or revert. The baseline is a CI gate, so it has to be regenerated deliberately — a stale baseline once showed 480 diffs on a clean tree.
- **Never compare two fills back-to-back in one test.** They share warm token balance slots, so whichever runs second looks ~37k cheaper for reasons unrelated to the change. Use state snapshot/revert so both run from identical state — that is what turned a fake 76k "saving" into the real, exactly predicted 19,275.
- **Always clean-build before measuring size.** Warm artifacts once read ~110 bytes low, which hid a tree that was actually *over* the limit.
- **Measure via-IR for hot-path decisions**, not only the legacy snapshot (see the profile rule above).
- **Some diffs are noise.** A persisted fuzz corpus makes a fuzz test run 257 times instead of 256, moving its mean between two runs. That is not a regression; chasing it wastes a day.

## The tradeoffs, summarized

| What was bought | What it cost |
|---|---|
| Packed arrays: −2.4 KB, cheaper hashing | Opaque wallet prompts; a 255-element cap; manual blob validation |
| Assembly hashing: −24% on `hashOrder` | A masking trap, answered by a differential fuzz test and executable-spec comments |
| Signature skip: −2,860 per repeat fill | Contract makers and delegates cannot revoke mid-order |
| Fill-once mode: −19,275 | Full fills only; `remaining()` no longer reports |
| via-IR at low optimizer runs: the contract deploys at all | Runtime gas on the deployed contract; a gas baseline that is not the deployed artifact |
| Pay-per-use module seams: a median +0.09% for the whole feature set | Every exotic behaviour is an extra contract to review and an address in the order |
| Netted settlement: zero filler inventory | A filler-ordered region, defended by contract-owned open and flush phases |
| Keeping the warm-storage reentrancy guard | ~2–4k gas per fill, paid for portability to pre-Cancun chains |
