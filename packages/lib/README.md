# `@1delta-x/lib`

Shared Solidity libraries for **module authors**. These lived in `core/src/utils` and
`core/src/dust`, but `packages/core/src` imports none of them — their consumers are
the ~24 module packages under `packages/modules`.

| | |
|---|---|
| `DustHandler` | residual disposal after a pull-exact repay: `SweepToUser` (the floor — a plain transfer that cannot revert for protocol-state reasons) or `Recycle` (push it back into the position, CoW × Aave style). Recycle is best-effort and falls back to sweep, because a re-supply can revert for reasons unrelated to the user's intent (supply caps, frozen reserves, isolation mode). |
| `FullFillGuard` | the full-fill assertion modules use when a partial slice would corrupt their accounting. |
| `PermitHelper` | EIP-2612 permit plumbing. |
| `DelegationHelper` | credit-delegation / operator approvals across Aave, Comet and Morpho. |

```
make test-lib
```

> Split out of core on 2026-08-24. `SafeTransferLib` and `Permit3TransferLib` did NOT
> come with them — `core/src/settlement` imports those two directly, so they are core
> internals and stayed behind. That split is the whole point: `utils/` had been two
> different things wearing one name.
