# Delegated order signers

*Session keys and trading desks: letting a key other than the maker's own
authorize that maker's orders, without handing over custody.*

Two contracts carry this: the registry and its setters live in
[`OrderState.sol`](../packages/core/src/settlement/OrderState.sol), the
verification in
[`Signatures.sol`](../packages/core/src/settlement/Signatures.sol). The
preflight mirror is in
[`SettlementLens.sol`](../packages/periphery/src/SettlementLens.sol).

---

## The problem

An order is authorized by an EIP-712 signature over its hash, verified against
`order.maker`. That is the right default and it is not always workable:

- a **trading desk** wants an operational hot key to sign flow, while the assets
  and approvals stay on a cold address;
- a **session key** should be able to sign for an hour and then stop mattering,
  without the user re-approving anything;
- a **passkey / smart account** may be the only signer a consumer actually has,
  while the funds sit on a plain EOA.

None of these are expressible with "the maker signs, or nothing happens".

## The shape of the wrong answer

Several protocols solve this with a **protocol-level operator**: an
admin-nominated address that may sign on users' behalf. The OpenOcean LOP fork is
the sharpest example — when a relayed blob is present, the *order hash* is
verified against an admin-set `operator`, while the user's own signature covers
only a fixed, order-independent message (`"fillGridOrder"`) with no nonce, no
deadline, and no binding to any order. One such signature, ever, is unbounded and
replayable delegation over everything that user has approved.

The capability is fine. The nomination is not. **Delegated signing is only safe
when the delegator chooses the delegate**, and that single distinction is what
the whole design below is arranged around.

## The registry

```solidity
mapping(address maker => mapping(address signer => uint256 expiry)) public orderSignerExpiry;

function setOrderSigner(address signer, uint256 expiry) external;   // msg.sender is the maker
```

`0` means *not a signer*. Any non-zero value is the unix time the delegation
lapses at; `type(uint256).max` never lapses.

> **Convention divergence, deliberate.** Permit3's `expiration` field uses `0` to
> mean *never expires*. Here `0` is the value of an unset mapping entry, so it
> must mean *not authorized* — the two conventions sit one contract apart and are
> called out in-file for exactly that reason.

`address(0)` cannot be nominated. `ecrecover` returns the zero address for any
malformed signature, so an authorized zero address would promote every
unrecoverable signature to a valid delegated one.

### The bound

The mapping is keyed **by `msg.sender` on write** and **by the order's own maker
on read**. Those two facts together are the security model:

- nobody can nominate a signer for someone else — the write key is the caller;
- a delegate's reach is exactly *orders naming its nominator*, because the order
  hash commits to `maker` and the lookup is
  `orderSignerExpiry[order.maker][recovered]`.

So a delegate can author **nothing the maker could not have authored itself**,
and nothing at all for any other maker. There is no protocol-level signer, and
every other gate — deadline, nonce, validators, invariants, and above all the
maker's Permit3 allowances with their own caps and expiries — binds a delegated
order exactly as it binds a self-signed one.

Precedent: 0x Protocol v4's `registerAllowedOrderSigner`. The expiry is ours.

## Verification order

[`Signatures._verifySignature`](../packages/core/src/settlement/Signatures.sol)
resolves authorization in this order. The ordering is load-bearing — it is what
keeps the hot path free and the delegate branches collision-proof.

| # | Condition | Path |
|---|---|---|
| 1 | `sig.length == 0` | on-chain `approveOrder` record |
| 2 | *(after the first fill)* `filled != 0` | already authorized once — skip |
| 3 | 64/65-byte sig recovering to `order.maker` | **the hot path** |
| 4 | 64/65-byte sig recovering to a nominated address | EOA delegate |
| 5 | non-ECDSA length **and** maker has no code | contract-delegate envelope |
| 6 | anything else | EIP-1271 on the maker (contract wallets, 7702) |

**Step 3 costs exactly what it cost before delegation existed.**
`SignatureVerification.tryRecoverSigner` was split out of `verify` (a
behaviour-preserving refactor — the `standardLength` flag keeps
`InvalidSigner` and `InvalidSignatureLength` distinct), so the verifier recovers
once, compares, and returns. The registry SLOAD sits behind a *mismatch*; an
ordinary fill never touches it.

Measured: **+448 bytes** of Settlement for steps 4 and the registry, **+180** for
step 5, and **under 100 gas** on a plain fill under the legacy profile — which,
per the profile note below, overstates what the deployed build pays.

## Contract delegates — the envelope

A Safe, a passkey wallet, any EIP-1271 signer cannot be reached by step 4: that
step keys on the address `ecrecover` produced, and a contract signature has no
such address. The filler therefore **names** the delegate:

```
sig = abi.encodePacked(address delegate, bytes innerSig)
```

### Why this cannot collide with a real signature

Step 5 is reached only when **both** hold:

1. the signature is not 64 or 65 bytes, so it is not an ECDSA signature step 3/4
   could have handled; **and**
2. the maker has **no code**, so it has no `isValidSignature` of its own and the
   payload cannot be a 1271 signature meant for the maker.

That combination is a state which, before this feature, *always* reverted
`InvalidSignatureLength`. It was dead space. A **contract maker never reaches
step 5** — it falls through to step 6 exactly as before, which is correct, since
a contract maker manages its own signer set internally and has no need of the
registry.

Neither condition may be relaxed. `test_contractMakerWithLongSig_notReadAsAnEnvelope`
pins it with an 85-byte payload — precisely an envelope's shape — presented
against a contract maker, and asserts it reaches the maker's 1271.

The filler choosing the address grants it nothing: the registry lookup is keyed
by the order's maker, so the only addresses that pass are ones that maker
nominated. Naming any other is a failed lookup.

> **Encoder rule.** An envelope whose *total* length lands on 64 or 65 bytes is
> unreachable — it would be read as a plain ECDSA signature at step 3. Builders
> must not emit an `innerSig` of 44 or 45 bytes. No real signature scheme
> produces one.

## Gasless nomination

A maker with no gas is precisely the maker the gasless-order flow exists for, and
they cannot send `setOrderSigner`. So nomination is also relayable:

```solidity
function setOrderSignerWithSig(
    address maker, address signer, uint256 expiry,
    uint256 nonce, uint256 deadline, bytes calldata sig
) external;
```

Signed over an EIP-712 `OrderSignerPermit` type, independent of `Order` — adding
it leaves the order typehash, and therefore the golden hash, untouched. Anyone may
relay it; the permit carries its own authorization.

**No re-delegation.** The permit is verified against `maker` through
`SignatureVerification.verify` directly, *not* through `_verifySignature`'s
delegated branch. A delegate therefore cannot appoint further delegates, and the
nomination graph stays exactly one level deep: every delegate in the book was
named by the maker whose orders it can sign. This is asserted by
`test_permit_delegateCannotReDelegate`, and the function carries a *do not
simplify this into `_verifySignature`* note.

**Replay protection reuses the maker's order nonce bitmap** rather than a private
counter, but in a **reserved half** of it. The coordinate actually consumed is
`nonce | SIGNER_NONCE_NS` (bit 255 forced on), never the bare `nonce`. The maker
still *signs* the bare value, so the EIP-712 payload and every signer is unchanged;
the reservation costs one `or` on-chain.

> ### ⚠ The namespace is not bookkeeping — it closes a kill switch
>
> Sharing the coordinate outright made an **unrelayed** nomination permit a latent,
> third-party-triggerable cancel on every order the maker later signed with the same
> nonce:
>
> | | |
> |---|---|
> | T0 | maker signs a nomination permit on nonce `N`; nobody relays it |
> | T1 | `isNonceCancelled(maker, N)` reads **false** — an allocator sees `N` as free |
> | T2 | maker signs and publishes an ordinary order on nonce `N` |
> | T3 | **anyone** relays the stale permit, at any point before its `deadline` |
> | T4 | the order is dead, with no action by the maker |
>
> Nothing at T3 needs a privilege, and nothing at T1 warns the maker: the bit stays
> clear until the permit lands. Nonce reuse is not exotic either — a shared nonce is
> exactly how an [OCO bracket](oco.md) is built, so the order side deliberately
> reuses the space the permit was drawing from. The SDK leaves nonce allocation to
> the caller (`amend.ts`), so nothing off-chain caught it either.
>
> Pinned by `test_signerPermit_cannotCancelALiveOrder`.

**The residual constraint — an *order* must not use a nonce with bit 255 set — is now
enforced on-chain.** `Base._gateOrderPost` rejects it with `OrderNonceReserved`, on
every fill entry. It used to rest on order builders alone, on the reasoning that a
range check would "tax every fill of every order forever to guard a range no allocator
picks"; that was true and still the wrong trade, because the tax is one `AND` on a word
the nonce-cancellation check reads on the very next line, while the guarantee it buys
must not depend on which client packed the order. A maker signing through a wallet, a
block explorer or a hand-rolled script now gets it too.

The SDK guard remains as the earlier, better-diagnosed failure: the constant is
exported as `SIGNER_NONCE_NS` and the check as `assertOrderNonce(nonce)`
(`packages/sdk/src/delegation.ts`), wired into `packOrder`.

Two consequences of the reservation, both deliberate:

- pre-emptively killing an unrelayed nomination still works with the primitives the
  maker already has, but it must name the **namespaced** coordinate:
  `cancelOrders([nonce | 1 << 255])`, or the matching `invalidateNonceWord`.
- `rollbackNonces` no longer reaches nominations at all — a floor would have to
  exceed 2²⁵⁵. That is the better behaviour, not a regression: retiring a ladder of
  orders should not silently revoke the desk's signing key as well.

## Caveats

### Revocation is final, and it is one call

A nomination permit burns its bitmap coordinate only when **relayed**. That used
to leave a hole: a maker who signed a gasless nomination, never had it landed, and
then revoked was still exposed — whoever held the message could relay it up to its
`deadline` and the delegate was live again, its signature settling orders the maker
never signed.

The remedy used to be a **two-call discipline** — clear the registry, then
`cancelOrders([permitNonce | SIGNER_NONCE_NS])`. The SDK emitted both. A wallet, a
block explorer, or a hand-rolled script emitted one. A safety property that depends
on the caller making a second call is not a safety property, so it is now the
contract's job:

```solidity
setOrderSigner(d, 0);   // clears the registry AND burns every permit for `d`
```

`OrderState._setOrderSigner` writes `nonceBitmap[maker][word] = type(uint256).max`
on the revoke branch, where `word = SIGNER_NONCE_NS >> 8 | d`. One `SSTORE`, no new
storage, and every client gets the property whether or not it has ever seen this
document.

**That single write covers every outstanding permit only because the coordinate
space is forced.** A permit's nonce MUST be `(signer << 8) | seq` with `seq` one
byte — `Signatures` rejects anything else with `SignerPermitNonceMalformed` — so all
256 coordinates a delegate could ever use live in that one word. Were the nonce
free-form, a permit could sit in another word and survive the revocation, which is
the hole all over again. The rule is enforced, not assumed; `test_permit_freeFormNonceRejected`
is the proof. It also forces `nonce < 2^168`, so a bare nonce can never itself carry
`SIGNER_NONCE_NS` — without which `n` and `n | SIGNER_NONCE_NS` would be two distinct
maker-signed permits sharing one coordinate (`test_permit_bareNonceCarryingTheNamespaceRejected`).

**The price, and it is deliberate:** after revoking `d`, gasless **re**-nomination
of `d` is impossible — every coordinate it could use is spent. Direct
`setOrderSigner(d, expiry)` still works, and a maker who cannot pay gas can nominate
a *different* key, which is what you should be doing with a delegate you just
revoked. Buying re-nomination back would take a per-delegate epoch in the permit
typehash: a storage slot and a breaking permit type, spent on making a compromised
key reusable.

`seq` therefore distinguishes *concurrent* nominations of the same delegate — a
rotation where an older permit may still be in flight — not successive ones across a
revocation. `encodeBurnSignerPermits` remains for the different job of killing a
permit **without** revoking: a nomination signed but never wanted relayed, where the
delegate was never live in the first place.

Pinned by `test_permit_staleUnrelayedPermit_cannotResurrectARevokedDelegate`,
`test_revocation_burnsEverySeqForThatDelegate` (all 256 die together) and
`test_revocation_doesNotBurnAnotherDelegatesPermits` (revocation stays per-address —
burning a word must not become an accidental bulk revoke).

Give permits a bounded `deadline` anyway. The SDK defaults to one hour.

### There is no bulk revocation, and `rollbackNonces` is not a substitute

Revocation is per-address. There is no epoch and no `lockdownAll` analogue, so
containing a compromised desk means naming every delegate it holds.

`rollbackNonces` looks like the panic button and is not: it sets a nonce **floor**,
and a delegate simply signs above it
(`test_rollbackNonces_doesNotContainACompromisedDelegate`). Per-address revocation
binds on any nonce (`test_perAddressRevocation_isTheOnlyContainment`). The only
other containment is revoking the Permit3 allowances that fund the fills — which
stops the maker trading too.

A maker who has lost the list can rebuild it: `expiry == 0` is the revocation
value, so the live set is a last-write-wins fold over `OrderSignerSet` logs. The
SDK does that in `liveDelegates(logs, now)` and batches the revocations with
`encodeRevokeOrderSigners`.

### A delegate cannot cancel on-chain, and two of the cancels fail silently

Every authoritative cancel is keyed by `msg.sender`. A delegate can *sign* orders
and can *retract* them from off-chain books — the `SoftCancel` verifier accepts the
same signer set the settler does ([soft-cancel.md](soft-cancel.md)) — but it cannot
hard-cancel.

`cancelOrder` and `revokeOrderApproval` say so loudly. The **nonce** cancels do
not: `cancelOrders` / `invalidateNonceWord` / `rollbackNonces` called by a delegate
succeed, write the *delegate's own* bitmap row, and emit
`OrdersCancelled(delegate, …)` — indistinguishable, to an operator or a bot
watching events, from a cancel that worked. Guard with the SDK's
`assertCanCancelOnChain(caller, maker)`; pinned by
`test_delegateCannotCancelForItsMaker`.

### Adopting EIP-7702 disables a maker's contract-delegate envelopes

The envelope branch is reachable only when the maker has **no code** — that
condition is what stops it shadowing a 1271 payload meant for a contract maker. The
consequence is easy to miss: an EOA maker who later sets an EIP-7702 delegation
stops reaching the branch, and every unfilled order its Safe/passkey delegate
signed becomes unauthorized.

Liveness only — nothing becomes authorizable that was not before, and no order is
stuck (`cancelOrder`, or re-sign). But it is a silent break on the day a principal
upgrades their wallet. Pinned by
`test_makerAdopting7702_disablesTheContractDelegateEnvelope`. ECDSA delegates are
unaffected: their registry probe runs before any `code.length` gate, which is also
why a **contract** maker may hold an EOA delegate.

### Revocation does not bind mid-order

`_verifySignature` re-checks a **signature** only on an order's first fill: a
non-zero `filled[orderHash]` is itself proof that some earlier fill presented
valid authorization for that exact hash, and the hash commits to `maker`. So
revoking a delegate does **not** stop the remainder of an order it already
part-filled.

This is the same caveat EIP-1271 makers already live with, and it is documented
there for the same reason. The kill switches that *do* bind mid-order are
unchanged:

- `cancelOrder(order)` — the specific order, by hash;
- nonce cancellation — `cancelOrders` / `invalidateNonceWord` / `rollbackNonces`;
- the order `deadline`;
- revoking the Permit3 allowances that fund the fill.

The on-chain `approveOrder` path is deliberately **not** subject to the skip — it
is a mutable record and a maker is told they may withdraw it, so it is re-read on
every fill.

### A contract maker with a 64/65-byte 1271 signature pays one extra SLOAD

It reaches step 4, misses the registry, and continues to step 6. Safe wallets and
most others produce longer payloads, which `tryRecoverSigner` rejects on length
alone, so they skip it entirely.

### Delegation is additive, never substitutive

The maker's own signature keeps working unchanged whether or not delegates exist
(`test_maker_stillSignsForThemselves`).

## Testing

[`DelegatedOrderSigner.t.sol`](../packages/core/test/swaps/DelegatedOrderSigner.t.sol)
— 35 tests. The ones that encode the security properties rather than the
capability:

| Test | Property |
|---|---|
| `test_delegate_cannotSignForADifferentMaker` | reach is bounded to the nominator |
| `test_nominationIsKeyedByCaller_notByOrderMaker` | an attacker nominating a key they hold buys nothing against a victim |
| `test_permit_delegateCannotReDelegate` | the nomination graph stays one level deep |
| `test_contractMakerWithLongSig_notReadAsAnEnvelope` | the envelope cannot shadow a 1271 payload |
| `test_7702RawKeyMaker_unaffectedByDelegation` | 7702 raw-key makers reach neither new branch |
| `test_7702Delegated1271Maker_stillFallsThroughTo1271` | the registry probe does not swallow the 1271 fallback |
| `test_permit_replayRejected` / `_preCancelledNonceRejected` | permits are one-shot and pre-cancellable |
| `test_signerPermit_cannotCancelALiveOrder` | a nomination permit cannot reach an order's nonce |
| `test_permit_bareNonceCancellationDoesNotReachIt` | …and the two halves are disjoint in both directions |
| `test_rollbackNonces_doesNotRevokeANomination` | a rollback retires orders, not the signing key |
| `test_permit_staleUnrelayedPermit_cannotResurrectARevokedDelegate` | revocation burns the permit word, so a stale message is dead |
| `test_revocation_burnsEverySeqForThatDelegate` | one revoke retires all 256 coordinates, not just the remembered one |
| `test_revocation_doesNotBurnAnotherDelegatesPermits` | …and only that delegate's — revocation stays per-address |
| `test_permit_freeFormNonceRejected` | the `(signer << 8) \| seq` derivation is enforced, not assumed |
| `test_permit_bareNonceCarryingTheNamespaceRejected` | a bare nonce cannot carry `SIGNER_NONCE_NS` |
| `test_permit_burningTheCoordinateMakesRevocationFinal` | …and the two-call revocation closes it |
| `test_rollbackNonces_doesNotContainACompromisedDelegate` | a nonce floor is not containment |
| `test_perAddressRevocation_isTheOnlyContainment` | …naming the delegate is |
| `test_makerAdopting7702_disablesTheContractDelegateEnvelope` | the envelope's codeless-maker precondition has teeth |
| `test_delegateCannotCancelForItsMaker` | a delegate's nonce cancel hits its own row, silently |

> **Fork-test gotcha.** The pinned-block fork hits a public RPC that rejects
> archive requests for **uncached** addresses. Any test that `prank`s, `deal`s, or
> triggers an `EXTCODESIZE` on a fresh `vm.addr(...)` fails with *"Archive
> requests require a personal token"*. Reuse `maker` / `solver`, or set
> `ETH_RPC_URL`.

> **Gas-profile gotcha.** `make gas` builds under the legacy `core` profile;
> deployment uses via-IR `core-deploy`. The two disagree materially on hot-path
> cost — a single added compare has measured +232 legacy against +40 via-IR. The
> snapshot is the right regression gate, not the right absolute number.

## SDK

Nomination is an ordinary contract call; the relayed variant needs the
`OrderSignerPermit` EIP-712 payload:

```
OrderSignerPermit(address maker,address signer,uint256 expiry,uint256 nonce,uint256 deadline)
```

signed against the settlement's `DOMAIN_SEPARATOR()`. An orderbook validating a
delegated order must consult `orderSignerExpiry(maker, signer)` — or simply call
`SettlementLens.getOrderRelevantState`, which mirrors the settler's full
verification order including both delegate branches.
