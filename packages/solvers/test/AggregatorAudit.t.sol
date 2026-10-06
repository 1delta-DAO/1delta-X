// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Order, LegIn} from "@core/settlement/Settlement.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {SolverCallbackExecutor} from "@core/settlement/SolverCallbackExecutor.sol";
import {
    AggregatorFillSolver,
    RoutePlan,
    FillRoute,
    SurplusPolicy,
    NO_PATCH
} from "@solvers/aggregator/AggregatorFillSolver.sol";
import {FillRecovery} from "@solvers/aggregator/FillRecovery.sol";

import {MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";
import {AggregatorFillSolverTest, MockRouter} from "./AggregatorFillSolver.t.sol";
import {RecoveringSolver} from "./FillRecovery.t.sol";

/// @dev Pays TWO output tokens from one input — a multicall-shaped route, the
///      only way one router call can fund an order whose output legs span tokens.
contract TwoOutRouter {
    address public immutable TOKEN_IN;
    address public immutable OUT_1;
    address public immutable OUT_2;
    uint256 public immutable OUT_2_AMOUNT;

    constructor(address tokenIn, address out1, address out2, uint256 out2Amount) {
        (TOKEN_IN, OUT_1, OUT_2, OUT_2_AMOUNT) = (tokenIn, out1, out2, out2Amount);
    }

    function swap(uint256 amountIn, address recipient) external {
        SafeTransferLib.safeTransferFrom(TOKEN_IN, msg.sender, address(this), amountIn);
        SafeTransferLib.safeTransfer(OUT_1, recipient, amountIn);
        SafeTransferLib.safeTransfer(OUT_2, recipient, OUT_2_AMOUNT);
    }
}

/// @dev A router that diverts part of the output to a caller-chosen address — the
///      `multicall` recipient split AGG-3 describes. Pins the documented limit.
contract DivertRouter {
    address public immutable TOKEN_IN;
    address public immutable TOKEN_OUT;

    constructor(address tokenIn, address tokenOut) {
        (TOKEN_IN, TOKEN_OUT) = (tokenIn, tokenOut);
    }

    function swapSplit(uint256 amountIn, address recipient, address divertTo, uint256 divert) external {
        SafeTransferLib.safeTransferFrom(TOKEN_IN, msg.sender, address(this), amountIn);
        SafeTransferLib.safeTransfer(TOKEN_OUT, divertTo, divert);
        SafeTransferLib.safeTransfer(TOKEN_OUT, recipient, amountIn - divert);
    }
}

/// @dev A router that tries to re-enter the solver mid-route, recording what happened.
contract ReentrantRouter {
    address public immutable TOKEN_IN;
    address public immutable TOKEN_OUT;
    address public target;
    bytes public reentry;
    bool public reentrySucceeded;
    bytes public reentryRevert;

    constructor(address tokenIn, address tokenOut) {
        (TOKEN_IN, TOKEN_OUT) = (tokenIn, tokenOut);
    }

    function arm(address _target, bytes calldata _reentry) external {
        (target, reentry) = (_target, _reentry);
    }

    function swap(uint256 amountIn, address recipient) external {
        SafeTransferLib.safeTransferFrom(TOKEN_IN, msg.sender, address(this), amountIn);
        (bool ok, bytes memory ret) = target.call(reentry);
        reentrySucceeded = ok;
        reentryRevert = ret;
        SafeTransferLib.safeTransfer(TOKEN_OUT, recipient, amountIn);
    }
}

/// @dev An output token whose `transfer` (the surplus split pays the filler with
///      it, AFTER Settlement unlocked) re-enters `executeFill` once.
contract SplitHookToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public target;
    bytes public reentry;
    bool public armed;
    bool public reentrySucceeded;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function arm(address _target, bytes calldata _reentry) external {
        (target, reentry, armed) = (_target, _reentry, true);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        // Only the solver's own payout (the split) — not the router paying the
        // solver mid-route, while Settlement is still locked.
        if (armed && msg.sender == target) {
            armed = false;
            (bool ok,) = target.call(reentry);
            reentrySucceeded = ok;
        }
        return true;
    }
}

/// @title AggregatorAudit20260930Test
/// @notice Regression tests for the 2026-09-30 audit findings on
///         {AggregatorFillSolver} and {FillRecovery}: AGG-1 (retain mode with no way
///         out), AGG-2 (non-anchor input legs stranded), AGG-3 (policy on an open
///         instance), AGG-6 (one output token on the pull path), AGG-7 (FillRecovery
///         and the any-size sentinel) and the AGG-8 test gaps (reentrancy from the
///         route and from the split, same-token orders, the diversion limit).
contract AggregatorAudit20260930Test is AggregatorFillSolverTest {
    function _gated(SurplusPolicy memory policy) internal returns (AggregatorFillSolver g) {
        address[] memory ops = new address[](1);
        ops[0] = address(this);
        g = new AggregatorFillSolver(address(settlement), ops, policy);
    }

    // ═══════════════════════════ AGG-1 ═══════════════════════════

    // AGG-1: retain mode on an open instance parked value no function could move
    // again. `test_audit_AGG_1_retainRefusedOnOpenInstance` pinned the refusal; it
    // was deleted in 2026-10 with the open mode itself ({NoOperators}).

    /// AGG-1: on a gated instance the retained spread comes back out through the
    /// operators' `sweep` — the exit the NatSpec promised and did not exist.
    function test_audit_AGG_1_gatedRetainIsRecoverableBySweep() public {
        AggregatorFillSolver g = _gated(_noSplit());
        Order memory o = _order(901);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _planFor(AMOUNT_IN, address(g), AMOUNT_OUT, NO_PATCH);
        p.profitRecipient = address(g);
        g.executeFill(o, sig, AMOUNT_IN, p, "");
        uint256 retained = tB.balanceOf(address(g));
        assertEq(retained, AMOUNT_IN - AMOUNT_OUT, "spread retained");

        vm.prank(address(0xD00D));
        vm.expectRevert(abi.encodeWithSelector(AggregatorFillSolver.NotOperator.selector, address(0xD00D)));
        g.sweep(address(tB), address(0xD00D), retained);

        address treasury = address(0x7EA5);
        g.sweep(address(tB), treasury, retained - 1); // keep a 1-wei floor
        assertEq(tB.balanceOf(treasury), retained - 1, "operator recovered the retained spread");
        assertEq(tB.balanceOf(address(g)), 1, "dust floor kept");
    }

    /// AGG-1: only operators sweep. (Was `…_sweepRefusedOnOpenInstance`; there are
    /// no open instances since 2026-10, so it now pins the non-operator refusal.)
    function test_audit_AGG_1_sweepRefusedForNonOperator() public {
        tB.mint(address(aggSolver), 1e18);
        vm.prank(address(0xD00D));
        vm.expectRevert(abi.encodeWithSelector(AggregatorFillSolver.NotOperator.selector, address(0xD00D)));
        aggSolver.sweep(address(tB), address(0xD00D), 1e18);
    }

    // ═══════════════════════════ AGG-2 ═══════════════════════════

    /// AGG-2: a second input leg in a third token used to be paid here and never
    /// looked at again. It is measured and split like any other residue now.
    function test_audit_AGG_2_nonAnchorInputLegIsNotStranded() public {
        uint256 extra = 5e18;
        tC.mint(maker, extra);
        _makerApprove(address(settlement), address(tC), type(uint160).max);
        LegIn[] memory legsIn = new LegIn[](2);
        legsIn[0] = LegIn(address(tA), AMOUNT_IN, 0);
        legsIn[1] = LegIn(address(tC), extra, 0);
        Order memory o = _order(902);
        o.legsIn = PackedEncode.legsIn(legsIn);
        bytes memory sig = _sign(o);

        aggSolver.executeFill(o, sig, AMOUNT_IN, _plan(address(aggSolver), AMOUNT_OUT), "");

        assertEq(tC.balanceOf(address(aggSolver)), 0, "no third-token input stranded on the solver");
        assertEq(tC.balanceOf(address(this)), extra, "it reached the filler as residue");
    }

    // ═══════════════════════════ AGG-6 ═══════════════════════════

    /// AGG-6: the pull path approved Settlement for `legsOut[0]`'s token only, so an
    /// order with an output leg in a second token always failed. Every output token
    /// is approved at its own measured proceeds now, and its surplus is split.
    function test_audit_AGG_6_pullPathFundsEveryOutputToken() public {
        TwoOutRouter r2 = new TwoOutRouter(address(tA), address(tB), address(tC), 3e18);
        tB.mint(address(r2), 1_000e18);
        tC.mint(address(r2), 1_000e18);
        AggregatorFillSolver s = new AggregatorFillSolver(address(settlement), _ops(), _noSplit());

        address[] memory outs = new address[](2);
        (outs[0], outs[1]) = (address(tB), address(tC));
        uint256[] memory amts = new uint256[](2);
        (amts[0], amts[1]) = (AMOUNT_OUT, 2e18);
        Order memory o = _plainOrderMultiOut(903, address(tA), AMOUNT_IN, outs, amts);
        bytes memory sig = _sign(o);
        RoutePlan memory p = RoutePlan({
            router: address(r2),
            minOut: AMOUNT_OUT,
            maxPay: 0,
            amountInOffset: NO_PATCH,
            amountOutOffset: NO_PATCH,
            minBumpBps: 0,
            profitRecipient: address(0),
            originator: address(0),
            originatorPpm: 0,
            data: abi.encodeCall(TwoOutRouter.swap, (AMOUNT_IN, address(s)))
        });
        s.executeFill(o, sig, AMOUNT_IN, p, "");

        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "leg 0 delivered");
        assertEq(tC.balanceOf(maker), 2e18, "leg 1 (second token) delivered");
        assertEq(tC.balanceOf(address(this)), 1e18, "second-token surplus split to the filler");
        assertEq(tC.balanceOf(address(s)), 0, "nothing left behind");
        assertEq(tC.allowance(address(s), address(settlement)), 0, "no approval outlived the fill");
    }

    // ═══════════════════════════ AGG-3 ═══════════════════════════

    /// AGG-3: an open caller writes the route and can keep the spread from ever
    /// reaching the split, so a non-zero policy needed operators. Since 2026-10 every
    /// instance does: no policy, zero or not, deploys without an operator set.
    function test_audit_AGG_3_noInstanceWithoutOperators() public {
        vm.expectRevert(AggregatorFillSolver.NoOperators.selector);
        new AggregatorFillSolver(address(settlement), new address[](0), SurplusPolicy({makerPpm: 1, protocolPpm: 0, protocolRecipient: address(0)}));
        vm.expectRevert(AggregatorFillSolver.NoOperators.selector);
        new AggregatorFillSolver(address(settlement), new address[](0), _noSplit());
        assertTrue(new AggregatorFillSolver(address(settlement), _ops(), _noSplit()).GATED());
    }

    /// AGG-3 / AGG-8: pin the documented limit — the policy binds only the spread
    /// that reaches the contract. A diverting route (an operator-tier choice on a
    /// gated instance) moves part of it elsewhere and the shares apply to the rest.
    function test_audit_AGG_3_policyBindsOnlyTheSpreadThatArrives() public {
        DivertRouter dr = new DivertRouter(address(tA), address(tB));
        tB.mint(address(dr), 1_000e18);
        AggregatorFillSolver g =
            _gated(SurplusPolicy({makerPpm: 500_000, protocolPpm: 0, protocolRecipient: address(0)}));
        Order memory o = _order(904);
        bytes memory sig = _sign(o);
        address divertTo = address(0xD1);
        RoutePlan memory p = RoutePlan({
            router: address(dr),
            minOut: AMOUNT_OUT,
            maxPay: 0,
            amountInOffset: NO_PATCH,
            amountOutOffset: NO_PATCH,
            minBumpBps: 0,
            profitRecipient: address(0),
            originator: address(0),
            originatorPpm: 0,
            data: abi.encodeCall(DivertRouter.swapSplit, (AMOUNT_IN, address(g), divertTo, 6e18))
        });
        uint256 makerBefore = tB.balanceOf(maker);
        g.executeFill(o, sig, AMOUNT_IN, p, "");
        // Spread 10e18: 6e18 diverted, 4e18 arrived → the maker's 50% is of 4e18 only.
        assertEq(tB.balanceOf(divertTo), 6e18, "diverted outside the split");
        assertEq(tB.balanceOf(maker) - makerBefore, AMOUNT_OUT + 2e18, "maker's share of what arrived");
    }

    // ═══════════════════════════ AGG-8 ═══════════════════════════

    /// AGG-8: a router that re-enters `executeFill` mid-route is refused (the
    /// settler is locked and the solver is mid-fill), and the outer fill completes.
    /// The router is listed as an OPERATOR (a contract operator), so the re-entry
    /// passes the operator gate and reaches the reentrancy guard it pins.
    function test_audit_AGG_8_reentrantRouterCannotNestAFill() public {
        ReentrantRouter rr = new ReentrantRouter(address(tA), address(tB));
        tB.mint(address(rr), 1_000e18);
        address[] memory ops = new address[](2);
        (ops[0], ops[1]) = (address(this), address(rr));
        AggregatorFillSolver s = new AggregatorFillSolver(address(settlement), ops, _noSplit());

        Order memory inner = _order(906);
        bytes memory innerSig = _sign(inner);
        RoutePlan memory innerPlan = _planFor(AMOUNT_IN, address(s), AMOUNT_OUT, NO_PATCH);
        innerPlan.router = address(rr);
        rr.arm(
            address(s), abi.encodeCall(AggregatorFillSolver.executeFill, (inner, innerSig, AMOUNT_IN, innerPlan, ""))
        );

        Order memory o = _order(905);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _planFor(AMOUNT_IN, address(s), AMOUNT_OUT, NO_PATCH);
        p.router = address(rr);
        s.executeFill(o, sig, AMOUNT_IN, p, "");

        assertFalse(rr.reentrySucceeded(), "nested fill refused");
        assertEq(bytes4(rr.reentryRevert()), AggregatorFillSolver.Reentrancy.selector, "by the solver's own guard");
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "outer fill completed");
    }

    /// AGG-8: a router that calls `onFill` itself mid-route is refused — only the
    /// EXECUTOR may, and the arming flag is already consumed.
    function test_audit_AGG_8_reentrantOnFillWithinTheFillIsRefused() public {
        ReentrantRouter rr = new ReentrantRouter(address(tA), address(tB));
        tB.mint(address(rr), 1_000e18);
        AggregatorFillSolver s = new AggregatorFillSolver(address(settlement), _ops(), _noSplit());
        FillRoute memory r = _anyRoute();
        r.router = address(rr);
        rr.arm(address(s), abi.encodeCall(AggregatorFillSolver.onFill, (r)));

        Order memory o = _order(907);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _planFor(AMOUNT_IN, address(s), AMOUNT_OUT, NO_PATCH);
        p.router = address(rr);
        s.executeFill(o, sig, AMOUNT_IN, p, "");
        assertFalse(rr.reentrySucceeded(), "onFill not reusable within the fill");
        assertEq(bytes4(rr.reentryRevert()), AggregatorFillSolver.OnlyExecutor.selector, "only the executor");
    }

    /// AGG-8: the surplus split runs AFTER Settlement unlocked, and pays the filler
    /// in the output token — whose code then runs. A hook that re-enters
    /// `executeFill` there used to start a whole nested fill; the solver now holds
    /// its in-fill state through the split and refuses.
    function test_audit_AGG_8_hookTokenCannotReenterDuringTheSplit() public {
        SplitHookToken hook = new SplitHookToken();
        MockRouter rh = new MockRouter(address(tA), address(hook));
        hook.mint(address(rh), 1_000e18);
        // The hook token is an operator (a contract operator), so its re-entry
        // reaches the in-fill state guard rather than stopping at the gate.
        address[] memory ops = new address[](2);
        (ops[0], ops[1]) = (address(this), address(hook));
        AggregatorFillSolver s = new AggregatorFillSolver(address(settlement), ops, _noSplit());

        // The nested fill the hook will try: an ordinary tA→tB order.
        Order memory inner = _order(909);
        bytes memory innerSig = _sign(inner);
        RoutePlan memory innerPlan = _planFor(AMOUNT_IN, address(s), AMOUNT_OUT, NO_PATCH);
        hook.arm(
            address(s), abi.encodeCall(AggregatorFillSolver.executeFill, (inner, innerSig, AMOUNT_IN, innerPlan, ""))
        );

        Order memory o = _plainOrder(908, address(tA), address(hook), AMOUNT_IN, AMOUNT_OUT);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _planFor(AMOUNT_IN, address(s), AMOUNT_OUT, NO_PATCH);
        p.router = address(rh);
        s.executeFill(o, sig, AMOUNT_IN, p, "");

        assertFalse(hook.reentrySucceeded(), "no nested fill during the split");
        assertEq(hook.balanceOf(address(this)), AMOUNT_IN - AMOUNT_OUT, "the outer split still paid the filler");
        assertEq(tB.balanceOf(maker), 0, "the nested order was not filled");
    }

    /// AGG-8: a same-token order (tokenIn == tokenOut) on the pull path — the input
    /// is the output; the route is a no-op and the residue is split once.
    function test_audit_AGG_8_sameTokenPullPathOrder() public {
        Order memory o = _plainOrder(910, address(tA), address(tA), AMOUNT_IN, AMOUNT_OUT);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _planFor(0, address(aggSolver), AMOUNT_OUT, NO_PATCH); // swap(0) — nothing to convert
        uint256 makerBefore = tA.balanceOf(maker);
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "");
        assertEq(makerBefore - tA.balanceOf(maker), AMOUNT_IN - AMOUNT_OUT, "maker paid in, got out, in one token");
        assertEq(tA.balanceOf(address(this)), AMOUNT_IN - AMOUNT_OUT, "spread to the filler once");
        assertEq(tA.balanceOf(address(aggSolver)), 0, "nothing left behind");
    }

    // ═══════════════════════════ AGG-7 ═══════════════════════════

    /// AGG-7: FillRecovery assumed a literal fill size; with the any-size sentinel
    /// `filled - fillAmount` underflowed into a bare panic. It now refuses with a
    /// named error pointing the caller at the resolved-size alternatives.
    function test_audit_AGG_7_fillRecoveryRefusesTheSentinel() public {
        RecoveringSolver rec = new RecoveringSolver(address(settlement));
        tB.mint(address(rec), 1_000e18);
        Order memory o = _order(911);
        bytes memory sig = _sign(o);
        vm.expectRevert(
            abi.encodeWithSelector(
                SolverCallbackExecutor.CallbackFailed.selector,
                abi.encodeWithSelector(FillRecovery.SentinelNotRecoverable.selector)
            )
        );
        rec.fillPostInputs(o, sig, type(uint256).max, address(tB));
    }
}
