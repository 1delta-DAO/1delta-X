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

    /// @dev Retain mode needs an operator set since audit 2026-09-30 AGG-1
    ///      ({RetainNeedsOperators}), so the retain benchmarks run on a gated instance.
    function _gated() internal returns (AggregatorFillSolver g) {
        address[] memory ops = new address[](1);
        ops[0] = address(this);
        g = new AggregatorFillSolver(address(settlement), _routers(address(router)), ops, _noSplit(), false, _none());
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
        AggregatorFillSolver g = new AggregatorFillSolver(address(settlement), _routers(address(router)), ops, _noSplit(), false, _none());
        tA.mint(address(g), 1);
        tB.mint(address(g), 1);
        _runTo("gated, retain, seeded (fresh tx)", g, 1, AMOUNT_OUT, address(g));
    }

    function test_gas_direct_seeded() public {
        // Direct orders need a gated instance (re-audit 2026-09-29).
        address[] memory ops = new address[](1);
        ops[0] = address(this);
        aggSolver = new AggregatorFillSolver(address(settlement), _routers(address(router)), ops, _noSplit(), false, _none());
        _warmWorld();
        tA.mint(address(aggSolver), 1);
        Order memory o = _directOrder(1);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _exactOutPlan(AMOUNT_OUT, AMOUNT_IN, maker);
        p.profitRecipient = address(aggSolver);
        uint256 g0 = gasleft();
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "");
        console.log("direct, retain, seeded (fresh tx)", g0 - gasleft());
    }

    function test_gas_standingAllowance() public {
        _warmWorld();
        address[] memory prime = new address[](1);
        prime[0] = address(tA);
        AggregatorFillSolver st =
            new AggregatorFillSolver(address(settlement), _routers(address(router)), _standingOps(), _noSplit(), true, prime);
        tA.mint(address(st), 1);
        tB.mint(address(st), 1);
        _runTo("standing allowance, seeded     ", st, 1, AMOUNT_OUT, address(st));
    }

    function test_gas_retain() public {
        _warmWorld();
        AggregatorFillSolver g = _gated();
        _runTo("retain: first fill (cold)       ", g, 1, AMOUNT_OUT, address(g));
        _runTo("retain: second fill             ", g, 2, AMOUNT_OUT, address(g));
        _runTo("retain: third fill              ", g, 3, AMOUNT_OUT, address(g));
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
