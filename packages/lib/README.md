# `@1delta-x/lib`

Shared Solidity libraries for **module authors**. These lived in `core/src/utils` and
`core/src/dust`, but `packages/core/src` imports none of them — their consumers are
the ~24 module packages under `packages/modules`.

| | |
|---|---|
| `DustHandler` | residual disposal after a pull-exact repay: `SweepToUser` (the floor — a plain transfer that cannot revert for protocol-state reasons) or `Recycle` (push it back into the position, CoW × Aave style). Recycle is best-effort and falls back to sweep, because a re-supply can revert for reasons unrelated to the user's intent (supply caps, frozen reserves, isolation mode). |
| `FullFillGuard` | the full-fill assertion modules use when a partial slice would corrupt their accounting. |
| `PermitHelper` | EIP-2612 permit plumbing. Best-effort replay; skipped when the standing allowance already covers the fill (permits SET, they do not raise); optional trailing `signedValue` word so one signature can serve partial fills. |
| `DelegationHelper` | credit-delegation / operator approvals across Aave, Comet, Morpho and the Euler EVC. Same set-not-raise skip and optional `signedValue` for Aave. The EVC tail is `abi.encode(EvcPermit[])`, each permit replayed independently with `sender = <the module>` — makers sign module-bound EVC permits, the operator grant in its own permit and namespace. |

### Signature tails outlive cancellation

A venue signature carried in an order's `data` is public. Cancelling the order or
revoking the grant directly on the venue does not consume the venue nonce, so for
Aave `delegationWithSig`, Comet `allowBySig` and Morpho/Lista
`setAuthorizationWithSig` (any-sender by venue design) the lifted bytes stay
landable until their venue deadline. A durable revoke must consume the nonce
(`allowBySig(…, false, currentNonce, …)`, `setAuthorizationWithSig({isAuthorized:
false, nonce: current})`, `delegationWithSig(…, 0, …)`); sign venue deadlines no
later than the order deadline. The EVC permit is module-bound and is not exposed.
See the `DelegationHelper` header.

```
make test-lib
```

> Split out of core on 2026-08-24. `SafeTransferLib` and `Permit3TransferLib` did NOT
> come with them — `core/src/settlement` imports those two directly, so they are core
> internals and stayed behind. That split is the whole point: `utils/` had been two
> different things wearing one name.
