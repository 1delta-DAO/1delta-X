# 19. Shapes checker: rule 9 can be satisfied by accident

- **Status:** open
- **Layer:** contract (tooling)
- **Package:** `tools/check-module-shapes.py`, `tools/test-module-shapes.py`
- **Severity:** low — a regression guard with holes, no live bug
- **Source:** 2026-10-06 pre-merge audit of the working set (four review agents: contracts, modules+tooling, filler, book/app/sdk)
- **Opened:** 2026-10-06

## Problem

Mutation probes against the Venus module showed three ways rule 9 (per-branch
`requireDelivered`) passes a branch it should flag:
1. `TAKE_BRANCH_BOUND` accepts any `if (x < amount) revert` — a pre-call liquidity
   check counts as the delivery bound.
2. `OP_LADDER_HEAD` only matches `op ==` / `_op ==`; an `Op(op) == Op.Borrow` ladder is
   not split, so a bounded sibling covers it again (the original M2 shape). Code after
   an early-return ladder is also counted in every branch.
3. `forwards_measured_delta` misses `transfer(receiver, received > amount ? amount : received)`.

## Change

Anchor the hand-written bound to the measured-delta name (`received`, `delta`, …);
accept `Op(op) ==` and enum-cast ladders; widen forward detection to both ternary
orders and `IERC20(t).transfer`. Add a fixture per hole.

## Acceptance

- Three new failing fixtures in `test-module-shapes.py`, each caught.
- `make modules-check` still passes on the tree.
