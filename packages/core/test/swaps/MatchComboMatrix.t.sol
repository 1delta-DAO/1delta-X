// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order} from "@core/settlement/Settlement.sol";
import {MatchShapes} from "../shared/MatchShapes.t.sol";

/// @title MatchComboMatrix
/// @notice EVERY matchable order shape against every other, checked for the one
///         thing a netted settlement could plausibly get wrong: letting the
///         counterparty, or the filler's schedule, move a maker's price.
///
///  `MatchSettleRoundingAttack.t.sol` answers that question for the ordinary
///  fixed/fixed pair. It is the pair most likely to be reasoned about and the least
///  likely to break, because neither side has an auction, a fee leg, a second
///  input, or an exact-output denominator. This file is the combinatorial
///  completion: the shapes are crossed with each other, so a leak that only opens
///  when (say) a decaying output sits opposite a rising-input BUY has somewhere to
///  show up. The ITEM axis is crossed separately, in `MatchItemMatrix.t.sol`.
///
///  ── THE INVARIANT ──────────────────────────────────────────────────────────
///  For every combination, the maker's realised ledger under `matchSettle` is
///  IDENTICAL to the same order's realised ledger under the single-order `fill`
///  path at the same fill amounts. That is the precise statement of "the
///  counterparty cannot touch your price", and it is the property the drain would
///  have to break first. It is asserted against the settler itself rather than
///  against a re-implementation of {Pricing}, so the test cannot drift into
///  agreeing with a bug in both places.
///
///  Layered on top, two absolute bounds that need no baseline — each derived
///  generically from the signed legs, so they hold for shapes added later:
///    • no input leg may charge the maker more than `max(start, end)`, the
///      worst-case tick they signed;
///    • at full fill, no maker output leg may deliver less than `min(start, end)`,
///      the floor they signed.
///
///  ── WHAT IS DELIBERATELY ABSENT FROM THE MATRIX ────────────────────────────
///  Four shapes are not rows here because `matchSettle` REFUSES them outright, and
///  the refusals are pinned in `MatchSettle.t.sol` / `MatchSettleGates.t.sol`
///  rather than duplicated: a SETTLE item and a TAKE_FOR item (both
///  {MatchSettleItemUnsupported}), a repeated input token ({MatchDuplicateInput}),
///  and delta-verified outputs ({DeltaVerifyNotBatchable}). A proportional input
///  leg is matchable but only at full fill
///  ({Proportional.ProportionalNeedsFullFill}), so it appears in the full-fill
///  sweep and is excluded from the sliced one.
///
///  See `docs/match-combinations.md` for the rendered matrix.
contract MatchComboMatrixTest is MatchShapes {
    // ──────────────────── the sweeps ────────────────────

    /// @notice Every shape against every shape, settled whole. The maker ledgers
    ///         must match the single-order path exactly, and both generic bounds
    ///         must hold.
    function test_matrix_fullFill_everyCombination() public {
        for (uint256 x; x < SHAPES; ++x) {
            for (uint256 y; y < SHAPES; ++y) {
                _runCombo(Shape(x), Shape(y), 1);
            }
        }
    }

    /// @notice The same cross product, sliced into three fills each. Slicing is the
    ///         only lever the maker-favourable rounding gives a filler, so this is
    ///         where a combination-specific leak would surface.
    ///
    ///         Proportional legs are excluded: they revert
    ///         {ProportionalNeedsFullFill} by construction, which is itself the
    ///         guarantee, and is pinned in `ProportionalLeg.t.sol`.
    function test_matrix_sliced_everyCombination() public {
        for (uint256 x; x < SHAPES; ++x) {
            if (_isProportional(Shape(x))) continue;
            for (uint256 y; y < SHAPES; ++y) {
                if (_isProportional(Shape(y))) continue;
                _runCombo(Shape(x), Shape(y), 3);
            }
        }
    }

    /// @dev One cell of the matrix: build the pair TWICE — once to settle each
    ///      order alone, once to settle them against each other — run both at the
    ///      same fill amounts and the same block timestamp (so every auction tick is
    ///      identical), and compare. Split into two halves because holding both runs'
    ///      state in one frame is stack-too-deep, not because they are independent.
    function _runCombo(Shape sa, Shape sb, uint256 slices) internal {
        (int256[3] memory aBase, int256[3] memory bBase, int256[3] memory fBase) = _baseline(sa, sb, slices);
        _matched(sa, sb, slices, aBase, bBase, fBase);
    }

    /// @dev The reference ledger: each order settled ALONE through `fill`, against
    ///      an ordinary solver holding inventory. No pool, no counterparty, no
    ///      schedule — so whatever this produces is the order's price on its own
    ///      terms.
    function _baseline(Shape sa, Shape sb, uint256 slices)
        internal
        returns (int256[3] memory aOut, int256[3] memory bOut, int256[3] memory fOut)
    {
        Order memory a0 = _build(sa, alice, false);
        Order memory b0 = _build(sb, bob, true);
        _fundMaker(a0, alice);
        _fundMaker(b0, bob);
        _fundSolver();

        uint256[3] memory aBefore = _snap(alice);
        uint256[3] memory bBefore = _snap(bob);
        uint256[3] memory fBefore = _snap(feeSink);
        _sliceFill(a0, _signWith(a0, alicePk), _anchor(a0, alice), slices);
        _sliceFill(b0, _signWith(b0, bobPk), _anchor(b0, bob), slices);
        aOut = _delta(aBefore, _snap(alice));
        bOut = _delta(bBefore, _snap(bob));
        fOut = _delta(fBefore, _snap(feeSink));
    }

    /// @dev The same two shapes, now netted against each other through
    ///      `matchSettle`, and every assertion the cell owns.
    function _matched(
        Shape sa,
        Shape sb,
        uint256 slices,
        int256[3] memory aBase,
        int256[3] memory bBase,
        int256[3] memory fBase
    ) internal {
        Order memory a = _build(sa, alice, false);
        Order memory b = _build(sb, bob, true);
        _fundMaker(a, alice);
        _fundMaker(b, bob);
        _fundFiller();

        uint256[3] memory pool = _snap(address(settlement));
        uint256[3] memory aBefore = _snap(alice);
        uint256[3] memory bBefore = _snap(bob);
        uint256[3] memory fBefore = _snap(feeSink);
        // Anchors are re-resolved rather than reused from the baseline: a
        // proportional leg reads the maker's LIVE balance, which the baseline moved.
        _sliceMatch(a, b, _anchor(a, alice), _anchor(b, bob), slices);

        // 1. The counterparty and the schedule are invisible to a maker's price —
        //    including a third-party fee recipient's slice of it.
        _assertSameLedger(_delta(fBefore, _snap(feeSink)), fBase, "fee recipient: netted ledger differs");
        // 2. …and the baseline-free bounds, per maker.
        _assertCell(a, alice, _delta(aBefore, _snap(alice)), aBase, slices);
        _assertCell(b, bob, _delta(bBefore, _snap(bob)), bBase, slices);
        // 3. The pre-existing pool balance is not the filler's to take, on any
        //    schedule — `_sweepSurplus` floors each token at its pre-context value.
        _assertPoolFloor(pool);
    }

    /// @dev One maker's half of a cell: ledger equality against the single-order
    ///      path, then the two bounds that hold with no baseline at all.
    function _assertCell(Order memory o, address who, int256[3] memory got, int256[3] memory base, uint256 slices)
        internal
        view
    {
        // Non-vacuity. Two identical ledgers are only evidence if something actually
        // moved — a cell whose fill amount silently resolved to zero would satisfy
        // every assertion below while testing nothing at all.
        assertTrue(got[0] != 0 || got[1] != 0 || got[2] != 0, "vacuous cell: the maker's ledger never moved");
        _assertSameLedger(got, base, "maker: netted ledger differs from the single-order path");
        _assertInputsWithinSignedCeiling(o, got);
        // The output floor is a FULL-FILL statement: a partial slice of a fixed leg
        // is deliberately below the signed total, and only sums to it at the end.
        if (slices == 1) _assertOutputsAboveSignedFloor(o, who, got);
    }


    /// @dev Settle the pair as a match in `slices` parts. Both sides advance
    ///      together, which is the schedule a real CoW filler would submit.
    function _sliceMatch(Order memory a, Order memory b, uint256 anchorA, uint256 anchorB, uint256 slices)
        internal
    {
        uint256 doneA;
        uint256 doneB;
        for (uint256 k; k < slices; ++k) {
            uint256 dA = k + 1 == slices ? anchorA - doneA : anchorA / slices;
            uint256 dB = k + 1 == slices ? anchorB - doneB : anchorB / slices;
            if (dA == 0 || dB == 0) continue;
            filler.run(_plan(a, b, dA, dB));
            doneA += dA;
            doneB += dB;
        }
    }
}
