// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {Order, LegOut} from "@core/settlement/Settlement.sol";
import {AggregatorFillSolver, RoutePlan, NO_PATCH, POOL_ROUTE, Permit2612} from "@solvers/aggregator/AggregatorFillSolver.sol";
import {AggregatorFillSolverTest, AggregatorProportionalSentinelTest} from "./AggregatorFillSolver.t.sol";

/// @dev Review 2026-10-18 "amount mismatch" probes against the solver changes on branch
///      zero-capital-item-fills. Each test pins what the contract DOES; the assertion
///      text says whether that matches the documented intent.
contract Review20261018SolverAmountMismatchTest is AggregatorFillSolverTest {
    uint256 constant AMOUNT_WORD = 4;
    address constant FEE = address(0xFEE);

    function _np() internal pure returns (Permit2612[] memory) {
        return new Permit2612[](0);
    }

    function _empty() internal view returns (RoutePlan memory p) {
        p = _plan(address(aggSolver), 0);
        p.router = POOL_ROUTE;
        p.data = "";
    }

    /// P1. DIRECT inventory top-up: `maxPay` is NOT applied — `maxPay` is ignored on the
    ///     direct path and `inventory` is the draw's only cap (D-1: the docs said "maxPay
    ///     still caps the total"; corrected). The pull path with the same plan reverts.
    function test_P1_direct_topUpIgnoresMaxPay() public {
        tB.mint(address(aggSolver), 100e18);
        Order memory o = _directOrder(1);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _empty();
        p.inventory = 100e18;
        p.maxPay = 50e18; // below the 90 owed
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "DIRECT: 90 paid although maxPay = 50");
        assertEq(tB.balanceOf(address(aggSolver)), 10e18, "90 drawn from inventory");

        // The same plan on the pull path is refused by maxPay.
        tB.mint(address(aggSolver), 100e18);
        Order memory o2 = _order(2);
        bytes memory sig2 = _sign(o2);
        vm.expectRevert();
        aggSolver.executeFill(o2, sig2, AMOUNT_IN, p, "", _np());
    }

    /// P2. Pro-rata floor with a KEPT-BACK same-token fee leg: if the quoted word at
    ///     `amountInOffset` is the whole `owed` (100) while the solver routes
    ///     `owed − fee` (90), `minOut` 95 silently becomes ceil(95·90/100) = 86 on a
    ///     FULL fill (no competitor at all).
    function test_P2_proRata_quotedWordIsOwed_keptFeeLowersFloor() public {
        LegOut[] memory lo = new LegOut[](2);
        lo[0] = LegOut(address(tB), 85e18, 0, address(0));
        lo[1] = LegOut(address(tA), 10e18, 0, FEE);
        Order memory o = _order(3);
        o.legsOut = PackedEncode.legsOut(lo);
        bytes memory sig = _sign(o);

        // Operator floor 95 tB; route makes 1:1, so 90 routed (less the seed wei) -> ~90 tB, below 95.
        RoutePlan memory p = _planFor(AMOUNT_IN, address(aggSolver), 95e18, AMOUNT_WORD);
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        assertEq(tB.balanceOf(maker), 85e18, "filled although proceeds ~90 < minOut 95");
        assertEq(tA.balanceOf(FEE), 10e18, "fee leg paid from the kept-back input");

        // Quoting the ROUTED amount (90) keeps the floor absolute: the same fill reverts.
        Order memory o2 = _order(4);
        o2.legsOut = PackedEncode.legsOut(lo);
        bytes memory sig2 = _sign(o2);
        RoutePlan memory q = _planFor(90e18, address(aggSolver), 95e18, AMOUNT_WORD);
        vm.expectRevert();
        aggSolver.executeFill(o2, sig2, AMOUNT_IN, q, "", _np());
        assertEq(tB.balanceOf(maker), 85e18, "second order not filled");
    }

    /// P3. The quoted word is read as "what the route was quoted for" — a LOOSE ceiling
    ///     (exact-output style `amountInMaximum` 2× the input) halves the floor.
    function test_P3_proRata_looseCeilingWordHalvesFloor() public {
        Order memory o = _plainOrder(5, address(tA), address(tB), AMOUNT_IN, 50e18);
        bytes memory sig = _sign(o);
        router.setRate(6_000); // 100 -> 60, far below the operator's 95 floor
        RoutePlan memory p = _planFor(200e18, address(aggSolver), 95e18, AMOUNT_WORD);
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        assertEq(tB.balanceOf(maker), 50e18, "filled at 60 proceeds against a 95 floor (scaled to 48)");
    }

    /// P3b. A `type(uint256).max` placeholder in the quoted word overflows the scaling.
    function test_P3b_proRata_maxPlaceholderReverts() public {
        Order memory o = _order(6);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _planFor(type(uint256).max, address(aggSolver), 95e18, AMOUNT_WORD);
        vm.expectRevert();
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
    }

    /// P4. Zero-output orders: `minOut` is never compared (no anchor output in outMask).
    function test_P4_zeroOutput_minOutUnenforced() public {
        Order memory o = _blank(7);
        o.legsIn = _legsIn1(address(tA), 10e18);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _empty();
        p.minOut = 1e30;
        aggSolver.executeFill(o, sig, 10e18, p, "", _np());
        assertEq(tA.balanceOf(address(this)), 10e18 - 1, "filled with an unreachable minOut");
    }

    /// P5. Empty route + a patched input offset: what does `_minOut` read as `quoted`?
    function test_P5_emptyRoute_patchedOffsetQuotedWord() public {
        tB.mint(address(aggSolver), 100e18);
        Order memory o = _order(8);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _empty();
        p.inventory = 100e18;
        p.minOut = 1e30; // unreachable unless scaled to ~0
        p.amountInOffset = 0;
        (bool ok,) = address(aggSolver).call(abi.encodeCall(aggSolver.executeFill, (o, sig, AMOUNT_IN, p, "", _np())));
        emit log_named_string("empty route + offset 0, minOut 1e30", ok ? "FILLED (quoted read as garbage)" : "reverted (quoted read as 0)");
    }
}

/// @dev F-1 (review 2026-10-18) did NOT reproduce: a proportional order's OUTPUT legs are
///      fixed at a full fill (`legStart × anchor / anchor`), so a maker balance that grew
///      after the preview raises only the routed input — never what the core pulls — and
///      the filler's `maxPay = owed` (previewed) still covers it.
contract Review20261018ProportionalMaxPayTest is AggregatorProportionalSentinelTest {
    function test_F1_grownBalance_previewedMaxPayStillCoversTheFixedOutput() public {
        _makerHolds(150e18); // previewed at 100, grew to 150 (cap 200)
        Order memory o = _propOrder(70);
        bytes memory sig = _sign(o);
        RoutePlan memory plan = _followingPlan(AMOUNT_OUT + 1e18); // owed + cost
        plan.maxPay = AMOUNT_OUT; // the filler's owed at the previewed balance
        uint256 makerBefore = tB.balanceOf(maker);
        vm.prank(FILLER);
        splitSolver.executeFill(o, sig, ANY, plan, "", new Permit2612[](0));
        assertEq(tA.balanceOf(maker), 0, "the whole grown balance was sold");
        assertGe(tB.balanceOf(maker) - makerBefore, AMOUNT_OUT, "the fixed output, plus the maker's surplus share");
    }
}
