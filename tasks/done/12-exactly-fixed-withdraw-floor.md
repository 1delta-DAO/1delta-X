# 12. Exactly: a pre-maturity fixed withdraw must carry a non-zero `minAssetsRequired`

- **Status:** done (2026-10-06)
- **Package:** `packages/modules/lending/exactly`, `packages/periphery` (lens)
- **Severity:** low — maker-bounded wallet draw; the floor is maker-signed and may be 0
- **Source:** [REVIEW-2026-10-05-amount-mismatch.md](../../REVIEW-2026-10-05-amount-mismatch.md), §8
- **Opened:** 2026-10-06

## Problem

`withdrawAtMaturity` pays `assetsDiscounted < amount` before maturity, straight to
the receiver; the module deliberately does not bound it (the discount is
legitimate), so the core bills `owed − assetsDiscounted` to the maker's wallet. The
fixed rate that sets the discount is a live utilisation figure a filler can raise in
the same block, and the induced discount accrues to the pool's other fixed
depositors. `minAssetsRequired` (`bound@128`) is the only cap, and every existing
test signs it 0 and warps past maturity, so the pre-maturity path is unpinned.
Header documents the rule now.

## Change

- Lens: flag `op == 1 && maturity > block.timestamp && bound == 0` on
  `ExactlyTakerModule` items as malformed.
- A pre-maturity fork test asserting the maker's wallet delta equals
  `owed − assetsDiscounted` and that a non-zero `minAssetsRequired` caps it.
- Also from the same review: the pull-branch `repayAtMaturity` has no
  `fixedBorrowPositions == 0` skip (its pre-fund twin does) and a dust slice scales
  `maxAssets` to 0 ⇒ venue `Disagreement`; both liveness, both worth the twin's fix.

## Acceptance

- Lens test for the zero-floor flag; fork test for the wallet draw; `modules-exactly`
  green.

## Resolution (2026-10-06)

- Lens: `ExactlyTakerModule` implements `ITakeFloor` (see task 11) and reports `false`
  exactly for `op == Withdraw ∧ maturity > block.timestamp ∧ bound == 0`; every other
  branch (floating, borrow, at/after maturity, any non-zero floor) reports `true` —
  a non-zero floor below the leg is the maker's accepted draw, not flagged, per the
  header. Lens test cases in `packages/periphery/test/Review20261006Lens.t.sol`
  (zero floor flagged; non-zero passes; other branches pass; the same order stops
  being flagged once maturity passes).
- Fork test `packages/modules/lending/exactly/test/audit/PreMaturityWithdraw.t.sol`
  (Optimism, live exaUSDC, real Settlement + lens, RAN): zero floor ⇒ wallet draw ==
  `owed − assetsDiscounted` exactly (discount measured by a rolled-back withdraw) and
  the lens flags it; a floor at the live discounted amount passes the lens and caps the
  draw at `owed − minAssetsRequired`; a same-block 500k `borrowAtMaturity` deepens the
  discount and the floored fill reverts `Disagreement()` with the wallet untouched.
- Twin fixes in the PULL `ExactlyRepayModule` fixed branch: reads
  `fixedBorrowPositions` and SKIPS an empty position (was a division-by-zero revert)
  and a dust slice whose scaled `maxAssets` floors to 0 (was `Disagreement`). A SIGNED
  `maxAssets == 0` now reverts `ZeroMaxAssets` in `_scaledBound` (it always reverted
  before), so the skip can never turn a zero-bound order into a silent no-op. The
  `if (maxAssets > 0)` pull guard became unconditional (unreachable at 0). Fork tests
  in `RepayAndPreFundRegressions.t.sol`: `test_review_1006_pullFixedRepay_emptyPosition_skips`,
  `_dustSlice_skips`, `_signedZeroCeiling_reverts` (first two verified to fail against
  the old branch). The two local mock markets (`Narrow160Overflow.t.sol`,
  `HoldingsPullMarket`) gained a `fixedBorrowPositions` view returning a live position.
- `modules-exactly` 59/59 (was 53).

## Follow-up: on-chain refusal (2026-10-06, ACCEPTED-PATTERNS-REVIEW B15)

- The lens flag was only an off-chain warning while the repay sibling refuses a
  signed 0 on-chain. `ExactlyTakerModule._withdrawAtMaturity` now reverts
  `ZeroMinAssets()` when `maturity > block.timestamp ∧ minAssetsRequired == 0`
  (checked before the position read); at/after maturity a zero floor stays legal.
  `takeFloored` keeps the same predicate (NatSpec: early warning, keep identical).
- Not an encoding change; only pre-maturity zero-floor fixed withdraws (already
  lens-flagged) stop filling.
- Tests: new mock suite `test/security/PreMaturityZeroFloor.t.sol` (5 incl. a fuzz
  pinning revert ⇔ `!takeFloored`); fork `PreMaturityWithdraw.t.sol` zero-floor test
  now expects the revert (`test_preMaturity_zeroFloor_reverts`) and gained
  `test_atMaturity_zeroFloor_fillsAtFace`. `modules-exactly` 65/65 (was 59).
