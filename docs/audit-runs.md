# Parallel-lens audit runs — coverage register

What the twelve-lens (`solidity-auditor`) runs have actually READ, and what they
have not. Kept because the runs' own bundle directories are transient build state
and get deleted: their inputs are copies of source already in git, their outputs
live in the F-ledger, but the SCOPE is recorded nowhere else — and scope is the
thing that turns out to matter.

Findings live in [reference-audits.md](./reference-audits.md) (F-ledger) and the
per-round write-ups. This file answers a different question: *has this file ever
been read by a lens run at all?*

---

## Runs

### F26 — 2026-09-02 · bundle `.audit-HFziTN` · 15 files

The 14 previously-unaudited lending packages. Produced one Critical
(`LiquityV2TroveAuth` forged auth root), two novel classes, and further instances
of four classes a mechanical sweep had just certified clean. Write-up:
[audit-2026-09-modules-plan.md](./audit-2026-09-modules-plan.md).

- `packages/modules/lending/aave-v2/src/AaveV2Modules.sol`
- `packages/modules/lending/compound-v2/src/CompoundV2Modules.sol`
- `packages/modules/lending/compound-v2/src/CompoundV2NativeModules.sol`
- `packages/modules/lending/compound-v3/src/CompoundV3Modules.sol`
- `packages/modules/lending/dolomite/src/DolomiteModules.sol`
- `packages/modules/lending/euler-v2/src/EulerV2Modules.sol`
- `packages/modules/lending/exactly/src/ExactlyModules.sol`
- `packages/modules/lending/fluid/src/FluidModules.sol`
- `packages/modules/lending/gearbox-v3/src/GearboxV3Modules.sol`
- `packages/modules/lending/liquity-v2/src/LiquityV2Modules.sol`
- `packages/modules/lending/lista/src/ListaModules.sol`
- `packages/modules/lending/river/src/RiverModules.sol`
- `packages/modules/lending/silo/src/SiloModules.sol`
- `packages/modules/lending/teller/src/TellerModules.sol`
- `packages/modules/lending/venus/src/VenusModules.sol`

### F27 — 2026-09-03 · bundle `.audit-rGnSkx` · 16 files

The pre-fund-module family plus `Base.sol`. Four Criticals, three with executed PoCs.
Write-up: [audit-2026-09-push-family.md](./audit-2026-09-push-family.md).

- `packages/core/src/settlement/Base.sol`
- `packages/modules/lending/aave-v2/src/AaveV2PreFundModules.sol`
- `packages/modules/lending/aave-v3/src/AaveV3PreFundModules.sol`
- `packages/modules/lending/aave-v4/src/AaveV4PreFundModules.sol`
- `packages/modules/lending/compound-v2/src/CompoundV2PreFundModules.sol`
- `packages/modules/lending/compound-v3/src/CompoundV3PreFundModules.sol`
- `packages/modules/lending/exactly/src/ExactlyPreFundModules.sol`
- `packages/modules/lending/gearbox-v3/src/GearboxV3PreFundModules.sol`
- `packages/modules/lending/liquity-v2/src/LiquityV2PreFundModules.sol`
- `packages/modules/lending/lista/src/ListaPreFundModules.sol`
- `packages/modules/lending/morpho-blue/src/MorphoBluePreFundModules.sol`
- `packages/modules/lending/morpho-midnight/src/MidnightPreFundModules.sol`
- `packages/modules/lending/river/src/RiverPreFundModules.sol`
- `packages/modules/lending/silo/src/SiloPreFundModules.sol`
- `packages/modules/lending/teller/src/TellerPreFundModules.sol`
- `packages/modules/lending/venus/src/VenusPreFundModules.sol`

---

### F28 — 2026-09-12 · bundle `.audit-RdeHOS` · 120 files

The whole tree: every `packages/*/src/**/*.sol` except `interfaces/`, `vendor/`,
`script/` and `periphery/src/SettlementLens.sol` (view-only, 1,539 lines — readable
by the lenses as out-of-scope context, not bundled). 27,803 source lines; the first
run to read `packages/core/src` beyond `Base.sol`, `packages/solvers`,
`packages/validators`, `packages/periphery` (minus the lens) and the non-lending
modules. Write-up: [audit-2026-09-12-full-tree.md](./audit-2026-09-12-full-tree.md).

- `packages/core/src/**` — permit3 (11), settlement (16), utils (2)
- `packages/modules/lending/*/src/*.sol` — all 17 venues, 41 files, every
  `*PreFundModules.sol` including the four contracts F27 never read
- `packages/modules/{bridge,erc4626,fill,maker,nft,oco,pricing,redeem,transfer}/src/**`
- `packages/periphery/src/*.sol` except `SettlementLens.sol`
- `packages/solvers/src/**` (16), `packages/validators/src/*.sol` (8)

With this run the "not covered by any run" list below is reduced to
`SettlementLens.sol` and the `interfaces/` / `vendor/` / `script/` trees.

### F29 — 2026-09-14 · bundle `.screen-1jmsP6` · 121 Solidity files + periphery

Six lenses, each assigned two or three of `reference-bounties.md`'s B-classes as
variant hunts. Same Solidity scope as F28 **plus the periphery, read for the first
time**: `packages/periphery/src/SettlementLens.sol` (read from disk by the
periphery lens), `packages/sdk/src/*.ts`, `packages/orderbook/src/*.ts`,
`packages/orderbook-server/src/*.ts` (bundled for three lenses). Write-up:
[audit-2026-09-14-bounty-screening.md](./audit-2026-09-14-bounty-screening.md).

## The coverage gap this register exists to make visible

19 files now contain pre-fund contracts. 18 were in the F27 bundle. **`AaveV3FusedModules.sol`
was in neither run** — and the other three fused files
(`DolomiteModules.sol`, `EulerV2Modules.sol`, `FluidModules.sol`) were in the F26
bundle, but their pre-fund contracts were **not in that snapshot**:

| contract | in F26 snapshot | in F27 snapshot |
| --- | --- | --- |
| `AaveV3PreFundLeverageModule` | no | no |
| `DolomitePreFundTakeForModule` | no | no |
| `EulerV2PreFundTakeForModule` | no | no |
| `FluidPreFundTakeForModule` | no | no |

**Four pre-fund contracts have never been read by any lens.** They were written after
the last bundle was built, and they live in files whose *other* `TakeFor` module is
pull-shaped — so neither a file-level scope list nor a `*PreFund*.sol` glob reaches
them. All four were missing the balance floor and the descriptor-bit requirement
when the post-fix census ran; that census, not the audit, is what caught them.

This is the same defect as F27/H-3 (the `ProratedBound` fix that never reached the
pre-fund family) in a different costume: **a scope fixed at bundle-build time cannot
cover code written afterwards.** The audit is a snapshot; the codebase is not.

## Rule

Before trusting "this has been audited", check this register — and re-derive the
push/pull census (`docs/audit-2026-09-push-family.md`, Post-fix assessment) rather
than a filename glob. Contract shape is a property of the contract, not of the
file it happens to share.

## Not covered by any run

As of F29 (2026-09-14): the `interfaces/`, `vendor/` and `script/` trees only —
`SettlementLens.sol` and the TypeScript periphery were read by F29 (and produced
eight of its fourteen findings/defects). Before F28, 103 of 134 source
files had never been through a twelve-lens run — all of `packages/core/src` except
`settlement/Base.sol`, `packages/solvers`, `packages/periphery` and
`packages/validators` (core and Permit3 had their own dedicated rounds: F24, F25 and
the Permit3 rounds in the ledger). Code written after 2026-09-12 is, again, unread
until the next run.
