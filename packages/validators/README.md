# `@1delta-x/validators`

`IOrderValidator` implementations — gates and invariants a maker names in a signed
order. Structurally identical to a module: reached only through a `staticcall` the
core makes on behalf of a signed order, one deployed instance per configuration,
permissionless to deploy. Nothing in `packages/core/src` imports any of them.

**Validators** run before the fill and gate it:

| | |
|---|---|
| `ChainlinkPriceValidators` | oracle triggers — take-profit / stop-loss, tick floors, staleness, and an optional L2 sequencer-uptime + grace-period guard (a trailing `(uptimeFeed, gracePeriod)` pair in the data; sign it on every rollup). Also exports the `ChainlinkRead` library the pegged price module builds on. The tick floor prices a Proportional `legsIn[0]` at its signed cap. |
| `ConditionTreeValidator` | boolean combinations of other validators. NEGATE inverts only a clean boolean: a reverting leaf is an error, and an out-of-gas leaf is propagated as out-of-gas even under TRY. Check that a leaf reverts on a broken input before negating it (see the contract note for the list). |
| `TimestampValidator` | time windows. |
| `PredicateStaticCall` | an arbitrary read-only predicate. A reverting / codeless / short-returning target reverts `PredicateFailed` (it is never read as `false`). |
| `FillerWhitelistValidator` | curated filler sets, with an open-after-T escape. |
| `FillerAttestationValidator` | signed filler attestations. A malformed `takerData` envelope reads as "no credential" (`false`). |

> **The gated filler is an address.** Both filler-keyed validators check
> Settlement's immediate `msg.sender`. Listing or attesting a contract that fills
> on behalf of arbitrary callers (an open `AggregatorFillSolver`, the flash-solver
> family, `GuardedMatchSolver`, `DestinationSettler7683`) admits every caller of
> it, and an attestation becomes public — replayable through that contract until
> `expiry` — on first use. List / attest EOAs or operator-GATED contracts only.

**Invariants** run *after* the fill and unwind it if violated — the receipt mechanism
for anything the core cannot express as a fungible leg:

| | |
|---|---|
| `OwnershipInvariants` | `Erc721OwnerInvariant` / `Erc1155BalanceInvariant` — "I must own this NFT when this fill ends". A reverting end-state condition, without the core knowing what an NFT is. |
| `MinBalanceInvariant` | a floor on a post-fill balance; the fee-on-transfer answer. |
| `InvariantReceiptGuard` | library the three invariants above share — see below. |

> **An invariant proves an END STATE, not a delivery.** `ownerOf == maker` or
> `balance >= floor` is equally true when the maker obtained the asset some other
> way (a second bid, a marketplace offer the filler accepts in its callback, a buy
> at the ask). So when the invariant is the order's only receipt — `legsOut` empty,
> the NFT-purchase / NFT-for-NFT / "pay X, end with ≥ Y" shapes — the three
> invariants refuse any filler other than the order's named `exclusiveFiller`
> (`ReceiptNeedsNamedFiller`; the F30 delta-verify rule, whole order life). With an
> output leg they are a floor on top of the leg and stay open to every filler.
> A maker with several live offers for the same asset should also share one
> fill-once nonce across them, or cancel the stale ones.

```
make test-validators
```

> Moved out of `packages/core/src/validators` on 2026-08-24, for the same reason the
> modules moved: a bug in one of these costs the orders that named it, not the
> protocol. `ExoticSettlement.t.sol` came along, since `OwnershipInvariants` is its
> subject.
