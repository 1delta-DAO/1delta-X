// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "@core/settlement/Base.sol";
import {OrderState} from "@core/settlement/OrderState.sol";
import {OrderGates} from "@core/settlement/OrderGates.sol";
import {Signatures} from "@core/settlement/Signatures.sol";
import {Proportional} from "@core/settlement/Proportional.sol";
import {NonceManager} from "@core/settlement/NonceManager.sol";
import {Settlement, Order, MatchPlan, MatchStep, LegIn} from "@core/settlement/Settlement.sol";

import {MockSettlementBase} from "../shared/MockSettlementBase.t.sol";
import {PackedEncode} from "../shared/PackedEncode.sol";

/// @title MatchSettleGatesTest
/// @notice The AUTHORISATION AND LIFECYCLE gate sequence of the netted path,
///         exercised through `matchSettle` itself rather than inferred from the
///         single-order path.
///
///  WHY A WHOLE FILE FOR THIS. `matchSettle` does not share `_fillCore`. Its Phase-1
///  opener, {Batch._openGated}, is a SECOND implementation of the same sequence —
///  zero-fill, delta-verify, expiry, signature/approval, exclusivity, nonce,
///  validators, `_openFill` — written out separately so the netted path can resolve
///  both sides' amounts at open. Every gate is therefore an independent claim, and
///  before this file every one of them was pinned only on the single-order path.
///
///  The argument for why "it's the same code" is not good enough is written at the
///  top of {OrderGates}: when the settler's gates were copied into
///  {SettlementLens}, TWO of the copies had already drifted silently — the lens
///  missed `_anchorTotal`'s empty-blob guard, and its `_verifySignature` copy was
///  STRICTER than the settler's. Neither was a theft path, and that is the point. A
///  gate that disagrees with its twin fails quietly, in whichever direction, and
///  nothing catches it. `_openGated` is a third copy of the same rules.
///
///  Covered here, one gate per test, each with its complement where the complement
///  is what makes the assertion precise:
///
///    • expired · cancelled-by-hash · nonce-cancelled · rolled-back
///    • hard and soft exclusivity, and the nominated filler
///    • the EMPTY-SIG {OrderState.approveOrder} path, and its revocation
///    • fill-once (the nonce-as-progress mode) full and partial
///    • a {Proportional} balance-relative anchor
///    • {Base.DeltaVerifyNotBatchable} — the one deliberate FEATURE exclusion
///    • the derived token universe, which is what makes {Base.TokenNotInUniverse}
///      unreachable
///
///  Deliberately on the mock (non-fork) harness: these are gate assertions, not
///  settlement-economics assertions, and `MatchSettle.t.sol` / `MatchSettleCoW.t.sol`
///  already own the fork-based economics.
/// @dev A CALL-step target that reverts with a custom error carrying arguments — so
///      the assertion can distinguish "the step's target failed" from "the plan was
///      rejected", which look identical to a bare `expectRevert`.
contract PlanCallReverter {
    error RouteWentStale(uint256 code);

    function boom() external pure {
        revert RouteWentStale(7);
    }
}

/// @dev A CALL-step target that re-enters Settlement. The netted path wears
///      `nonReentrant` on `matchSettle` itself, and the CALL step runs deep inside
///      the schedule walk with the pool holding both makers' inputs.
contract PlanCallReenterer {
    Settlement immutable SETTLEMENT;

    constructor(Settlement s) {
        SETTLEMENT = s;
    }

    function reenter() external {
        SETTLEMENT.batchFill(new Order[](0), new bytes[](0), new uint256[](0), false);
    }
}

contract MatchSettleGatesTest is MockSettlementBase {
    uint256 bobPk = 0xB0B;
    address bob = vm.addr(bobPk);

    // Alice sells A_IN of tA for B_OUT of tB; Bob mirrors her exactly, so the two
    // fund each other and the solver needs no inventory at all.
    uint256 constant A_IN = 1_000e18;
    uint256 constant B_OUT = 2_000e18;

    function setUp() public override {
        super.setUp();
        vm.label(bob, "bob");

        tA.mint(maker, A_IN * 10);
        tB.mint(bob, B_OUT * 10);
        _approveFrom(maker, address(tA), A_IN * 10);
        _approveFrom(bob, address(tB), B_OUT * 10);
    }

    /// @dev The base helper pranks the fixed `maker`; the netted path needs a second
    ///      one. FINITE caps, never `uint160.max` — an infinite allowance MASKS every
    ///      question about how much authority a schedule consumed (the F15 lesson).
    function _approveFrom(address who, address token, uint256 cap) internal {
        vm.startPrank(who);
        tA.approve(address(permit3), type(uint256).max);
        tB.approve(address(permit3), type(uint256).max);
        tC.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), token, uint160(cap), 0);
        vm.stopPrank();
    }

    // ──────────────────── builders ────────────────────

    function _aliceOrder(uint256 nonce) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), A_IN, B_OUT);
    }

    function _bobOrder(uint256 nonce) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tB), address(tA), B_OUT, A_IN);
        o.maker = bob;
    }

    function _step(uint256 kind, uint256 a, uint256 b) internal pure returns (uint256) {
        return kind | (a << 8) | (b << 24);
    }

    /// @dev Pool both inputs, then deliver both outputs — the item-free CoW shape.
    function _cowSchedule() internal pure returns (uint256[] memory s) {
        s = new uint256[](4);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.DELIVER, 0, 0);
        s[3] = _step(MatchStep.DELIVER, 1, 0);
    }

    /// @dev A two-order plan. `sigA == bytes("")` selects the on-chain-approval path
    ///      for Alice; anything else is signed normally.
    function _plan(Order memory a, Order memory b, uint256 fillA, uint256 fillB, bool emptySigA)
        internal
        view
        returns (MatchPlan memory)
    {
        Order[] memory orders = new Order[](2);
        (orders[0], orders[1]) = (a, b);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = emptySigA ? bytes("") : _signWith(a, makerPk);
        sigs[1] = _signWith(b, bobPk);
        uint256[] memory fills = new uint256[](2);
        (fills[0], fills[1]) = (fillA, fillB);
        return MatchPlan({
            orders: orders,
            sigs: sigs,
            fillAmounts: fills,
            takerDatas: new bytes[](0),
            schedule: _cowSchedule(),
            callTargets: new address[](0),
            callDatas: new bytes[](0),
            profitRecipient: address(0)
        });
    }

    function _balancedPlan(Order memory a, Order memory b) internal view returns (MatchPlan memory) {
        return _plan(a, b, A_IN, B_OUT, false);
    }

    /// @dev The control every gate test is measured against: with no gate tripped,
    ///      this exact plan settles and both makers are paid in full.
    function test_control_balancedMatchSettles() public {
        MatchPlan memory p = _balancedPlan(_aliceOrder(1), _bobOrder(2));
        vm.prank(solver);
        settlement.matchSettle(p);
        assertEq(tB.balanceOf(maker), B_OUT, "alice paid");
        assertEq(tA.balanceOf(bob), A_IN, "bob paid");
    }

    // ════════════════════ lifecycle gates ════════════════════

    function test_gate_expiredOrder_reverts() public {
        Order memory a = _aliceOrder(1);
        _setExpiry(a, block.timestamp - 1);
        MatchPlan memory p = _balancedPlan(a, _bobOrder(2));

        vm.prank(solver);
        vm.expectRevert(Base.OrderExpired.selector);
        settlement.matchSettle(p);
    }

    function test_gate_cancelledByHash_reverts() public {
        Order memory a = _aliceOrder(1);
        MatchPlan memory p = _balancedPlan(a, _bobOrder(2));

        vm.prank(maker);
        settlement.cancelOrder(a);

        vm.prank(solver);
        vm.expectRevert(OrderState.OrderCancelled.selector);
        settlement.matchSettle(p);
    }

    function test_gate_nonceCancelled_reverts() public {
        Order memory a = _aliceOrder(1);
        MatchPlan memory p = _balancedPlan(a, _bobOrder(2));

        vm.prank(maker);
        settlement.cancelOrders(_u1(1));

        vm.prank(solver);
        vm.expectRevert(OrderState.NonceCancelled.selector);
        settlement.matchSettle(p);
    }

    /// @dev The bulk kill switch reaches the netted path too — a maker who rolls
    ///      their floor forward must not find their old orders still matchable.
    function test_gate_rolledBackNonce_reverts() public {
        Order memory a = _aliceOrder(1);
        MatchPlan memory p = _balancedPlan(a, _bobOrder(2));

        vm.prank(maker);
        settlement.rollbackNonces(5); // nonce 1 is now below the floor

        vm.prank(solver);
        vm.expectRevert(OrderState.NonceCancelled.selector);
        settlement.matchSettle(p);
    }

    /// @dev A fully-filled order is refused by the same {OverFill} the single-order
    ///      path uses — the netted opener must not treat "nothing left" as "fill 0".
    function test_gate_alreadyFilled_reverts() public {
        Order memory a = _aliceOrder(1);
        bytes memory sigA = _signWith(a, makerPk);
        tB.mint(solver, B_OUT);
        _solverApprove(address(settlement), address(tB), B_OUT);

        vm.prank(solver);
        settlement.fill(a, sigA, A_IN); // exhaust it on the single-order path

        MatchPlan memory p = _balancedPlan(a, _bobOrder(2));
        vm.prank(solver);
        vm.expectRevert(OrderState.OverFill.selector);
        settlement.matchSettle(p);
    }

    function test_gate_zeroFill_reverts() public {
        MatchPlan memory p = _plan(_aliceOrder(1), _bobOrder(2), 0, B_OUT, false);
        vm.prank(solver);
        vm.expectRevert(OrderState.ZeroFill.selector);
        settlement.matchSettle(p);
    }

    // ════════════════════ exclusivity ════════════════════

    function test_gate_hardExclusivity_outsiderReverts() public {
        Order memory a = _aliceOrder(1);
        a.exclusiveFiller = address(0xE7C1);
        _setExclusivityEnd(a, block.timestamp + 1 hours);
        MatchPlan memory p = _balancedPlan(a, _bobOrder(2));

        vm.prank(solver);
        vm.expectRevert(OrderGates.NotExclusiveFiller.selector);
        settlement.matchSettle(p);
    }

    /// @dev The complement, and the reason the test above is about EXCLUSIVITY rather
    ///      than about the order being broken: the nominated filler settles the same
    ///      plan. `msg.sender` is what the netted opener passes as the filler, so
    ///      this also pins that the plan's caller — not its `profitRecipient` — is
    ///      the identity the gate keys on.
    function test_gate_exclusivity_nominatedFillerSettles() public {
        address chosen = address(0xE7C1);
        Order memory a = _aliceOrder(1);
        a.exclusiveFiller = chosen;
        _setExclusivityEnd(a, block.timestamp + 1 hours);
        MatchPlan memory p = _balancedPlan(a, _bobOrder(2));

        vm.prank(chosen);
        settlement.matchSettle(p);
        assertEq(tB.balanceOf(maker), B_OUT, "the nominated filler matched it");
    }

    /// @dev A lapsed window opens the order to everyone, on this path as on the
    ///      others — the window is read from the order's own clock inside
    ///      {OrderGates.exclusivityOverride}, which the netted opener also calls.
    function test_gate_exclusivity_lapsedWindowOpensUp() public {
        Order memory a = _aliceOrder(1);
        a.exclusiveFiller = address(0xE7C1);
        _setExclusivityEnd(a, block.timestamp + 1 hours);
        MatchPlan memory p = _balancedPlan(a, _bobOrder(2));

        vm.warp(block.timestamp + 2 hours);
        _setExpiry(p.orders[0], block.timestamp + 1 hours); // keep it alive past the warp
        _setExpiry(p.orders[1], block.timestamp + 1 hours);
        p.sigs[0] = _signWith(p.orders[0], makerPk);
        p.sigs[1] = _signWith(p.orders[1], bobPk);

        vm.prank(solver);
        settlement.matchSettle(p);
        assertEq(tB.balanceOf(maker), B_OUT, "an outsider matched it after the window");
    }

    // ════════════════════ the empty-sig / approveOrder path ════════════════════

    /// @dev The signature-LESS credential reaches `matchSettle` through the same
    ///      {Signatures._verifySignature} the single-order path calls, but nothing
    ///      had ever driven it here. It matters more on this path than on any other:
    ///      a plan carries a `sigs[]` ARRAY, so a solver chooses the branch
    ///      INDEPENDENTLY PER ORDER, which is exactly the freedom F13 turned into a
    ///      bypass on the single-order path.
    function test_gate_emptySig_authorizesViaOnChainApproval() public {
        Order memory a = _aliceOrder(1);
        vm.prank(maker);
        settlement.approveOrder(a);

        MatchPlan memory p = _plan(a, _bobOrder(2), A_IN, B_OUT, true); // sigs[0] = ""
        vm.prank(solver);
        settlement.matchSettle(p);
        assertEq(tB.balanceOf(maker), B_OUT, "the approved order matched with an empty sig");
    }

    function test_gate_emptySig_withoutApproval_reverts() public {
        MatchPlan memory p = _plan(_aliceOrder(1), _bobOrder(2), A_IN, B_OUT, true);
        vm.prank(solver);
        vm.expectRevert(Signatures.OrderNotApproved.selector);
        settlement.matchSettle(p);
    }

    /// @dev Revocation binds on the netted path too. Asserted on an UNTOUCHED order,
    ///      which is the case where {OrderState.revokeOrderApproval} clears the flag
    ///      rather than escalating to the cancel sentinel.
    function test_gate_revokedApproval_reverts() public {
        Order memory a = _aliceOrder(1);
        vm.startPrank(maker);
        bytes32 h = settlement.approveOrder(a);
        settlement.revokeOrderApproval(h);
        vm.stopPrank();

        MatchPlan memory p = _plan(a, _bobOrder(2), A_IN, B_OUT, true);
        vm.prank(solver);
        vm.expectRevert(Signatures.OrderNotApproved.selector);
        settlement.matchSettle(p);
    }

    function test_gate_wrongSigner_reverts() public {
        Order memory a = _aliceOrder(1);
        MatchPlan memory p = _balancedPlan(a, _bobOrder(2));
        p.sigs[0] = _signWith(a, bobPk); // Bob cannot authorise Alice's order

        vm.prank(solver);
        vm.expectRevert();
        settlement.matchSettle(p);
    }

    // ════════════════════ fill-once (nonce-as-progress) ════════════════════

    /// @dev A fill-once order keeps NO per-order counter — its progress IS the
    ///      consumed nonce — so a partial would burn the nonce and strand the
    ///      remainder. The netted path lets a solver choose each order's fill amount
    ///      freely, so it is the path where a partial is easiest to ask for.
    function test_gate_fillOnce_partialInAPlan_reverts() public {
        Order memory a = _aliceOrder(1);
        a.timing |= uint256(1) << 100; // fill-once
        MatchPlan memory p = _plan(a, _bobOrder(2), A_IN / 2, B_OUT, false);

        vm.prank(solver);
        vm.expectRevert(OrderState.FillOnceMustBeFull.selector);
        settlement.matchSettle(p);
    }

    /// @dev The complement: a FULL fill of the same order settles, consumes the
    ///      maker's nonce, and leaves `filled` untouched — the whole point of the
    ///      mode is that it never writes a fresh counter slot.
    function test_gate_fillOnce_fullFillConsumesTheNonce() public {
        Order memory a = _aliceOrder(1);
        a.timing |= uint256(1) << 100;
        MatchPlan memory p = _balancedPlan(a, _bobOrder(2));
        bytes32 h = lens.hashOrder(a);

        vm.prank(solver);
        settlement.matchSettle(p);
        assertEq(tB.balanceOf(maker), B_OUT, "alice paid");
        assertEq(settlement.filled(h), 0, "fill-once writes no per-order counter");

        // ...and the nonce is spent, so a second attempt dies on the nonce gate.
        tB.mint(bob, B_OUT);
        MatchPlan memory again = _balancedPlan(a, _bobOrder(3));
        vm.prank(solver);
        vm.expectRevert(OrderState.NonceCancelled.selector);
        settlement.matchSettle(again);
    }

    // ════════════════════ proportional anchor ════════════════════

    /// @dev A balance-relative anchor resolves through a `balanceOf` STATICCALL on a
    ///      maker-chosen token, and on the single-order path the ordering of that
    ///      call against the reentrancy guard is explicitly load-bearing
    ///      ({OrderState._gateFillState} carries a "do not flip these two lines"
    ///      note). The netted opener reaches the same resolution by a different
    ///      route; this is the case that proves it resolves at all.
    ///
    ///      Alice holds exactly `A_IN` here, so the resolved anchor equals the
    ///      absolute order the other tests use and the balanced plan still clears.
    function test_gate_proportionalAnchor_resolvesInAPlan() public {
        // Drain Alice to exactly A_IN so the sweep is a known quantity. The excess is
        // read BEFORE the prank — `balanceOf` is an external call and would eat it.
        uint256 excess = tA.balanceOf(maker) - A_IN;
        vm.prank(maker);
        tA.transfer(address(0xdead), excess);

        Order memory a = _aliceOrder(1);
        LegIn[] memory legs = new LegIn[](1);
        legs[0] = LegIn({token: address(tA), start: Proportional.encode(10_000), end: A_IN}); // 100%, capped
        a.legsIn = PackedEncode.legsIn(legs);

        MatchPlan memory p = _balancedPlan(a, _bobOrder(2));
        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(tA.balanceOf(maker), 0, "the whole balance was swept");
        assertEq(tB.balanceOf(maker), B_OUT, "and paid for in full");
    }

    /// @dev A proportional order cannot be partially filled anywhere, and the netted
    ///      path is no exception — the rule is enforced where the marker is CONSUMED
    ///      ({Pricing.inputOwed}), which both paths share.
    function test_gate_proportionalAnchor_partialInAPlan_reverts() public {
        uint256 excess = tA.balanceOf(maker) - A_IN;
        vm.prank(maker);
        tA.transfer(address(0xdead), excess);

        Order memory a = _aliceOrder(1);
        LegIn[] memory legs = new LegIn[](1);
        legs[0] = LegIn({token: address(tA), start: Proportional.encode(10_000), end: A_IN});
        a.legsIn = PackedEncode.legsIn(legs);

        MatchPlan memory p = _plan(a, _bobOrder(2), A_IN / 2, B_OUT, false);
        vm.prank(solver);
        vm.expectRevert(Proportional.ProportionalNeedsFullFill.selector);
        settlement.matchSettle(p);
    }

    // ════════════════════ the one deliberate feature exclusion ════════════════════

    /// @dev DELTA-VERIFY delivery (timing bit 104) verifies each output against the
    ///      RECIPIENT'S measured balance delta instead of pushing a nominal amount —
    ///      which is what makes a fee-on-transfer output safe. It needs a per-order
    ///      callback and a recipient snapshot, and the netted PRESEND/DELIVER flow has
    ///      neither. Delivering nominally instead would silently hand a FoT maker less
    ///      than they signed for, so the order is REFUSED.
    ///
    ///      This is the only place in the batch path where a legal order is turned
    ///      away for a reason that is not an authorisation failure — precisely the
    ///      kind of check that reads like dead weight in a bytecode-size pass. Until
    ///      now {Base.DeltaVerifyNotBatchable} fired in no test at all.
    function test_gate_deltaVerifyOrder_isNotBatchable() public {
        Order memory a = _aliceOrder(1);
        a.timing |= uint256(1) << 104; // DELTA-VERIFY outputs
        MatchPlan memory p = _balancedPlan(a, _bobOrder(2));

        vm.prank(solver);
        vm.expectRevert(Base.DeltaVerifyNotBatchable.selector);
        settlement.matchSettle(p);
    }

    /// @dev …and it is the FLAG that is refused, not the order. The identical order
    ///      without bit 104 matches, so a future edit cannot satisfy the test above
    ///      by breaking the shape generally.
    function test_gate_sameOrderWithoutTheFlag_matches() public {
        MatchPlan memory p = _balancedPlan(_aliceOrder(1), _bobOrder(2));
        vm.prank(solver);
        settlement.matchSettle(p);
        assertEq(tB.balanceOf(maker), B_OUT, "unflagged, it settles");
    }

    // ════════════════════ the derived token universe ════════════════════

    /// @dev WHY THIS IS AN INVARIANT TEST AND NOT A REVERT TEST.
    ///      {Base.TokenNotInUniverse} is the fall-through of `_tokenIndex`, and its
    ///      own source says nothing can raise it today: the universe is the on-chain
    ///      union of exactly the legs being indexed, so every lookup hits. It is a
    ///      loud backstop for a FUTURE caller that widens the universe, deliberately
    ///      carrying its own error so a broken internal invariant never masquerades
    ///      as a malformed call.
    ///
    ///      An error that cannot be raised cannot be pinned by expecting it — so the
    ///      thing to pin is the PROPERTY that makes it unreachable. A plan spanning
    ///      three distinct tokens across four legs settles, which is only possible if
    ///      every leg token resolved to a universe slot. If `_collectTokens` and
    ///      `_tokenIndex` ever disagree, this test fails with the backstop's own
    ///      error and names the token.
    function test_tokenUniverse_coversEveryLegTokenAcrossOrders() public {
        // Alice: tA → tB. Bob: tB → tA. Carol: tC → tA, funded by the pool's tA.
        uint256 carolPk = 0xCA401;
        address carol = vm.addr(carolPk);
        tC.mint(carol, A_IN);
        _approveFrom(carol, address(tC), A_IN);

        Order memory c = _plainOrder(3, address(tC), address(tA), A_IN, 1);
        c.maker = carol;

        // Bob takes one wei less so the pool's tA covers Carol's token exactly. The
        // point of the plan is the token UNIVERSE, so it must balance without the
        // solver fronting anything — a shortfall would fail as a funding error and
        // say nothing about `_tokenIndex`.
        Order memory b = _plainOrder(2, address(tB), address(tA), B_OUT, A_IN - 1);
        b.maker = bob;

        Order[] memory orders = new Order[](3);
        (orders[0], orders[1], orders[2]) = (_aliceOrder(1), b, c);
        bytes[] memory sigs = new bytes[](3);
        sigs[0] = _signWith(orders[0], makerPk);
        sigs[1] = _signWith(orders[1], bobPk);
        sigs[2] = _signWith(orders[2], carolPk);
        uint256[] memory fills = new uint256[](3);
        (fills[0], fills[1], fills[2]) = (A_IN, B_OUT, A_IN);

        uint256[] memory s = new uint256[](6);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.PULL, 2, 0);
        s[3] = _step(MatchStep.DELIVER, 0, 0);
        s[4] = _step(MatchStep.DELIVER, 1, 0);
        s[5] = _step(MatchStep.DELIVER, 2, 0);

        MatchPlan memory p = MatchPlan({
            orders: orders,
            sigs: sigs,
            fillAmounts: fills,
            takerDatas: new bytes[](0),
            schedule: s,
            callTargets: new address[](0),
            callDatas: new bytes[](0),
            profitRecipient: address(0)
        });

        vm.prank(solver);
        (,, address[] memory tokens) = _run(p);
        assertEq(tokens.length, 3, "three distinct tokens in the derived universe");
        assertEq(tC.balanceOf(solver), A_IN, "carol's tC was swept to the filler as surplus");
    }

    /// @dev Named wrapper so the tuple destructuring above stays readable; also
    ///      re-orders the return so the universe is last.
    function _run(MatchPlan memory p) internal returns (uint256[][] memory outs, uint256[] memory swept, address[] memory tokens) {
        (outs, tokens, swept) = settlement.matchSettle(p);
    }

    // ════════════════════ the CALL step's failure surface ════════════════════
    //
    // A CALL step routes a solver-supplied `(target, data)` through the same
    // allowance-less {SolverCallbackExecutor} as a single-order callback, via the same
    // hand-encoded {Core._execute}. These pin the two things that must survive that
    // shared path on the NETTED side: the target's revert reason, and the guard.

    /// @dev The balanced CoW plan with a CALL step spliced in between the pulls and
    ///      the deliveries — the point in the walk where the pool holds both makers'
    ///      inputs and has delivered nothing.
    function _planWithCall(address target, bytes memory data) internal view returns (MatchPlan memory p) {
        p = _balancedPlan(_aliceOrder(1), _bobOrder(2));
        uint256[] memory s = new uint256[](5);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.CALL, 0, 0);
        s[3] = _step(MatchStep.DELIVER, 0, 0);
        s[4] = _step(MatchStep.DELIVER, 1, 0);
        p.schedule = s;
        address[] memory targets = new address[](1);
        targets[0] = target;
        bytes[] memory datas = new bytes[](1);
        datas[0] = data;
        p.callTargets = targets;
        p.callDatas = datas;
    }

    /// @dev A failing CALL step aborts the whole plan and the target's own error —
    ///      selector AND arguments — reaches the solver, wrapped one layer by the
    ///      executor. Nothing settles.
    function test_call_stepRevert_bubblesTheTargetsReason() public {
        PlanCallReverter target = new PlanCallReverter();
        MatchPlan memory p = _planWithCall(address(target), abi.encodeCall(PlanCallReverter.boom, ()));

        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSignature(
                "CallbackFailed(bytes)", abi.encodeWithSelector(PlanCallReverter.RouteWentStale.selector, uint256(7))
            )
        );
        settlement.matchSettle(p);

        assertEq(tB.balanceOf(maker), 0, "alice unpaid - the plan unwound");
        assertEq(tA.balanceOf(bob), 0, "bob unpaid");
    }

    /// @dev And the guard spans the schedule walk: a CALL step cannot re-enter a fill
    ///      while the pool is holding both makers' pulled inputs.
    function test_call_stepReentrancy_blocked() public {
        PlanCallReenterer target = new PlanCallReenterer(settlement);
        MatchPlan memory p = _planWithCall(address(target), abi.encodeCall(PlanCallReenterer.reenter, ()));

        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSignature("CallbackFailed(bytes)", abi.encodeWithSelector(Base.Reentrancy.selector))
        );
        settlement.matchSettle(p);

        assertEq(tB.balanceOf(maker), 0, "alice unpaid - the plan unwound");
        assertEq(tA.balanceOf(bob), 0, "bob unpaid");
    }

}
