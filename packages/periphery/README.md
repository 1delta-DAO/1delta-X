# `@1delta-x/periphery`

Deployed contracts that sit **in front of** the settlement core, never inside it. The
dependency is one-way — periphery imports `@core/`, nothing in `packages/core/src`
imports back — so a bug here costs one integration, not the protocol.

| | |
|---|---|
| `SettlementLens` | the read-only reader: `hashOrder`, `validateOrder`, `previewFill`, `getOrderRelevantStates`. Holds no funds and no authority. A book that publishes prices calls this. |
| `Erc7683` + `OriginSettler7683` + `DestinationSettler7683` | the ERC-7683 cross-chain adapter pair. `DestinationSettler7683` is the one paid consumer of the lens on-chain (a `previewFill` staticcall). |
| `NativeSettler` + `NativeForwarderFactory` | native-ETH handling. Settlement itself is **native-agnostic** — no `payable`, no `msg.value`, no WETH anywhere in `core/src/settlement` — so these are adapters exactly like the 7683 pair, not a privileged part of the core. |

## Deployment

`SettlementLens` is a CREATE2 singleton in core's `Deploy.s.sol` (permit3 → settlement
→ lens), so its **address is a hash of its init code**.

> ⚠ `[profile.periphery-deploy]` in `foundry.toml` pins `via_ir`, `bytecode_hash`,
> `cbor_metadata`, `evm_version` and `optimizer_runs` byte-identical to
> `[profile.core-deploy]`. Changing one without the other starts a new address family
> for the lens alone, silently. The init-code hashes were verified **unchanged** across
> the 2026-08-24 split out of core.

`make size-check` gates all three deployable contracts from this profile. The lens is
the tightest of them historically — under legacy codegen it sat 162 bytes from
EIP-170, which is why it builds with via-IR here.

```
make test-periphery
```

See [docs/deterministic-deployment.md](../../docs/deterministic-deployment.md).
