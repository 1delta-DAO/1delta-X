# `@1delta-x/periphery`

Deployed contracts that sit **in front of** the settlement core, never inside it. The
dependency is one-way — periphery imports `@core/`, nothing in `packages/core/src`
imports back — so a bug here costs one integration, not the protocol.

| | |
|---|---|
| `SettlementLens` | the read-only reader: `hashOrder`, `validateOrder`, `previewFill`, `getOrderRelevantStates`. Holds no funds and no authority. A book that publishes prices calls this. |
| `SettlementLensChecks` | the well-formedness and item-funding half of the lens (`validateOrder`, `previewTakerAllowances`, `previewItemFunding`, `deadShape`). Created by the lens's constructor and reached by a plain `STATICCALL`; the lens forwards those three functions with unchanged signatures, so callers never address it. Split out for EIP-170 (audit 2026-09-30) — not a proxy: no `DELEGATECALL`, no state, callable directly. |
| `Erc7683` + `OriginSettler7683` + `DestinationSettler7683` | the ERC-7683 cross-chain adapter pair. `DestinationSettler7683` is the one paid consumer of the lens on-chain (a `previewFill` staticcall). |
| `NativeSettler` + `NativeForwarderFactory` | native-ETH handling. Settlement itself is **native-agnostic** — no `payable`, no `msg.value`, no WETH anywhere in `core/src/settlement` — so these are adapters exactly like the 7683 pair, not a privileged part of the core. |

## The ERC-7683 pair

- **Quotes are priced for the destination settler.** It is the settlement-level filler
  of the only instruction the origin publishes, so an exclusivity window naming anyone
  else makes every 7683 fill an outsider's: a soft window is quoted *with* its premium,
  and a hard one (or a pre-funded leg under a live override) is refused, never
  broadcast. `minReceived[i].recipient` is `0` — whoever fills.
- **`maxSpent` / `minReceived` are enforced.** The instruction's `originData` is
  `abi.encode(FillPayload{payload, bounds})`; `DestinationSettler7683.fill` reverts
  `BoundExceeded` unless every leg settled at the quoted per-unit price or better,
  checked on the amounts the settlement itself returns. A solver can pass its own
  bounds and a `minBumpBps` floor in `fillerData` (`FillerData`) — a priority bidder,
  which moves the price with its own tip, has to.
- **Not carried:** delta-verify orders, and orders with a `SETTLE` item (it would pay the
  adapter, in a token nobody sweeps). Filler-aware gates (whitelists, attestations,
  filler-bound quotes) see the adapter, not the solver.
- **`openFor` authorises only the inner order.** The envelope is bound to this settler,
  chain, maker and the order's nonce; deadlines and the payload's `fillAmount` /
  `takerData` are the opener's, and harmless because the bounds are a price.

## Deployment

`SettlementLens` is a CREATE2 singleton in core's `Deploy.s.sol` (permit3 → settlement
→ lens), so its **address is a hash of its init code** — which includes
`SettlementLensChecks`'s creation code (the lens deploys it), so the pair moves together.

> ⚠ `[profile.periphery-deploy]` in `foundry.toml` pins `via_ir`, `bytecode_hash`,
> `cbor_metadata`, `evm_version` and `optimizer_runs` byte-identical to
> `[profile.core-deploy]`. Changing one without the other starts a new address family
> for the lens alone, silently.

`make size-check` gates the deployable contracts from this profile. The lens was the
tightest of them — 268 bytes under EIP-170 before the 2026-09-30 split. The checks
contract is created by the lens constructor, so a CREATE of an over-limit
`SettlementLensChecks` would revert the lens deployment: it is bound by EIP-170 too and
belongs in the gate.

```
make test-periphery
```

See [docs/deterministic-deployment.md](../../docs/deterministic-deployment.md).
