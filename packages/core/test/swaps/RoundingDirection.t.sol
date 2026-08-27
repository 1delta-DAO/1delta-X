// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order} from "@core/settlement/Settlement.sol";
import {MockSettlementBase} from "../shared/MockSettlementBase.t.sol";

/// @title RoundingDirection
/// @notice The FILL-SPLITTING invariant: slicing an order into many small fills must
///         never pay the maker less, nor charge them more, than settling it in one.
///
///  Provenance — Uniswap v4 failure pattern #3, "custom accounting value leaks"
///  (Trail of Bits). The lesson there is not that rounding exists but that the
///  protocol-level settlement check does not catch it: the PoolManager only verifies
///  that a session's currency deltas resolve to zero, so a hook's internal rounding
///  error leaks value while every transaction still satisfies the invariant. Bunni
///  lost funds to exactly this — an idle-balance rounding bug drained through 44
///  tiny transactions, each individually valid.
///
///  We have the same structural gap. `matchSettle`'s wholeness check ({BatchNotWhole})
///  and the per-leg reconcile ({LegUnfunded}) both assert that the POOL balances and
///  that each leg was funded to its `owed`; neither says anything about whether
///  `owed` was rounded in the maker's favour or the solver's. `filled[orderHash]`
///  caps the total but not the per-slice remainder. So the direction of every
///  rounding step is load-bearing, and it is asserted here rather than inferred from
///  reading {Pricing}.
///
///  ⚠ THE ASYMMETRY IS DELIBERATE, and this file is what pins it:
///    • FIXED inputs use a CUMULATIVE-DIFFERENCE form
///      (`start*new/anchor − start*prev/anchor`), so N slices sum to exactly the
///      signed total — no drift in either direction, however finely sliced.
///    • OUTPUTS round UP per slice (`ceilDiv`), so slicing can only ever pay the
///      maker MORE. The solver absorbs the dust, and the solver is the party
///      choosing the slice size — so there is no one to grief.
///  A change that flipped either to round toward the SOLVER would be a value leak of
///  the Bunni shape, and would break these tests loudly.
contract RoundingDirectionTest is MockSettlementBase {
    // Deliberately coprime-ish so every slice leaves a remainder. A round number
    // would divide evenly and the whole property would go untested.
    uint256 constant AMOUNT_IN = 1_000_000_000_000_000_007; // anchor
    uint256 constant AMOUNT_OUT = 3_000_000_000_000_000_001;

    function _fund(uint256 mult) internal {
        tA.mint(maker, AMOUNT_IN * mult);
        _makerApprove(address(settlement), address(tA), AMOUNT_IN * mult);
        tB.mint(solver, AMOUNT_OUT * mult * 2);
        _solverApprove(address(settlement), address(tB), AMOUNT_OUT * mult * 2);
    }

    function _order(uint256 nonce) internal view returns (Order memory) {
        return _plainOrder(nonce, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
    }

    /// @dev Baseline: settle the whole order in ONE fill.
    function _fillWhole(uint256 nonce) internal returns (uint256 makerOut, uint256 makerIn) {
        Order memory o = _order(nonce);
        bytes memory sig = _sign(o);
        uint256 outBefore = tB.balanceOf(maker);
        uint256 inBefore = tA.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, AMOUNT_IN);
        return (tB.balanceOf(maker) - outBefore, inBefore - tA.balanceOf(maker));
    }

    /// @dev The same order settled in `slices` even pieces (remainder on the last).
    function _fillSliced(uint256 nonce, uint256 slices) internal returns (uint256 makerOut, uint256 makerIn) {
        Order memory o = _order(nonce);
        bytes memory sig = _sign(o);
        uint256 outBefore = tB.balanceOf(maker);
        uint256 inBefore = tA.balanceOf(maker);

        uint256 each = AMOUNT_IN / slices;
        uint256 done;
        for (uint256 k; k < slices; k++) {
            uint256 amt = k == slices - 1 ? AMOUNT_IN - done : each;
            vm.prank(solver);
            settlement.fill(o, sig, amt);
            done += amt;
        }
        assertEq(settlement.filled(_hashOrder(o)), AMOUNT_IN, "order fully filled");
        return (tB.balanceOf(maker) - outBefore, inBefore - tA.balanceOf(maker));
    }

    /// @dev THE INVARIANT. Slicing must never favour the solver — on either side.
    ///      Checked across a spread of slice counts, including ones that divide the
    ///      anchor unevenly, because an even split hides remainder handling.
    function test_slicing_neverFavoursTheSolver() public {
        _fund(64);
        (uint256 wholeOut, uint256 wholeIn) = _fillWhole(1);

        uint256[5] memory counts = [uint256(2), 3, 7, 13, 32];
        for (uint256 i; i < 5; i++) {
            (uint256 slicedOut, uint256 slicedIn) = _fillSliced(100 + i, counts[i]);
            assertGe(slicedOut, wholeOut, "maker must never RECEIVE less by slicing");
            assertLe(slicedIn, wholeIn, "maker must never PAY more by slicing");
        }
    }

    /// @dev The fixed-input side specifically: the cumulative-difference form means
    ///      the maker pays EXACTLY the signed amount however finely it is sliced.
    ///      Asserted as equality, not a bound — a per-slice floor/ceil here would
    ///      show up as drift and this is the test that would catch it.
    function test_fixedInput_isExactUnderAnySlicing() public {
        _fund(64);
        (, uint256 wholeIn) = _fillWhole(2);
        assertEq(wholeIn, AMOUNT_IN, "one fill charges the signed amount");

        uint256[4] memory counts = [uint256(3), 7, 13, 32];
        for (uint256 i; i < 4; i++) {
            (, uint256 slicedIn) = _fillSliced(200 + i, counts[i]);
            assertEq(slicedIn, AMOUNT_IN, "sliced input must sum to exactly the signed total");
        }
    }

    /// @dev Fuzzed over the slice count, so the property is not just true for the
    ///      handful of divisors picked above.
    function testFuzz_slicing_neverFavoursTheSolver(uint8 rawSlices) public {
        uint256 slices = bound(rawSlices, 2, 40);
        _fund(128);
        (uint256 wholeOut, uint256 wholeIn) = _fillWhole(3);
        (uint256 slicedOut, uint256 slicedIn) = _fillSliced(300, slices);
        assertGe(slicedOut, wholeOut, "maker receives at least as much");
        assertLe(slicedIn, wholeIn, "maker pays at most as much");
        assertEq(slicedIn, AMOUNT_IN, "fixed input stays exact");
    }

    // ════════════ the BUY side (Balancer's asymmetry lesson) ════════════

    /// @dev Provenance — the Balancer V2 exploit (3 Nov 2025, ~$128M), the largest
    ///      instance of this class on record and one that got past Trail of Bits,
    ///      Spearbit AND Certora. Root cause: **asymmetric rounding between the two
    ///      directions of the same conversion** — upscaling rounded down while
    ///      downscaling rounded up/down — amplified by **batch atomicity**: 65 tuned
    ///      micro-swaps inside a single `batchSwap` compounded wei-level truncations
    ///      into a deflated invariant. Any single swap was negligible; the batch was
    ///      not.
    ///
    ///      The transferable lesson is that testing ONE direction proves nothing
    ///      about the other. The tests above cover a SELL order (fixed input,
    ///      auctioned output). A BUY order inverts the roles — fixed OUTPUT is the
    ///      anchor and the INPUT is the auctioned side — so it exercises a different
    ///      branch of {Pricing} and would hide an asymmetry that the SELL tests
    ///      cannot see.
    ///
    ///      Same invariant, other side: slicing must never make the maker pay more.
    function test_buySide_slicing_neverFavoursTheSolver() public {
        uint256 out = 1_000_000_000_000_000_007; // anchor, deliberately not round
        uint256 price = 3_000_000_000_000_000_001;

        // Baseline: one fill.
        tA.mint(maker, price * 8);
        _makerApprove(address(settlement), address(tA), price * 8);
        tB.mint(solver, out * 8);
        _solverApprove(address(settlement), address(tB), out * 8);

        Order memory whole = _buyOrder(1, address(tA), address(tB), price, price, out);
        bytes memory sigW = _sign(whole);
        uint256 inBefore = tA.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(whole, sigW, out);
        uint256 wholeIn = inBefore - tA.balanceOf(maker);
        assertEq(wholeIn, price, "one fill pays the signed price");

        // The same order, sliced.
        uint256[3] memory counts = [uint256(3), 7, 13];
        for (uint256 c; c < 3; c++) {
            Order memory o = _buyOrder(50 + c, address(tA), address(tB), price, price, out);
            bytes memory sig = _sign(o);
            uint256 before_ = tA.balanceOf(maker);
            uint256 each = out / counts[c];
            uint256 done;
            for (uint256 k; k < counts[c]; k++) {
                uint256 amt = k == counts[c] - 1 ? out - done : each;
                vm.prank(solver);
                settlement.fill(o, sig, amt);
                done += amt;
            }
            assertEq(settlement.filled(_hashOrder(o)), out, "fully filled");
            assertLe(before_ - tA.balanceOf(maker), wholeIn, "BUY maker must never PAY more by slicing");
        }
    }
}
