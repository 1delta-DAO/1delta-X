# `@1delta-x/modules-maker`

[`IMakerModule`](../../core/src/interfaces/IMakerModule.sol) implementations — MAKE
items, which act **on the maker's behalf** during a fill.

| | |
|---|---|
| `FeeTransferModule` | the originator fee on an **outputless** order. Fees are normally output legs (`recipientOut`); an order with no output leg has nowhere to put one, so the fee becomes an item that pulls an absolute amount via Permit3 to a named recipient. |
| `PermissionlessCallModule` | the escape hatch: one arbitrary maker-signed call, from an identity that holds **no authority at all**. |

> ⚠ `PermissionlessCallModule` is deliberately powerless, and that is the whole design.
> The 2026-08 audit found that its predecessor `GenericCallModule` held per-user
> Permit3 allowances **and** made an arbitrary maker-signed call from its own identity
> — so an attacker's self-signed order could spend a stranger's allowance to it.
> "Maker-signed `data`" is not a safety argument on its own, because every address can
> be the maker of its own order. What makes this version safe is that it has nothing
> worth stealing.

```
make test-modules-maker
```

> Moved out of `packages/core/src/modules` on 2026-08-24 along with every other module.

See [docs/originator-fees.md](../../../docs/originator-fees.md) and
[docs/relayer-fees.md](../../../docs/relayer-fees.md).
