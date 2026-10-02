# Security

This document describes the security model of the 1delta-x intent-settlement
system, the invariants each component upholds, and the findings + fixes from the
internal security audits of 2026-06-18, 2026-07-29, 2026-08-06, 2026-08-25 (the
external-corpus crosswalk, F1–F15) and the 2026-09-30 whole-tree audit (F32;
write-up and remediation status in
[docs/audit-2026-09-30-full-tree.md](docs/audit-2026-09-30-full-tree.md)).

- [Architecture & trust model](#architecture--trust-model)
- [Security invariants](#security-invariants)
- [Caveats integrators must know](#caveats-integrators-must-know)
- [Audit (2026-06-18): findings & fixes](#audit-2026-06-18-findings--fixes)
- [Audit (2026-07-29): findings & fixes](#audit-2026-07-29-findings--fixes)
- [Audit (2026-08-06): the remaining open items](#audit-2026-08-06-the-remaining-open-items)
- [Audit (2026-08-25): external-corpus crosswalk](#audit-2026-08-25-external-corpus-crosswalk)
- [Audit (2026-09-30): whole-tree audit](#audit-2026-09-30-whole-tree-audit)
- [Breaking change for integrators](#breaking-change-for-integrators)
- [Reporting a vulnerability](#reporting-a-vulnerability)

> **Integrators:** the 2026-07-29 and 2026-09-30 audits changed the off-chain
> signing format for several modules and the Settlement fill ABI — read
> [Breaking change for integrators](#breaking-change-for-integrators) before
> writing or updating an encoder or a filler.

---

## Architecture & trust model

The system has three on-chain layers and no admin role / no module whitelist —
authority comes entirely from a maker's EIP-712 signature plus their Permit3
allowances.

```
   maker (EIP-712 order + permits)
        │
        ▼
   Settlement ───────────── the only trusted "spender" ────┐
        │  fill(order, sig, amount)                          │
        │                                                    │
        ├─ MAKE item ─▶ IMakerModule.makeOnBehalf(...)       │  gated: msg.sender == settlement
        │                 └─ permit3.transferFrom(...)  ◀─────┤  token book (spender = module)
        │                                                     │
        └─ TAKE item ─▶ permit3.take(module, maker, ...)  ◀──┘  taker book, key (maker, settlement, module, ref)
                          └─ ITakerModule.takeOnBehalf(...)      gated: msg.sender == permit3
                                └─ protocol borrow/withdraw
```

### Permit3 — the allowance hub

Permit3 holds **two allowance books**, both keyed by **spender** (the address
allowed to consume the allowance), exactly like Permit2:

| Book  | Key                              | Consumed by                                   |
|-------|----------------------------------|-----------------------------------------------|
| Token | `(user, spender, token)`         | `transferFrom(user, to, token, amount)` — `msg.sender == spender` |
| Taker | `(user, spender, module, ref)`   | `take(module, user, amount, receiver, data)` — `msg.sender == spender`, `ref = keccak256(data)` |

The taker book lets a module pull *value out of a position* (borrow, withdraw,
unstake, claim) — operations that don't fit the ERC20 `transferFrom` shape.
`take` decrements the `(user, msg.sender, module, ref)` allowance and then calls
`module.takeOnBehalf(...)`, which performs the protocol-native call.

**The `module` is part of the key** (2026-08-17 audit fix S-2). `ref =
keccak256(data)` alone did not bind the module, and the shipped module `data`
layouts are deliberately minimal (`abi.encode(comet)`, `abi.encode(cToken)`, a
`MarketParams`), so two distinct modules routinely shared a `ref`. Naming the
module in the key makes an `approveTaker(spender, borrowModule, ref, …)` grant
unusable to dispatch any *other* module, whatever its data — the property is now
per-allowance, not merely per-signature. `TakerPermit`, `approveTaker`,
`takerAllowance`, `revokeTaker` and `SpenderRefPair` all carry the module.

### Modules — adapters grouped by the standing grant they consume

Modules used to be one operation per contract. Since the 2026-09 grant merges they
are grouped by **the standing venue grant they consume**: `AaveV3CreditModule`
(borrow + leverage), `DolomiteOperatorModule`, `EulerV2OperatorModule`, and the
Comet, Morpho, Silo, Venus, Exactly, Liquity, Lista and River `*TakerModule`s
multiplex several ops behind a leading `op` word. **The granularity unit is now
`(module, ref)` with the op inside `data`**: because the op is inside
`ref = keccak256(data)` and the taker book is keyed on `(module, ref)`, a taker
grant signed for one op cannot dispatch another, exactly as when the ops were
separate contracts (`tools/check-module-shapes.py` rule 7 requires every multi-op
module to reject an unknown op). What no longer separates ops is the **venue
grant**: `setOperators`, `setAccountOperator`, `setAuthorization`, `allow` and
`setIsAuthorized` are one unscoped boolean over the whole account, so the
containment boundary for those venues is the standing venue grant, not the module
address. See [docs/approval-surface.md](docs/approval-surface.md#how-many-addresses-hold-the-grant-2026-09-10).
Modules come in these shapes:

- **Taker modules** (`ITakerModule.takeOnBehalf`) — borrow/withdraw. Reachable
  **only** through `Permit3.take`; they enforce `msg.sender == permit3`.
- **FUSED modules** (also `ITakerModule`) — a deliberate, documented exception:
  one call that performs a value-IN leg and a value-OUT leg together (supply +
  borrow, repay + withdraw, a debt swap). They exist because some protocols check
  health *inside* the value-out call, so the two legs are only valid back-to-back;
  fusing makes that ordering internal instead of a scheduling obligation the solver
  must honour. **This relaxes the one-operation rule, and the granularity is
  recovered by the allowance key rather than by the module boundary:** the taker
  allowance is keyed on `(module, ref = keccak256(data))` and amount-capped, and a
  fused module's `data` names BOTH legs (pool, both assets, both totals). So
  approving a fused `(module, ref)` authorises exactly that composite at those
  parameters — strictly narrower than approving a generic borrow module for any
  amount, and (since S-2) unusable to dispatch any other module — and the value-in
  leg is separately capped by the maker's ordinary token allowance to that module.
  Reference implementation + the equivalence and pro-rata tests:
  `packages/modules/lending/aave-v3/src/AaveV3CreditModule.sol`.
- **Maker modules** (`IMakerModule.makeOnBehalf`) — deposit/repay. Called
  **only** by Settlement; they enforce `msg.sender == settlement`.

### Settlement — the only trusted spender

`Settlement` is the only address makers approve as their **taker-book** spender and
as the token-book spender for their legs. Makers also approve **modules** as
token-book spenders (a pull MAKE module draws the maker's asset itself, see the
diagram), and Aave v2/v3 withdraw modules take a **direct aToken ERC-20 approval**
(or an aToken EIP-2612 permit) to the module, outside Permit3 — that grant is not
revoked by `lockdownAll`, though every pull through it is still gated by the
taker-book allowance. Settlement verifies the EIP-712 order, runs pre-execution
validators, executes items pro-rata, runs post-execution invariants, and pays the
solver from the proceeds **produced by that fill only**.

### Who may authorize an order

Authorization is the maker's signature, **or** a signature from a key that maker
itself nominated, **or** an on-chain record that maker itself wrote. There is no
fourth source, and in particular **no protocol-level operator**: no admin-set
address can sign for a user, and no role exists that could be granted one.

The delegated-signer registry
([`OrderState.orderSignerExpiry`](packages/core/src/settlement/OrderState.sol))
is keyed **by `msg.sender` on write** and **by the order's own maker on read**.
Those two facts bound it completely:

- nobody can nominate a signer for another address;
- a delegate's reach is exactly *orders naming its nominator* — the order hash
  commits to `maker` — so it can author nothing that maker could not have
  authored itself, and nothing at all for anyone else;
- delegates cannot appoint further delegates: the relayed nomination permit
  (`setOrderSignerWithSig`) is verified against `maker` through the shared
  verifier, never through the delegated branch, so the nomination graph is
  exactly one level deep.

A delegated order is gated by every other check unchanged — deadline, nonce,
validators, invariants, and the maker's Permit3 allowances with their own caps
and expiries. Full design: [docs/delegated-signers.md](docs/delegated-signers.md).

---

## Security invariants

1. **Taker authority is keyed `(user, spender, module, ref)`.** A taker allowance
   can be consumed only by the spender the user approved, only for the module
   named in the grant, and only for the exact `ref = keccak256(data)`. For a maker
   that spender is Settlement, which enforces the maker-signed `recipient` of the
   proceeds. `Permit3.take` / `takeFor` are **permissionless for SELF-grants**: any
   caller may `approveTaker` itself as spender and then `take(module, user = self,
   …)` against its OWN positions — that is harmless by construction, because the
   grantor and the charged user are the same address. A caller with no allowance
   under its own address for that `(user, module, ref)` reverts
   `InsufficientAllowance`.
   *(Regression test: `Permit3.t.sol::test_take_revert_unauthorizedSpender_C1`.)*

2. **Taker modules are Permit3-only, and that check authorises nothing by
   itself.** Every `takeOnBehalf` reverts unless `msg.sender == permit3`. That pin
   establishes only that Permit3's taker book was consulted; it does NOT establish
   that Settlement dispatched the call. `onBehalfOf` is the **grantor** whose
   `(onBehalfOf, spender, module, ref)` bucket was spent, so a module may act only
   on positions of `onBehalfOf`, and a module that spends its OWN balance must also
   pin the forwarded `spender` to Settlement (`PreFundGuard.requireSettlement`,
   shapes rule 3) — see [docs/module-security-model.md](docs/module-security-model.md).

3. **Maker modules are Settlement-only.** Every `makeOnBehalf` reverts unless
   `msg.sender == settlement`, so an attacker cannot force unsolicited
   deposits/repays that consume a victim's standing token allowance.

4. **`ref = keccak256(data)` with no module-side canonicalisation.** The bytes a
   maker authorises are byte-for-byte the bytes the module decodes. The module is
   part of the taker-book key (S-2, 2026-08-17), so a grant over one module's `ref`
   cannot dispatch any other module whose `data` happens to hash the same. (The
   older argument — "the order binds the module, so it need not enter `ref`" — was
   the pre-S-2 containment story and is superseded.)

5. **Reentrancy.** The load-bearing locks are the **dispatchers'**: Settlement
   holds its lock around every fill, including every MAKE/SETTLE dispatch, and
   Permit3's single shared lock covers `take`, `takeFor` and `permitTake*`. Every
   module entrypoint is pinned to `msg.sender == settlement` or `== permit3`, and
   no module ever pays out a raw self-balance (I-16, shapes rule 8): every payout
   is a same-call delta. Several modules also carry their own `_locked` guard, but
   some deliberately do not — `DolomiteOperatorModule`, `GearboxCreditRepayModule`,
   `EulerV2OperatorModule` and `AaveV3CreditModule` (rationale and proof in
   `DolomiteOperatorModule` and `test/audit/ReentrancyWindow.t.sol`). A module
   guard becomes REQUIRED when a MAKE seam is merged into a contract that holds
   custody or reads a raw balance across an external call.
   Flash-solver callbacks are authenticated by an in-flight flag plus the provider
   identity — pinned as an **immutable** where the provider is fixed, and, where the
   provider is chosen per call (Euler EVK vaults), recorded in storage by
   `_armProvider` BEFORE the external call and checked by
   `_requireInFlashFromArmed`. Deriving the expected provider from the callback's
   own payload is circular and therefore no check at all (audit H-5). Initiator
   handling per provider: Aave checks `initiator == this`; Midnight checks
   `caller == this`; Morpho and the Euler EVK call back only their own caller;
   Balancer has no initiator, so the callback is bound to the payload the solver
   committed before the flash. The callback gate closes as soon as the provider
   returns (`_providerReturned`), and the per-call providers assert the callback
   actually ran. **Arming stops injection into an honest flash, but it does not
   stop a caller from driving the solver with its OWN fake provider**: the solver's
   identity (and any residue it holds) is then reachable by anyone, which is why
   the flash family sweeps every fill's profit out and refuses SETTLE items
   (`SettleItemsUnsupported`) — see the caveat on self-filling contracts below.

6. **Token movement is safe-by-default.** All ERC20 `transfer`/`transferFrom`/
   `approve` go through [`SafeTransferLib`](packages/core/src/utils/SafeTransferLib.sol)
   (`safeTransfer`, `safeTransferFrom`, `forceApprove`) — tolerating non-standard
   tokens (USDT-style no-return / approve-race). This now covers
   `packages/solvers` too (audit L-3): before that, no solver could fill a USDT
   leg at all, and a `false`-returning token turned the flash-repayment transfer
   into a silent no-op.

7. **Validators are read-only and signer-bound.** They run via `staticcall`
   (no state change, no reentrancy), and their `target` + `data` are in the
   order's EIP-712 typehash, so a solver cannot weaken or swap them.
   Validators also receive the filler address (the fill's `msg.sender`, or the
   threaded caller for `batchFill`) and can express filler-conditional policy
   such as per-order solver whitelists; the gate remains read-only and
   signer-bound.
   Validators additionally receive a filler-supplied `takerData` blob (the same
   blob for every validator + invariant of a fill), threaded from the fill
   entrypoint. `takerData` is **unsigned and adversarial** — it is NOT part of the
   maker's signed order and any filler can set it to anything — so a validator
   MUST independently verify anything it reads from it before trusting it (e.g.
   recover a maker-chosen trusted signer over an EIP-712 digest bound to the
   on-chain `filler` and the validator's own domain, as `FillerAttestationValidator`
   does). `takerData` cannot alter the maker's signed TOKENS or RECIPIENTS: the three
   consumers are a validator/invariant (a read-only gate that can only pass or fail
   the fill), a fill module (which picks the fill FRACTION, under the core's
   over-fill cap and uniform per-leg scaling), and — since 2026-08 — a price module
   (which picks the BUMP, which the core clamps to `[0, 10000]` and maps through the
   maker's own signed `start`/`end`). So the most `takerData` can do to the maker's
   economics is move a fill to a different point INSIDE the band that maker signed,
   or size the fraction it advances; it can never price outside the band, redirect a
   leg, or introduce a token.

8. **Oracle freshness is enforced *where the feed exposes it*.** Chainlink
   validators reject non-positive prices, incomplete rounds, and prices older than
   a maker-signed `maxStaleness`. `MocPriceBandValidator` **cannot** match that:
   classic MoC `peek()` has no `updatedAt`, so a frozen feed reads in-band
   indefinitely. It rejects zero prices and honours the provider's validity flag,
   and that is the whole of its liveness story — orders relying on it must bound
   their own exposure with a short expiry.
   `ChainlinkPeggedPriceModule` — which PRICES rather than gates — additionally
   enforces an absolute `[MIN_ANSWER, MAX_ANSWER]` plausibility band, so a feed
   that is fresh and *wrong* reverts the fill instead of pricing against it. The
   trigger validators still have no such band; see FEATURES.md's gap list.
   **`maxStaleness` does not cover an L2 sequencer outage** (2026-09-30 PRICE-8):
   a feed can look fresh to the first transactions after a sequencer restart. The
   Chainlink validators accept an optional trailing `(uptimeFeed, gracePeriod)`
   pair (`ChainlinkRead.checkSequencer`), which should be signed on every rollup;
   `ChainlinkPeggedPriceModule` takes the pair as immutable constructor arguments.
   `MocPriceBandValidator` now reverts (rather than reading false) on a zero price
   or a reversed band (VAL-2).

9. **Settlement holds no cross-fill funds.** The solver is paid from the TAKE
   proceeds of the current fill (measured as a balance delta), never from any
   pre-existing or donated Settlement balance; surplus is returned to the maker.

10. **Pricing is bounded by the maker's signed band, whatever chooses it.** The
   clock, a priority-fee bid, and an external `pricingModule` all produce one
   normalized bump that the core clamps to `[0, 10000]` before mapping it through
   each leg's own `start`/`end`. A price module is consensus-critical and
   maker-signed (exactly like a validator), MUST be `view`, and is resolved once
   per fill; a hostile or broken one can only move the price INSIDE the band the
   maker signed — never outside it, and never to another token or recipient.
   See [docs/pricing-modes.md](docs/pricing-modes.md).

11. **Delta-verified delivery fails closed.** An order may opt into having its
   output legs VERIFIED by the recipient's measured balance delta (`timing` bit
   104) instead of pushed as a nominal amount — the settlement-level form of the
   "measure the delta, `require` at or above the signed amount" rule that H-3 and
   M-10 imposed on modules. The required amount is the leg's own priced amount, so
   the guarantee is the maker's signed output NET of any transfer fee; a short
   delivery reverts (`DeltaTooLow`) rather than silently underpaying. Two shapes
   would make a per-leg delta ambiguous and are rejected on-chain: two output legs
   sharing a `(token, recipient)` (one delivery would satisfy both checks —
   `DeltaVerifyDuplicateLeg`) and a maker-bound output token that is also an input
   token (the measurement would be net, not gross — `DeltaVerifySameToken`). The
   mode is callback-only and refused on the netted path, and fillable ONLY by the
   order's named `exclusiveFiller`: the check counts any balance increase across
   the fill, so an unnamed filler could route the maker's OTHER paid intent (on
   another venue, same token) through its callback and pass it off as this
   delivery (F30). The maker therefore trusts the filler it names to run the
   callback, and a reflection/rebasing token can still supply part of the delta —
   prefer plain fee-on-transfer tokens.

12. **An invariant proves an END STATE, not a delivery** (2026-09-30 VAL-1). An
   ownership or balance invariant ("the maker owns NFT #7", "balance ≥ X") cannot
   tell THIS fill's delivery from any other inflow — a second bid, another venue, a
   purchase the maker made elsewhere. With no output leg, nothing else binds the
   filler, so an open filler could collect the maker's payment and deliver nothing.
   Settlement therefore enforces the sibling of invariant 11 on-chain, for ANY
   invariant including third-party ones (`Base._runInvariants`): **an order with
   non-empty `invariants` and an empty `legsOut` can be filled only by its named
   `exclusiveFiller`, for its whole life** — no exclusivity window, no soft
   override; position items (MAKE/TAKE/TAKE_FOR) do not lift it; an open order or
   `FILLER_SET` fails closed (`OrderGates.NotExclusiveFiller`). An order with an
   output leg is untouched: the leg is the receipt and the invariant an extra
   floor. The shipped invariants (`Erc721OwnerInvariant`, `Erc1155BalanceInvariant`,
   `MinBalanceInvariant`) also enforce the rule themselves through
   `InvariantReceiptGuard` (`ReceiptNeedsNamedFiller`), as defence in depth, and
   `SettlementLens.validateOrder` / SDK `packOrder` refuse the shape.
   `MinBalanceInvariant` is an ABSOLUTE floor: it does not prove that stranded TAKE
   proceeds reached the maker (see the TAKE-proceeds caveat below).

---

## Caveats integrators must know

These are properties of the design, not bugs — but each one breaks a reasonable
default assumption, so they are stated explicitly.

### Revoking a delegated signer does NOT bind mid-order

`Signatures._verifySignature` re-checks a **signature** only on an order's first
fill: a non-zero `filled[orderHash]` is itself proof that some earlier fill
presented valid authorization for that exact hash, and the hash commits to
`maker`. So `setOrderSigner(delegate, 0)` does **not** stop the remainder of an
order the delegate already part-filled.

This is the same caveat EIP-1271 makers already have (a wallet that starts
returning `false` does not block a part-filled order either), and it is the price
of not re-running `ecrecover` on every partial fill. The kill switches that *do*
bind mid-order are unchanged:

- `cancelOrder(order)` — that specific order, by hash;
- nonce cancellation — `cancelOrders` / `invalidateNonceWord` / `rollbackNonces`;
- the order `deadline`;
- revoking the Permit3 allowances that fund the fill.

A direct `setOrderSigner` that LOWERS a stored expiry also burns the delegate's
relayed-permit word (2026-09-30 X-DIFF-CORE-3), so outstanding unrelayed
nominations die with it; the price is that gasless re-extension of that delegate is
gone until the maker nominates again.

The on-chain `approveOrder` path is deliberately **not** subject to the skip: it
is a mutable record the maker is told they may withdraw, so it is re-read on
every fill.

### A contract delegate is named by the FILLER, in the signature

A Safe or passkey delegate cannot be reached by address recovery, so the filler
prepends it: `sig = abi.encodePacked(delegate, innerSig)`. This grants the filler
nothing — the registry lookup is keyed by the order's maker, so only addresses
that maker nominated pass.

The branch is reachable **only** when the signature is not 64/65 bytes **and** the
maker has no code — a combination that previously always reverted
`InvalidSignatureLength`. A contract maker therefore never reaches it and falls
through to its own `isValidSignature` unchanged. **Neither condition may be
relaxed**, or an envelope could shadow a legitimate 1271 payload. Encoders must
not emit an `innerSig` of 44 or 45 bytes, since a 64/65-byte total would be read
as a plain ECDSA signature instead.

*(Regression test:
`DelegatedOrderSigner.t.sol::test_contractMakerWithLongSig_notReadAsAnEnvelope`.)*

### An uncapped balance-relative leg is an offer on the maker's whole holding

A [`Proportional`](packages/core/src/settlement/Proportional.sol) leg fills whole,
so every output leg pays its full signed amount regardless of what the anchor
resolved to. A maker's balance is **not under their sole control** — anyone can
raise it by transferring tokens to them — so without a cap, a sweep signed
against a small balance becomes an offer to buy the maker's entire holding at
that small order's price.

The cap is therefore mandatory: `end == 0` on a marker leg reverts
`ProportionalNeedsCap`, because `0` is what an unset field holds and the dangerous
mode must not be the default. A deliberately unbounded sweep is
`end = SENTINEL_FLOOR`. See
[docs/proportional-legs.md](docs/proportional-legs.md).

### Revoking a Permit3 allowance is NOT a kill switch

`Base._pullViaPermit3` (every Settlement maker/filler pull; it replaced
`Permit3TransferLib.transferFromWithFallback`, which was deleted in the 2026-09-30
remediation, P3-2) refuses an amount above `uint160` (`Permit3Denied`), tries the
Permit3 book and, if that leg fails for any reason, falls back to a direct ERC20
`transferFrom` unless the payer is in strict mode. For a payer who ALSO holds a
plain ERC20 approval to Settlement, that means:

- per-order Permit3 **amount caps are not binding** — the fallback pulls the full
  amount regardless;
- **`revokeToken` / `lockdown` / an expiry do not stop fills.**

This is intended (a direct ERC20 approval *is* the broader grant, made
deliberately), but it means a maker who wants to actually stop settlement from
moving a token must zero BOTH the Permit3 allowance and the direct ERC20
allowance. **Wallets and UIs offering a "revoke" action MUST clear both.**

**Strict mode (2026-08-17, U-6) makes revocation binding for makers who want it.**
`IPermit3.setStrictMode(true)` (or the per-token form) marks the caller so that
`_pullViaPermit3` **refuses** the direct-ERC20 fallback for that payer —
a failed Permit3 leg reverts `Permit3Denied` instead of silently pulling via the
plain approval. A maker who opts in gets `revokeToken` / `lockdown` / an expiry
back as real kill switches. It is off by default and read only on the
already-failed Permit3 leg, so it costs nothing on the hot path for anyone who
never opts in. `lockdownAll(tokens, takers, nonceWords, nonceMasks)` revokes both
books and invalidates signed-permit nonces in one transaction.

**Revocation binds only grants already in the book** (2026-09-30 CENSUS-A-3,
accepted: Permit2 parity). `revokeToken`, `lockdown` and strict mode do not touch a
signed permit batch that has not been applied yet: a filler can still land it and
install fresh allowances. A complete revoke must ALSO burn the outstanding permit
nonces (`invalidateUnorderedNonces` / the `nonceWords` of `lockdownAll`); the SDK's
`buildRevokeAll` now requires the outstanding nonces and burns them.

**Venue signatures in an order's data outlive the order** (2026-09-30 L-CMT-3 /
L-ML-9). A venue signature embedded in an item's `data` — Aave `delegationWithSig`,
Comet `allowBySig`, Morpho/Lista `setAuthorizationWithSig` — is published with the
order and stays landable by ANYONE until its venue-side deadline, even after the
order is cancelled or expires. Cancelling, expiring, or revoking directly on the
venue (`approveDelegation(m, 0)`, Comet `allow(m, false)`, Morpho/Moolah
`setAuthorization(m, false)`) does **not** consume the venue nonce, so a stale
signature at the current nonce re-installs the grant. A **durable** revoke must
consume it: `allowBySig(owner, m, false, currentNonce, …)`,
`setAuthorizationWithSig({isAuthorized: false, nonce: current, …})`,
`delegationWithSig(…, value: 0, …)` signed at the current nonce — the SDK's
`buildRevokeAll` does this — or the maker cancels the order / calls
`Permit3.lockdownAll` so no fill can use the re-installed grant. No value moves
through a re-installed grant on its own (every module using these helpers is gated
by Permit3's taker book or by Settlement), but the maker's revoke is undone. Sign
venue deadlines no later than the order deadline. EVC permits are not exposed:
since L-ED-1 they are bound to `sender = EulerV2OperatorModule`; the Euler remedies
are `EVC.setNonce` / `setPermitDisabledMode`. A Morpho Midnight `setIsAuthorized`
grant is full position control, re-delegation included, and is required by every
Midnight module.

**The SDK now makes the safe configuration the default one (2026-08-25, F1).**
Strict mode being off by default meant the protected configuration was the one
nobody was in, which is the shape the iosiro lingering-allowance finding took
against 1inch Settlement. Three builders close it at the point where the user
actually is:

- `buildStrictOnboarding({ permit3, spender, tokens })` — the recommended account
  setup: `setStrictMode(true)` **then** the Permit3 grants, so the window in which
  a stray direct approval could fund a fill never opens.
- `buildRevokeAll({ …, directApprovals, strictMode })` — a revoke bundle that also
  zeroes the direct ERC20 approvals (`approve(spender, 0)`, addressed to the
  **token**) and enables strict mode. Strict mode is emitted **first**, so a fill
  landing between separately-sent calls cannot use the fallback.
- `readFundingPosture(reader, { permit3, token, owner, spender })` — reads both
  surfaces and returns `fallbackIsLoadBearing`: true exactly when Permit3 says
  "revoked" but the direct allowance still funds every fill. That is the state a
  revoke badge otherwise gets wrong. An SDK read rather than a lens method — the
  lens is hard against EIP-170.

See [docs/account-onboarding.md](docs/account-onboarding.md#strict-mode-and-the-two-funding-surfaces)
for the integrator-facing version.

### A signed permit batch OVERWRITES standing allowances (S-4)

`Allowance.grant` is an unconditional single-slot write, and `fillWithPermit`
applies the maker's signed batch as a side effect of the *filler's* transaction.
So a maker who holds `approveToken(settlement, USDC, max, …)` and then has one
`fillWithPermit` order landed with a smaller/short-dated batch ends up with the
smaller, short-dated allowance — their *other* resting orders lose their funding,
with no revert and no warning (and the reverse: one order's batch can *raise* the
cap another draws against). This matches Permit2's overwrite rule, but Permit2 has
no flow in which a third party applies your batch. Tooling that builds a batch
should refuse to *shrink* a live allowance, and the lens reports current caps
(`tokenAllowance` / `previewTakerAllowances`) so a UI can warn.

### Signature malleability is inert on-chain, but the orderbook must key on the hash (S-7)

`SignatureVerification` does not reject high-`s` (matching Permit2). On-chain this
is harmless — replay is keyed by the nonce bitmap in Permit3 and by
`filled[orderHash]` in Settlement, never by the signature bytes. **Off-chain,
`@1delta-x/orderbook` must key deduplication, cancellation and rate-limiting on the
order hash, never on a hash of the signature envelope**, or the same order
re-enters the book under a second identity.

### Any contract that fills on its own behalf must defend its balance

`_deliverOutputs` pulls output legs **from `ctx.filler`**, with the direct-ERC20
fallback above. So a contract that (a) holds a token balance, (b) has approved
Settlement, and (c) exposes a permissionless path making itself the filler of a
caller-supplied order is fully drainable: anyone can sign an order naming
themselves as maker, name that token and balance as the output leg, and set
themselves as recipient. It is also the recipient of every SETTLE item of the
orders it fills (`ISettlementModule.settle` pays `ctx.filler`), so it must account
for SETTLE receipts too.

A STANDING approval scoped to an amount is **not** sufficient — the attacker simply
signs an amount equal to the balance they want. Three defences work, and every
shipped self-filling contract uses one of them (2026-09-30 X-SPEC-7):

- **A balance floor**: snapshot each touched token on entry and revert if the call
  ends below it — `NativeSettler` (pinned by `NativeSettlerDrainPoC`) and
  `DestinationSettler7683`.
- **Delta-scoped, per-fill approvals**: `AggregatorFillSolver` approves Settlement
  for exactly THIS fill's measured proceeds, zeroes the approval after the fill,
  restricts routers to an allowlist, and is operator-gated for retain mode and
  surplus policies. Its `executeItemFill` entry (a one-order `matchSettle` plan:
  TAKE items early, wallet-funded MAKE late; not SETTLE, TAKE_FOR, PUSH-funded MAKE
  or delta-verify) has the same router allowlist, delta-only amounts and operator
  gating as `executeFill`, and never approves Settlement at all.
- **Operator gating plus owner budgets**: `UsdrifInventorySolver` holds inventory
  by design; only operators can fill, bounded by owner-set routes, a rate floor,
  per-window budgets and a per-fill `maxSpent` (see M-8).

The **flash-solver family** (`BaseFlashSolver` and its subclasses, plus
`GuardedMatchSolver`) relies instead on holding no balance between fills:
`setupTokenApproval` is permissionless and leaves Settlement a standing max Permit3
allowance, and `executeFill` is permissionless, so any residue is claimable by
anyone with a self-signed order. That posture depends on every sweep being
exhaustive: the flash solvers sweep each fill's profit out in the flash asset,
refuse SETTLE items (`SettleItemsUnsupported`), and refuse Settlement / the
EXECUTOR / themselves as profit recipient. **Accepted, not hardened (2026-10-02,
X-SPEC-7):** gating `setupTokenApproval` or replacing it with per-fill scoped
approvals was considered and rejected. It would not change who can reach a
residue: `executeFill` is permissionless by design, any per-fill approval would be
armed by the attacker's own call, and `_sweep` already pays the solver's WHOLE
balance of the flash asset to the caller-named recipient. A balance floor (the
`NativeSettler` defence) contradicts that whole-balance sweep. The zero-balance
rule is the posture; deploy an operator-gated solver when a contract must hold
inventory. Their `PERMIT_ENVELOPE` sig form fills a
PermitBatchWitness order through `fillWithPermit` inside the flash, so
permit-witness first fills ARE fillable with zero inventory (SDK
`encodeFlashPermitEnvelope`). **Never name an open flash solver or an open
`GuardedMatchSolver` as `exclusiveFiller`, in a `FILLER_SET`, or in a filler-keyed
validator** — those gate Settlement's immediate `msg.sender`, so naming a
permissionless contract admits every caller of it (VAL-5); use an operator-gated
instance instead.

**The EXECUTOR is a public trampoline** (2026-09-30 CORE-FILLER-4). Anyone can run
an empty `matchSettle` and make `SolverCallbackExecutor` call any target, so the
EXECUTOR is never a grantor: callback and `CALL` targets must check a flag their own
entrypoint armed and authenticate the caller, must never grant the EXECUTOR
authority, and must never stage value on it. A TAKE/TAKE_FOR item whose recipient is
the EXECUTOR reverts `OutputToSettlement`. Untrusted item modules and tokens run
code around `CALL` steps.

### Position-ID modules MUST bind the position to `onBehalfOf`

`ref = keccak256(data)` proves the bytes were authorised by **someone** — never
that the position named inside them belongs to the user being charged. The taker
book is keyed by the approver (`_takerAllowance[user][spender][module][ref]`), so an
attacker can self-approve a `ref` computed over a **victim's** position and carry
it in an order they signed themselves.

For most protocols this is harmless because the protocol call itself takes
`onBehalfOf` (Aave, Compound, Morpho, Silo, Venus, Lista) — the charged user and
the position are the same address by construction. It becomes a **full drain** for
protocols that identify a position by an opaque ID and grant the delegation to the
MODULE, because the module is a shared singleton registered against every user who
onboards. The protocol's own check ("is this module authorised on this position?")
then passes for the whole victim set.

Any module of that shape must resolve the position's owner on-chain and require it
to equal `onBehalfOf`:

| Protocol | Position ID | Required binding |
|---|---|---|
| Gearbox V3 | `creditAccount` | `ICreditManagerV3.getBorrowerOrRevert(ca) == onBehalfOf` — `GearboxCreditAuth` |
| Liquity V2 (+ Felix) | `troveId` on collateral branch `branchIndex` | `TroveNFT.ownerOf(troveId) == onBehalfOf` — `LiquityV2TroveAuth`, rooted at the module's IMMUTABLE `CollateralRegistry`: `getTroveManager(branchIndex)` → `troveNFT()` / `borrowerOperations()`; the collateral token is pinned to `getToken(branchIndex)` (`CollTokenMismatch`, L-LRG-1) |
| Fluid (custody modules) | position NFT `nftId` | the VaultFactory is an IMMUTABLE of the module; a signed `factory` must equal it (`WrongFactory`) and the vault must be the factory's `getVaultAddress(VAULT_ID())` (`UnknownVault`); the NFT is taken just-in-time from `ownerOf` (L-FSE-1) |
| Fluid (deposit / repay) | position NFT `nftId` | the factory's `ownerOf(nftId) == onBehalfOf` (`NotPositionOwner`, L-CENSUS-8) |
| Teller | loan `bidId` | `getLoanBorrower(bidId) == onBehalfOf` on repay (`NotBorrower`, L-CENSUS-8) |

The Fluid row used to read "free: `transferFrom(onBehalfOf, module, nftId)` makes
ERC-721 enforce `from == ownerOf`". That held only for NFTs the module did not
already own: a module-resident NFT (e.g. a position left by an aborted flow) was
claimable by anyone. The factory pin closes it (2026-09-30 L-FSE-1).

**Value-IN position modules bind too** (2026-09-30 L-CENSUS-8). A deposit or repay
into someone else's position is not theft, but it spends the maker's asset on a
position the maker does not own, so Teller repay and Fluid deposit/repay now
require the position owner to be the maker. `FluidRepayModule` also gains a tagged
`Full` mode (`0xB0DE0001`; an untagged non-zero word reverts `InvalidModeWord`)
that clamps to the live debt, full-fill only (`totalAmount` at 128), and
`FluidTakerModule` carries a `_locked` guard around its just-in-time NFT custody.

Two corollaries, both learned in the composer integration (`GEARBOX.md` A2/A3):
the addresses on the auth path must be **derived on-chain** from a root the module
trusts — for Liquity that root is the module's immutable `CollateralRegistry`,
indexed by `branchIndex` (an earlier version derived it from a single
caller-supplied root, and before that from the TroveManager) — never taken from
`data` (otherwise authorization can read one contract while dispatch hits
another); and the ownership read must **revert** for an unknown position rather
than return a default.

Both bindings are validated against live Ethereum mainnet state, not just mocks:

- `liquity-v2/test/fork/LiquityV2ForkAuth.t.sol` — borrows against a real trove
  through Permit3, blocks the drain, and includes
  `test_protocolItselfWouldHaveAllowedTheDrain`, which calls `withdrawBold`
  directly as the module and **succeeds**. That is the proof the finding was real:
  Liquity mints the victim's borrow with no beneficiary check anywhere, so the
  module's binding is the only control.
- `gearbox-v3/test/fork/GearboxV3ForkAuth.t.sol` — same shape against a live
  credit account.

The fork tests earn their keep: Liquity's binding was first written rooted at
`BorrowerOperations.troveManager()`, which **reverts on mainnet** (BorrowerOps
exposes almost no getters). The unit-test mocks happily provided it, so only the
fork run caught it. The chain was then rooted at the TroveManager, and is now
rooted at the immutable `CollateralRegistry` via `branchIndex` (which also serves
Felix on HyperEVM, `test/fork/FelixFork.t.sol`). Both fork files assert the exact
getters they depend on, so a silent reroot fails loudly.

### A TAKE item's proceeds token must appear in `order.legsIn`

TAKE proceeds land on Settlement (when `item.recipient` is 0). What happens to a
proceeds token that matches no input leg of its order depends on the path
(2026-09-30 X-SPEC-11 / CORE-ITEMS-2):

- **Single-order paths** (`fill`, `fillUpTo`, `fillWithPermit`, `fillWithCallback`,
  `batchFill`): `Core._payInputsToSolver` iterates `legsIn` only, so the token is
  **permanently stranded** — Settlement has no sweep and no admin.
- **`matchSettle`, token inside the plan's universe** (the union of every order's
  leg tokens): `Batch._creditItemProceeds` measures the item's gain and
  **refunds** any un-attributed proceeds to the maker as the item runs;
  `Batch._matchReconcileInputs` then settles the attributed part.
- **`matchSettle`, token outside the universe**: neither measured, refunded nor
  swept — stranded exactly as on the single path.

It cannot be stolen (every payout is bounded by a per-fill balance delta, and the
batch paths floor each touched token at its pre-batch balance), but it is lost. The
core cannot enforce this — the proceeds token is encoded inside the
module-specific `item.data`, which the core deliberately does not decode — so order
construction owns it. The primary guard is the lens rule (F22): a TAKE item's
recipient is the maker, or its proceeds token is in `legsIn`
(`SettlementLens.validateOrder` flags the stranded tail; the proceeds token comes
from `IProceedsAsset` where the module implements it). A `MinBalanceInvariant` is
an ABSOLUTE floor on the maker's balance: it does not pin stranded proceeds, because
other inflows can satisfy it (2026-09-30 VAL-1.v4).

### Wallets show packed order fields as opaque hex

`legsIn`, `legsOut`, `items`, `validators` and `invariants` are packed `bytes` in
the EIP-712 struct, so a wallet's signing prompt shows them as hex, not as amounts,
recipients and modules (2026-09-30 CORE-SIG-4). A maker cannot verify an order from
the prompt alone: the front end must decode the packed fields (the SDK
encoders' inverses, `unpackTiming` / `unpackParams`, or `SettlementLens`) and show them out of band, and makers should sign only from software
they trust to do so. The same holds for fee legs: a fee leg is a `LegOut` like any
other and is not rendered specially.

### `BridgedOrderInbox` admits only exact-transfer tokens

The inbox is a pooled escrow for bridged funds: it credits each delivery at the
amount the bridge reports, because arrival cannot be measured per delivery without
breaking liveness (2026-09-30 X-TOKENS-1, accepted). It therefore admits only
exact-transfer, non-rebasing tokens, chosen by the owner via `enableToken` — the
core itself stays asset-general. The owner's recovery paths cannot reach in-flight
LayerZero deliveries: `rescue(token, to, amount)` is bounded by the announced-orphan
ledger, and an unannounced balance leaves only through a `COMPOSE_SOURCE_DELAY`-
timelocked stray rescue re-bounded at execution (BRIDGE-A-1). `settleExpired`
refunds a row that can never fund its order immediately and requires a finite
deadline (BRIDGE-A-2).

### LayerZero fee sponsorship is bound to the filler

`LzOftBridgeOutModule` lets a third party (`feePayer`) sponsor a maker's native LZ
fee. A sponsored send must be signed as a **SETTLE** item, so the module receives
the filler from `ISettlementModule.settle`, and the filler must be the `feePayer`
itself or an agent the sponsor named with `setSponsorFiller` (`FillerNotSponsor`);
a sponsored send on a MAKE item reverts `SponsoredSendNeedsSettle` (2026-09-30
X-DIFF-REST-3, closed). Sponsorships are capped per send
(`approveFeeSponsorship(maker, amount, maxPerSend)`), whole-item only
(`LzSpec.totalAmount`), and unavailable through `matchSettle`, which rejects SETTLE.

### ERC-7683 adapters

`OriginSettler7683` quotes every order for `DestinationSettler7683`, the real
Settlement-level filler: a soft exclusivity window is quoted with the outsider
premium, and a hard window, a SETTLE item, a delta-verify order, a reserved nonce or
a past `fillDeadline` is refused rather than broadcast. `resolve` is a quote AND the
enforced bound: the destination checks `fillUpTo`'s returned received/paid amounts
per unit against the `FillBounds` in `originData` (`BoundExceeded`), and a solver
may pass its own `FillerData{payTo, minBumpBps, bounds}`. Filler-aware gates
(exclusive filler, `FILLER_SET`, filler-keyed validators and price modules) see the
ADAPTER as the filler, not the solver behind it. `openFor` authorises only the inner
order; the envelope nonce must equal the order nonce (2026-09-30 PERIPH-1/2/4).

---

## Audit (2026-06-18): findings & fixes

Internal audit of `packages/core` + all module packages. All items below are
fixed in the working tree and covered by the test suite (**133/133 passing**,
including fork tests).

| ID  | Severity | Component | Finding | Fix |
|-----|----------|-----------|---------|-----|
| **C-1** | **Critical** | `Permit3.take` | The taker book was keyed by *module* and `take` was callable by anyone with an arbitrary `receiver`. Any standing taker allowance (required by the `fill()` path; left as a residual by partial `fillWithPermit`) could be drained by anyone — borrow/withdraw proceeds redirected to an attacker while the victim kept the debt. | Re-keyed the taker book by **spender** (`_takerAllowance[user][msg.sender][ref]`), mirroring the token book. Only the approved spender (Settlement) can consume an allowance; Settlement enforces the maker-signed `recipient`. |
| H-1 | High | Chainlink / MoC price validators | Oracle reads ignored staleness, round completeness, and price sign — a stale/zero price could pass a take-profit/stop-loss gate. | Added `price > 0`, `answeredInRound >= roundId`, and a maker-signed `maxStaleness` heartbeat to the Chainlink validators; the MoC band validator rejects zero price. Its staleness half is **not fixable at this layer** — `peek()` exposes no timestamp; documented in-contract instead. |
| M-1 | Medium | Maker modules | `makeOnBehalf` was ungated — anyone could force a victim's pre-approved funds into deposits/repays (griefing / order-layer bypass). | Gated every `makeOnBehalf` to `msg.sender == settlement`. |
| M-2 | Medium | All modules + core | Raw ERC20 calls ignored return values (USDT-class break / silent failure). | Introduced `SafeTransferLib` and applied it repo-wide. |
| M-3 | Medium | `RedemptionSettledValidator` | "Settled" was inferred from the FIFO queue head (`firstOperId`), which only proves the op was *dequeued*, not that it cleared. | Now reads the op's final state via `opersInfo(opId)` / `operIdCount()`. |
| M-4 | Medium | Full-mode withdraws | Trusted a stale pre-read balance / static amount; could over-forward or leak a stray balance. | Forward a **measured** balance delta with `require(received >= amount)`; sweep only the real excess to the user. |
| L-1 | Low | `UniversalSettlement` (now `Settlement`) | Solver payout used the whole contract balance (could scoop donated funds). | Pay from the current fill's measured proceeds only; return surplus to the maker. |
| L-2 | Low | `MocPriceBandValidator` (was `DepegGuardValidator`) | No `minPrice <= maxPrice` validation (self-DoS). | ~~Reverts `InvalidBand`~~ — superseded 2026-08-14 on the reasoning that the revert was unobservable (`OrderGates.gatePasses` folds a top-level revert into `false`), so the check was removed. **That reasoning was wrong inside a `ConditionTree`** (2026-09-30 VAL-2): there a revert aborts the tree while a `false` can be NEGATEd into a pass, so "reversed band reads false" let a negated leaf pass. The validator now **reverts** on a zero price or a reversed band (`test_audit_VAL_2_zeroPriceRevertsNotFalse`), and tree leaves propagate failures and out-of-gas instead of reading false. |

**Confirmed-safe (no change needed):** flash-solver callback authentication;
Morpho `onMorphoRepay` is morpho-gated with a cap check (and supply uses empty
callback data); Fluid never implements `liquidityCallback` and always returns
the position NFT to the owner; token-side `transferFrom` is spender-gated;
EIP-712 domain caching with fork-recompute; Dutch-decay ceil-div (maker never
underpaid).

---

## Audit (2026-07-29): findings & fixes

Second internal audit, covering `packages/core` (settlement + Permit3 + periphery),
every module package, and `packages/solvers`. All items below are fixed in the
working tree; the whole repo is green (**591/591 across 135 suites**). Every
security-critical fix carries a regression test, and the fixes marked ✓mut were
**mutation-tested** — the guard was removed and the test confirmed to fail — so the
coverage is known to be load-bearing rather than incidental.

| ID | Severity | Component | Finding | Fix |
|----|----------|-----------|---------|-----|
| **C-2** | **Critical** ✓mut | `LiquityV2TakerModule` | Liquity authorises the trove **manager** (this module), never a beneficiary, and `troveId` came from `data` while `onBehalfOf` was used only as a sweep destination. Since the taker book is keyed by the *approver*, an attacker could self-approve a `ref` over a **victim's** trove and fill their own order: the module ran `withdrawBold`/`withdrawColl` against the victim's trove and forwarded the proceeds to the attacker, who kept none of the debt. Every user who completed the documented setup was exposed. | `LiquityV2TroveAuth.authorizeTrove` binds `TroveNFT.ownerOf(troveId) == onBehalfOf`, with the NFT and `borrowerOperations` both DERIVED from one caller-supplied root. Mainnet-fork validated. |
| **C-3** | **Critical** (latent) | `GearboxCreditBorrowModule` | Identical shape: `creditAccount` from `data`, `onBehalfOf` explicitly discarded. Not exploitable as shipped only because the module implemented no `requiredPermissions()`, so it could never be registered as a Gearbox bot — i.e. it was armed by the first change that made it *work*. | `GearboxCreditAuth.authorize` (CA → CreditManager → facade, `getBorrowerOrRevert == onBehalfOf`), plus `requiredPermissions()` so the modules are registerable, plus the approval retargeted to the CreditManager. Mainnet-fork validated. |
| **H-2** | **High** ✓mut | `NativeSettler` | `settleFromNative` force-approved Settlement over an **attacker-named** `legsOut[0].token` and then self-settled as the filler; `_deliverOutputs` pulls outputs *from the filler*, so the contract's whole balance was drainable for 1 wei. | Balance floor: each touched token must end ≥ its entry balance. Scoping the approval alone does **not** fix this — the attacker simply signs an amount equal to the balance. |
| **H-3** | **High** ✓mut | `RiverTakerModule`, `RiverOpenModule` | River's value-out ops carry no `receiver`, so the module pulled the payout from the **maker's wallet** — without measuring what the CDP call delivered. A short or zero delivery was silently covered from the maker's pre-existing balance and paid to the solver. | `RiverProceeds` measures the maker's balance delta and fails closed. Also makes the modules correct under *both* candidate fund-flow directions. |
| **H-4** | **High** | Composite modules (Dolomite, Euler V2, Fluid, River) | `sideAmount` lives in the constant `item.data` and does **not** pro-rate, so every partial fill re-pulled it in full — an N-slice fill pulled N × the signed collateral, at a leverage ratio the maker never signed and a slice count the *solver* chooses. | `FullFillGuard`: composite items carry the item total and are full-fill only. |
| **H-5** | **High** | `EulerFlashSolver`, `EulerMultiInputFlashSolver` | `onFlashLoan` authenticated `msg.sender` against a `flashVault` decoded from the **same attacker-supplied blob** — circular, so no check at all. Separately, a fake vault that returned without calling back fell through to the tail `_sweep`, which names a token from an order that was never signature-checked on that path. | Provider pinned in storage before the external call; `_requireCallbackRan` asserts the callback fired. |
| M-5 | Medium | 15 `BalanceMode.Full` branches | `Full` liquidates the user's entire live balance regardless of slice, so a 1-unit fill force-closed the whole position and bricked the rest of the order. | `FullFillGuard.requireFullFillFromData` — maker signs the item total after the mode slot. |
| M-6 | Medium | `PermitHelper`, `DelegationHelper` (×3) | Nonce-based replays were hard calls, so a mempool front-runner could permanently brick any gasless order for ~50k gas — the signature bytes are inside `ref` and the order hash, so it could not be re-encoded. | Best-effort `try/catch`; the Permit3 pull remains the gate. See [gasless-permit-relay.md](docs/gasless-permit-relay.md). |
| M-7 | Medium | `ERC4626WithdrawModule` | Three: `asset` was caller-supplied (a free transfer of any token the module held); `pendingWithdrawals[vault][requestId]` was blind-overwritten (permanent share loss on any ERC-7540 `REQUEST_ID_0` vault); and `amount` was used as a slippage **floor**, inverting the Permit3 cap. | `vault.asset()` read on-chain; collision reverts; `amount` is the cap with surplus to the beneficiary; `minAssets` moved into `data`. |
| M-8 | Medium | `UsdrifInventorySolver` | `executeFill` accepts an arbitrary `(order, sig)` while holding a max Permit3 allowance, so an **operator** — a deliberately lower trust tier than owner — could take 100% of inventory in one self-signed order. | Owner-set `maxOutflowPerFill`, enforced as a measured delta, defaulting to zero (fail closed). **Superseded (F30, 2026-09-28):** the cap measured only what LEFT, per call — a self-signed order paying the cap for a junk token could be repeated, in one transaction by a contract operator, and `sell` did not consult it at all. The operator is now bounded by owner-set fill and sell ROUTES (what leaves must return as the owner's token at no worse than the owner's rate, measured) plus a cumulative per-token budget per 1-hour window shared by both paths. A compromised operator's worst case is conversions at the owner's floor rates, up to the window budget, until the key is revoked. **Broken and restored (2026-09-30 RIF-1 / RIF-2 / PERIPH-1.v2):** `MocMultiCollateralGuard.execute()` is **PERMISSIONLESS**, so MoC queue execution can land the solver's own RIF/USDRIF delivery or failed-op refund inside ANY external call, including inside `sell`'s and a fill's measured window, offsetting the measured outflow (PoC: 15,196.28 RIF drained with 0 charged to the budget; a maker-signed item could trigger a refund inside a fill). `sell` and every fill are now bracketed by `MocQueue.firstOperId()` and revert `QueueMovedDuringMeasurement` if the queue head moved; fills refuse item-bearing orders and take an operator `maxSpent` bound. With that, the floor-rate/window-budget containment above holds again. |
| L-3 | Low | `packages/solvers` (18 call sites) | Unchecked bool-returning ERC20 calls: **no solver could fill a USDT leg at all** (the approve reverts on the ABI decode), and a `false`-returning token made the flash-repayment transfer a silent no-op. | `SafeTransferLib` throughout; `forceApprove` also clears the USDT approve-race. |
| L-4 | Low | `Base` (constructor) | A `permit3` address with no code made every transfer a **silent no-op** — orders would "settle" with nothing moving — because `transferFromWithFallback` probes with a low-level call and treats success as done. | `InvalidPermit3` constructor check. |
| L-5 | Low | `Base`, `NonceManager` | Unchecked `uint160(slice)` downcast on a value path; `exclusivityOverrideBps > 10000` surfaced as an arithmetic panic; `invalidateNonceWord` emitted no event, so bulk cancellation was invisible to indexers. | `AmountOverflow`, `InvalidOverrideBps`, `NonceWordInvalidated`. |
| L-6 | Low | `CompoundV2Native*` (×3) | Open `receive()` with no owner or rescue, and only the redeem *delta* was wrapped — stray ETH was stranded permanently. | Wrap/sweep the full native balance; the modules end every call empty. |

**Confirmed-safe (no change needed):** the `SolverCallbackExecutor` trampoline
(callback injection via `target = PERMIT3` gains nothing); `matchSettle` netting (pre-send bounded to the batch's own inflow — in `matchSettle`
netted further against obligations not yet delivered; every schedule step
bounds-checked, deliver/item units guarded exactly-once AT THE STEP, per-order
completeness and input funding asserted in the deferred flush, `BatchNotWhole`
backstop); `IFillModule` / `IOrderValidator`
declared `view`, so solc emits STATICCALL and neither can mutate state or reenter;
Settlement never grants an ERC20 approval and is not payable; EIP-712 typehash
ordering and the hand-rolled `OrderHash` buffer; signature malleability (order replay
is bounded by `filled[orderHash]`, permit replay by the nonce bitmap).

---

## Audit (2026-08-06): the remaining open items

The items previously carried as "known open" are now closed. All five code defects
are fixed in the working tree, each with a regression test; the two marked ✓mut
were **mutation-tested** — the guard was removed and the test confirmed to fail —
so the coverage is known to be load-bearing. The whole repo is green
(**758 tests across 119 suites, 23 packages**), fork tests included. The core gas
baseline is unchanged: every deterministic entry in `.gas-snapshot` held, so none
of these guards sit on the settlement hot path.

| ID | Severity | Component | Finding | Fix |
|----|----------|-----------|---------|-----|
| M-9 | Medium | `MidnightSupplyCollateral/Repay/Lend`, `MidnightLoopCallback` | The modules granted Midnight a standing `type(uint256).max` allowance via `ensureApproval`, on the usual "immutable, trusted singleton" reasoning, while `take` lets the caller name a payer (`takerCallback`). *(Corrected 2026-09-30, L-ML-7: naming a payer means naming it as the CALLBACK, which Midnight invokes first, so an outside caller cannot simply designate a module as payer — the D-1 re-read in [docs/audit-2026-09-leads.md](docs/audit-2026-09-leads.md). The scoped-approval fix stands as defence in depth.)* | Approvals scoped to the amount each call funds and cleared afterwards (`forceApprove(…, amount)` → call → `forceApprove(…, 0)`). Asserted directly: no module retains an allowance to Midnight after any maker leg. |
| M-10 | Medium | `AaveV4WithdrawModule` (Exact), `AaveV4BorrowModule` | Both forwarded NOMINAL amounts — the PM's reported `assets`, and for borrow the requested `amount` with the return value ignored outright. Neither figure is a claim about the module's balance, so an under-delivering op was silently topped up from any balance the module happened to hold and paid to the order, while the user kept the full debt. The H-3 River shape; the module's own `Full` branch already measured. | Measure the balance delta on both legs, `require` at or above the signed amount, route any surplus to `onBehalfOf`. |
| M-11 | Medium | `MidnightLendModule`, `MidnightBorrowModule` | `offer.buy` was decoded and used but never checked against the leg's role, and Midnight derives who pays and who receives entirely from that flag. An order carrying the wrong value inverted the leg: the lend leg would make the maker a *borrower* and send the proceeds to the hard-coded `address(0)` — debt kept, funds burned. The borrow leg would flip a value-OUT leg into a value-IN pull. | Each leg asserts its side (`WrongOfferSide`); the lend-side check fires before the module takes custody. |
| L-7 | Low | `FluidDepositModule`, `FluidRepayModule` | Fluid overloads `nftId == 0` as "open a NEW position", and `operate` mints it to `msg.sender` — the module. The single-op legs have no NFT custody or hand-off step, so a deposit signed with the sentinel supplied the user's collateral into a position owned by the module forever. Not theft (nobody can reach it), but the funds are gone. | `FluidBase._requireExistingPosition` rejects the sentinel before the Permit3 pull. Opening a position remains `FluidOperateModule`'s Open path, which captures the minted id and hands the NFT to the user. *(2026-09-30: deposit/repay now also require the factory's `ownerOf(nftId) == maker` (`NotPositionOwner`, L-CENSUS-8), and the custody modules pin the VaultFactory (L-FSE-1): a module-resident NFT, which "nobody can reach" assumed, was in fact claimable by anyone before that pin.)* |
| L-8 | Low ✓mut | `DustHandler` | `readAction` / `readBalanceMode` narrowed the trailing mode word with `uint8(word)` *before* the enum conversion, so the high 248 bits were discarded and never range-checked. `word = 256` did not revert as out-of-range — it truncated to `0` and read as a well-formed *default* mode, contradicting the library's own docstring. Maker-authored (the value is inside `ref = keccak256(data)`), not filler-reachable. | Range-check the FULL word before narrowing; out-of-range reverts `InvalidModeWord`. |

**Solver F3/F4/F5** (from the item-aware netted-settle review) are resolved as
documentation and test, not code: F3 is the documented constraint above ([A TAKE
item's proceeds token must appear in `order.legsIn`](#a-take-items-proceeds-token-must-appear-in-orderlegsin));
F4's "cheap future guard" is now `NoApprovalsInvariantTest`, which pins the
Settlement-grants-no-approval assumption the batch completeness argument rests on;
F5 is an accepted gas cost on a deliberate non-hot path.

**`RiverModules` fork validation** is in place — `test/leverage/Leverage.t.sol`
forks Hemi (River's live deployment) at the real `XAPP` / `TroveManager` /
`satUSD` addresses and exercises open, leverage, partial-fill and the
missing-delegate revert. All four pass.

**No open items remain from the 06-18 / 07-29 audits.** Note that all three audits
to date are **internal**; the protocol has not been reviewed by an external firm,
and nothing in this repository is deployed.

---

## Audit (2026-08-25): external-corpus crosswalk

A different method from the three passes above: rather than reading this code for
defects, the published audit corpus for the protocol class — 1inch LOP + Fusion, 0x
v4, CoW GPv2, UniswapX, Velora Portikus, plus the two live incidents — was distilled
into **fifteen failure classes**, and each was traced through this tree. The full
taxonomy, with the finding or exploit that anchors each class, is
[docs/reference-audits.md](docs/reference-audits.md); the class keys `C1…C15` used
below are defined there.

Eleven classes are structurally prevented or already correct, several of them by
decisions taken deliberately in response to the same findings (C5 — a price module
returns a *clamped bump*, never an amount; C1 — the solver's call runs through
`SolverCallbackExecutor`; C11 — the idempotent permit). Two are inverted in the safe
direction relative to the published bug (C8 — a zero-duration decay resolves to the
maker's `start`, where UniswapX L-03 resolved to the filler's `end`).

| ID | Class | Severity | Finding | Resolution |
|----|-------|----------|---------|------------|
| F1 | C12 | Medium | `transferFromWithFallback` does not discriminate *why* the Permit3 leg failed, so the direct-approval fallback silently overrides a deliberate revocation. Strict mode closed it but defaulted to off — the protected configuration was the one nobody was in. | **Off-chain.** Three SDK builders (`buildStrictOnboarding`, `buildRevokeAll` with `directApprovals`/`strictMode`, `readFundingPosture`) plus [account-onboarding.md](docs/account-onboarding.md#strict-mode-and-the-two-funding-surfaces). No contract change: the fallback is load-bearing for direct-approval makers, and the lens has no EIP-170 headroom. |
| F2 | C3/C6 | Low | `ItemOp` was decoded as a raw byte and `Base._runItem` folded every `op >= 2` into the SETTLE branch, so `Batch._assertMatchShape`'s `op == SETTLE` prohibition could be stepped around by signing `op = 3` — running a SETTLE inside `matchSettle`, the one item kind that path declares it cannot account for. Maker-signed, so never third-party reachable, and both shipped SETTLE modules move only the maker's own assets. | **Fixed.** `_runItem` reverts `MalformedPackedArray` on an unknown op (the existing selector is reused — Settlement had 67 bytes of headroom); `_assertMatchShape` asks `>=`. `test/items/ItemOpRange.t.sol`, 6 tests incl. a fuzz over the invalid range. **+14 bytes** (24,509 → 24,523 of 24,576). |
| F3 | C9 | Low | Maker-supplied targets (`pricingModule`, `fillModule`, validators, invariants, item modules) are gas-unbounded and the filler pays. Accepted class — 1inch L11, UniswapX M-01 — but the posture was inferred rather than stated. | **Documented.** [filler-strategy.md §7](docs/filler-strategy.md#7-every-maker-supplied-target-is-gas-unbounded), with the per-surface static/stateful table and the damage ceiling for each. |
| F4 | C7 | Info | Rounding is uniformly maker-favourable, and the auctioned side is per-fill rather than cumulative, so splitting a fill costs the *filler* ≤1 wei per leg per fill. Correct direction; bounded by `minFillAnchor`. | **Documented.** [pricing-modes.md](docs/pricing-modes.md#rounding-who-pays-the-wei) states the invariant: *fixed legs are exact and cumulative; auctioned legs round toward the maker, per fill.* |
| F5 | C4 | Info | `fillWithPermitTake`'s "NOTHING survives it" was true of the permit but not the order — a successful fill writes `filled[orderHash]`, which permanently disables signature re-verification for that hash. Correct per the documented invariant (the permit's witness IS the order hash) and near-unreachable (`permit.amount == slice` forces a full fill). | **Comment corrected** to state what actually holds, and to point at `cancelOrder` as the switch that binds. |
| F6 | C3 | Info | Signature malleability accepted, matching Permit2. | **No change** — already covered by [S-7](#signature-malleability-is-inert-on-chain-but-the-orderbook-must-key-on-the-hash-s-7). Verified `@1delta-x/orderbook` keys, sorts and paginates on `orderHash`. |

Three checks worth re-running whenever the relevant code moves are listed under
[Checked and clean](docs/reference-audits/checked-and-clean.md#checked-and-clean) — in particular the
**module-dispatch selector scan** (`makeOnBehalf` / `settle` must never collide with
anything on Permit3, which is what contains the C1 shape here) and the rule that a
**SETTLE module must never pull from the filler**.

Repo state after this pass: core **513/513**, SDK **158/158**, Settlement
24,523 / 24,576.

### Second pass, same day: F7–F12

An independent review against the same corpus produced six more items, two with
executed PoCs. All were re-derived here before being acted on, and all six hold. Five
are fixed in code; one is documentation. Notably **three of the six are C13
(preflight drift)** — the class this codebase had already been bitten by once and
written up — which is the strongest available argument for keeping shared rules in
`OrderGates` rather than in two implementations.

| ID | Class | Severity | Finding | Resolution |
|----|-------|----------|---------|------------|
| F7 | C15/C13 | Low | `matchSettle` paid a self-addressed output leg to the SOLVER instead of burning it. The pool→pool self-transfer leaves the balance untouched while `outstanding` marks the obligation discharged, so the amount clears the pre-context floor and reaches `_sweepSurplus`. Three doc sites promised a permanent burn. Maker-authored (`legsOut` is in the typehash) but solver-opportunistic. Reproduced: 2,000 USDC burned via `fill`, the same 2,000 paid to the solver via `matchSettle`. | **Fixed.** `_stepDeliver` reverts `OutputToSettlement`; the single-order burn is unchanged and pinned by a control. Docs corrected. `test/swaps/OutputToSettlement.t.sol`. **+25 bytes** (24,523 → 24,548); the error takes no arguments because naming `(order, leg)` cost +37 against a 53-byte budget. |
| F8 | C13 | Low | `ChainlinkPeggedPriceModule._band` read `legsIn[0].start` raw, so a `Proportional` marker (≈1.15e77) overflowed `anchor · answer` and every fill reverted `PriceModuleFailed` — while `validateOrder` approved the order. A preflight LOOSER than the settler. | **Fixed, and the combination now works.** The core already passes `total` (the resolved denominator); the module now uses it instead of re-reading the leg. The other three pricing modules were checked and do not read legs raw. `test/ProportionalPeggedPrice.t.sol`, 5 tests. |
| F9 | C13 | Info | The lens read only the NONCE axis, so an order cancelled by HASH — whose `filled` sentinel is ≥ any denominator — reported as **Filled**. `validateOrder` repeated it in its reason string. | **Fixed** in that direction. The inverse (a completed fill-once order reports `Cancelled`) is **not fixable** — such an order keeps no counter, so filled and nonce-cancelled leave identical state. Now documented on `OrderStatus`, pointing consumers at the `OrderFilled` event. |
| F10 | C13 | Info | `SettlementLens.remaining` had no sentinel check outside `unchecked`, so a cancelled order produced `Panic(0x11)` rather than the `OrderCancelled()` its sibling `_resolveState` raises. | **Fixed** to revert `OrderCancelled()`. Not `0` — that is already the truthful answer for a fully-filled order, and collapsing the two hands callers one number for "done" and "revoked". Docstring points batch callers at `getOrderRelevantState`. |
| F11 | C13 | Info | `OriginSettler7683.open` emitted `Open` without the signature check `openFor` performs, so it could advertise an order that reverts at fill time — breaking the invariant `openFor` states. | **Fixed** by adding `LENS.checkSignature`. Costs the signature-less maker nothing: an empty `sig` routes to the settler's `orderApproved` record, so the `approveOrder`-then-`open` path passes by construction. |
| F12 | C13 | Info | `UnorderedNonces` called `invalidateUnorderedNonces` "a complete kill switch … regardless of what was signed against it". True of permits; a maker could read it as covering the ORDER. `permitBatchWithWitnessIfNeeded` skips a spent nonce (the S-1 remediation), so the fill proceeds without the grants and succeeds if other funding exists. | **Docs.** Corrected in `UnorderedNonces`, `IPermit3` and the permit3 README, as the converse of the existing "Revoking a Permit3 allowance is NOT a kill switch" caveat above. No code defect — the order-level cancels all bind on this path. |

Repo state after the second pass: core **518/518**, periphery **41/41**,
modules-pricing-chainlink **10/10**, SDK **158/158**, Settlement **24,548 / 24,576**.

### Third pass: F13–F15, and the systematic sweep that followed

A re-audit of the *withdrawal* and *netted-step* surfaces. Two of the three are real
defects, both PoC'd and fixed; the third is a corrected inference rather than a bug,
kept in the ledger because the faulty reasoning is the reusable trap. Full write-ups
in [docs/reference-audits.md](docs/reference-audits.md).

| ID | Class | Severity | Finding | Resolution |
|----|-------|----------|---------|------------|
| F13 | C12 | **High** | A **revoked on-chain order approval was bypassable.** `_verifySignature` skips re-verification once `filled != 0`, which is sound for a signature (it cannot be withdrawn) — but the skip is reached by *any* non-empty `sig`, and nothing records how the earlier fill was authorised. An order authorised by `approveOrder` set `filled`; a filler then passed 65 arbitrary bytes, took the signature branch, hit the skip, and settled the remainder of a **revoked** order — for a maker with no EIP-1271, for whom no signature can ever be valid. The comment claimed the skip "applies ONLY to the signature branch": it does, but the *filler* picks the branch. | **Fixed.** `revokeOrderApproval` parks the `cancelOrder` sentinel when the order is already partially filled, gated on `wasApproved` (which proves the caller is the maker). Zero hot-path cost — `filled` is already read by every fill. Reading `orderApproved` on the signature path instead would put a cold SLOAD on every fill of every order to protect the rare sigless one. Revoking a *touched* approval is now one-way; an untouched one still round-trips. |
| F14 | C11/C12 | Info | `permitBatchWithWitnessIfNeeded`'s silent return on a spent nonce was commented "authorization still proven; **grants already applied**". The second clause is false — a bit is set by `invalidateUnorderedNonces`/`lockdownAll` just as much as by a prior application, and in that case the grants were never applied and never will be. | **Not a vulnerability; comment corrected.** The signature is verified *before* the nonce check and the spent-bit path applies nothing, so the direction is fail-safe. The silent return is the deliberate S-1 remediation. Ledgered because the *inference* — "nonce spent ⇒ effect happened" — is the trap worth remembering. |
| F15 | — (new shape) | **Medium** | **A refund that restores the asset but not the authority spent to move it.** `Batch._stepPull` moved the nominal `owed` unconditionally, on the in-file reasoning that a duplicate `PULL` "costs the solver gas and the maker nothing" because Phase 3 refunds the surplus. The *tokens* are refunded — net spend stayed one fill — but the **Permit3 allowance** spent to move them is not. Against a finite, amount-gated allowance (the model `IPermit3` is built around) a padded schedule consumed 2× the allowance for 1× the fill, leaving the maker unable to fund the next one. `matchSettle` is permissionless, so any solver could do it. Makers on `uint160.max` were unaffected — Permit3 treats that sentinel as "do not decrement". | **Fixed.** Pull the **shortfall** (`owed - credit`) rather than the nominal amount. Keeps the tolerant, guard-free shape the schedule wants — a second `PULL` now moves nothing and spends no allowance — and makes ITEM-then-PULL exact instead of over-pull-then-refund. A `credit != 0` guard would have been wrong: `_creditItemProceeds` also credits input legs. |

**F15 is the one to generalise from.** "The funds come back" is not the same as "nothing
was consumed": allowances, nonces, and one-shot authorisations are spent by the
*attempt*, not by the net outcome. The re-audit sweep that F13–F15 prompted —
generalising each into a question asked across the whole surface — is
[in reference-audits.md](docs/reference-audits.md), and the combinatorial coverage
argument it produced is [docs/edge-case-matrix.md](docs/edge-case-matrix.md).

---

## Audit (2026-09-30): whole-tree audit

A nine-goal, 48-lens internal audit of the whole tree at `56d1405` (Permit3,
Settlement, the executor, every module, solver, validator, the periphery and the
TypeScript packages), by AI agents, with a PoC for every high and medium. Full
write-up, per-component tables and remediation status:
[docs/audit-2026-09-30-full-tree.md](docs/audit-2026-09-30-full-tree.md); ledger
entry F32 in [docs/reference-audits/findings-ledger.md](docs/reference-audits/findings-ledger.md).

**The immutable core held**: Settlement, Permit3 and the executor have no critical,
high or medium finding. Every high and medium sat outside the core (223 issues: 1
high, 19 medium, 94 low, 109 info), and the recurring cause was again a guarantee
that reached one sibling and missed its neighbours.

| ID | Severity | Component | Finding | Fix |
|----|----------|-----------|---------|-----|
| PERIPH-1 | **High** | `DestinationSettler7683` | `resolve` published the current tick as `maxSpent` and `fill` enforced no cap, so a maker-controlled bump charged a 7683 solver up to `legsOut.start` from its approval. | `originData = FillPayload{payload, FillBounds}`; per-unit bounds enforced against `fillUpTo`'s return (`BoundExceeded`). **BREAKING** originData. |
| PERIPH-2/3/4 | Medium | 7683 adapters | Quotes priced for the named filler, not the destination settler; a forwarded `uint256.max` sentinel; SETTLE proceeds stranded on the adapter. | Quotes for `DESTINATION_SETTLER`, hard windows refused; the bounds above; SETTLE items refused. |
| PERIPH-1.v1, G-TS_FILLER-1, PRICE-1.v1 | Medium | orderbook-server `/quote`, auction | Quote calldata that was not the quote; sybil-crowded auction rounds; SELL routes sized by `fillTotal`. | Calldata carries the quoted bump as `minBumpBps` and the resolved delta; one bid per filler, signed fields only; sized by `legsIn[0].start`. |
| RIF-1, RIF-2 | Medium | `UsdrifInventorySolver` | The permissionless MoC guard `execute()` could land the solver's own queue deliveries inside its measured windows (see M-8). | Queue-head bracket, item orders refused, `maxSpent`. |
| PRICE-1 | Medium | `ChainlinkPeggedPriceModule` | Fair price computed against the fill denominator: every `fillTotal` order cleared at the maker's floor. | Anchors on the counterpart leg's whole-order amount. |
| PRICE-2 | Medium | `OcoGroupModule` | A 1-wei fill of a sibling claimed the group and retired a stop-loss. | Claim blob `(groupId, nonce, minClaim)`; a missing floor fails closed. **BREAKING**. |
| VAL-1 | Medium | invariants | An invariant proves an end state, not a delivery: a filler could collect a purchase payment without delivering. | On-chain core rule (invariant 12) + `InvariantReceiptGuard` + lens/SDK refusal. |
| MISC-MOD-1 | Medium | `ProportionalSweepModule` | bps re-applied to the post-sweep balance on every partial fill. | Fractional bps needs the 3-word blob and is full-fill only. **BREAKING**. |
| BRIDGE-A-1 | Medium | `BridgedOrderInbox` | `rescue()` could take an uncredited LZ compose, paid later from other users' escrow. | Orphan ledger + timelocked stray rescue. **BREAKING** `rescue`. |
| L-LIB-1, X-STATIC-1 | Medium | Morpho / Compound v2 repay | Recycle repays drew the module's residue. | Bounded draws, scoped approvals, `FloorBreached`. |
| L-CMT-1, L-CV2-1(.v1), G-VENUE_B-1 | Medium | Teller repay, Aave v4 / Exactly withdraw, Liquity v2 taker | Venue clamps (or no clamp) billed the shortfall to the maker's wallet or overpaid a lender. | `requireDelivered` / position pre-checks / `repayLoanFull`. |

Selected lows that change behaviour: `fillWithPermit` collapsed to one 6-argument
entry and every fill entry gained a price floor (`minBumpBps`, PERIPH-1.v3); a fill
module may not upsize the request (`OverFill`, CORE-FILLER-2); `type(uint256).max`
resolves to the remainder on every entry (CORE-FILL-4); zero-amount carrier legs no
longer keep a soft window soft (CORE-FILL-1); a direct `setOrderSigner` shortening
burns relayed nominations (X-DIFF-CORE-3); Euler EVC permits are bound to the
module (L-ED-1); LZ fee sponsorship is bound to the filler (X-DIFF-REST-3); Fluid,
Teller deposit/repay bind the position owner (L-CENSUS-8). Accepted, with reasons in
the write-up: X-TOKENS-2 (double-entry tokens on `matchSettle`), CENSUS-A-3 (revoke
does not kill unapplied permit batches; burn the nonces), X-TOKENS-1, BRIDGE-B-5,
L-LIB-9, PRICE-12, L-AAVE-3, L-CMT-4.

Settlement after the remediation: **24,311 / 24,576** bytes in a clean via-IR build
(24,325 at the audited HEAD).

---

## Breaking change for integrators

### 2026-09-30 — whole-tree audit remediation

The **order typehash, order wire format and golden order hash are unchanged**
(the golden fixtures stand). Everything below is ABI, module `data`, behaviour or
SDK API. **Every changed module, solver and periphery contract needs a new
deployment**, and any pre-audit beta deployment record or CREATE2 address
prediction for them (including the Rootstock beta set's `AggregatorFillSolver` and
flash solvers) must be regenerated.

**Settlement (ABI and behaviour)**

- `fillWithPermit` is ONE entry: `fillWithPermit(Order, PermitBatch, bytes sig,
  uint256 fillAmount, uint256 minBumpBps, bytes takerData)`; the 4- and 5-argument
  overloads are gone. `fillWithPermitTake(Order, PermitTake, bytes, uint256
  fillAmount, uint256 minBumpBps)` gains its 5th argument. The `takerDatas`
  `batchFill` is `batchFill(Order[], bytes[], uint256[] fillAmounts, bool
  revertIfIncomplete, uint256[] minBumpBps, bytes[] takerDatas)`, and `fillSelf`
  gains `minBumpBps`. Plain `fill` has no floor: use `fillUpTo`.
- `FillCtx` gains a trailing `uint256 minBump`; `BumpTooLow` moved from `Base` to
  `OrderState` (selector unchanged).
- A fill module returning a delta above `fillAmount` reverts `OverFill`; callers
  of all-or-nothing fill modules pass `type(uint256).max` or the remainder.
- `type(uint256).max` resolves to the remainder on every entry; a module never
  receives max.
- A soft exclusivity window whose legs are only zero-amount carriers is now hard.
- A TAKE / TAKE_FOR item whose recipient is the EXECUTOR reverts
  `OutputToSettlement` on every path.
- A direct `setOrderSigner` that lowers a stored expiry burns the delegate's
  relayed-permit word.
- An order with non-empty `invariants` and an empty `legsOut` reverts
  `OrderGates.NotExclusiveFiller` for any filler other than `order.exclusiveFiller`,
  regardless of the window, the soft override or position items; `FILLER_SET` or an
  open order fails closed. `SettlementLens.previewFill` reverts the same way, and
  `validateOrder` / SDK `packOrder` refuse such orders unless one hard
  `exclusiveFiller` covers the order's whole life.
- `DutchAuction.currentAmountIn` (and `SettlementLens.previewAmountIn`) reverts
  `InvalidProportionalLeg` for a marker off `legsIn[0]`.
- `packages/core/src/utils/Permit3TransferLib.sol` is deleted (see `Base._pullViaPermit3`).

**Permit3**: `permitBatchWithWitness(Hash)IfNeeded` with an expired deadline is a
no-op when the nonce is already spent (a partial first fill can be continued past
`batch.deadline`), instead of reverting `PermitExpired`.

**Periphery**: `DestinationSettler7683.fill` `originData` is
`abi.encode(FillPayload{OrderPayload payload; FillBounds bounds})`, bounds
mandatory; `fillerData` is empty, `abi.encode(address)` or
`abi.encode(FillerData{payTo, minBumpBps, bounds})`. `OriginSettler7683` quotes for
the destination settler, sets `minReceived[i].recipient = 0` and requires the
envelope nonce to equal the order nonce. `SettlementLens` deploys
`SettlementLensChecks` in its constructor (new `CHECKS()`; the lens init code and
CREATE2 address change); new `pinnedBump` / `previewFillInFlightPinned`;
`getOrderRelevantState(s)` reports Invalid for reserved-nonce and dead shapes;
`remaining()` returns 0 instead of panicking; `validateOrder` no longer rejects
`floorBps > 10000`. `NativeSettler`: `SingleOutputLegRequired` →
`OutputLegRequired` (multi-output orders accepted).

**Solvers**: `UsdrifInventorySolver.executeFill(order, sig, amt, maxSpent)` and
`executeFillAndRedeem(order, sig, amt, maxSpent, qACmin)`; item orders refused.
`GuardedMatchSolver(settlement, address[] operators)`; PRESEND plans and
Settlement/EXECUTOR profit recipients revert; new `settleMatchWithNonces`.
`AggregatorFillSolver`: the `FillRoute` struct is replaced by a token-set form
(`tokens, before, inMask, outMask, outAnchor`); a non-zero `SurplusPolicy` needs
operators (`PolicyNeedsOperators`), retain mode needs operators
(`RetainNeedsOperators`); `executeFill` is non-reentrant; new `sweep()`,
`executeItemFill` / `onMatchRoute` (additive). Flash solvers: SETTLE items revert
`SettleItemsUnsupported`, `MultiOutputFlashSolver` refuses multi-input orders,
profit is swept in the flash asset, EXECUTOR/self as profit recipient reverts
`BadProfitRecipient`; new `FlashOpts` overloads and `PERMIT_ENVELOPE` /
`permitEnvelope` (a sig whose first word equals `PERMIT_ENVELOPE` is read as a
permit envelope). `FillRecovery`: the any-size sentinel reverts
`SentinelNotRecoverable`.

**Validators**: `Erc721OwnerInvariant`, `Erc1155BalanceInvariant`,
`MinBalanceInvariant` revert `ReceiptNeedsNamedFiller` on a no-output order unless
the filler is `exclusiveFiller` (re-sign open purchase orders with a named filler).
`PredicateStaticCall` reverts `PredicateFailed` on a reverting/codeless/short target
(inside a `ConditionTree` a non-TRY leaf now raises `ConditionErrored`); an
out-of-gas sub-call consumes all remaining gas, even under TRY.
`ChainlinkTickFloorValidator` evaluates Proportional orders at the cap (uncapped or
zero cap: `UncappedProportional`). The Chainlink validators read an optional
trailing `(uptimeFeed, gracePeriod)` pair: a blob that carried 2+ ignored trailing
words is now interpreted. `FillerAttestationValidator` returns false (no longer
reverts) on a foreign or malformed `takerData` envelope.

**Module `data` and behaviour** (no core change):

| Module | Change |
|---|---|
| `OcoGroupModule` | claim item data `abi.encode(groupId, nonce, minClaim)`, `0 < minClaim <= item amount`; the 2-word blob fails validation |
| `CosignedQuotePriceModule`, `ClockFlooredQuoteModule` | quote typehash `PriceQuote(bytes32 orderHash,address filler,uint256 bumpBps,uint256 deadline,uint256 prevFilled)`; an unquoted ClockFloored fill gets 0 (start) |
| `RangePriceModule` | `START_BPS > END_BPS` reverts `DescendingRange` |
| `ChainlinkPeggedPriceModule` | anchors on the counterpart leg's whole-order amount; `NUM == 0` rejected; `fair == 0` reverts `ImplausiblePrice`; +2 constructor args (sequencer feed, grace) |
| `ProportionalSweepModule` | fractional bps needs `abi.encode(token, marker, total)` and is full-fill only |
| `ERC20PermitTransferModule` | `abi.encode(token, recipient, transferAmount, totalAmount[, permit @128])`, full-fill only |
| `NftSettlementModule` | `abi.encode(collection, tokenId, total)`, full-fill only |
| `PermissionlessCallModule` | `CallSpec` gains `address bountyToken` |
| `MocPriceBandValidator` | `abi.encode(mocCore, tp, minPrice, maxPrice)`, reads `getPACtp` |
| `TwapFillModule` | `decayStartTime == 0` reverts |
| `ListaBrokerModule` borrow (op 1) | `abi.encode(uint8(1), broker, termId, maxApr, duration, totalAmount[, moolah, authBlock])`, base 192, `maxApr`/`duration` mandatory; `TermMismatch` post-check |
| Midnight modules | trailing `totalAmount` mandatory on Taker/Borrow/Lend blobs (short blobs: `MalformedData`); `MidnightLoopCallback` word 3 is `minRateWad` (per-take rate); every module and the loop callback need the maker's `setIsAuthorized` |
| `MorphoBlueRepayModule` | repays `min(amount, accrued debt)` (partial instead of `BufferTooSmall`); `FloorBreached` |
| Exact withdraws on Aave v4 / Venus / Compound v2 (+native) | revert `ShortWithdraw` on a short delivery (size fee-charging venues net of the fee; close a whole position with `Full`); Venus/Compound v2/Aave v4 takers revert `UnderlyingMismatch` |
| Liquity v2 (+ Felix) | `data` leads with `branchIndex` (rooted at the immutable `CollateralRegistry`); taker op 0 Borrow carries a mandatory `totalAmount`; value-out reverts `ShortWithdraw` unless the trove's remove-manager receiver is the module (re-run `setRemoveManagerWithReceiver(troveId, module, module)`); `CollTokenMismatch`; the pull repay no longer has `FullCloseNotSupported` (River pre-fund gains it) |
| Teller | `full = false` with `amount >= owed` closes via `repayLoanFull` and sweeps the surplus; repay reverts `NotBorrower` unless `getLoanBorrower(bidId) == maker`; pool deposit needs Hypernative oracle registration of the module (deploy step) |
| Fluid | custody modules' constructors take `(…, vaultFactory, wrappedNative)`; `WrongFactory` / `UnknownVault`; native value-out is delivered as WETH; deposit/repay revert `NotPositionOwner`; `FluidRepayModule` data gains an optional mode word at 96 (tagged `Full = 0xB0DE0001`, an untagged non-zero word reverts `InvalidModeWord`) and `totalAmount` at 128 (required under `Full`) |
| `ExactlyRepayModule` fixed branch | permit tail is `(value, deadline, v, r, s)` at 192 |
| `ExactlyPreFundModule` | fixed-repay `totalAmount` @160 is the leg's smallest full-fill delivery |
| `ExactlyTakerModule` | fixed withdraw reverts `ShortFixedPosition` above the fixed deposit |
| `DolomiteOperatorModule` | `MarketTokenMismatch`; `proceedsAsset` is `view` and returns registry tokens |
| `EulerV2OperatorModule` | EVC tail at 128 is `abi.encode(EvcPermit[])`, signed with `sender = module`; optional `subId` words (`subId = 0` blobs unchanged) |
| `BridgedOrderInbox` | `rescue(token, to, amount)` bounded by `orphaned[token]`; new stray-rescue queue; `settleExpired(order, beneficiary, token)`; `composeConsumed` removed; finite deadlines required |
| `AcrossBridgeOutModule` / `LzOftBridgeOutModule` | specs gain trailing `totalAmount`; `approveFeeSponsorship(maker, amount, maxPerSend)` (+ increase/decrease); a sponsored LZ send must be a SETTLE item (`SponsoredSendNeedsSettle`, `FillerNotSponsor`; new `setSponsorFiller`) |
| `CctpBridgeOutModule` | CCTP **V2** (V1 sunsets 2026-10-31 / 2026-12-01): `CctpSpec` gains `maxFeeBps`, `minFinalityThreshold`; V2 TokenMessenger constructor arg |
| `PositionFunnel` | `isValidSignature` rejects on the implementation / zero owner |
| `DelegationHelper` / `PermitHelper` (lib) | optional trailing `signedValue` (permit block 160 bytes, Aave delegation 192); replays skipped when the standing grant covers the fill |
| `ERC4626WithdrawModule` | claim data is 4 words `(vault, requestId, minAssets, totalAmount)`; a 3-word blob reverts `PartialFillUnsupported` (fails closed) |

**SDK and off-chain**: `encodeFillUpTo` requires `minBumpBps`; `encodeFillWithPermit`
and the ABI follow the new Settlement entries; `buildRevokeAll` requires the
outstanding permit nonces and burns venue nonces; `PriceQuote` gains `prevFilled`;
`fillAmountFromBudget` / `previewFillLocal` take a `FillerContext` object;
`forLegPreFund(index, token, op)` requires `op`; priority-auction pricing helpers
throw `PricingNeedsContext` without an explicit `priorityFee`; `patchOrder` /
`amendOrder` refuse a same-nonce replacement of an ordinary order and a fresh nonce
for a fill-once order unless `{leaveNonceGroup: true}`; Permit3 typed-data builders
throw on a mis-namespaced nonce; block-clocked orders need `opts.headBlock`;
`adviseBand` returns null for a fixed leg. `@1delta-x/orderbook`: `Book.admit`
`{exempt}` → `{replaces}`; `OrderSummary.amountIn` / `.price` nullable; cancel
verification accepts no ERC-6492/8010 wrappers; permit announces need a valid
Permit3 witness signature. `orderbook-server /quote` needs `gasPrice` for
priority-auction orders and returns calldata with the quoted `minBumpBps` and the
resolved `fillAmount`. `@1delta-x/auction`: one standing bid per filler, quotes
bound to a declared executor, SELL sizing by `legsIn[0].start`. The reference app
funds with two transactions (ERC-20 approve to Permit3 + an exact, expiring
`Permit3.approveToken` to Settlement).

### 2026-08-12 — the order struct changed shape (NEW ORDER TYPEHASH)

Every order encoder, signer and indexer must be updated together. There is no
compatibility shim: an order built the old way produces a different hash and
simply fails signature verification.

**Removed** three fields — `exclusivityOverrideBps`, `gasBumpBps`, `gasPriceRef`.
**Added** `uint256 params` (which carries all three, plus the new priority-fee
scale) and `address pricingModule`. Field order is now:

```
maker, nonce, deadline, legsIn, legsOut, timing, exclusiveFiller, minFillAnchor,
params, curve, items, validators, invariants, fillModule, fillTotal, pricingModule
```

`params` layout — mirror it exactly (`DutchAuction.packParams`, SDK `packParams`):

```
[0:16)    exclusivityOverrideBps        [32:96)    gasPriceRef   (wei)
[16:32)   gasBumpBps                    [96:160)   priorityScale (wei)
```

Two new `timing` bits are now meaningful and were previously required to be zero:
**102 = BLOCK clock** (the decay clocks count blocks, not seconds) and
**103 = PRIORITY auction** (the bump is bid in priority fee). An encoder that
leaves them clear keeps the old behaviour exactly.

The golden order hash moved to
`0x627e590874df6c58eba2354e7f1cf0c103f72bc95d48a01e758493e7a5bbcfef`; it is pinned
on both sides (`HashGolden.t.sol` and the SDK's `canonicalOrder.ts`).

**Also new, and opt-in rather than breaking:** a signature may now be a BULK
(Merkle) envelope — `innerSig(65) ‖ proof ‖ 0xB0` — authorizing every order whose
hash is a leaf of a root the maker signed as `OrderRoot(bytes32 root)`. Anything
that constructs signature envelopes must avoid accidentally producing that shape:
a payload of length ≥ 98 with `(length - 66) % 32 == 0` and a trailing `0xB0` byte
is read as a proof. Ordinary 64/65-byte ECDSA signatures can never collide.

### 2026-07-29 — signing-format changes

These change `ref = keccak256(data)` and/or the order hash. **SDK and relayer
encoders must be updated together**; there is no compatibility shim.

| Component | Old `data` | New `data` |
|---|---|---|
| Gearbox credit (borrow / add-collateral) | `(facade, creditAccount, asset)` | `(creditAccount, asset)` — facade **derived** |
| Liquity add-coll | `(borrowerOps, troveId, collateralToken[, permit])` | `(troveManager, troveId, collateralToken[, permit])` |
| Liquity repay | `(borrowerOps, troveManager, troveId, boldToken)` | `(troveManager, troveId, boldToken)` |
| Liquity taker (both ops) | `(op, borrowerOps, troveId, …)` | `(op, troveManager, troveId, …)` |
| ERC4626 claim (phase 2) | `(vault, asset, requestId)` | `(vault, requestId, minAssets)` — since 2026-09-30 `(vault, requestId, minAssets, totalAmount)` |
| Composite items (Dolomite / Euler V2 / Fluid / River) | struct without `totalAmount` | `totalAmount` appended — the item's full signed amount |
| Any `BalanceMode.Full` taker leg | `… | mode(32)` | `… | mode(32) | itemTotal(32)` |

Two of these fail **silently** if missed, so they deserve extra care:

- **ERC4626 claim** — the pre-2026-07-29 encoding decoded without error (the asset
  address was reinterpreted as a `requestId`). Since 2026-09-30 the claim carries a
  trailing `totalAmount`, and a 3-word blob of either generation fails closed with
  `PartialFillUnsupported`; it no longer decodes silently.
- **Liquity** — the leading address became the TroveManager, not BorrowerOperations.
  Both are addresses of the same width; passing the old one resolved the chain to the
  wrong contract. (Mainnet BorrowerOperations exposes no `troveManager()` getter,
  which is *why* the root moved — see `LiquityV2TroveAuth`.) **Superseded since:**
  the root is now the module's immutable `CollateralRegistry`, and every Liquity blob
  leads with `branchIndex` instead of an address (see the 2026-09-30 table above).

Everything else fails closed with a named error.

### Also required before deployment

- **Gearbox** — users grant the bot role with a mask that must EXACTLY equal the
  module's `requiredPermissions()`: `0x01` for add-collateral, `0x22` for borrow.
  Gearbox rejects any other value.
- **`UsdrifInventorySolver`** — `setMaxOutflowPerFill(token, cap)` must be set by the
  owner before any operator can fill; it defaults to zero and fails closed. Since
  F30 the owner must ALSO set `setFillRoute(USDT0, USDRIF, minRateWad)`, a
  `setSellRoute` per recycle pair, and `setOutflowLimit(token, limit)` for every
  token that leaves (USDT0, RIF, …) — each defaults to zero and fails closed. Keep
  the rate floors near market: a stale floor is the loss budget of a stolen key.
  Since 2026-09-30 operator tooling must pass `maxSpent` to every fill, and must
  expect `QueueMovedDuringMeasurement` when a MoC queue execution (permissionless:
  `MocMultiCollateralGuard.execute()`) lands inside the call — retry, do not widen
  the bounds.
- **Teller pool deposits** — register `TellerPoolDepositModule` with the
  Hypernative oracle firewall (`onlyOracleApprovedAllowEOA`) before advertising it.
- **Liquity v2 troves** — onboard with `setRemoveManagerWithReceiver(troveId,
  module, module)`; a trove onboarded with the 2-argument `setRemoveManager`, or
  bought with a stale pair, must be re-onboarded.
- **CCTP** — deploy `CctpBridgeOutModule` against the V2 TokenMessenger.
- **Settlement constructor** — now rejects a `permit3` address with no code.
- **Orderbook indexers** — must additionally watch `NonceWordInvalidated`, or they
  will keep serving orders a maker has bulk-cancelled via `invalidateNonceWord`.

### 2026-06-18 — the C-1 fix

The C-1 fix changes the **off-chain signing format**. Relayers / SDKs MUST update:

- **`TakerPermit` struct**: field `module` → **`spender`**. Set it to the
  **Settlement contract address**, not the module.
- **`approveTaker(spender, ref, amount, expiration)`**: the first argument is now
  the spender (Settlement).
- **`ref` is unchanged**: still `keccak256(data)`.
- **`ModuleRefPair` → `SpenderRefPair`** (for `lockdownTakers`).
- **EIP-712 typestrings** changed to
  `TakerPermit(address spender,bytes32 ref,uint160 amount,uint48 expiration)`
  in Permit3's batch/witness typehashes and Settlement's witness typestring.
- **Maker module constructors** now take an extra `address settlement` argument.

---

## Reporting a vulnerability

Report suspected vulnerabilities privately to **security@1delta.io**. Please do
not open public issues for security reports. Include a description, affected
contracts/addresses, and a reproduction (a failing Foundry test is ideal).

### Running the test suite

```bash
forge build --skip '*.s.sol'     # '*.s.sol' skip: boilerplate Deploy script is not part of the system
forge test  --skip '*.s.sol'     # fork tests; set ETH_RPC_URL to pin a fast mainnet RPC
```
