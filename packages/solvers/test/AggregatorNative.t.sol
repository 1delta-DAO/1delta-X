// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Order, LegOut} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {
    AggregatorFillSolver,
    RoutePlan,
    SurplusPolicy,
    NO_PATCH,
    POOL_ROUTE,
    Permit2612,
    PoolVenue
} from "@solvers/aggregator/AggregatorFillSolver.sol";
import {NativeBalance} from "@periphery/NativeBalance.sol";

import {MockRouter} from "./AggregatorFillSolver.t.sol";
import {AggregatorPoolRouteTest, MockV3Pool} from "./AggregatorPoolRoute.t.sol";
import {newAggNative} from "./shared/AggDeploy.sol";

/// @dev WETH9-shaped wrapped native: `withdraw` pays with `transfer` (2,300 gas stipend),
///      exactly like WETH9 / Rootstock's WRBTC, so the solver's `receive()` is held to
///      the real budget. `mint` = deposit on behalf of `to`, backed by dealt native.
contract MockWNative {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 wad) external {
        require(balanceOf[msg.sender] >= wad, "wnative: balance");
        balanceOf[msg.sender] -= wad;
        payable(msg.sender).transfer(wad);
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        require(balanceOf[msg.sender] >= a, "wnative: balance");
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        require(balanceOf[from] >= a, "wnative: balance");
        if (from != msg.sender && allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= a;
        }
        balanceOf[from] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// @dev A smart-account recipient. `mode` 0 accepts; 1 reverts; 2 spends half of what
///      it receives inside `receive()`; 3 tries to re-enter the solver as an OPERATOR
///      (its {sweep}) and records the revert selector.
contract NativeRecipient {
    uint256 public mode;
    bytes4 public reentryError;
    AggregatorFillSolver public solver;

    function set(uint256 m, AggregatorFillSolver s) external {
        (mode, solver) = (m, s);
    }

    receive() external payable {
        if (mode == 1) revert("no native");
        if (mode == 2) payable(address(0xB0B)).transfer(msg.value / 2);
        if (mode == 3) {
            try solver.sweep(address(0), address(this), 0) {
                reentryError = bytes4(0xffffffff);
            } catch (bytes memory err) {
                reentryError = bytes4(err);
            }
        }
    }
}

/// @title AggregatorNativeTest
/// @notice Task 30 / solver v3 — NATIVE DELIVERY on DIRECT orders through the
///         {NativeBalance} view token: the maker signs `legsOut[0] = {NativeBalance,
///         amount, recipient}` with the delta-verify bit and this solver as exclusive
///         filler; the route ends in WNATIVE paid to the solver, which unwraps EXACTLY
///         the core's `pricedOut[0]` and sends it on; the core verifies the recipient's
///         native balance rose. Zero inventory, no item, no Settlement change. Against
///         the real Settlement + Permit3 from core.
contract AggregatorNativeTest is AggregatorPoolRouteTest {
    MockWNative wn;
    NativeBalance nb;
    AggregatorFillSolver ns; // the native-enabled instance
    MockRouter wnRouter; // tA -> WNATIVE opaque route
    MockV3Pool poolAW; // tA/WNATIVE on venue 0

    function setUp() public virtual override {
        super.setUp();
        wn = new MockWNative();
        nb = new NativeBalance();
        ns = newAggNative(address(settlement), _ops(), _noSplit(), _venues(), address(nb), address(wn));
        vm.label(address(ns), "nativeSolver");
        wnRouter = new MockRouter(address(tA), address(wn));
        _fundWn(address(wnRouter), 1_000e18);
        poolAW = fac0.createPool(address(tA), address(wn), F500);
        tA.mint(address(poolAW), 1_000e18);
        _fundWn(address(poolAW), 1_000e18);
    }

    function _fundWn(address to, uint256 amt) internal {
        vm.deal(address(this), amt);
        wn.deposit{value: amt}();
        wn.transfer(to, amt);
    }

    /// @dev Sell AMOUNT_IN tA for AMOUNT_OUT native, DIRECT, exclusive to `s`.
    function _nativeOrder(uint256 nonce, address recipient, AggregatorFillSolver s)
        internal
        view
        returns (Order memory o)
    {
        o = _blank(nonce);
        o.legsIn = _legsIn1(address(tA), AMOUNT_IN);
        o.legsOut = PackedEncode.oneLegOut(address(nb), AMOUNT_OUT, 0, recipient);
        o.timing |= uint256(1) << 104;
        o.exclusiveFiller = address(s);
    }

    /// @dev An opaque exact-input route tA -> WNATIVE paying the SOLVER.
    function _wnPlan(AggregatorFillSolver s, uint256 minOut) internal view returns (RoutePlan memory p) {
        p = _planFor(AMOUNT_IN, address(s), minOut, NO_PATCH);
        p.router = address(wnRouter);
        p.profitRecipient = TREASURY;
    }

    function _fill(Order memory o, RoutePlan memory p) internal {
        bytes memory sig = _sign(o);
        ns.executeFill(o, sig, AMOUNT_IN, p, "", _np());
    }

    // ════════════════════════ the happy paths ════════════════════════

    /// Opaque exact-input route: the maker receives EXACTLY the priced native amount,
    /// the WNATIVE spread (10e18) goes to the profit recipient less the self-seeded wei,
    /// and the solver ends holding no native and only that wei of WNATIVE.
    function test_native_opaqueExactIn_makerGetsRawNative() public {
        uint256 before = maker.balance;
        _fill(_nativeOrder(1, address(0), ns), _wnPlan(ns, AMOUNT_OUT));
        assertEq(maker.balance - before, AMOUNT_OUT, "raw native, exactly the priced amount");
        assertEq(wn.balanceOf(maker), 0, "nothing left wrapped at the maker");
        assertEq(wn.balanceOf(TREASURY), AMOUNT_IN - AMOUNT_OUT - 1, "WNATIVE spread split to the filler");
        assertEq(wn.balanceOf(address(ns)), 1, "only the self-seeded WNATIVE floor");
        assertEq(address(ns).balance, 0, "the solver keeps no native");
        assertEq(tA.balanceOf(address(ns)), 0, "zero inventory");
        assertEq(settlement.filled(_hashOrder(_nativeOrder(1, address(0), ns))), AMOUNT_IN, "filled");
    }

    /// Opaque exact-OUTPUT route with `amountOutOffset`: the word is patched with the
    /// live `pricedOut[0]`, so the route produces exactly the native leg and the
    /// spread stays in the INPUT token.
    function test_native_opaqueExactOut_patched() public {
        RoutePlan memory p = _exactOutPlan(1, AMOUNT_IN, address(ns)); // word patched below
        p.router = address(wnRouter);
        p.amountOutOffset = 4;
        p.profitRecipient = TREASURY;
        uint256 before = maker.balance;
        _fill(_nativeOrder(2, address(0), ns), p);
        assertEq(maker.balance - before, AMOUNT_OUT, "maker paid the live tick");
        assertEq(wn.balanceOf(address(ns)), 0, "no WNATIVE spread on an exact-output route");
        assertEq(tA.balanceOf(TREASURY), AMOUNT_IN - AMOUNT_OUT - 1, "the spread is input residue (seeded)");
    }

    /// DIRECT POOL ROUTE: the last hop pays THE SOLVER (not the leg's recipient), the
    /// unwrap sends the coin on. Exact-output, patched.
    function test_native_poolRoute_exactOut() public {
        _rate(poolAW, address(tA), 10_000);
        RoutePlan memory p =
            _poolPlan(_hop1(address(tA), F500, 0, address(wn)), AMOUNT_IN, 1, 0, 32, 0);
        uint256 before = maker.balance;
        _fill(_nativeOrder(3, address(0), ns), p);
        assertEq(maker.balance - before, AMOUNT_OUT, "pool route delivered native");
        assertEq(wn.balanceOf(address(ns)), 0, "the hop paid the solver, which unwrapped all of it");
        assertEq(tA.balanceOf(TREASURY), AMOUNT_IN - AMOUNT_OUT - 1, "input residue split (seeded)");
        assertEq(tA.balanceOf(address(ns.SANDBOX())), 0, "no sandbox on a pool route");
    }

    /// Exact-input pool route: the WNATIVE surplus over the priced leg stays and is split.
    function test_native_poolRoute_exactIn() public {
        _rate(poolAW, address(tA), 9_500);
        RoutePlan memory p = _poolPlan(_hop1(address(tA), F500, 0, address(wn)), AMOUNT_IN, 0, 0, NO_PATCH, 0);
        uint256 before = maker.balance;
        _fill(_nativeOrder(4, address(0), ns), p);
        assertEq(maker.balance - before, AMOUNT_OUT);
        assertEq(wn.balanceOf(TREASURY), 95e18 - AMOUNT_OUT - 1, "WNATIVE spread to the filler");
    }

    /// The leg's own recipient (a smart account) is paid — from the ORDER, never the plan.
    function test_native_paysLegRecipient() public {
        NativeRecipient rcpt = new NativeRecipient();
        _fill(_nativeOrder(5, address(rcpt), ns), _wnPlan(ns, 0));
        assertEq(address(rcpt).balance, AMOUNT_OUT, "smart-account recipient got the coin");
    }

    /// A surplus policy splits the WNATIVE spread exactly as any output surplus.
    function test_native_surplusPolicySplitsInWNative() public {
        SurplusPolicy memory pol = SurplusPolicy({makerPpm: 500_000, protocolPpm: 0, protocolRecipient: address(0)});
        AggregatorFillSolver s = newAggNative(address(settlement), _ops(), pol, _venues(), address(nb), address(wn));
        Order memory o = _nativeOrder(6, address(0), s);
        bytes memory sig = _sign(o);
        s.executeFill(o, sig, AMOUNT_IN, _wnPlan(s, 0), "", _np());
        assertEq(maker.balance, AMOUNT_OUT, "native leg");
        assertEq(wn.balanceOf(maker), 5e18, "half the 10e18 WNATIVE spread back to the maker");
        assertEq(wn.balanceOf(TREASURY), 5e18 - 1, "the filler's half, less the self-seeded wei");
    }

    // ════════════════════════ solver-side bounds (WNATIVE) ════════════════════════

    function test_native_minOutMeasuredInWNative() public {
        Order memory o = _nativeOrder(7, address(0), ns);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _wnPlan(ns, AMOUNT_IN + 1);
        vm.expectRevert(
            _wrapped(abi.encodeWithSelector(AggregatorFillSolver.InsufficientOutput.selector, AMOUNT_IN, AMOUNT_IN + 1))
        );
        ns.executeFill(o, sig, AMOUNT_IN, p, "", _np());
    }

    function test_native_maxPayCapsTheSend() public {
        Order memory o = _nativeOrder(8, address(0), ns);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _wnPlan(ns, 0);
        p.maxPay = AMOUNT_OUT - 1;
        vm.expectRevert(
            _wrapped(abi.encodeWithSelector(AggregatorFillSolver.InsufficientOutput.selector, AMOUNT_OUT - 1, AMOUNT_OUT))
        );
        ns.executeFill(o, sig, AMOUNT_IN, p, "", _np());
    }

    /// A route that produced too little WNATIVE cannot be topped up from what the
    /// solver already holds: the send is bounded by THIS fill's delta.
    function test_native_cannotSpendParkedWNative() public {
        _fundWn(address(ns), 50e18); // retained / donated WNATIVE
        wnRouter.setRate(5_000); // 50e18 out, the leg needs 90e18
        Order memory o = _nativeOrder(9, address(0), ns);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _wnPlan(ns, 0);
        vm.expectRevert(
            _wrapped(abi.encodeWithSelector(AggregatorFillSolver.InsufficientOutput.selector, 50e18, AMOUNT_OUT))
        );
        ns.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        assertEq(wn.balanceOf(address(ns)), 50e18, "parked WNATIVE untouched");
    }

    // ════════════════════════ fail-closed shapes ════════════════════════

    /// A PULL (non-direct) native leg is refused before the route runs.
    function test_native_pullOrderRefused() public {
        Order memory o = _nativeOrder(10, address(0), ns);
        o.timing &= ~(uint256(1) << 104);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _wnPlan(ns, 0);
        vm.expectRevert(AggregatorFillSolver.NativeLegShape.selector);
        ns.executeFill(o, sig, AMOUNT_IN, p, "", _np());
    }

    /// WNATIVE or NativeBalance named by another leg is refused.
    function test_native_conflictingLegsRefused() public {
        LegOut[] memory lo = new LegOut[](2);
        lo[0] = LegOut(address(nb), AMOUNT_OUT, 0, address(0));
        lo[1] = LegOut(address(wn), 1e18, 0, address(0xFEE));
        Order memory o = _nativeOrder(11, address(0), ns);
        o.legsOut = PackedEncode.legsOut(lo);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _wnPlan(ns, 0);
        vm.expectRevert(AggregatorFillSolver.NativeLegShape.selector);
        ns.executeFill(o, sig, AMOUNT_IN, p, "", _np());

        lo[1] = LegOut(address(nb), 1e18, 0, address(0xFEE));
        o = _nativeOrder(12, address(0), ns);
        o.legsOut = PackedEncode.legsOut(lo);
        sig = _sign(o);
        vm.expectRevert(AggregatorFillSolver.NativeLegShape.selector);
        ns.executeFill(o, sig, AMOUNT_IN, p, "", _np());

        o = _nativeOrder(13, address(0), ns);
        o.legsIn = _legsIn1(address(wn), AMOUNT_IN);
        sig = _sign(o);
        vm.expectRevert(AggregatorFillSolver.NativeLegShape.selector);
        ns.executeFill(o, sig, AMOUNT_IN, p, "", _np());
    }

    /// Review 2026-10-14 L-1: a second native VIEW (another `NativeBalance` deployment,
    /// a different address over the same `a.balance` ledger) to the same recipient
    /// would be satisfied by the one native send — the core's duplicate-leg guard keys on
    /// the token address. Any other output leg to the native recipient is refused; a
    /// leg to someone else (a fee) is not.
    function test_native_secondLegToSameRecipientRefused() public {
        NativeBalance nb2 = new NativeBalance();
        LegOut[] memory lo = new LegOut[](2);
        lo[0] = LegOut(address(nb), AMOUNT_OUT, 0, address(0));
        lo[1] = LegOut(address(nb2), 10e18, 0, address(0));
        Order memory o = _nativeOrder(15, address(0), ns);
        o.legsOut = PackedEncode.legsOut(lo);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _wnPlan(ns, 0);
        vm.expectRevert(AggregatorFillSolver.NativeLegShape.selector);
        ns.executeFill(o, sig, AMOUNT_IN, p, "", _np());

        lo[1] = LegOut(address(nb2), 10e18, 0, maker); // the maker named explicitly
        o = _nativeOrder(16, address(0), ns);
        o.legsOut = PackedEncode.legsOut(lo);
        sig = _sign(o);
        vm.expectRevert(AggregatorFillSolver.NativeLegShape.selector);
        ns.executeFill(o, sig, AMOUNT_IN, p, "", _np());
    }

    /// A NativeBalance leg that is not leg 0 is not delivered natively: the core's delta
    /// check fails closed.
    function test_native_onlyLegZero() public {
        LegOut[] memory lo = new LegOut[](2);
        lo[0] = LegOut(address(tB), 1e18, 0, address(0));
        lo[1] = LegOut(address(nb), AMOUNT_OUT, 0, address(0));
        Order memory o = _nativeOrder(14, address(0), ns);
        o.legsOut = PackedEncode.legsOut(lo);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _wnPlan(ns, 0);
        vm.expectRevert();
        ns.executeFill(o, sig, AMOUNT_IN, p, "", _np());
    }

    /// An instance with native delivery OFF treats the view token as an ordinary output
    /// token: nothing pays it, and the core's delta check reverts.
    function test_native_featureOffFailsClosed() public {
        Order memory o = _nativeOrder(15, address(0), aggSolver);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _wnPlan(aggSolver, 0);
        p.data = abi.encodeCall(MockRouter.swap, (AMOUNT_IN, maker)); // even paying WNATIVE to the maker
        vm.expectRevert(Base.DeltaTooLow.selector);
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
    }

    /// The netted path cannot delta-verify: refused up front.
    function test_native_itemFillRefused() public {
        Order memory o = _nativeOrder(16, address(0), ns);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _wnPlan(ns, 0);
        vm.expectRevert(AggregatorFillSolver.DirectNotMatchable.selector);
        ns.executeItemFill(o, sig, AMOUNT_IN, p, "", 0, _np());
    }

    /// A recipient whose `receive()` reverts kills the fill (NativeUnwrapModule's posture).
    function test_native_revertingRecipientKillsFill() public {
        NativeRecipient rcpt = new NativeRecipient();
        rcpt.set(1, ns);
        Order memory o = _nativeOrder(17, address(rcpt), ns);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _wnPlan(ns, 0);
        vm.expectRevert(_wrapped(abi.encodeWithSelector(AggregatorFillSolver.NativeSendFailed.selector, address(rcpt))));
        ns.executeFill(o, sig, AMOUNT_IN, p, "", _np());
    }

    /// A recipient that spends native inside `receive()` lowers its own measured delta.
    function test_native_spendingRecipientFailsDeltaCheck() public {
        NativeRecipient rcpt = new NativeRecipient();
        rcpt.set(2, ns);
        Order memory o = _nativeOrder(18, address(rcpt), ns);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _wnPlan(ns, 0);
        vm.expectRevert(Base.DeltaTooLow.selector);
        ns.executeFill(o, sig, AMOUNT_IN, p, "", _np());
    }

    /// Re-entry from the recipient finds every entry closed — even as an OPERATOR.
    function test_native_recipientReentryBlocked() public {
        NativeRecipient rcpt = new NativeRecipient();
        address[] memory ops = new address[](2);
        (ops[0], ops[1]) = (address(this), address(rcpt));
        AggregatorFillSolver s = newAggNative(address(settlement), ops, _noSplit(), _venues(), address(nb), address(wn));
        rcpt.set(3, s);
        Order memory o = _nativeOrder(19, address(rcpt), s);
        bytes memory sig = _sign(o);
        s.executeFill(o, sig, AMOUNT_IN, _wnPlan(s, 0), "", _np());
        assertEq(address(rcpt).balance, AMOUNT_OUT, "paid");
        assertEq(rcpt.reentryError(), AggregatorFillSolver.Reentrancy.selector, "sweep re-entry refused");
    }

    /// `receive()` accepts WNATIVE's unwrap only.
    function test_native_receiveOnlyFromWNative() public {
        vm.deal(address(this), 1 ether);
        (bool ok, bytes memory ret) = address(ns).call{value: 1}("");
        assertFalse(ok);
        assertEq(bytes4(ret), AggregatorFillSolver.NotWNative.selector);
        (ok,) = address(aggSolver).call{value: 1}(""); // native off: nothing accepted
        assertFalse(ok);
    }

    function test_native_constructorPairing() public {
        vm.expectRevert(AggregatorFillSolver.BadNative.selector);
        new AggregatorFillSolver(address(settlement), _ops(), _noSplit(), new PoolVenue[](0), address(nb), address(0));
        vm.expectRevert(AggregatorFillSolver.BadNative.selector);
        new AggregatorFillSolver(address(settlement), _ops(), _noSplit(), new PoolVenue[](0), address(0), address(wn));
        vm.expectRevert(AggregatorFillSolver.BadNative.selector);
        new AggregatorFillSolver(address(settlement), _ops(), _noSplit(), new PoolVenue[](0), address(wn), address(wn));
        (address a, address b) = ns.nativeDelivery();
        assertEq(a, address(nb));
        assertEq(b, address(wn));
        (a, b) = aggSolver.nativeDelivery();
        assertEq(a, address(0));
        assertEq(b, address(0));
    }

    // ════════════════════════ gas (read the DIFFERENCE) ════════════════════════
    //
    // Same floors as the pool-route unit benches; the maker already holds native (an
    // EMPTY recipient account pays the EVM's +25k new-account charge on top).

    function _nativeFloors(AggregatorFillSolver s) internal {
        tA.mint(address(s), 1);
        tB.mint(address(s), 1);
        _fundWn(address(s), 1);
        tB.mint(maker, 1);
        vm.deal(maker, 1);
        tA.mint(TREASURY, 1);
        tB.mint(TREASURY, 1);
        _fundWn(TREASURY, 1);
        vm.prank(address(s.SANDBOX()));
        tA.approve(address(router), type(uint256).max);
    }

    /// The plain direct pool fill, typed (`amountOutOffset = 32`), on the same instance —
    /// the baseline the native fill is compared with (a native fill is always typed).
    function test_gas_native_baseline_directPoolTyped() public {
        _nativeFloors(ns);
        Order memory o = _directOrder(1);
        o.exclusiveFiller = address(ns);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _poolPlan(_hop1(address(tA), F500, 0, address(tB)), AMOUNT_IN, AMOUNT_OUT, 0, 32, 0);
        uint256 g0 = gasleft();
        ns.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        emit log_named_uint("unit: POOL direct exact-out, typed ", g0 - gasleft());
    }

    function test_gas_native_directPool() public {
        _nativeFloors(ns);
        _rate(poolAW, address(tA), 9_000);
        Order memory o = _nativeOrder(1, address(0), ns);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _poolPlan(_hop1(address(tA), F500, 0, address(wn)), AMOUNT_IN, AMOUNT_OUT, 0, 32, 0);
        uint256 g0 = gasleft();
        ns.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        emit log_named_uint("unit: POOL direct exact-out, NATIVE", g0 - gasleft());
        assertEq(maker.balance, AMOUNT_OUT + 1);
    }

    function test_gas_native_directPool_emptyMaker() public {
        _nativeFloors(ns);
        vm.deal(maker, 0);
        _rate(poolAW, address(tA), 9_000);
        Order memory o = _nativeOrder(1, address(0), ns);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _poolPlan(_hop1(address(tA), F500, 0, address(wn)), AMOUNT_IN, AMOUNT_OUT, 0, 32, 0);
        uint256 g0 = gasleft();
        ns.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        emit log_named_uint("unit: POOL direct, NATIVE, empty maker", g0 - gasleft());
    }
}
