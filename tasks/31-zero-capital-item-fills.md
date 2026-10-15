# 31. Zero-capital fills for orders that carry items (matchSettle delivery ledger)

- **Status:** built in the tree (2026-10-14, branch `zero-capital-item-fills`), ships with the next Settlement version. See the plan's §7 for what was built and where it deviates from the plan.
- **Layer:** contracts (core + solver) + filler
- **Package:** `packages/core` (`Batch.sol`), `packages/solvers`, `packages/beta-filler`
- **Severity:** design flaw. Every order with a delivery-consuming item or a SETTLE item needs filler capital
- **Opened:** 2026-10-14
- **Plan:** [docs/fill-ordering-capital-plan.md](../docs/fill-ordering-capital-plan.md)

## Problem

Items run only in the forward ordering (deliver → items → pay inputs), so the
filler must front every output. `PostInputs` refuses items. `matchSettle` can
schedule pull → route → deliver → item, but it refuses pre-funded MAKE, TAKE_FOR
and SETTLE items. Affected:

- native-out;
- all 15 pre-funded lending sinks;
- OCO bracket legs;
- NFT and 1155 sales;
- proportional sweeps;
- a future LP mint, which would need 2 flashes.

Native-out is task 30's workaround for one of these.

## Change

1. `Batch._stepDeliver`: `st.fills[i].outs = amts;`. `_forSlice` then fails closed
   for an item scheduled before its order's delivery.
2. `Batch._assertMatchShape`: admit pre-funded MAKE and TAKE_FOR. Admit SETTLE after
   the per-module review in plan §4.2.
3. Solver v3 (`executeItemFill`): handle SETTLE receipts and multi-output routes, and
   fold in tasks 16, 17 and 30.
4. Filler: a shape classifier that picks `executeFill`, `executeItemFill`, flash, or
   skip.

## Acceptance

See plan §6. Ships with the next Settlement version (the audited rollout), because
the Settlement address changes.
