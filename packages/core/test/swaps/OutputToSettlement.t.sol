// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "../shared/PackedEncode.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Order, Item, LegOut, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @title OutputToSettlement
/// @notice An output leg addressed at Settlement itself — the maker "self-burn" —
///         must not become SOLVER REVENUE on the netted path.
///
///  ⚠ SECURITY REGRESSION SUITE. On the single-order path such a leg is genuinely
///  burned: the filler pays it into Settlement, which has no sweep and no admin, so
///  it is stranded forever. That is what `docs/originator-fees.md`, the settlement
///  README and `SettlementLens.validateOrder` all describe.
///
///  `matchSettle` could not honour the same promise. `_stepDeliver` performed a real
///  pool→pool SELF-transfer, which leaves the balance untouched while `outstanding`
///  records the obligation as discharged — so the amount sat above the pre-context
///  floor and `_sweepSurplus` handed it to the SOLVER. Same signed order, opposite
///  outcome, and a positive-EV reason for a solver to hunt mis-authored orders and
///  bundle them with anything touching the same token.
///
///  This is the sibling of the stray-TAKE-proceeds hazard `_creditItemProceeds`
///  already closes, and it is BROADER: an item's proceeds token may be absent from
///  the match's token universe, but a `legsOut` token is always in it.
///
///  Refused rather than refunded: unlike item proceeds there is no honest
///  destination: the maker deliberately signed the amount away.
contract OutputToSettlementTest is CoreSettlementBase {
    uint256 bobPk = 0xB0B;
    address bob = vm.addr(bobPk);

    uint256 constant WETH_AMT = 1 ether;
    uint256 constant USDC_AMT = 2_000e6;

    function _signAs(Order memory o, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(o)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _approveToSettlement(address who, address token, uint256 cap) internal {
        vm.startPrank(who);
        IERC20(token).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), token, uint160(cap), 0);
        vm.stopPrank();
    }

    function _step(uint256 kind, uint256 a, uint256 b) internal pure returns (uint256) {
        return kind | (a << 8) | (b << 24);
    }

    /// @dev Alice sells WETH for USDC; Bob is the mirror. Both funded and approved.
    function _mirrorPair(uint256 nonceA, uint256 nonceB)
        internal
        returns (Order memory a, Order memory b)
    {
        a = _order(maker, nonceA, WETH, USDC, WETH_AMT, USDC_AMT, new Item[](0));
        b = _order(bob, nonceB, USDC, WETH, USDC_AMT, WETH_AMT, new Item[](0));
        deal(WETH, maker, WETH_AMT);
        deal(USDC, bob, USDC_AMT);
        _approveToSettlement(maker, WETH, WETH_AMT);
        _approveToSettlement(bob, USDC, USDC_AMT);
    }

    /// @dev The plain two-order CoW schedule: pull both, deliver both.
    function _plan(Order memory a, Order memory b) internal view returns (MatchPlan memory) {
        Order[] memory orders = new Order[](2);
        orders[0] = a;
        orders[1] = b;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signAs(a, makerPk);
        sigs[1] = _signAs(b, bobPk);
        uint256[] memory fills = new uint256[](2);
        fills[0] = WETH_AMT;
        fills[1] = USDC_AMT;
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
            profitRecipient: address(0)
        });
    }

    // ──────────────── the regression ────────────────

    /// The whole output addressed at Settlement. Before the guard this paid the
    /// solver the full 2,000 USDC.
    function test_matchSettle_rejectsSelfAddressedOutputLeg() public {
        (Order memory a, Order memory b) = _mirrorPair(1, 2);
        a.legsOut = PackedEncode.setLegOutRecipient(a.legsOut, 0, address(settlement));

        // Built BEFORE the cheatcodes: `_plan` staticcalls DOMAIN_SEPARATOR() to
        // sign, which would consume the prank/expectRevert. See the harness note in
        // CoreSettlementBase.
        MatchPlan memory p = _plan(a, b);

        vm.prank(solver);
        vm.expectRevert(Base.OutputToSettlement.selector);
        settlement.matchSettle(p);

        assertEq(IERC20(USDC).balanceOf(solver), 0, "solver got nothing");
    }

    /// The realistic shape: a 5% originator FEE leg mis-addressed at Settlement,
    /// with the maker's own leg perfectly fine. Before the guard the maker was paid
    /// its 1,900 and the solver quietly pocketed the 100.
    function test_matchSettle_rejectsSelfAddressedFeeLeg() public {
        uint256 fee = 100e6;
        (Order memory a, Order memory b) = _mirrorPair(3, 4);
        LegOut[] memory lo = new LegOut[](2);
        lo[0] = LegOut(USDC, USDC_AMT - fee, 0, address(0)); //           to the maker
        lo[1] = LegOut(USDC, fee, 0, address(settlement)); //             mis-addressed fee
        a.legsOut = PackedEncode.legsOut(lo);
        MatchPlan memory p = _plan(a, b); // before the cheatcodes — see above

        vm.prank(solver);
        vm.expectRevert(Base.OutputToSettlement.selector);
        settlement.matchSettle(p);

        assertEq(IERC20(USDC).balanceOf(solver), 0, "solver got nothing");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "the whole match unwound");
    }

    // ──────────────── controls ────────────────

    /// The single-order path's documented behaviour is UNCHANGED: the leg really is
    /// burned into Settlement, where nothing can ever move it again.
    function test_singleOrderFill_stillBurnsIntoSettlement() public {
        Order memory a = _order(maker, 5, WETH, USDC, WETH_AMT, USDC_AMT, new Item[](0));
        a.legsOut = PackedEncode.setLegOutRecipient(a.legsOut, 0, address(settlement));
        deal(WETH, maker, WETH_AMT);
        deal(USDC, solver, USDC_AMT);
        _approveToSettlement(maker, WETH, WETH_AMT);
        vm.startPrank(solver);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDC, uint160(USDC_AMT), 0);
        vm.stopPrank();

        bytes memory sigA = _signAs(a, makerPk); // before the prank — see above

        vm.prank(solver);
        settlement.fill(a, sigA, WETH_AMT);

        assertEq(IERC20(USDC).balanceOf(address(settlement)), USDC_AMT, "burned: stranded in Settlement");
        assertEq(IERC20(USDC).balanceOf(solver), 0, "the solver paid it away");
        assertEq(IERC20(WETH).balanceOf(solver), WETH_AMT, "and received the input");
    }

    /// An ordinary match — every recipient well-formed — is untouched by the guard.
    function test_matchSettle_ordinaryPairStillSettles() public {
        (Order memory a, Order memory b) = _mirrorPair(6, 7);
        MatchPlan memory p = _plan(a, b); // before the prank — see above

        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(IERC20(USDC).balanceOf(maker), USDC_AMT, "maker paid in full");
        assertEq(IERC20(WETH).balanceOf(bob), WETH_AMT, "bob paid in full");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "pool flat");
    }

    /// A leg addressed at the maker or left as `address(0)` must NOT trip the guard —
    /// those are the two ordinary spellings of "pay the maker".
    function test_matchSettle_explicitMakerRecipientIsFine() public {
        (Order memory a, Order memory b) = _mirrorPair(8, 9);
        a.legsOut = PackedEncode.setLegOutRecipient(a.legsOut, 0, maker); // explicit, not 0
        MatchPlan memory p = _plan(a, b); // before the prank — see above

        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(IERC20(USDC).balanceOf(maker), USDC_AMT, "maker paid in full");
    }
}
