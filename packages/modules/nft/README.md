# `@1delta-x/modules-nft`

[`ISettlementModule`](../../core/src/interfaces/ISettlementModule.sol) implementations
for non-fungible and semi-fungible wares. A `SETTLE` item is a generic, **filler-aware**
maker↔solver exchange: it hands the maker's ware to whoever fills, after the maker has
been paid by the order's mandatory `legsOut` legs.

| | |
|---|---|
| `NftSettlementModule` | ERC-721. INDIVISIBLE — `data = abi.encode(collection, tokenId, total)` with `total` = the item's signed `amount`, and the module requires the fill's slice to equal it (`FullFillGuard`), so the token only ever moves on a FULL fill whatever `amount` was signed. (Until audit 2026-09-30 MISC-MOD-2 the slice was ignored and only the core's `SettleSliceZero` — which covers just `amount = 1` — stood between a one-unit fill and the NFT. BREAKING: the old two-word blob reverts.) |
| `Erc1155SettlementModule` | ERC-1155. DIVISIBLE — `Item.amount` is the quantity for a fully-filled order and each fill moves its exact pro-rata slice, so the item composes with partial fills. |

Both are gated on `msg.sender == settlement` (the maker's order signature is the
authority) plus the maker's `setApprovalForAll` on the collection. 1155 `data =
abi.encode(collection, id)`.

```
make test-modules-nft
```

> Moved out of `packages/core/src/modules` on 2026-08-24 along with every other
> module. Core keeps proving its own SETTLE semantics — dispatch, filler-awareness,
> the pro-rata slice and the `SettleSliceZero` floor — against local mocks; see
> `packages/core/test/items/SettleSlice.t.sol`, which asserts the exact slice the core
> computes instead of inferring it from a token balance.
