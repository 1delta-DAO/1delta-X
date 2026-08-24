# `@1delta-x/validators`

`IOrderValidator` implementations — gates and invariants a maker names in a signed
order. Structurally identical to a module: reached only through a `staticcall` the
core makes on behalf of a signed order, one deployed instance per configuration,
permissionless to deploy. Nothing in `packages/core/src` imports any of them.

**Validators** run before the fill and gate it:

| | |
|---|---|
| `ChainlinkPriceValidators` | oracle triggers — take-profit / stop-loss, tick floors, staleness. Also exports the `ChainlinkRead` library the pegged price module builds on. |
| `ConditionTreeValidator` | boolean combinations of other validators. |
| `TimestampValidator` | time windows. |
| `PredicateStaticCall` | an arbitrary read-only predicate. |
| `FillerWhitelistValidator` | curated filler sets, with an open-after-T escape. |
| `FillerAttestationValidator` | signed filler attestations. |

**Invariants** run *after* the fill and unwind it if violated — the receipt mechanism
for anything the core cannot express as a fungible leg:

| | |
|---|---|
| `OwnershipInvariants` | `Erc721OwnerInvariant` / `Erc1155BalanceInvariant` — "I must own this NFT when this fill ends". Makes NFT delivery reverting-mandatory without the core knowing what an NFT is. |
| `MinBalanceInvariant` | a floor on a post-fill balance; the fee-on-transfer answer. |

```
make test-validators
```

> Moved out of `packages/core/src/validators` on 2026-08-24, for the same reason the
> modules moved: a bug in one of these costs the orders that named it, not the
> protocol. `ExoticSettlement.t.sol` came along, since `OwnershipInvariants` is its
> subject.
