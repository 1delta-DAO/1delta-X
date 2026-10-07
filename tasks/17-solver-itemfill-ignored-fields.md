# 17. Solver: `executeItemFill` silently ignores `minBumpBps` and `amountOutOffset`

- **Status:** open
- **Layer:** contract
- **Package:** `packages/solvers` (`AggregatorFillSolver.sol`)
- **Severity:** low — an operator's floor silently does nothing; needs a solver redeploy
- **Source:** 2026-10-06 pre-merge audit of the working set (four review agents: contracts, modules+tooling, filler, book/app/sdk)
- **Opened:** 2026-10-06

## Problem

`executeItemFill` ([AggregatorFillSolver.sol:724](../packages/solvers/src/aggregator/AggregatorFillSolver.sol#L724))
builds a one-order `matchSettle` plan. `matchSettle` has no `minBump`, and the netted
path never patches `amountOut`, so both new `RoutePlan` fields are dropped (documented
in the NatSpec near L285). An operator who sets a floor and sends an item-bearing order
down this path gets no protection against a maker-ward tick move.

## Change

Revert (a named error) when `plan.minBumpBps != 0` or
`plan.amountOutOffset != NO_PATCH` on `executeItemFill`.

## Acceptance

- Two tests: each non-default field reverts `executeItemFill`; defaults still fill.
- SDK `encodeAggregatorExecuteItemFill` (if any) and beta-filler never set them on
  that path (they do not today).
