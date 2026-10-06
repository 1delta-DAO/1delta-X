# 10. Docs: label the three different gas figures for an aggregator fill

- **Status:** done (2026-10-06)
- **Package:** `packages/beta-filler`, `packages/solvers` (READMEs), `RouteSandbox.sol` note
- **Severity:** docs only
- **Source:** [REVIEW-2026-10-05-amount-mismatch.md](../../REVIEW-2026-10-05-amount-mismatch.md), §7
- **Opened:** 2026-10-06

## Problem

Three numbers for "a fill through AggregatorFillSolver" appear across the tree. They
are different measurements, not drift — but nothing says so:

| where | figure | what it is |
| --- | --- | --- |
| `packages/beta-filler/README.md` (table, `ROUTE_GAS_ESTIMATE` row) | 267k direct / 290k pull | "fork-measured"; provenance unstated |
| `packages/solvers/README.md` | 247.9k / 242.6k direct, 305.9k / 277.6k pull | execution / net-of-refund, `RawSwapComparison.t.sol` fork suite |
| `RouteSandbox.sol` dust-floor note | 242,605 / 277,601 | net transaction gas, fresh tx, 2026-10-04 fork |

`packages/solvers/README.md` also still quotes 173.3k / 139.8k for the unit benchmark;
`AggregatorFillGas.t.sol` prints 196.3k / 172.9k today (sandbox, multi-token and the
2026-10-05 anchor fix).

## Change

- Next to each figure name the measurement (profile, fork block, execution vs net of
  refund, with/without the 21k intrinsic, floor seeded or not) and the test that
  produces it (`test_fresh_*`, `test_sandbox_gas_*`, `test_gas_*`).
- Say that `ROUTE_GAS_ESTIMATE = 320000` is the floor of the re-price loop
  (`max(320k, simulated × 1.25)`): above net pull gas, below pull execution + 21k.
- Refresh the unit-benchmark figures or label them as historical.

## Acceptance

- Every gas figure in the three places carries its measurement label and test name;
  `make docs-check` passes.

## Resolution (2026-10-06)

All figures re-measured on 2026-10-06 (`FOUNDRY_PROFILE=solvers`: legacy codegen, runs
20,000, Prague; fork suites on Rootstock via public-node.rsk.co at the suite's pinned
block 8,920,000). Where a figure could not be re-run (it needs a since-removed contract
or a patched constant), it is now labelled with its date, harness and "not re-run".

- `packages/beta-filler/README.md`: the gas row now reads ≈ 154.4k (inventory, GROSS:
  execution 126,257 + calldata 7,096 + 21k, `FreshTxComparisonTest.test_fresh_inventoryFill`)
  and ≈ 247.9k direct / ≈ 282.9k pull (NET of refund, solver floor seeded,
  `SandboxGasBench.test_sandbox_gas_*`), with a "What the gas row measures" table. The
  unexplained 267k / 290k is gone. `ROUTE_GAS_ESTIMATE` row explains the re-price loop
  `G = max(ROUTE_GAS_ESTIMATE, ⌈simulated × 1.25⌉)` (`routeFiller.ts`, `GAS_LIMIT_PCT`):
  320k is above net pull (282.9k) and below gross pull (343.5k; execution + 21k =
  331.5k), and on today's shapes the measured term wins (≈ 357k direct, ≈ 429k pull).
  The +11.5k / +18k sandbox cost, the typed ~+5.9k and the direct-vs-pull saving
  (now −35.0k net / −57.9k execution, was "−27k") carry labels; the ~554k Sushi figure is
  marked as an operator observation.
- `packages/solvers/README.md`: unit benchmark table refreshed from
  `AggregatorFillGas.t.sol` (cold 252,378; dust 208,578; dust/no surplus 198,955;
  retain/gated seeded 197,321; retain 2nd 159,236; direct 173,864; typed direct 179,773;
  plain fill 91,058 — execution gas, in-test floor = dirty slot); 168.2k/173.3k,
  135.5k/139.8k, 167.1k/142.7k, −9.0k and ~3k pull-retain marked historical; solver
  floor re-measured −17,100 execution (was −17,153); the three-design sandbox table
  labelled as the 2026-10-04 pre-06/08 harness plus today's `SandboxGasBench` figures
  (direct 252,567 / 247,907, pull 310,502 / 282,890); size 15,176 / 19,562
  (`make size-check-solvers`); race-guard table re-run: 23,409 / 3,743 / 19,666 (−84%),
  was 34,679 / 3,641 / 31,038.
- `RouteSandbox.sol` `FLOOR` note: provenance (test, profile, block, date, net
  definition, solver floor seeded, constant patched) + today's FLOOR = 0 figures.
- Not touched: `docs/filler-strategy.md` still quotes the old race-guard 34,679 / 3,641.
- `make docs-check` passes.
