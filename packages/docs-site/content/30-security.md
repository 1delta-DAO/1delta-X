---
title: Security
slug: security
eyebrow: Security
description: The trust model, the attack vectors the design is built against, what structurally prevents each one, the invariants the code upholds, and the audit record — including what is deliberately not defended.
---

> **Status.** Nothing in this repository is deployed. The protocol has had
> several **internal** security reviews and **no external audit**. Treat it as
> research-grade code. Report suspected vulnerabilities privately to
> **security@1delta.io** — a failing Foundry test is the ideal report.

## The trust model

| Actor | Trusted? | Consequence |
|---|---|---|
| **Maker** | signs its own order; may name itself maker of *any* order | order `data` — venues, tokens, amounts, descriptors — is attacker-choosable. A maker can author a hostile order against a shared module singleton. |
| **Filler / solver** | **untrusted** | controls matching, ordering, `matchSettle` schedules, `takerData`, and may deploy arbitrary contracts (fake pools, fake tokens, fake modules) and pass them wherever an address is caller-supplied. |
| **Settlement** | trusted; the only legitimate dispatcher | an approved Permit3 spender in every maker's book; the caller pin every module rests on. |
| **Permit3** | trusted hub, but `take` / `takeFor` are **permissionless** | `approveTaker` lets any caller name *itself* spender, so `msg.sender == permit3` authorizes nothing on its own — a module reached through Permit3 always resolves `onBehalfOf` to the grantor. |
| **Venue** (pool, vault, comet, market, EVC) | decoded from order `data` ⇒ **attacker-choosable** | any approval granted to a venue hands that allowance to attacker-chosen code; it must be scoped to what the fill delivered and cleared afterwards. |

There is **no admin, no module whitelist, no upgrade path and no protocol
operator**. The absence is load-bearing: there is no privileged address to
compromise, and no role that could be granted one.

### Sources of authority

An order executes only if one of exactly three things holds, and the order hash
commits to `maker` in all three:

1. a signature from the maker (EOA / EIP-2098 / EIP-1271 / EIP-7702);
2. a signature from a key that maker itself nominated, with an expiry;
3. an on-chain approval record that maker itself wrote.

Every other gate still applies to all three — deadline, nonce, validators,
invariants, and the maker's own Permit3 caps and expiries.

## Attack vectors considered

Each vector below is stated as an attacker would state it, followed by what
structurally prevents it and where that control lives.

### Stealing a standing allowance

*"A maker must keep a taker allowance live for their resting orders. Can I
consume it?"*

Both allowance books are **spender-keyed**: `take` decrements
`(user, msg.sender, module, ref)`, so a caller with no allowance under its *own*
address reverts. Only Settlement can consume a maker's grant, and Settlement
enforces the maker-signed recipient. The `module` is part of the key, so a grant
for a borrow module cannot dispatch any other module whatever its data, and `ref
= keccak256(data)` pins every protocol parameter the module will decode.

This is the shape of the first critical finding this codebase had (a taker book
keyed by module and callable by anyone with an arbitrary receiver). The fix —
re-keying by spender — is the reason the two books now mirror each other exactly.

### Redirecting proceeds

*"The maker borrows. Can I make the proceeds land somewhere else?"*

The recipient is chosen by the trusted spender from the maker-signed item, never
by the caller. A TAKE item's `recipient` is inside the EIP-712 hash; defaulting
it to Settlement is what pays the filler, and signing `recipient = maker` is what
chains it into a following MAKE. A filler cannot change which of those it is.

### Fake modules and fake venues

*"I deploy a contract that returns success and delivers nothing, and net it
against a real user's order."*

Three properties close this:

- **The address is signed.** Both the `module` and the venue decoded from `data` live inside the maker-signed order and inside `ref`. A fake module can therefore appear only in an order the attacker authored themselves, where `onBehalfOf == maker == attacker`.
- **A fake module has no authority when called.** Called by Settlement or Permit3 it runs as a nobody: a `transferFrom`/`take` from inside it keys the spender to itself, which no victim approved; re-entering Settlement hits `nonReentrant`; and a filler's arbitrary `(target, data)` call in a match runs through an **allowance-less executor** that is an approved spender for nobody.
- **A fake module can fake a call but not a balance.** Every asset a maker receives is a real transfer out of the pool, and the pool holds only what was really pulled in. A fake TAKE credits *measured* proceeds — zero — so the order fails `LegUnfunded`.

### Position-ID confusion

*"The module is authorized on the venue for every user who onboarded. Can I point
it at someone else's position?"*

This is the sharpest drain class in the system, and two real Critical findings
here were instances of it. `ref = keccak256(data)` proves the bytes were
authorized by **someone** — never that the position named inside them belongs to
the user being charged. Because the taker book is keyed by the approver, an
attacker can self-approve a `ref` computed over a **victim's** position.

For venues whose call takes `onBehalfOf` (Aave, Compound, Morpho, Silo, Venus,
Lista) the charged user and the position are the same address by construction.
For venues that identify a position by an opaque ID and grant delegation to the
*module*, the module must resolve the owner on-chain:

| Venue | Position ID | Required binding |
|---|---|---|
| Gearbox V3 | `creditAccount` | `getBorrowerOrRevert(ca) == onBehalfOf` |
| Liquity V2 | `troveId` | `TroveNFT.ownerOf(troveId) == onBehalfOf` |
| Fluid | position NFT `nftId` | free — `transferFrom(onBehalfOf, module, nftId)` makes ERC-721 enforce it |

Two corollaries, both learned the hard way: every address on the authorization
path must be **derived on-chain** from one caller-supplied root rather than taken
from `data`, and the bindings are validated on **mainnet forks**, not mocks. One
of them was first rooted at a getter that exists in the mock and reverts on
mainnet — only the fork run caught it.

### Price manipulation and oracle failure

*"I control, or can wait for, a bad price."*

A price source never sets the price. The clock, a priority bid and an external
`pricingModule` all produce one normalized **bump**, which the core clamps to
`[0, 10000]` and maps through each leg's own signed `start`/`end`. A hostile,
buggy or stale module can move a fill anywhere *inside* the band the maker
signed and nowhere outside it. It cannot redirect a leg or introduce a token, it
must be `view`, and it is resolved once per fill.

That is the deliberate difference from an "amount getter" design, where the
maker-supplied function *is* the price and a broken one is unbounded loss.

Oracle *freshness* is enforced where the feed exposes it: the Chainlink
validators reject non-positive prices, incomplete rounds and prices older than a
maker-signed `maxStaleness`. `ChainlinkPeggedPriceModule` additionally enforces
an absolute `[MIN, MAX]` plausibility band, so a feed that is fresh and *wrong*
reverts the fill instead of pricing against it. **The trigger validators have no
such band** — see [Known gaps](#what-is-deliberately-not-defended).

### Re-entrancy and callback authentication

`Permit3.take`, the settlement entry points and the repay/operate modules carry
`nonReentrant` guards (a warm 1/2 storage guard — [not transient
storage](/optimization/#rejected-and-why)). Validators and invariants are
`staticcall`, so they cannot mutate state or re-enter at all. The netted path
needs no re-entrancy by construction: the composition a callback would express is
a schedule, and its whole context is a memory struct.

Flash-solver callbacks are authenticated by an in-flight flag **plus provider
identity** — pinned as an immutable where the provider is fixed, and recorded in
storage *before* the external call where the provider is chosen per call.
Deriving the expected provider from the callback's own payload is circular and
therefore no check at all; that was a real High finding. Providers also assert
the callback actually ran, so a "provider" that returns without calling back
cannot fall through to a profit sweep with an unvalidated order.

### Donation and balance accounting

*"I send tokens to the settler and claim them as fill proceeds."*

Settlement holds no cross-fill funds. The filler is paid from the **measured
balance delta** of the current fill's TAKE proceeds, never from a pre-existing or
donated balance, and surplus returns to the maker. The batch paths floor every
touched token at its pre-batch balance. An early finding here paid the solver out
of the whole contract balance; the fix is the rule the accounting now rests on.

### Partial-fill and slice arithmetic

*"I choose the slice count. Can I make the arithmetic pay me?"*

Every leg and every item slice scales by one fraction, so legs cannot be sized
independently, and cumulative slicing accumulates exactly to the signed totals.
Rounding is uniformly maker-favourable, so splitting costs the *filler*; the
`minFillAnchor` floor bounds grinding.

Two real findings lived here and both were about a value that *did not* pro-rate:
a composite item whose side amount sat in constant `data` (an N-slice fill
re-pulled it N times, at a leverage ratio the maker never signed) and a
`BalanceMode.Full` leg that liquidated the whole position on a one-unit fill.
Both are now guarded by a maker-signed item total and full-fill enforcement, and
the rule is checked mechanically across the module tree.

### Replay, signature and cancellation

Order replay is bounded by `filled[orderHash]`; permit replay by a bitmap nonce.
Signature malleability is accepted (matching Permit2) and is inert on-chain
precisely because nothing is keyed by the signature bytes — but an **off-chain
book must key deduplication, cancellation and rate limiting on the order hash**,
or the same order re-enters under a second identity.

The signature is re-verified only on an order's **first** fill: a non-zero
`filled` counter is itself proof that some earlier fill presented valid
authorization for that exact hash. That is a deliberate gas decision with a
documented consequence — see the caveats below — and one High finding was
exactly the corner it created: a *revoked on-chain approval* was bypassable by
passing arbitrary bytes to take the signature branch and hit the skip. Revoking a
touched approval now parks the cancellation sentinel.

### Ordering, MEV and exclusivity

Losers of a race revert on the `filled` guard rather than executing badly. Hard
exclusivity names a filler for a window; soft exclusivity prices the right to
jump the queue as a bps improvement **to the maker's leg only**, so a
third-party fee leg is never inflated by it — and where no leg can carry that
improvement, the window stays hard. The priority-auction mode makes the
sequencer's own ordering the auction: every wei of priority fee moves the tick
toward the maker's ambition, and an unbid fill clears at the maker's guaranteed
floor. Nothing new is trusted — the floor is the same absolute bound every other
order has.

A degenerate auction (zero duration) resolves to the **maker's** `start`. The
published bug in a comparable system resolved the same case to the filler's end.

### Griefing and denial of service

Maker-supplied targets — `pricingModule`, `fillModule`, validators, invariants,
item modules — are **gas-unbounded, and the filler pays**. This is an accepted
class shared with every comparable settler; the defence is filler-side
simulation, and the per-surface damage ceiling is documented rather than
pretended away.

The mirror case is a filler griefing a maker, and two were fixed: a front-runner
replaying a maker's nonce-based permit to brick a gasless order (now best-effort
`try/catch`, with the Permit3 pull remaining the gate), and a padded netted
schedule that spent a maker's **allowance twice** for one fill — the tokens came
back, the authority did not. That one generalizes: *"the funds come back" is not
"nothing was consumed"*. Allowances, nonces and one-shot authorizations are spent
by the attempt, not by the net outcome.

### Netted-path specific

The filler orders the middle of a match, so every abuse of that freedom is
considered: skipping a pull, delivering twice, interleaving an item that breaks a
venue's health check, padding the schedule, or netting a hostile order against a
real one.

- Phases 1 and 3 are **contract-owned loops** over every order — a schedule can reorder, never skip.
- Deliver and item units are guarded **exactly once, at the step**.
- Per-order completeness is asserted in the flush: an order's inputs are pulled only if every one of its output legs is funded, so pull and deliver are inseparable.
- A pre-send is bounded by the batch's own inflow, netted against obligations not yet delivered, with a whole-batch backstop.
- Item ordering policies (`ORDERED`, `ATOMIC`) are the maker's protection where a venue checks health inside a call.
- Shapes the path cannot account for are refused outright: `SETTLE` and `TAKE_FOR` items, duplicate input tokens, delta-verify delivery.
- A self-addressed output leg is refused (`OutputToSettlement`) — on the netted path the pool→pool transfer would otherwise leave the amount to be swept to the filler instead of burned.

The cross-order question — *can a counterparty sign an order that makes the
maker-favourable rounding pay out of the maker?* — is answered structurally: the
pricing has no cross-order term, so matching cannot reprice a maker, and the
slack lands in the pool. Grinding a match pays the victim more and costs the
grinder more.

### Cross-chain

The bridge hosts invert their revert posture deliberately (a bridge that reverts
on the destination strands funds; one that accepts and refunds does not). The
shared inbox authorizes destination orders by a bridged commitment turned into an
on-chain approval, forbids items, and accounts for stray funds explicitly with a
permissionless refund after a deadline; the per-user funnel authorizes by owner
signature through EIP-1271 and lets the owner withdraw at any time. A
first-credit-wins beneficiary bug in the inbox was found and fixed; the
**full-funding invariant** that replaced reservation bookkeeping is what makes
the accounting sound.

### The off-chain surface

The orderbook is not a trust boundary — orders are self-authenticating and the
on-chain fill is the real gate — but it is a *resource* boundary, so it is
defended as one: two-layer verification (cheap local checks, then a chunked
on-chain lens call, TTL-cached), a per-maker negative cache that keeps rejecting
unfunded orders O(1) amortized, RLN rate limiting on the P2P transport, and
event-driven eviction so cancellations propagate without polling.

The sharper off-chain risk is **encoder drift**: the SDK, a relayer and the
contract must agree on the order hash and on every module's `data` layout. It is
pinned by golden-hash tests on both sides and by shape tests, because two
historical format changes failed *silently* rather than reverting.

## Security invariants

The properties the code is written to uphold, each with a regression test:

1. **Taker authority is spender-keyed** — only the approved spender can consume an allowance, and it enforces the maker-signed recipient.
2. **Taker modules are Permit3-only** — `takeOnBehalf` reverts unless `msg.sender == permit3`.
3. **Maker modules are Settlement-only** — `makeOnBehalf` reverts unless `msg.sender == settlement`.
4. **`ref = keccak256(data)` with no module-side canonicalisation** — the bytes a maker authorizes are byte-for-byte the bytes the module decodes.
5. **Re-entrancy is guarded**, and callbacks are authenticated by provider identity pinned *before* the external call.
6. **Token movement is safe by default** — every transfer/approve goes through a safe wrapper tolerating non-standard tokens, in the solvers as well as the core.
7. **Validators are read-only and signer-bound** — `staticcall`, with `target` and `data` inside the typehash. `takerData` is unsigned and adversarial, and can only move a fill inside the signed band or size its fraction.
8. **Oracle freshness is enforced where the feed exposes it**, and the pegged price module additionally enforces an absolute plausibility band.
9. **Settlement holds no cross-fill funds** — the filler is paid from this fill's measured proceeds; surplus returns to the maker.
10. **Pricing is bounded by the maker's signed band, whatever chooses it.**
11. **Delta-verified delivery fails closed** — a short delivery reverts rather than silently underpaying, and the two leg shapes that would make a per-leg delta ambiguous are rejected on-chain.

## Caveats integrators must know

These are properties of the design, not bugs — but each breaks a reasonable
default assumption.

**Revoking a Permit3 allowance is not a kill switch.** Ordinary transfer legs try
Permit3 and fall back to a direct ERC20 `transferFrom` when the payer also
approved Settlement directly. For such a payer, per-order caps are not binding
and revocation does not stop fills. **A "revoke" action in a wallet or UI must
clear both surfaces.** Makers who want revocation to bind can enable **strict
mode**, which refuses the fallback for that payer; the SDK's onboarding and
revoke builders make that the default configuration, because "protected but
off by default" is the configuration nobody is in.

**Revoking a delegated signer does not bind mid-order.** Signatures are
re-checked only on the first fill, so revocation does not stop the remainder of
an order a delegate already part-filled. Same caveat as EIP-1271 makers. What
*does* bind mid-order: `cancelOrder`, nonce cancellation, the deadline, and
revoking the funding allowances.

**A signed permit batch overwrites standing allowances.** A grant is an
unconditional single-slot write, and `fillWithPermit` applies the maker's batch as
a side effect of the *filler's* transaction — so one order's batch can shrink (or
raise) the cap another order draws against. Tooling should refuse to shrink a
live allowance.

**Any contract that fills on its own behalf must defend its balance.** Output
legs are pulled *from the filler*. A contract that holds a balance, has approved
Settlement, and exposes a permissionless path making itself the filler of a
caller-supplied order is fully drainable. Scoping a standing approval does not fix
it — the attacker signs an amount equal to the balance. Three defences work: a
**balance floor** (snapshot every touched token on entry, revert if the call ends
below it), **delta-scoped per-fill approvals** cleared after the fill, or
**operator gating plus owner budgets**. The permissionless flash solvers instead
hold no balance between fills (accepted posture, X-SPEC-7).

**A TAKE item's proceeds token must appear in `legsIn`.** Proceeds landing on
Settlement are paid out by code that iterates the input legs; a proceeds token
matching no input leg is permanently stranded. It cannot be stolen — every payout
is bounded by a per-fill delta — but there is no sweep and no admin. The core
cannot enforce this because the proceeds token is inside module-specific `data`
it deliberately does not decode; order construction owns it. On `matchSettle` an
un-attributed proceeds token that is in the plan's token universe is refunded to
the maker; outside it, it strands as on `fill`. The primary guard is the lens rule:
the TAKE recipient is the maker, or the proceeds token is in `legsIn`. A
`MinBalanceInvariant` is an absolute floor and does NOT pin stranded proceeds —
other inflows can satisfy it.

**An invariant proves an end state, not a delivery.** An order with invariants and
no output leg is fillable only by its named `exclusiveFiller`, for its whole life —
enforced in the core for any invariant.

**An uncapped balance-relative leg is an offer on the maker's whole holding** —
hence the mandatory cap.

**Wallet legibility is a known cost.** Since the order's arrays became packed
blobs, EIP-712 hashes each blob as one `keccak256`, so a signer prompt shows
opaque hex rather than amounts, recipients and module addresses. The mitigation —
an ERC-7730 descriptor plus a lens-side decoder — is not built. Until it is, the
front end must decode the order and show it out of band; makers should sign only
from software they trust to do so.

## The external-corpus crosswalk

A separate review method sits alongside reading this code for defects: the
published audit corpus for this protocol class — 1inch LOP and Fusion, 0x v4, CoW
GPv2, UniswapX, Velora Portikus, plus live incidents — was distilled into fifteen
failure classes, and each was traced through this tree.

| Class | The failure |
|---|---|
| C1 | An arbitrary call made from the settler's own identity |
| C2 | Hand-rolled calldata arithmetic without a bounds proof |
| C3 | Signed-payload fields that do not bind execution |
| C4 | Authorization gates that only run on the first fill |
| C5 | The maker supplies the function that *is* the price |
| C6 | Overfill and cumulative-slice accounting |
| C7 | Rounding direction and split-fill dust |
| C8 | Degenerate auction parameters resolving the wrong way |
| C9 | One side spending the other side's gas |
| C10 | Hard-coded gas stipends on value transfer |
| C11 | The permit as a liveness bomb |
| C12 | Revocation that does not revoke |
| C13 | Preflight logic drifting from the settler |
| C14 | Assumptions about how tokens behave |
| C15 | The settler's balance treated as a shared pot |

Most of these are already load-bearing decisions here, which is the point of
keeping the crosswalk: the price module returns a clamped bump *because of* C5,
the filler's call runs through a trampoline *because of* C1, the permit is
idempotent *because of* C11. Knowing which published finding a piece of code
answers is what stops it being "simplified" back into the bug.

A second registry does the same for post-deployment bug-bounty disclosures and
incidents at comparable settlers and at every lending venue driven here —
fourteen more classes the audit corpus does not have: units and offsets,
encoder/interpreter drift, stale approvals, donation-inflated accounting, loosely
keyed ledgers.

## How the code is reviewed

- **Internal audit rounds**, each recorded with findings, severities, fixes and the regression test that pins each fix. Security-critical fixes are **mutation-tested** — the guard is removed and the test is confirmed to fail — so the coverage is known to be load-bearing rather than incidental.
- **Mainnet-fork suites** for the bindings that mocks cannot validate. At least one binding passed every unit test and reverted on mainnet.
- **A combinatorial edge-case matrix.** Ten axes (credential, lifecycle state, entry point, pricing mode, kill switch, fill granularity, leg shape, items, exclusivity, token behaviour) crossed over the axis *pairs the code actually couples*, with a verdict per cell bound to the test that pins it. It exists because several findings were bugs in a **combination** rather than in a function, which a per-feature suite cannot find. It carries a mechanical completeness check: every `revert` in the settler is a must-not cell, so an error with no test is an unpinned combination by definition.
- **Stateful invariant walks** over fill / cancel / approval / delegation state, and a schedule-fuzzed walk over the netted path.
- **Static analysis** (Slither, Semgrep) over core and periphery.
- **Source-level shape checks** — a script that enforces module invariants syntactically across every module package, because *a rule that is re-typed per call site is a rule that eventually misses a site*. Every finding in one recent audit was an instance of exactly that: a guard present on one branch and absent on its neighbour ten lines away.
- **An audit-run register** recording which files each run actually read, because a scope fixed at bundle-build time cannot cover code written afterwards. "This has been audited" is checked against that register, not assumed.

## What is deliberately not defended

- **Fee-on-transfer and rebasing tokens** are supported only for simple single-order swaps. The netted path reverts on them by design rather than mis-settling. Reported `filled` figures are nominal, so they are pre-fee.
- **Trigger validators check freshness, not plausibility.** A feed that is fresh and wrong passes a Chainlink *validator* (the pegged price *module* has an absolute band). A maker-signed `[min, max]` band per feed would close it — a validator change, costing no core bytecode.
- **Maker-supplied targets are gas-unbounded** and the filler pays; the defence is filler-side.
- **Signature malleability** is accepted on-chain, with the off-chain keying requirement stated above.
- **Wallet-legible order rendering** is not built.
- **Some venues are partial**: Gearbox credit accounts are best-effort and unvalidated; Teller borrow/withdraw are not wireable; Lista's flex borrow is `msg.sender`-only; Term Finance is structurally incompatible. Several newer packages await fork validation.

Every one of these is listed here for the same reason the crosswalk exists: an
undocumented limitation is indistinguishable from an oversight the next time
somebody reads the code.
