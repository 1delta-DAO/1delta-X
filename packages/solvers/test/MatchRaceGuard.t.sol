// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Settlement, Order, Item, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {Batch} from "@core/settlement/Batch.sol";
import {MatchRaceGuard} from "@solvers/base/MatchRaceGuard.sol";
import {GuardedMatchSolver} from "@solvers/match/GuardedMatchSolver.sol";

import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";

/// @dev The race-loss cost of a contested match.
///
/// Several solvers see the same profitable match and land in the same block. One
/// wins; the rest revert. This file pins what the losers pay, with and without
/// {MatchRaceGuard}, and proves the guard is transparent on the winning path.
///
/// The match: Alice sells 1 WETH → 2000 USDC, Bob sells 2100 USDC → 1 WETH. It
/// nets on WETH and leaves 100 USDC of solver edge.
contract MatchRaceGuardTest is CoreSettlementBase {
    uint256 bobPk = 0xB0B;
    address bob = vm.addr(bobPk);
    address rival = address(0xDEFEA7);

    GuardedMatchSolver guarded;

    uint256 constant WETH_AMT = 1 ether;
    uint256 constant ALICE_OUT = 2_000e6; //  Alice is owed 2000 USDC
    uint256 constant BOB_IN = 2_100e6; //     Bob pays 2100 USDC → 100 USDC edge
    uint256 constant EDGE = BOB_IN - ALICE_OUT;

    function setUp() public override {
        super.setUp();
        vm.label(bob, "bob");
        vm.label(rival, "rival");
        guarded = new GuardedMatchSolver(address(settlement));
        vm.label(address(guarded), "guardedSolver");

        vm.startPrank(bob);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        vm.stopPrank();
    }

    // ──────────────────── Builders ────────────────────

    function _orders() internal returns (Order memory a, Order memory b) {
        a = _order(maker, 1, WETH, USDC, WETH_AMT, ALICE_OUT, new Item[](0));
        b = _order(bob, 2, USDC, WETH, BOB_IN, WETH_AMT, new Item[](0));

        deal(WETH, maker, WETH_AMT);
        deal(USDC, bob, BOB_IN);
        vm.startPrank(maker);
        permit3.approveToken(address(settlement), WETH, uint160(WETH_AMT), 0);
        vm.stopPrank();
        vm.startPrank(bob);
        permit3.approveToken(address(settlement), USDC, uint160(BOB_IN), 0);
        vm.stopPrank();
    }

    function _signAs(Order memory o, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(o)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _step(uint256 kind, uint256 x, uint256 y) internal pure returns (uint256) {
        return kind | (x << 8) | (y << 24);
    }

    function _plan(Order memory a, Order memory b, address profitTo) internal view returns (MatchPlan memory) {
        Order[] memory orders = new Order[](2);
        (orders[0], orders[1]) = (a, b);
        bytes[] memory sigs = new bytes[](2);
        (sigs[0], sigs[1]) = (_signAs(a, makerPk), _signAs(b, bobPk));
        uint256[] memory fills = new uint256[](2);
        (fills[0], fills[1]) = (WETH_AMT, BOB_IN);
        uint256[] memory s = new uint256[](4);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.DELIVER, 0, 0);
        s[3] = _step(MatchStep.DELIVER, 1, 0);
        return MatchPlan({
            orders: orders,
            sigs: sigs,
            fillAmounts: fills,
            takerDatas: new bytes[](0),
            schedule: s,
            callTargets: new address[](0),
            callDatas: new bytes[](0),
            profitRecipient: profitTo
        });
    }

    function _hashes(Order memory a, Order memory b) internal pure returns (bytes32[] memory h) {
        h = new bytes32[](2);
        (h[0], h[1]) = (_hashOrder(a), _hashOrder(b));
    }

    function _zeros() internal pure returns (uint256[] memory z) {
        z = new uint256[](2); // both orders fresh at simulation time
    }

    // ── The winner: the guard is transparent, and the edge reaches the caller. ──
    function test_guarded_winner_settlesAndForwardsEdge() public {
        (Order memory a, Order memory b) = _orders();
        // Built BEFORE the prank: `_plan` signs, which calls DOMAIN_SEPARATOR() and
        // would otherwise consume it.
        MatchPlan memory plan = _plan(a, b, rival);
        bytes32[] memory hashes = _hashes(a, b);

        vm.prank(rival);
        guarded.settleMatch(hashes, _zeros(), plan);

        assertEq(IERC20(USDC).balanceOf(maker), ALICE_OUT, "Alice paid her signed 2000 USDC");
        assertEq(IERC20(WETH).balanceOf(bob), WETH_AMT, "Bob received his 1 WETH");
        assertEq(IERC20(USDC).balanceOf(rival), EDGE, "the 100 USDC edge went straight to profitRecipient");
        assertEq(IERC20(USDC).balanceOf(address(guarded)), 0, "solver never touched the edge");
        assertEq(IERC20(WETH).balanceOf(address(guarded)), 0, "solver never touched the edge");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "pool flat");
    }

    // ── The losers. Same plan, already taken. Measured both ways. ──
    function test_raceLoser_guardIsFarCheaperThanReverting() public {
        (Order memory a, Order memory b) = _orders();
        MatchPlan memory plan = _plan(a, b, rival);
        bytes32[] memory hashes = _hashes(a, b);
        uint256[] memory expected = _zeros();

        // The winner takes it.
        vm.prank(rival);
        guarded.settleMatch(hashes, expected, plan);
        assertEq(settlement.filled(hashes[0]), WETH_AMT, "order A is now full");

        // Loser A — calls `matchSettle` directly, learns the race is over only
        // after the universe walk, the balance snapshots, the order hash and the
        // ecrecover. Reverts OverFill.
        bytes memory direct = abi.encodeCall(Batch.matchSettle, (plan));
        vm.prank(solver);
        uint256 g0 = gasleft();
        (bool okDirect,) = address(settlement).call(direct);
        uint256 unguardedGas = g0 - gasleft();
        assertFalse(okDirect, "the direct loser must revert");

        // Loser B — same plan through the guard. Two SLOADs and out; `plan` is
        // never copied out of calldata.
        bytes memory viaGuard = abi.encodeCall(GuardedMatchSolver.settleMatch, (hashes, expected, plan));
        vm.prank(solver);
        g0 = gasleft();
        (bool okGuard, bytes memory ret) = address(guarded).call(viaGuard);
        uint256 guardedGas = g0 - gasleft();
        assertFalse(okGuard, "the guarded loser must revert");

        // …and it reverts with a TYPED error naming the order, so a searcher can
        // classify "lost the race" without re-simulating.
        assertEq(bytes4(ret), MatchRaceGuard.OrderTaken.selector, "typed race-loss error");
        (uint256 idx, uint256 exp, uint256 act) = abi.decode(_body(ret), (uint256, uint256, uint256));
        assertEq(idx, 0, "order 0 is the one that moved");
        assertEq(exp, 0, "simulated against a fresh order");
        assertEq(act, WETH_AMT, "and is now fully filled");

        emit log_named_uint("race loss, unguarded (gas)", unguardedGas);
        emit log_named_uint("race loss, guarded   (gas)", guardedGas);
        emit log_named_uint("saved                (gas)", unguardedGas - guardedGas);

        assertLt(guardedGas, unguardedGas / 2, "the guard must cost well under half an unguarded revert");
    }

    // ── A partial fill by a competitor also trips the guard: the plan's amounts
    //    were balanced against the old `filled`, so it is stale even though the
    //    order still has room. ──
    function test_partialFillByCompetitor_alsoTripsGuard() public {
        (Order memory a, Order memory b) = _orders();
        bytes32[] memory hashes = _hashes(a, b);

        // A competitor takes a slice of Bob's order via a plain single fill.
        deal(WETH, solver, WETH_AMT);
        vm.startPrank(solver);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), WETH, uint160(WETH_AMT), 0);
        settlement.fill(b, _signAs(b, bobPk), BOB_IN / 4);
        vm.stopPrank();

        assertGt(settlement.filled(hashes[1]), 0, "Bob's order moved");
        assertLt(settlement.filled(hashes[1]), BOB_IN, "but still has room");

        MatchPlan memory plan = _plan(a, b, rival);
        vm.prank(rival);
        vm.expectRevert(
            abi.encodeWithSelector(MatchRaceGuard.OrderTaken.selector, uint256(1), uint256(0), BOB_IN / 4)
        );
        guarded.settleMatch(hashes, _zeros(), plan);
    }

    // ── A plan that would leave its residual in the solver contract (where the
    //    next caller would sweep it) is rejected before anything moves. ──
    function test_profitStranded_reverts() public {
        (Order memory a, Order memory b) = _orders();
        MatchPlan memory unset = _plan(a, b, address(0)); //      0 == msg.sender == the solver
        MatchPlan memory selfish = _plan(a, b, address(guarded)); // explicit, same problem
        bytes32[] memory hashes = _hashes(a, b);

        vm.prank(rival);
        vm.expectRevert(GuardedMatchSolver.ProfitStranded.selector);
        guarded.settleMatch(hashes, _zeros(), unset);

        vm.prank(rival);
        vm.expectRevert(GuardedMatchSolver.ProfitStranded.selector);
        guarded.settleMatch(hashes, _zeros(), selfish);
    }

    // ── Misaligned guard arrays fail closed. ──
    function test_guardLengthMismatch_reverts() public {
        (Order memory a, Order memory b) = _orders();
        MatchPlan memory plan = _plan(a, b, rival);
        vm.prank(rival);
        vm.expectRevert(MatchRaceGuard.GuardLengthMismatch.selector);
        guarded.settleMatch(_hashes(a, b), new uint256[](1), plan);
    }

    /// @dev Strip the 4-byte selector off returndata.
    function _body(bytes memory ret) internal pure returns (bytes memory out) {
        out = new bytes(ret.length - 4);
        for (uint256 i; i < out.length; i++) {
            out[i] = ret[i + 4];
        }
    }
}
