# `@1delta-x/modules-nft`

[`ISettlementModule`](../../core/src/interfaces/ISettlementModule.sol) implementations
for non-fungible and semi-fungible wares. A `SETTLE` item is a generic, **filler-aware**
maker↔solver exchange: it hands the maker's ware to whoever fills, after the maker has
been paid by the order's mandatory `legsOut` legs.

| | |
|---|---|
| `NftSettlementModule` | ERC-721. INDIVISIBLE — it ignores `slice`, so an order using it must be full-fill only (`minFillAnchor == anchor`). The core's `SettleSliceZero` floor is what stops a dust fill from taking the token for nothing. |
| `Erc1155SettlementModule` | ERC-1155. DIVISIBLE — `Item.amount` is the quantity for a fully-filled order and each fill moves its exact pro-rata slice, so the item composes with partial fills. |

Both are gated on `msg.sender == settlement` (the maker's order signature is the
authority) plus the maker's `setApprovalForAll` on the collection. `data =
abi.encode(collection, id)`.

```
make test-modules-nft
```

> Moved out of `packages/core/src/modules` on 2026-08-24 along with every other
> module. Core keeps proving its own SETTLE semantics — dispatch, filler-awareness,
> the pro-rata slice and the `SettleSliceZero` floor — against local mocks; see
> `packages/core/test/items/SettleSlice.t.sol`, which asserts the exact slice the core
> computes instead of inferring it from a token balance.
