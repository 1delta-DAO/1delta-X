# 11. Lista SmartTaker: tie the LP-unit item to the coin-unit leg

- **Status:** done (2026-10-06)
- **Package:** `packages/modules/lending/lista`, `packages/periphery` (lens)
- **Severity:** low — maker-config exposure (wallet draw on under-delivery), lens blind spot
- **Source:** [REVIEW-2026-10-05-amount-mismatch.md](../../REVIEW-2026-10-05-amount-mismatch.md), §8 M3
- **Opened:** 2026-10-06

## Problem

`ListaSmartTakerModule.takeOnBehalf` burns `amount` LP units and pays ONE pool coin
to the receiver, floored at `amount · minOutRateE18 / 1e18`
([ListaSmartModules.sol](../../packages/modules/lending/lista/src/ListaSmartModules.sol)).
The core prices `legsIn[0]` in COIN and measures the coin that lands. Nothing
on-chain relates the two: a floor below the leg's `owed` has the shortfall pulled
from the maker's wallet; the module declares no `IProceedsAsset` (the coin is
`dex.coins(coinIndex)`, not in `data`), so the lens's stranded-proceeds preflight is
skipped for it. Documented in the header for now.

## Change

- Lens rule in `SettlementLensChecks.validateOrder`: for an item whose module is a
  `ListaSmartTakerModule`, require `minOutRateE18 · item.amount / 1e18 >=
  legsIn[0].start` (and `legsIn[0].token == dex.coins(coinIndex)` once the dex is
  readable — add a `dex()` view to `IListaSmartProvider` if the provider exposes one).
- Implement `IProceedsAsset.proceedsAsset(data)` on the module once the coin can be
  resolved from `data` (encode the coin address, or read it through the provider).

## Acceptance

- A lens test: an order signed with the rate floor below the leg is reported
  malformed; one at/above passes.
- `proceedsAsset` returns the coin for a well-formed blob; the existing
  `SmartLp.t.sol` cases still pass.

## Resolution (2026-10-06)

No blob change (non-breaking): the coin is read THROUGH the provider.

- `IListaSmartProvider.dex()` added (verified live on BSC: provider 0xC3be…24dE →
  dex 0x3DcE…6131, `coins(0)` = slisBNB, `coins(1)` = the 0xEeee… native sentinel,
  also at the fork pin 113,020,000) plus a minimal `IListaStableSwap.coins(i)`.
- `ListaSmartTakerModule` now implements `IProceedsAsset.proceedsAsset(data)` =
  `dex().coins(coinIndex)`, so the lens's stranded-proceeds preflight runs for it.
- Recognition is by interface, not address: new `packages/lib/src/interfaces/ITakeFloor.sol`
  (`takeFloored(amount, legToken, legStart, data) → bool`), an optional module
  self-check. The module judges its own rule because only it can read its layout and
  the rule differs per venue (Lista: floor ≥ leg; Exactly, task 12: floor ≠ 0). Lista
  reports `amount · minOutRateE18 / 1e18 ≥ legsIn[0].start ∧ legsIn[0].token == coin`
  (an overflowing rate reports `false`).
- `SettlementLensChecks._proceedsItemAt` calls it (best-effort staticcall, silence /
  revert / short return = skipped, explicit zero word = flagged) for TAKE/TAKE_FOR items
  routed to the settler, against `legsIn[0]` (skipped for no input leg or a
  `Proportional` leg 0). Reason: `"item proceeds floor does not bound the wallet draw on
  its input leg"`.
- Tests: `packages/periphery/test/Review20261006Lens.t.sol` (Lista cases: below / one
  wei short / zero / at / above / coin mismatch both ways / overflowing rate /
  recipient-maker not checked / `proceedsAsset`), real module against mock
  provider+dex; `SmartLp.t.sol` +3 BSC fork tests (`proceedsAsset` on the live roster,
  `takeFloored` bounds, a floored leg covered by a real burn). All 10 existing
  `SmartLp.t.sol` cases still pass (13/13; `modules-lista` 75/75, fork ran via
  blastapi).
- Lens size (`periphery-deploy`, clean out dir): `SettlementLensChecks` 16,128 →
  17,221 runtime (tasks 11–13 together), `SettlementLens` 16,970 runtime / 35,095
  initcode — far under both limits; no split needed.
