// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "../shared/PackedEncode.sol";
import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, LegIn, OrderSide} from "@core/settlement/Settlement.sol";
import {Proportional} from "@core/settlement/Proportional.sol";
import {OrderState} from "@core/settlement/OrderState.sol";
import {DutchAuction} from "@core/settlement/DutchAuction.sol";

/// @dev Balance-relative ({Proportional}) input legs — "sell 100% of whatever I
///      hold, capped at N". The marker lives in the TOP of `legsIn[0].start`, so
///      none of this changes the EIP-712 typehash; {HashGoldenTest} is the
///      standing proof of that.
///
///      The three properties that matter, and which every test below is an
///      instance of:
///        1. the anchor is resolved from the maker's LIVE balance, once,
///        2. the fill is always WHOLE (a live denominator cannot measure partial
///           progress), and
///        3. `end` caps it, so the maker is never worse off than the absolute
///           order they would otherwise have signed.
contract ProportionalLegTest is CoreSettlementBase {
    uint256 constant WETH_OUT = 1 ether;

    function _approveMaker(uint256 usdcCap) internal {
        vm.prank(maker);
        permit3.approveToken(address(settlement), USDC, uint160(usdcCap), 0);
    }

    /// @dev A SELL order whose input anchor is `bps` of the maker's USDC balance,
    ///      capped at `cap` (0 = uncapped), against a fixed `WETH_OUT`.
    function _propOrder(uint256 nonce, uint256 bps, uint256 cap) internal view returns (Order memory o) {
        o = _order(maker, nonce, USDC, WETH, 1, WETH_OUT, new Item[](0));
        o.legsIn = PackedEncode.setLegInStart(o.legsIn, 0, Proportional.encode(bps));
        o.legsIn = PackedEncode.setLegInEnd(o.legsIn, 0, cap);
    }

    /// @dev Stage a maker holding `bal` USDC and a solver holding the output, with
    ///      both sides' approvals in place.
    function _stage(uint256 bal) internal {
        deal(USDC, maker, bal);
        deal(WETH, solver, WETH_OUT);
        _approveMaker(type(uint160).max); // the cap under test is the LEG's, not the allowance's
        _approveSolverSide(WETH_OUT, WETH);
    }

    // ──────────────────── The happy path ────────────────────

    /// The headline case: the maker signed "all of it" and never had to know the
    /// amount. Everything they hold moves; they are paid the full signed output.
    function test_prop_fullSweep_sellsEntireBalance() public {
        uint256 bal = 2_000e6;
        _stage(bal);

        Order memory order = _propOrder(0, 10_000, bal);
        bytes memory sig = _sign(order);
        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, bal)[0];

        assertEq(paid, WETH_OUT, "maker paid the full signed output");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "maker swept to zero");
        assertEq(IERC20(USDC).balanceOf(solver), bal, "solver received the whole balance");
        assertEq(IERC20(WETH).balanceOf(maker), WETH_OUT, "maker received WETH");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement holds nothing");
    }

    /// Drift DOWN — the balance shrank after signing. The maker sells what they
    /// actually have and is still paid in full, which is strictly better for them
    /// than the absolute order (which would simply have failed to fund).
    function test_prop_balanceBelowCap_sellsBalance_stillPaidInFull() public {
        uint256 bal = 1_500e6;
        _stage(bal);

        Order memory order = _propOrder(0, 10_000, 2_000e6); // cap above the balance
        bytes memory sig = _sign(order);
        // `fillUpTo` is the entry for a proportional order: the solver names a
        // ceiling and the clamp resolves the actual size. Plain `fill` would need
        // the exact balance, which is precisely what the solver cannot know.
        vm.prank(solver);
        (, , uint256[] memory paidLegs) = settlement.fillUpTo(order, sig, 2_000e6, address(0), "");
        uint256 paid = paidLegs[0];

        assertEq(paid, WETH_OUT, "output does not shrink with the input");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "sold exactly the balance");
        assertEq(IERC20(USDC).balanceOf(solver), bal, "solver got the balance, not the cap");
    }

    /// Drift UP — the balance grew after signing. THE cap test: without `end` the
    /// maker would hand over the extra 1,000 USDC for the same 1 WETH.
    function test_prop_balanceAboveCap_clampsToCap() public {
        _stage(3_000e6);

        uint256 cap = 2_000e6;
        Order memory order = _propOrder(0, 10_000, cap);
        bytes memory sig = _sign(order);
        vm.prank(solver);
        settlement.fill(order, sig, cap);

        assertEq(IERC20(USDC).balanceOf(solver), cap, "solver capped at the signed maximum");
        assertEq(IERC20(USDC).balanceOf(maker), 1_000e6, "maker keeps everything above the cap");
    }

    /// A fractional sweep — "sell half of whatever I hold".
    function test_prop_partialBps_sellsThatFraction() public {
        _stage(2_000e6);

        Order memory order = _propOrder(0, 5_000, 0); // 50%, uncapped
        bytes memory sig = _sign(order);
        vm.prank(solver);
        settlement.fill(order, sig, 1_000e6);

        assertEq(IERC20(USDC).balanceOf(solver), 1_000e6, "solver received half");
        assertEq(IERC20(USDC).balanceOf(maker), 1_000e6, "maker kept half");
    }

    // ──────────────────── The solver's staleness bound ────────────────────

    /// `fillAmount` is the SOLVER's ceiling, and `fillUpTo`'s clamp never raises
    /// it. A maker balance that grew past the quote therefore arrives as a partial
    /// fill and is refused — the solver is never made to buy more than it priced.
    function test_prop_balanceGrewPastSolverCeiling_reverts() public {
        _stage(2_500e6);

        Order memory order = _propOrder(0, 10_000, 0); // uncapped: only the solver's bound applies
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(Proportional.ProportionalNeedsFullFill.selector);
        settlement.fillUpTo(order, sig, 2_000e6, address(0), "");
    }

    /// "Give me only part of it" is not expressible: a live-balance denominator
    /// cannot measure progress across fills, so anything short of the whole sweep
    /// is refused rather than silently rounded.
    function test_prop_partialRequest_reverts() public {
        _stage(2_000e6);

        Order memory order = _propOrder(0, 10_000, 2_000e6);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(Proportional.ProportionalNeedsFullFill.selector);
        settlement.fill(order, sig, 500e6);
    }

    /// A maker holding nothing resolves to a zero anchor. It must revert rather
    /// than "succeed" moving nothing — otherwise anyone could brick a fill-once
    /// proportional order by filling it during a momentary zero balance. The
    /// over-fill cap catches it: any non-zero request exceeds a zero denominator.
    function test_prop_zeroBalance_reverts() public {
        _stage(0);

        Order memory order = _propOrder(0, 10_000, 2_000e6);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(OrderState.OverFill.selector);
        settlement.fill(order, sig, 2_000e6);
    }

    /// `minFillAnchor` is the matching FLOOR and needs no new machinery — the
    /// anti-dust check already runs against the resolved delta.
    function test_prop_minFillAnchor_actsAsFloor() public {
        _stage(100e6);

        Order memory order = _propOrder(0, 10_000, 2_000e6);
        order.minFillAnchor = 500e6; // "do not bother unless I hold at least 500"
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(OrderState.FillTooSmall.selector);
        settlement.fillUpTo(order, sig, 2_000e6, address(0), "");
    }

    // ──────────────────── Only ever the SELL anchor ────────────────────

    function test_prop_onNonAnchorInputLeg_reverts() public {
        _stage(2_000e6);
        deal(WETH, maker, 1 ether);

        // Two input legs; the marker sits on leg 1, which is exactly the position
        // the anchor resolution never sees — only {Pricing.inputOwed} can catch it.
        Order memory order = _order(maker, 0, USDC, WETH, 2_000e6, WETH_OUT, new Item[](0));
        LegIn[] memory legs = new LegIn[](2);
        legs[0] = LegIn({token: USDC, start: 2_000e6, end: 0});
        legs[1] = LegIn({token: WETH, start: Proportional.encode(10_000), end: 0});
        order.legsIn = PackedEncode.legsIn(legs);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(Proportional.InvalidProportionalLeg.selector);
        settlement.fill(order, sig, 2_000e6);
    }

    function test_prop_onBuyOrderOutputAnchor_reverts() public {
        _stage(2_000e6);

        Order memory order = _propOrder(0, 10_000, 2_000e6);
        order.timing |= uint256(1) << 101; // BUY (timing bit 101)
        // BUY resolves its anchor from legsOut[0]; put the marker there.
        order.legsIn = PackedEncode.setLegInStart(order.legsIn, 0, 2_000e6);
        order.legsIn = PackedEncode.setLegInEnd(order.legsIn, 0, 0);
        order.legsOut = PackedEncode.setLegOutStart(order.legsOut, 0, Proportional.encode(10_000));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(Proportional.InvalidProportionalLeg.selector);
        settlement.fill(order, sig, WETH_OUT);
    }

    function test_prop_withSignedFillTotal_reverts() public {
        _stage(2_000e6);

        Order memory order = _propOrder(0, 10_000, 2_000e6);
        // A `fillTotal` order never reaches the anchor resolution, so the marker
        // would never be resolved — `ctx.anchor` would hold the signed total.
        order.fillTotal = 2_000e6;
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(Proportional.InvalidProportionalLeg.selector);
        settlement.fill(order, sig, 2_000e6);
    }

    // ──────────────────── The aggregator entry ────────────────────

    /// `fillUpTo` clamps to the remaining size, which for an unfilled proportional
    /// order IS the resolved anchor — so an aggregator asking for "as much as
    /// possible" gets the whole sweep with no special-casing.
    function test_prop_fillUpTo_clampsToResolvedAnchor() public {
        uint256 bal = 2_000e6;
        _stage(bal);

        Order memory order = _propOrder(0, 10_000, 0);
        bytes memory sig = _sign(order);
        vm.prank(solver);
        (uint256 delta, uint256[] memory received,) =
            settlement.fillUpTo(order, sig, type(uint128).max, address(0), "");

        assertEq(delta, bal, "clamped to the live balance");
        assertEq(received[0], bal, "receipts report the swept amount");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "maker swept");
    }

    // ──────────────────── The encoding boundary ────────────────────

    /// The marker range must not be reachable by an ordinary amount. `SENTINEL_FLOOR`
    /// itself is absolute; one above it is the smallest proportional value (1 bp).
    function test_prop_sentinelBoundary_isExact() public pure {
        assertFalse(Proportional.isProportional(0), "zero is absolute");
        assertFalse(Proportional.isProportional(type(uint128).max), "an ordinary amount is absolute");
        assertFalse(Proportional.isProportional(Proportional.SENTINEL_FLOOR), "the floor itself is absolute");
        assertTrue(Proportional.isProportional(Proportional.SENTINEL_FLOOR + 1), "one above is a marker");
        assertEq(Proportional.bps(Proportional.SENTINEL_FLOOR + 1), 1, "and it carries 1 bp");
        assertTrue(Proportional.isProportional(type(uint256).max), "max is the 100% marker");
        assertEq(Proportional.bps(type(uint256).max), Proportional.BPS, "which decodes to BPS");
    }

    /// {Proportional} declares its own `BPS` rather than importing {DutchAuction}'s,
    /// to keep the import graph acyclic. That is the exact duplication this codebase
    /// has been bitten by before ({OrderGates}' contract note), so it is pinned here
    /// instead of trusted to a comment.
    function test_prop_bpsMatchesDutchAuction() public pure {
        assertEq(Proportional.BPS, DutchAuction.BPS, "Proportional.BPS drifted from DutchAuction.BPS");
    }

    function testFuzz_prop_encodeRoundTrips(uint256 bps) public pure {
        bps = bound(bps, 1, Proportional.BPS);
        uint256 marker = Proportional.encode(bps);
        assertTrue(Proportional.isProportional(marker), "encoded value is a marker");
        assertEq(Proportional.bps(marker), bps, "round trip");
    }

    /// An absolute amount below the floor must keep decoding as itself — this is
    /// the property that lets the marker share the field with no format change.
    function testFuzz_prop_absoluteAmountsUnaffected(uint256 amount) public {
        amount = bound(amount, 1e6, 100_000e6);
        _stage(amount);

        Order memory order = _order(maker, 0, USDC, WETH, amount, WETH_OUT, new Item[](0));
        bytes memory sig = _sign(order);
        vm.prank(solver);
        settlement.fill(order, sig, amount);

        assertEq(IERC20(USDC).balanceOf(solver), amount, "absolute leg unchanged");
    }
}
