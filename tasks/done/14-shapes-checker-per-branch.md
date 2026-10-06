# 14. Shapes checker: rule 9 per branch, and two rules it cannot express

- **Status:** done (2026-10-06)
- **Package:** `tools/check-module-shapes.py`
- **Severity:** low — the gap let the Venus borrow cap-only branch through
- **Source:** [REVIEW-2026-10-05-amount-mismatch.md](../../REVIEW-2026-10-05-amount-mismatch.md), §8 M2/M3
- **Opened:** 2026-10-06

## Problem

Rule 9 ("a `Full`/clamping-Exact leg carries `requireDelivered`") searches the whole
reachable body of `takeOnBehalf`, so one bounded branch satisfies it for every
branch: `VenusTakerModule.Op.Borrow` was cap-only while both withdraw branches were
bounded (fixed in the review). Two further properties the reviews needed have no
rule: "`amount`'s unit equals the delivery's unit" (Lista SmartTaker, task 11) and "a
venue that under-delivers by design carries a non-zero maker floor" (Exactly, task 12).

## Change

- Rule 9 per `op` branch: split the comment-stripped body on the `if (op ==` ladder
  and require the bound (or a venue-exactness allow-list entry with a reason) in
  each branch that measures a delta.
- A rule 17: a taker module whose `amount` is not in the proceeds token's unit must
  implement `IProceedsAsset` AND name the conversion in its header (syntactic:
  presence of both), so the lens can see it.
- Add the two new allow-list reasons where a branch is exact-or-revert by venue
  (Aave v4 borrow, Lista broker borrow) rather than relying on the whole-function
  search.

## Acceptance

- `tools/test-module-shapes.py` gains a fixture where one branch is bounded and
  another is not, and the rule fires; `make modules-check` passes on the tree.

## Resolution (2026-10-06)

`tools/check-module-shapes.py` (now 17 rules) and `tools/test-module-shapes.py`;
`make modules-check` passes on the tree. No module source changed.

- **Rule 9 per `op` branch.** `op_ladder` splits the comment-stripped body on the
  `if (op == …) {} else if (op == …) {} else {}` ladder (in `takeOnBehalf` or the
  first helper it reaches that holds one); `take_branches` blanks the sibling blocks
  and recomputes the call closure, so a helper only a sibling calls cannot lend its
  bound. A branch is held to the bound when it forwards a measured delta (a
  `balanceOf(address(this))` token transferred to `receiver`, or any
  `min(received, amount)` forward); the bound is `requireDelivered`, `WouldBorrow`,
  or the hand-rolled `if (… < amount) revert` (`RiverProceeds.settle`, Fluid native).
  Removing the Venus Borrow `requireDelivered` (the M2 pre-fix shape) now fails the
  check. Coverage limit, documented in the script: a `BalanceMode` Full/Exact fork
  *inside* one op branch is still searched whole (that pairing is what
  `CLAMPING_VENUE_MODULES` covers).
- **`VENUE_EXACT_BRANCHES`** — four rows, each checked against the module source and
  the venue's borrow path; all assume policy A1 (no FoT/rebasing borrow reserve):
  - `AaveV2BorrowModule` — `LendingPool.borrow` validates then
    `transferUnderlyingTo(msg.sender, amount)`; the module's own comment already
    states exact-or-revert.
  - `AaveV3CreditModule` `Borrow` and `Leverage` — both reach the one `_borrowLeg`
    (`Pool.borrow`, caps/liquidity/health revert, exact transfer).
  - `AaveV4BorrowModule` — `borrowOnBehalfOf` → `Spoke.borrow` → `Hub.draw`, exact or
    revert; unlike `Spoke.withdraw` (a clamping-venue row) a borrow never clamps.
  - Lista broker borrow needs **no** row: `ListaBrokerModule.takeOnBehalf` has the
    broker pay `receiver` directly (no measured delta for the module to cap) and
    post-checks the booked `principal == amount`, so the rule does not reach it. A
    row for it would be dead.
  - Every other newly-split branch is either bounded or not delta-measured; no real
    unbounded branch was found.
- **Rule 17.** `UNIT_CONVERTING_TAKERS` names each taker whose `amount` unit differs
  from the proceeds unit (`ListaSmartTakerModule`: LP → coin). A row must implement
  `IProceedsAsset` (in the inheritance list + a `proceedsAsset` function) and its
  header must name both units. Heuristic detection for unregistered modules: a venue
  call in the take seam handed a rate-scaled `amount` (`amount * minOutRate / 1e18`)
  fails until a row is added. Task 11 landed `IProceedsAsset` on the module, so it
  passes.
- **Not done:** the third rule from the title ("a venue that under-delivers by design
  carries a non-zero maker floor", Exactly) — not in this task's Change list; it is
  task 12's subject.
- Fixtures: per-branch fire (bounded Withdraw sibling + unbounded Borrow), all-bounded
  pass, hand-rolled bound pass, allow-listed `AaveV4BorrowModule` pass vs. the same
  body unlisted fire; rule 17: missing `IProceedsAsset` fires, compliant passes,
  header missing a unit fires, unregistered rate-scaled taker fires. The two
  L-CENSUS-7b fixtures gained a `requireDelivered` line (they forward a measured
  delta, which the per-branch rule now holds to the bound).
