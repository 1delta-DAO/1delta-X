// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {MatchRaceGuard} from "@solvers/base/MatchRaceGuard.sol";
import {GuardedMatchSolver} from "@solvers/match/GuardedMatchSolver.sol";

import {MatchRaceGuardTest} from "./MatchRaceGuard.t.sol";

/// @title MatchSolverAudit20260930Test
/// @notice Regression tests for the 2026-09-30 audit findings on
///         {GuardedMatchSolver} / {MatchRaceGuard}: CORE-MATCH-1 (PRESEND
///         stranding + the two other stranding recipients), CORE-MATCH-3 (the
///         optional operator set that gives an instance a filler identity) and
///         FLASH-5 / CORE-MATCH-5 (nonce-gated orders the `filled` guard cannot see).
contract MatchSolverAudit20260930Test is MatchRaceGuardTest {
    /// CORE-MATCH-1: a PRESEND step pays `msg.sender` of `matchSettle` — the
    /// wrapper, which can never move a token again. The plan is refused before
    /// anything moves, and the wrapper ends holding nothing.
    function test_audit_CORE_MATCH_1_presendPlansAreRefused() public {
        (Order memory a, Order memory b) = _orders();
        MatchPlan memory plan = _plan(a, b, rival);
        uint256[] memory s = new uint256[](5);
        for (uint256 i; i < 4; i++) {
            s[i] = plan.schedule[i];
        }
        s[4] = _step(MatchStep.PRESEND, 1, 0); // the USDC edge → msg.sender (the wrapper)
        plan.schedule = s;
        bytes32[] memory hashes = _hashes(a, b);

        vm.prank(rival);
        vm.expectRevert(GuardedMatchSolver.PresendUnsupported.selector);
        guarded.settleMatch(hashes, _zeros(), plan);

        assertEq(IERC20(USDC).balanceOf(address(guarded)), 0, "nothing locked in the wrapper");
        assertEq(IERC20(WETH).balanceOf(address(guarded)), 0, "nothing locked in the wrapper");
    }

    /// CORE-MATCH-1: the stranding guard covered 1 of 3 routes. Settlement (a
    /// self-transfer nobody can claim) and the shared EXECUTOR (takeable by anyone's
    /// next CALL step) are refused as profit recipients too.
    function test_audit_CORE_MATCH_1_settlementAndExecutorAreNotRecipients() public {
        (Order memory a, Order memory b) = _orders();
        bytes32[] memory hashes = _hashes(a, b);
        MatchPlan memory toSettlement = _plan(a, b, address(settlement));
        MatchPlan memory toExecutor = _plan(a, b, address(settlement.EXECUTOR()));

        vm.prank(rival);
        vm.expectRevert(GuardedMatchSolver.ProfitStranded.selector);
        guarded.settleMatch(hashes, _zeros(), toSettlement);

        vm.prank(rival);
        vm.expectRevert(GuardedMatchSolver.ProfitStranded.selector);
        guarded.settleMatch(hashes, _zeros(), toExecutor);
    }

    /// CORE-MATCH-3: a GATED instance is a filler identity an order may name —
    /// strangers are refused before the guard, operators settle.
    function test_audit_CORE_MATCH_3_gatedInstanceAdmitsOnlyItsOperators() public {
        address[] memory ops = new address[](1);
        ops[0] = rival;
        GuardedMatchSolver gated = new GuardedMatchSolver(address(settlement), ops);
        assertTrue(gated.GATED(), "gated");
        assertTrue(gated.isOperator(rival), "rival operates it");
        assertFalse(guarded.isOperator(rival), "an open instance has no operators");

        (Order memory a, Order memory b) = _orders();
        MatchPlan memory plan = _plan(a, b, rival);
        bytes32[] memory hashes = _hashes(a, b);

        vm.prank(address(0xD00D));
        vm.expectRevert(abi.encodeWithSelector(GuardedMatchSolver.NotOperator.selector, address(0xD00D)));
        gated.settleMatch(hashes, _zeros(), plan);

        vm.prank(rival);
        gated.settleMatch(hashes, _zeros(), plan);
        assertEq(IERC20(USDC).balanceOf(rival), EDGE, "the operator settled and took the edge");
    }

    function test_audit_CORE_MATCH_3_operatorSetValidation() public {
        address[] memory zero = new address[](1);
        vm.expectRevert(GuardedMatchSolver.BadOperatorSet.selector);
        new GuardedMatchSolver(address(settlement), zero);
        address[] memory five = new address[](5);
        for (uint256 i; i < 5; i++) {
            five[i] = address(uint160(i + 1));
        }
        vm.expectRevert(GuardedMatchSolver.BadOperatorSet.selector);
        new GuardedMatchSolver(address(settlement), five);
    }

    /// FLASH-5 / CORE-MATCH-5: the maker cancels order A BY NONCE after the plan was
    /// simulated. `filled` still reads 0, so the hash guard passes and the loser pays
    /// the whole approach run; the nonce guard catches it with a typed error.
    function test_audit_FLASH_5_nonceCancellationIsCaughtCheaply() public {
        (Order memory a, Order memory b) = _orders();
        MatchPlan memory plan = _plan(a, b, rival);
        bytes32[] memory hashes = _hashes(a, b);

        uint256[] memory cancel = new uint256[](1);
        cancel[0] = a.nonce;
        vm.prank(maker);
        settlement.cancelOrders(cancel);
        assertEq(settlement.filled(hashes[0]), 0, "nonce cancellation leaves `filled` untouched");

        address[] memory makers = new address[](1);
        makers[0] = maker;
        uint256[] memory nonces = new uint256[](1);
        nonces[0] = a.nonce;

        vm.prank(rival);
        vm.expectRevert(abi.encodeWithSelector(MatchRaceGuard.NonceTaken.selector, uint256(0), maker, a.nonce));
        guarded.settleMatchWithNonces(hashes, _zeros(), makers, nonces, plan);

        // Live nonces pass straight through to the settlement.
        (Order memory c, Order memory d) = (a, b);
        c.nonce = 11;
        d.nonce = 12;
        MatchPlan memory plan2 = _plan(c, d, rival);
        nonces[0] = c.nonce;
        vm.prank(rival);
        guarded.settleMatchWithNonces(_hashes(c, d), _zeros(), makers, nonces, plan2);
        assertEq(IERC20(USDC).balanceOf(rival), EDGE, "live nonces settle");
    }

    function test_audit_FLASH_5_nonceGuardLengthMismatch() public {
        (Order memory a, Order memory b) = _orders();
        MatchPlan memory plan = _plan(a, b, rival);
        vm.prank(rival);
        vm.expectRevert(MatchRaceGuard.GuardLengthMismatch.selector);
        guarded.settleMatchWithNonces(_hashes(a, b), _zeros(), new address[](1), new uint256[](0), plan);
    }
}

/// @title MatchSolverCrossAudit20260930Test
/// @notice X-DIFF-CORE-1.v1: the `filled` guard cannot see a {Proportional}
///         anchor drained from the maker's wallet, nor a plan that swept less than
///         it was priced for. {GuardedMatchSolver.settleMatchChecked} catches both.
contract MatchSolverCrossAudit20260930Test is MatchRaceGuardTest {
    function _anchor(uint256 minBal) internal view returns (MatchRaceGuard.AnchorCheck[] memory a) {
        a = new MatchRaceGuard.AnchorCheck[](1);
        a[0] = MatchRaceGuard.AnchorCheck({maker: maker, token: WETH, minBalance: minBal});
    }

    function _floor(uint256 min) internal view returns (MatchRaceGuard.SweptFloor[] memory f) {
        f = new MatchRaceGuard.SweptFloor[](1);
        f[0] = MatchRaceGuard.SweptFloor({token: USDC, min: min});
    }

    function _g(bytes32[] memory h, MatchRaceGuard.AnchorCheck[] memory a, MatchRaceGuard.SweptFloor[] memory f)
        internal
        pure
        returns (GuardedMatchSolver.CheckedGuard memory)
    {
        return GuardedMatchSolver.CheckedGuard({orderHashes: h, expectedFilled: _zeros(), anchors: a, minSwept: f});
    }

    function test_audit_X_DIFF_CORE_1_v1_drainedAnchorRevertsBeforeThePlan() public {
        (Order memory a, Order memory b) = _orders();
        MatchPlan memory plan = _plan(a, b, rival);
        bytes32[] memory hashes = _hashes(a, b);
        // The maker drains half the anchor after simulation; `filled` is untouched.
        vm.prank(maker);
        IERC20(WETH).transfer(address(0xdead), WETH_AMT / 2);
        assertEq(settlement.filled(hashes[0]), 0, "the filled guard is blind to it");

        vm.prank(rival);
        vm.expectRevert(
            abi.encodeWithSelector(MatchRaceGuard.AnchorShrunk.selector, uint256(0), WETH_AMT, WETH_AMT / 2)
        );
        guarded.settleMatchChecked(_g(hashes, _anchor(WETH_AMT), _floor(0)), plan);
        assertEq(IERC20(USDC).balanceOf(rival), 0, "nothing settled");
    }

    function test_audit_X_DIFF_CORE_1_v1_sweptFloorEnforced() public {
        (Order memory a, Order memory b) = _orders();
        MatchPlan memory plan = _plan(a, b, rival);
        bytes32[] memory hashes = _hashes(a, b);
        vm.prank(rival);
        vm.expectRevert(abi.encodeWithSelector(MatchRaceGuard.SweptShort.selector, USDC, EDGE + 1, EDGE));
        guarded.settleMatchChecked(_g(hashes, _anchor(WETH_AMT), _floor(EDGE + 1)), plan);

        vm.prank(rival);
        guarded.settleMatchChecked(_g(hashes, _anchor(WETH_AMT), _floor(EDGE)), plan);
        assertEq(IERC20(USDC).balanceOf(rival), EDGE, "an intact plan settles through the checks");
    }
}
