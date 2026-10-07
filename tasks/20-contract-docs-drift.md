# 20. Contract docs drift (solver header, Exactly repay behaviour)

- **Status:** open
- **Layer:** contract (docs)
- **Package:** `packages/solvers`, `packages/modules/lending/exactly`
- **Severity:** info
- **Source:** 2026-10-06 pre-merge audit of the working set (four review agents: contracts, modules+tooling, filler, book/app/sdk)
- **Opened:** 2026-10-06

## Problem

- The solver header ([AggregatorFillSolver.sol:4-10](../packages/solvers/src/aggregator/AggregatorFillSolver.sol#L4))
  says every fill uses `PostInputsTypedDirect` + `onSettlementFill`. Untyped
  `PostInputsDirect` + `onFill` is the default; the typed pair is used only when the
  plan needs it (same-token output leg or `amountOutOffset` set).
- `ExactlyRepayModule`: a fixed repay against an already-closed position now SKIPS
  (was a division-by-zero revert). A "close my position" order whose other items
  withdraw collateral now fills when someone else already repaid. Value-preserving and
  matches the pre-fund twin, but undocumented.

## Change

Fix the header; add the skip semantics to the Exactly README and module NatSpec.

## Acceptance

- `make docs-check` passes.
