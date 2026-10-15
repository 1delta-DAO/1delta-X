// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MockSettlementBase, MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Base} from "@core/settlement/Base.sol";
import {OrderState} from "@core/settlement/OrderState.sol";
import {Settlement, Order, Item, ItemOp, Validator, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";

import {OcoGroupModule} from "../src/OcoGroupModule.sol";

/// @dev Output-token stock: takes `amtIn` of `tokenIn` from the caller and pays
///      `amtOut` of `tokenOut` — the venue a zero-capital solver converts through.
contract OcoMockDex {
    function swap(address tokenIn, uint256 amtIn, address tokenOut, uint256 amtOut) external {
        MockERC20(tokenIn).transferFrom(msg.sender, address(this), amtIn);
        MockERC20(tokenOut).transfer(msg.sender, amtOut);
    }
}

/// @dev A ZERO-CAPITAL solver: a PRESEND hands it the pooled input, a CALL swaps it
///      through the dex and pushes the output back into the pool. Authenticated the
///      way a fund-releasing CALL target must be (executor AND an entrypoint-armed
///      flag — audit 2026-09-30 CORE-FILLER-4).
contract OcoPresendSolver {
    Settlement immutable settlement;
    OcoMockDex immutable dex;
    uint256 armed = 1;

    constructor(Settlement s, OcoMockDex d) {
        settlement = s;
        dex = d;
    }

    function run(MatchPlan calldata p) external {
        armed = 2;
        settlement.matchSettle(p);
        armed = 1;
    }

    function swapAndCover(address tokenIn, uint256 amtIn, address tokenOut, uint256 amtOut) external {
        require(msg.sender == address(settlement.EXECUTOR()) && armed == 2, "not my plan");
        MockERC20(tokenIn).approve(address(dex), amtIn);
        dex.swap(tokenIn, amtIn, tokenOut, amtOut);
        MockERC20(tokenOut).transfer(address(settlement), amtOut);
    }
}

/// @title NettedOcoTest
/// @notice {OcoGroupModule} on the NETTED path. Since task 31 `matchSettle` admits
///         SETTLE items, which is what makes a bracket leg CoW-matchable and fillable
///         with zero solver capital (it was PRICE-12's "forward entries only").
///
///         The new exposure, and the reason the module's own header ("fill B:
///         validators → group claimed by A, FAIL") no longer describes the whole
///         story: on this path every order's validators run at OPEN, before ANY item
///         of the plan. Two sibling legs in one plan therefore BOTH pass the
///         `validate` gate. What keeps the group single-fill is the claim ITEM, which
///         writes and checks in one call and reverts the second sibling
///         ({OcoGroupModule.GroupAlreadyClaimed}); the solver cannot drop it, because
///         Phase 3 requires every signed item to have run (`PlanIncomplete`).
contract NettedOcoTest is MockSettlementBase {
    OcoGroupModule oco;
    OcoMockDex dex;
    OcoPresendSolver presendSolver;

    uint256 carolPk = 0xCA201;
    address carol = vm.addr(carolPk);

    uint256 constant AMOUNT_IN = 100e18;
    uint256 constant TP_OUT = 300e18;
    uint256 constant SL_OUT = 200e18;
    uint256 constant MIN_CLAIM = AMOUNT_IN / 10;
    uint256 constant GROUP = 0xB4A6E7;
    uint256 constant TP_NONCE = 1;
    uint256 constant SL_NONCE = 2;
    uint256 constant FILL_ONCE_BIT = uint256(1) << 100;

    function setUp() public override {
        super.setUp();
        oco = new OcoGroupModule(address(settlement));
        dex = new OcoMockDex();
        presendSolver = new OcoPresendSolver(settlement, dex);

        // Enough tA for BOTH legs, so only the OCO gate can stop the second one.
        tA.mint(maker, 1_000e18);
        _makerApprove(address(settlement), address(tA), type(uint160).max);
    }

    // ──────────────────── builders ────────────────────

    function _leg(uint256 nonce, uint256 amountOut) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), AMOUNT_IN, amountOut);
        Validator[] memory v = new Validator[](1);
        v[0] = Validator({target: address(oco), data: abi.encode(GROUP)});
        o.validators = PackedEncode.validators(v);
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.SETTLE,
            module: address(oco),
            amount: AMOUNT_IN, // the anchor — slice == this fill's delta
            recipient: address(0),
            data: abi.encode(GROUP, nonce, MIN_CLAIM)
        });
        o.items = PackedEncode.items(items);
    }

    /// @dev Carol buys the makers' tA with tB — the CoW side of a two-leg plan.
    function _carol(uint256 tbIn, uint256 taOut) internal returns (Order memory o) {
        o = _blank(1);
        o.maker = carol;
        o.legsIn = PackedEncode.oneLegIn(address(tB), tbIn, 0);
        o.legsOut = PackedEncode.oneLegOut(address(tA), taOut, 0, address(0));
        tB.mint(carol, tbIn);
        vm.startPrank(carol);
        tB.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(tB), type(uint160).max, 0);
        vm.stopPrank();
    }

    function _step(uint256 kind, uint256 a, uint256 b) internal pure returns (uint256) {
        return MatchStep.pack(kind, a, b);
    }

    function _planOf(Order[] memory orders, uint256[] memory pks, uint256[] memory fills, uint256[] memory s)
        internal
        view
        returns (MatchPlan memory)
    {
        bytes[] memory sigs = new bytes[](orders.length);
        for (uint256 i; i < orders.length; i++) {
            sigs[i] = _signWith(orders[i], pks[i]);
        }
        return MatchPlan({
            orders: orders,
            sigs: sigs,
            fillAmounts: fills,
            takerDatas: new bytes[](0),
            schedule: s,
            callTargets: new address[](0),
            callDatas: new bytes[](0),
            profitRecipient: address(0)
        });
    }

    /// @dev [TP, SL, Carol] where Carol buys both legs' tA. `itemsFirst` puts both
    ///      claims ahead of every transfer; otherwise they run after the deliveries.
    function _siblingPlan(bool tpClaimsFirst, bool itemsFirst) internal returns (MatchPlan memory) {
        Order[] memory orders = new Order[](3);
        orders[0] = _leg(TP_NONCE, TP_OUT);
        orders[1] = _leg(SL_NONCE, SL_OUT);
        orders[2] = _carol(TP_OUT + SL_OUT, 2 * AMOUNT_IN);
        uint256[] memory pks = new uint256[](3);
        pks[0] = makerPk;
        pks[1] = makerPk;
        pks[2] = carolPk;
        uint256[] memory fills = new uint256[](3);
        fills[0] = AMOUNT_IN;
        fills[1] = AMOUNT_IN;
        fills[2] = TP_OUT + SL_OUT;

        (uint256 first, uint256 second) = tpClaimsFirst ? (uint256(0), uint256(1)) : (uint256(1), uint256(0));
        uint256[] memory s = new uint256[](8);
        uint256 k;
        if (itemsFirst) {
            s[k++] = _step(MatchStep.ITEM, first, 0);
            s[k++] = _step(MatchStep.ITEM, second, 0);
        }
        s[k++] = _step(MatchStep.PULL, 0, 0);
        s[k++] = _step(MatchStep.PULL, 1, 0);
        s[k++] = _step(MatchStep.PULL, 2, 0);
        s[k++] = _step(MatchStep.DELIVER, 0, 0);
        s[k++] = _step(MatchStep.DELIVER, 1, 0);
        if (!itemsFirst) {
            s[k++] = _step(MatchStep.ITEM, first, 0);
            s[k++] = _step(MatchStep.ITEM, second, 0);
        }
        s[k++] = _step(MatchStep.DELIVER, 2, 0);
        return _planOf(orders, pks, fills, s);
    }

    // ──────────────────── two siblings in one plan ────────────────────

    /// Both legs of one group in ONE plan. Both pass `validate` at open (the group is
    /// unclaimed then); the second CLAIM reverts. Every combination of which leg
    /// claims first and whether the claims run before or after the transfers.
    function test_netted_twoSiblingLegsInOnePlan_reverts() public {
        for (uint256 c; c < 4; c++) {
            MatchPlan memory p = _siblingPlan(c & 1 == 0, c & 2 == 0);
            vm.prank(solver);
            vm.expectRevert(OcoGroupModule.GroupAlreadyClaimed.selector);
            settlement.matchSettle(p);
            assertEq(oco.claim(maker, GROUP), 0, "atomic: the group is still unclaimed");
        }
    }

    /// The validators really did pass at open — the revert above is the ITEM, not the
    /// gate. Proved by the same plan with one sibling dropped: it settles.
    function test_netted_singleLegWithCounterOrder_settles() public {
        Order[] memory orders = new Order[](2);
        orders[0] = _leg(TP_NONCE, TP_OUT);
        orders[1] = _carol(TP_OUT, AMOUNT_IN);
        uint256[] memory pks = new uint256[](2);
        pks[0] = makerPk;
        pks[1] = carolPk;
        uint256[] memory fills = new uint256[](2);
        fills[0] = AMOUNT_IN;
        fills[1] = TP_OUT;
        uint256[] memory s = new uint256[](5);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.DELIVER, 0, 0);
        s[3] = _step(MatchStep.ITEM, 0, 0);
        s[4] = _step(MatchStep.DELIVER, 1, 0);
        MatchPlan memory p = _planOf(orders, pks, fills, s);

        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(oco.claim(maker, GROUP), TP_NONCE + 1, "take-profit claimed the group");
        assertEq(tB.balanceOf(maker), TP_OUT, "maker paid");
        assertEq(tA.balanceOf(carol), AMOUNT_IN, "carol paid");
        assertTrue(oco.isRetiredFor(maker, GROUP, SL_NONCE), "the stop-loss is retired");
    }

    // ──────────────────── one leg, zero solver capital ────────────────────

    function _zeroCapitalPlan(bool itemFirst) internal view returns (MatchPlan memory p) {
        Order[] memory orders = new Order[](1);
        orders[0] = _leg(TP_NONCE, TP_OUT);
        uint256[] memory pks = new uint256[](1);
        pks[0] = makerPk;
        uint256[] memory fills = new uint256[](1);
        fills[0] = AMOUNT_IN;

        // Universe (on-chain, leg order): [tA, tB]. PRESEND 0 = the pooled tA.
        uint256[] memory s = new uint256[](5);
        uint256 k;
        if (itemFirst) s[k++] = _step(MatchStep.ITEM, 0, 0);
        s[k++] = _step(MatchStep.PULL, 0, 0);
        s[k++] = _step(MatchStep.PRESEND, 0, 0);
        s[k++] = _step(MatchStep.CALL, 0, 0);
        s[k++] = _step(MatchStep.DELIVER, 0, 0);
        if (!itemFirst) s[k++] = _step(MatchStep.ITEM, 0, 0);

        p = _planOf(orders, pks, fills, s);
        p.callTargets = new address[](1);
        p.callTargets[0] = address(presendSolver);
        p.callDatas = new bytes[](1);
        p.callDatas[0] =
            abi.encodeCall(OcoPresendSolver.swapAndCover, (address(tA), AMOUNT_IN, address(tB), TP_OUT));
    }

    function _assertZeroCapitalOutcome() internal {
        assertEq(tB.balanceOf(maker), TP_OUT, "maker received the take-profit output");
        assertEq(oco.claim(maker, GROUP), TP_NONCE + 1, "the leg claimed its group");
        assertEq(tA.balanceOf(address(presendSolver)), 0, "solver ends with no tA");
        assertEq(tB.balanceOf(address(presendSolver)), 0, "solver ends with no tB");
        assertEq(tA.balanceOf(address(dex)), AMOUNT_IN, "the dex took the maker's input");
        assertEq(tA.balanceOf(address(settlement)) + tB.balanceOf(address(settlement)), 0, "nothing pooled");

        // The sibling is dead on every path afterwards.
        Order memory sl = _leg(SL_NONCE, SL_OUT);
        bytes memory sig = _sign(sl);
        tB.mint(solver, SL_OUT);
        _solverApprove(address(settlement), address(tB), SL_OUT);
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.ValidationFailed.selector, uint256(0)));
        settlement.fill(sl, sig, AMOUNT_IN);
    }

    /// PULL → PRESEND → CALL → DELIVER → ITEM: the bracket leg fills with the solver
    /// holding nothing at any point — the maker's own input, pre-sent and swapped,
    /// funds the delivery.
    function test_netted_bracketLeg_zeroCapital_claimLast() public {
        tB.mint(address(dex), TP_OUT);
        presendSolver.run(_zeroCapitalPlan(false));
        _assertZeroCapitalOutcome();
    }

    /// ITEM → PULL → PRESEND → CALL → DELIVER: the claim first. Same outcome — the
    /// claim moves no value, so its position in the schedule is free.
    function test_netted_bracketLeg_zeroCapital_claimFirst() public {
        tB.mint(address(dex), TP_OUT);
        presendSolver.run(_zeroCapitalPlan(true));
        _assertZeroCapitalOutcome();
    }

    // ──────────────────── the zero-contract alternative ────────────────────

    /// Shared nonce + fill-once, both legs in ONE plan: the nonce is consumed when
    /// the FIRST leg opens (Phase 1 writes it before any later order is gated), so
    /// the second leg's open reverts — the netted path keeps this bracket shape
    /// single-fill too.
    function test_netted_sharedFillOnceNonce_bothLegsInOnePlan_reverts() public {
        Order memory tp = _plainOrder(7, address(tA), address(tB), AMOUNT_IN, TP_OUT);
        tp.timing |= FILL_ONCE_BIT;
        Order memory sl = _plainOrder(7, address(tA), address(tB), AMOUNT_IN, SL_OUT);
        sl.timing |= FILL_ONCE_BIT;
        Order[] memory orders = new Order[](3);
        orders[0] = tp;
        orders[1] = sl;
        orders[2] = _carol(TP_OUT + SL_OUT, 2 * AMOUNT_IN);
        uint256[] memory pks = new uint256[](3);
        pks[0] = makerPk;
        pks[1] = makerPk;
        pks[2] = carolPk;
        uint256[] memory fills = new uint256[](3);
        fills[0] = AMOUNT_IN;
        fills[1] = AMOUNT_IN;
        fills[2] = TP_OUT + SL_OUT;
        uint256[] memory s = new uint256[](6);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.PULL, 2, 0);
        s[3] = _step(MatchStep.DELIVER, 0, 0);
        s[4] = _step(MatchStep.DELIVER, 1, 0);
        s[5] = _step(MatchStep.DELIVER, 2, 0);
        MatchPlan memory p = _planOf(orders, pks, fills, s);

        vm.prank(solver);
        vm.expectRevert(OrderState.NonceCancelled.selector);
        settlement.matchSettle(p);
    }
}
