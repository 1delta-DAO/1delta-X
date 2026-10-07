# 16. Solver: the live `amountOutOffset` patch writes `pricedOut[0]`, not the anchor output leg

- **Status:** open
- **Layer:** contract
- **Package:** `packages/solvers` (`AggregatorFillSolver.sol`)
- **Severity:** low — revert only, no funds; needs a solver redeploy
- **Source:** 2026-10-06 pre-merge audit of the working set (four review agents: contracts, modules+tooling, filler, book/app/sdk)
- **Opened:** 2026-10-06

## Problem

`onSettlementFill` passes `pricedOut[0]` (the price of `legsOut[0]`) as the value to
write into the route's `amountOut` word
([AggregatorFillSolver.sol:1088](../packages/solvers/src/aggregator/AggregatorFillSolver.sol#L1088)).
Since the 2026-10-05 anchor fix the solver's floor/cap apply to `outAnchor` — the first
output token no input leg pays — which is not `legsOut[0]` when a fee leg is listed
first. With `legsOut = [tokenIn fee → originator, tokenOut → maker]` the exact-output
word receives the fee amount; the fill reverts (delta check or the core's pull). Same
for a tokenOut fee leg listed first on the pull path.

## Change

Write `pricedOut[j]` for the anchor leg `j` (the leg `_plan` resolves `outAnchor`
from), not index 0. Keep `NO_PATCH` behaviour unchanged.

## Acceptance

- A direct order with `legsOut = [fee in tokenIn, tokenOut → maker]` and
  `amountOutOffset` set fills and the maker receives `outputAt(t_incl)`.
- `AggregatorFillGas.t.sol` within noise; `make size-check-solvers` passes.
