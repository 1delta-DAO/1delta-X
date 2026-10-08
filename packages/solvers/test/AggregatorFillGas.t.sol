// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/console.sol";
import {Order} from "@core/settlement/Settlement.sol";
import {AggregatorFillSolver, RoutePlan, NO_PATCH} from "@solvers/aggregator/AggregatorFillSolver.sol";
import {AggregatorFillSolverTest} from "./AggregatorFillSolver.t.sol";

/// @title AggregatorFillGasTest
/// @notice Gas benchmark for `executeFill` — raw execution gas, refunds excluded,
///         printed with `-vv`. Not assertions: the numbers are for reading the
///         effect of a change, one change at a time. The cold/dust/retain trio
///         is the balance-floor argument in the contract's header.
contract AggregatorFillGasTest is AggregatorFillSolverTest {
    function _warmWorld() internal {
        // Realistic steady state: the maker has received tokenOut before, the
        // profit recipient has a balance, the router holds both sides.
        tB.mint(maker, 1);
        tB.mint(address(this), 1);
        tA.mint(address(router), 1);
    }

    function _run(string memory label, AggregatorFillSolver s, uint256 nonce, uint256 minOut) internal {
        _runTo(label, s, nonce, minOut, address(0));
    }

    function _runTo(string memory label, AggregatorFillSolver s, uint256 nonce, uint256 minOut, address to) internal {
        Order memory o = _order(nonce);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _planFor(AMOUNT_IN, address(s), minOut, NO_PATCH);
        p.profitRecipient = to;
        uint256 g0 = gasleft();
        s.executeFill(o, sig, AMOUNT_IN, p, "");
        uint256 used = g0 - gasleft();
        console.log(label, used);
    }

    function test_gas_baseline_cold() public {
        _warmWorld();
        _run("cold solver, 10% surplus        ", aggSolver, 1, AMOUNT_OUT);
    }

    function test_gas_baseline_dust() public {
        _warmWorld();
        tA.mint(address(aggSolver), 1);
        tB.mint(address(aggSolver), 1);
        _run("1-wei dust floor, 10% surplus   ", aggSolver, 1, AMOUNT_OUT);
    }

    function test_gas_baseline_dust_noSurplus() public {
        _warmWorld();
        tA.mint(address(aggSolver), 1);
        tB.mint(address(aggSolver), 1);
        router.setRate(9_000); // route quoted exactly at the maker's price
        _run("1-wei dust floor, zero surplus  ", aggSolver, 1, AMOUNT_OUT);
    }

    /// @dev A fresh single-operator instance for the retain benchmarks (every
    ///      instance is gated since 2026-10; this one is not shared with the base).
    function _gated() internal returns (AggregatorFillSolver g) {
        address[] memory ops = new address[](1);
        ops[0] = address(this);
        g = new AggregatorFillSolver(address(settlement), ops, _noSplit());
    }

    function test_gas_retain_seeded() public {
        _warmWorld();
        AggregatorFillSolver g = _gated();
        tA.mint(address(g), 1);
        tB.mint(address(g), 1);
        _runTo("retain, seeded floor (fresh tx) ", g, 1, AMOUNT_OUT, address(g));
    }

    function test_gas_gated_seeded() public {
        _warmWorld();
        address[] memory ops = new address[](1);
        ops[0] = address(this);
        AggregatorFillSolver g = new AggregatorFillSolver(address(settlement), ops, _noSplit());
        tA.mint(address(g), 1);
        tB.mint(address(g), 1);
        _runTo("gated, retain, seeded (fresh tx)", g, 1, AMOUNT_OUT, address(g));
    }

    function test_gas_direct_seeded() public {
        _direct("direct, retain, seeded (fresh tx)", NO_PATCH);
    }

    /// @dev The same direct fill with `amountOutOffset` set: the TYPED callback (the
    ///      live `pricedOut[0]` patched into the exact-output word, task 06). The
    ///      difference to {test_gas_direct_seeded} is the typed payload's price.
    function test_gas_direct_seeded_liveAmountOut() public {
        _direct("direct, live amountOut (typed)   ", 4);
    }

    function _direct(string memory label, uint256 outOffset) internal {
        // A fresh single-operator instance, so the direct benchmark starts cold.
        address[] memory ops = new address[](1);
        ops[0] = address(this);
        aggSolver = new AggregatorFillSolver(address(settlement), ops, _noSplit());
        _warmWorld();
        tA.mint(address(aggSolver), 1);
        Order memory o = _directOrder(1);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _exactOutPlan(AMOUNT_OUT, AMOUNT_IN, maker);
        p.profitRecipient = address(aggSolver);
        p.amountOutOffset = outOffset;
        uint256 g0 = gasleft();
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "");
        console.log(label, g0 - gasleft());
    }

    function test_gas_retain() public {
        _warmWorld();
        AggregatorFillSolver g = _gated();
        _runTo("retain: first fill (cold)       ", g, 1, AMOUNT_OUT, address(g));
        _runTo("retain: second fill             ", g, 2, AMOUNT_OUT, address(g));
        _runTo("retain: third fill              ", g, 3, AMOUNT_OUT, address(g));
    }

    /// @dev The SELF-SEEDING first fill (2026-10): a cold solver, the route patched
    ///      (`amountInOffset` = 4), spread paid out — it keeps one wei of tA and of
    ///      tB. Then a second fill in the same tx, which finds both floors. (Same-tx
    ///      slots are dirty — see the README; the fresh-tx figures are the fork's
    ///      `SelfSeedColdBench` / `SelfSeedSteadyBench`.)
    function test_gas_selfSeed_patched() public {
        _warmWorld();
        for (uint256 i = 1; i <= 2; ++i) {
            Order memory o = _order(i);
            bytes memory sig = _sign(o);
            RoutePlan memory p = _planFor(AMOUNT_IN, address(aggSolver), AMOUNT_OUT, 4);
            uint256 g0 = gasleft();
            aggSolver.executeFill(o, sig, AMOUNT_IN, p, "");
            console.log(i == 1 ? "self-seed: first fill (cold)    " : "self-seed: second fill (same tx)", g0 - gasleft());
        }
        assertEq(tA.balanceOf(address(aggSolver)), 1, "tA floor self-seeded");
        assertEq(tB.balanceOf(address(aggSolver)), 1, "tB floor self-seeded");
    }

    function test_gas_second_fill() public {
        _warmWorld();
        _run("first fill                      ", aggSolver, 1, AMOUNT_OUT);
        _run("second fill (same tx)           ", aggSolver, 2, AMOUNT_OUT);
    }

    /// @dev The floor: the same order filled by an inventory EOA through the plain
    ///      `fill` — what the core costs before this contract adds anything.
    function test_gas_floor_plainFill() public {
        _warmWorld();
        tB.mint(solver, 1_000e18);
        _solverApprove(address(settlement), address(tB), type(uint160).max);
        Order memory o = _order(1);
        bytes memory sig = _sign(o);
        vm.startPrank(solver);
        uint256 g0 = gasleft();
        settlement.fill(o, sig, AMOUNT_IN);
        uint256 used = g0 - gasleft();
        vm.stopPrank();
        console.log("plain fill by inventory EOA    ", used);
    }
}
