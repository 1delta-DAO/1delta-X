---
title: Reference
slug: reference
eyebrow: Reference
description: Glossary, repository map, build and test commands, the honest list of limits and known gaps, and where in the source tree each design note lives.
---

## Glossary

The same words mean different things in different settlers; these are the
meanings used here.

| Term | Meaning in 1delta x |
|---|---|
| **Order** | One EIP-712 struct carrying legs, items, conditions, the price curve and the fill unit. The unit of authorization. |
| **Maker** | The account the order is scoped to — funding source, position owner and signer (or nominator of the signer). |
| **Filler / solver** | Whoever executes the order. Untrusted, permissionless, pays gas, keeps the surplus. |
| **Leg** | One `(token, start, end)` entry on the input or output side. Output legs also carry a recipient. |
| **Item** | A maker-signed module call: `MAKE` (deposit/repay), `TAKE` (borrow/withdraw), `SETTLE` (solver↔maker exchange). |
| **Bump** | The normalized `[0, 10000]` position between a leg's `start` and `end`, produced by whichever pricing mode is active. |
| **Anchor / denominator** | The amount a fill fraction is measured against — leg 0 of the fixed side, or a maker-signed `fillTotal`. |
| **Token book / taker book** | Permit3's two allowance books: ERC20 transfers, and pulling value out of a position. |
| **`ref`** | `keccak256(item.data)` — the taker allowance key component that pins every protocol parameter a module will decode. |
| **Validator / invariant** | A read-only `staticcall` gate before items / after everything. |
| **Fill module** | A view module choosing the fill delta when the unit is not a fungible amount. |
| **Price module** | A view module returning a bump, which the core clamps and maps through the signed bounds. |
| **`matchSettle`** | The netted N-order entry point that clears against the settlement pool. |
| **Strict mode** | A per-payer flag making Permit3 revocation binding by refusing the direct-ERC20 fallback. |

## Repository map

```
packages/
├── core/                       Settlement, Permit3, and everything they need
│   └── src/
│       ├── settlement/         entry points, order struct, packed arrays, pricing
│       ├── permit3/            allowance hub — token book, taker book, signature transfers
│       ├── modules/            core modules (price modules, OCO groups, NFT settle, …)
│       ├── validators/         pre-execution triggers (staticcall only)
│       ├── periphery/          SettlementLens, NativeSettler, forwarders, ERC-7683 adapters
│       ├── dust/               dust handling for module legs
│       ├── interfaces/         module and settlement interfaces
│       └── utils/              shared helpers and guards
├── modules/                    protocol adapters — one package per venue
│   ├── lending/                aave-v2/v3/v4, compound-v2/v3, morpho-blue, morpho-midnight,
│   │                           euler-v2, silo, fluid, dolomite, exactly, gearbox-v3, lista,
│   │                           liquity-v2, river, teller, venus
│   ├── bridge/                 cross-chain orders — funnels, bridged inbox, bridge-out modules
│   ├── redeem/usdrif/          USDRIF → USDT0 exit path
│   ├── erc4626/                vault deposit / withdraw / claim
│   └── transfer/               plain token movement
├── solvers/                    reference permissionless fillers
├── sdk/                        TypeScript SDK — order packing, EIP-712 signing, calldata
├── orderbook/                  transport-agnostic order distribution
├── orderbook-server/           demo backend (Fastify REST + WS)
├── docs-site/                  this documentation site
└── app/                        reference trading interface (React + Vite)
```

## Building and testing

A Foundry monorepo. Each package compiles in isolation under its own profile,
which keeps peak memory well below a full-tree build.

```bash
make build-all              # compile-check every package
make test-all               # run every package's tests, sequentially

make test PKG=core          # one package
make gas-check              # fail if any core test's gas moved from the baseline
make size-check             # fail if Settlement / lens exceed the deploy size limits
make help                   # all targets, and the package list
```

TypeScript packages build and test with pnpm:

```bash
pnpm install
pnpm -r build
pnpm -r test
```

Some packages carry mainnet-fork suites that need an archive RPC. Deploy scripts
must use the via-IR deploy profile — see [Optimization](/optimization/#the-eip-170-wall).

## Lens functions added 2026-09-30

- `SettlementLens.pinnedBump(order, filler, takerData)` — the bump a fill will pin,
  captured in the same transaction BEFORE the fill; pair it with
  `previewFillInFlightPinned(order, prevFilled, anchor, filler, pin)` from inside a
  callback (`previewFillInFlight` is exact only for clock-priced orders).
- `SettlementLens.CHECKS()` — the `SettlementLensChecks` contract the lens creates in
  its constructor (the lens was split to fit EIP-170).
- `SettlementLens.bumpFloorAdvised(order)` — whether a filler should pass a
  `minBumpBps` floor for this order, and which price mover makes it necessary.
- New `validateOrder` reasons: a stranded `minFillAnchor` tail, and invariant-only
  consideration without a lifelong named filler.

## Limits and known gaps

Stated plainly, so nothing reads as more finished than it is.

- **Nothing is deployed**, and there has been **no external audit**.
- **Fee-on-transfer / rebasing tokens** — supported only for simple single-order swaps; the netted path reverts on them by design. Reported fill figures are nominal, hence pre-fee.
- **Gearbox credit accounts** — shipped best-effort and unvalidated (bot permission bitmask, account resolution, multicall fund flow). The ERC-4626 pool side is solid.
- **Teller** — borrow and withdraw are not wireable (sender attribution makes the module the borrower; withdrawals have a per-owner cooldown).
- **Lista flex borrow** — the flex broker's borrow is `msg.sender`-only, so only the fixed-term broker borrow is delegable.
- **Term Finance** — structurally incompatible (sealed-bid asynchronous clearing, no delegation surface).
- **Fork coverage** — several newer packages (silo, exactly, lista, river, liquity-v2, gearbox-v3, teller) compile and pass their security gates, but their full fork suites await an RPC endpoint. Each package README flags its own unvalidated assumption.
- **Trigger validators check freshness, not plausibility** — a fresh but wrong feed passes a Chainlink *validator*. The pegged price *module* does carry an absolute band.
- **Multi-token sweeps are a module, not a leg** — see [what the byte budget refused](/optimization/#what-the-byte-budget-refused).
- **Revoking a delegated signer does not bind mid-order** — signatures are re-checked only on an order's first fill.
- **EIP-170 headroom is small**, and it was bought with compiler settings. Weigh any further *core* feature against that; anything reachable from the pricing path is inlined ~8× and pays 8× for every byte. Modules and periphery cost nothing here.
- **The committed gas baseline does not measure the deployed contract** — different codegen and optimizer settings.
- **Wallet-legible order rendering** (ERC-7730 descriptor + lens-side decoder) is not built.
- **Breaking encoder changes have shipped before**, two of which fail *silently* if missed. Read the breaking-change section of `SECURITY.md` before touching an encoder.

## Where the deeper notes live

This site is the overview. The repository carries the authoritative detail:

| In the repo | Covers |
|---|---|
| `FEATURES.md` | Complete inventory of what the protocol does today |
| `SECURITY.md` | Trust model, invariants, integrator caveats, full audit history with findings and fixes |
| `packages/core/src/settlement/README.md` | API reference for the fill flow, item ops, denominator, fees |
| `packages/core/src/permit3/README.md` | The allowance hub, and what it keeps from and changes versus Permit2 |
| `docs/pricing-modes.md` | Every pricing mode, the clamp argument, measured per-mode gas |
| `docs/deferred-match-settle.md` | The netted path: step schedule, credit ledger, exactly-once guards |
| `docs/filler-strategy.md` | The recommended filler shape, and the revert-reason taxonomy |
| `docs/reference-audits/` | The C1–C15 failure-class taxonomy, the F1–F29 findings ledger, and the verdict for each here |
| `docs/reference-bounties.md` | The bug-bounty and incident corpus, classes B1–B14 |
| `docs/edge-case-matrix.md` | Ten axes crossed, a verdict per cell, bound to the test that pins it |
| `docs/module-security-model.md` | What each module may assume, and which automated check enforces it |
| `docs/delegated-signers.md` | Session keys, the registry's keying, gasless nomination, the revocation caveat |
| `docs/proportional-legs.md` | Balance-relative orders and why the cap is mandatory |
| `docs/deterministic-deployment.md` | Identical addresses across chains; the EVM-version survey |
| `docs/waku-orderbook.md` | Decentralized order transport and its spam defence |

## Contact

Security reports: **security@1delta.io** — privately, please, and a failing
Foundry test is the ideal report. Do not open public issues for security
findings.
