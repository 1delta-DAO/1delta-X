# 1delta-x

An intent settlement system for lending and trading. A maker signs one EIP-712
`Order` off-chain describing fungible legs it gives and receives, arbitrary
actions on its own lending positions (deposit / borrow / withdraw / repay on any
wired lender), pre- and post-execution conditions, and a price curve. Any
permissionless filler executes it in a single transaction and keeps the surplus.

There is no admin, no module whitelist, and no on-chain orderbook. Authority
comes entirely from the maker's signature plus its Permit3 allowances.

> **Status — read before using.** Nothing in this repository is deployed. The
> protocol has had three **internal** security reviews (2026-06-18, 2026-07-29,
> 2026-08-06) and **no external audit**. Treat it as research-grade code: read
> [SECURITY.md](SECURITY.md) for the trust model, the audit findings, and the
> caveats integrators must know, and [FEATURES.md § Limits and known
> gaps](FEATURES.md#limits-and-known-gaps) for what is partial, blocked, or
> unvalidated.

## Where to read

| | |
|---|---|
| [FEATURES.md](FEATURES.md) | Complete inventory of what the protocol does today — order model, entry points, items, pricing, fees, netting, conditions, coverage, limits. **Start here.** |
| [SECURITY.md](SECURITY.md) | Trust model, security invariants, integrator caveats, all three audits with findings and fixes, disclosure policy. |
| [docs/](docs/README.md) | Topic-level design notes: netted settlement, fill modules, condition trees, fees, proportional legs, deterministic deployment, orderbook transport. |
| [settlement README](packages/core/src/settlement/README.md) | API reference for the fill flow, item ops, denominator, fees. |
| [permit3 README](packages/core/src/permit3/README.md) | The token / taker allowance hub, and what it keeps from and changes versus Uniswap's Permit2. |

## Repository map

```
packages/
├── core/                       Settlement, Permit3, and everything they need
│   └── src/
│       ├── settlement/         Settlement entry points, order struct, packed arrays, pricing
│       ├── permit3/            Allowance hub — token book, taker book, signature transfers
│       ├── modules/            Core modules (OCO groups, permissionless calls, NFT settle, …)
│       ├── validators/         Pre-execution triggers (staticcall only)
│       ├── periphery/          SettlementLens, NativeSettler, forwarders
│       ├── dust/               Dust handling for module legs
│       ├── interfaces/         Module and settlement interfaces
│       └── utils/              Shared helpers and guards
├── modules/                    Protocol adapters — one package per venue
│   ├── lending/                aave-v2/v3/v4, compound-v2/v3, morpho-blue, morpho-midnight,
│   │                           euler-v2, silo, fluid, dolomite, exactly, gearbox-v3, lista,
│   │                           liquity-v2, river, teller, venus
│   ├── bridge/                 Cross-chain orders — funnels, bridged inbox, bridge-out modules
│   ├── redeem/usdrif/          USDRIF → USDT0 exit path
│   ├── erc4626/                Vault deposit / withdraw / claim
│   └── transfer/               Plain token movement
├── solvers/                    Reference permissionless fillers (flash-funded leverage, …)
├── sdk/                        TypeScript SDK — order packing, EIP-712 signing, calldata
├── orderbook/                  Transport-agnostic order distribution (protobuf, verifier, book)
└── orderbook-server/           Demo backend for the orderbook (Fastify REST + WS)
```

## Building and testing

Foundry monorepo. Each package compiles in isolation under its own profile in
[`foundry.toml`](foundry.toml), which keeps peak memory well below a
full-monorepo build. [`Makefile`](Makefile) wraps the profiles:

```bash
make build-all              # compile-check every package
make test-all               # run every package's tests, sequentially

make test PKG=core          # one package
make test-modules-aave-v3   # shorthand for the same

make gas-check              # fail if any core test's gas moved from .gas-snapshot
make size-check             # fail if Settlement / lens exceed the deploy size limits
make help                   # all targets, and the package list
```

Some packages carry mainnet-fork suites that need an archive RPC; see each
package's README for what it forks and what is still unvalidated.

The TypeScript packages build and test with pnpm:

```bash
pnpm install
pnpm -r build
pnpm -r test
```

## License

MIT — see [LICENSE](LICENSE). Third-party code that ships in this repository,
most notably the Permit3 sources derived from Uniswap's Permit2, is attributed
in [NOTICE](NOTICE).
