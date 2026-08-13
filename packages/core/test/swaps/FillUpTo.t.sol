// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "../shared/PackedEncode.sol";

import {Base} from "@core/settlement/Base.sol";
import {OrderState} from "@core/settlement/OrderState.sol";
import {Order, LegIn, LegOut, OrderSide} from "@core/settlement/Settlement.sol";
import {IFillModule} from "@core/interfaces/IFillModule.sol";
import {RangePriceModule} from "@core/modules/RangePriceModule.sol";

import {MockSettlementBase} from "../shared/MockSettlementBase.t.sol";

/// @dev Pass-through matcher: accepts the solver's requested amount verbatim.
///      Used to prove the core does NOT clamp a module order's proposal.
contract EchoFillModule is IFillModule {
    function resolveFill(Order calldata, uint256, uint256 fillAmount, bytes calldata) external pure returns (uint256) {
        return fillAmount;
    }
}

/// @dev Matcher that clamps itself to the remaining size via `prevFilled` — the
///      documented module-side clamp obligation (see {IFillModule}).
contract ClampingFillModule is IFillModule {
    function resolveFill(Order calldata order, uint256 prevFilled, uint256 fillAmount, bytes calldata)
        external
        pure
        returns (uint256)
    {
        uint256 rem = order.fillTotal - prevFilled;
        return fillAmount > rem ? rem : fillAmount;
    }
}

/// @title FillUpTo
/// @notice The aggregator entry: `fillUpTo` clamps to the order's remaining size
///         (instead of the {OverFill} race revert) and returns full both-sides
///         accounting `(delta, received, paid)`. Covers the clamp matrix (race,
///         over-request, full-fill-only orders, minFill floor, cancelled/filled
///         fall-through, fill-module pass-through), the `recipient` redirect, and
///         the exactness of the recomputed `received` against real balance deltas
///         under decay — SELL and BUY.
contract FillUpToTest is MockSettlementBase {
    uint256 constant IN_ = 1_000e18; // tA the maker gives (SELL anchor)
    uint256 constant OUT_ = 2e18; //   tB the solver delivers at the fixed price

    address recipient = address(0xFEE1);

    function _fund(uint256 makerIn, uint256 solverOut) internal {
        tA.mint(maker, makerIn);
        tB.mint(solver, solverOut);
        _makerApprove(address(settlement), address(tA), makerIn);
        _solverApprove(address(settlement), address(tB), solverOut);
    }

    // ──────────────────── Accounting: the return triple ────────────────────

    function test_fillUpTo_full_returnsBothSides() public {
        _fund(IN_, OUT_);
        Order memory order = _plainOrder(1, address(tA), address(tB), IN_, OUT_);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        (uint256 delta, uint256[] memory received, uint256[] memory paid) =
            settlement.fillUpTo(order, sig, IN_, address(0), 0, "");

        assertEq(delta, IN_, "full delta");
        assertEq(received.length, 1, "one input leg");
        assertEq(paid.length, 1, "one output leg");
        assertEq(received[0], IN_, "received = exact anchor slice");
        assertEq(paid[0], OUT_, "paid = exact output");
        assertEq(tA.balanceOf(solver), IN_, "returned receipt matches balance");
        assertEq(tB.balanceOf(maker), OUT_, "maker got the output");
        assertEq(lens.remaining(order), 0, "fully filled");
    }

    function test_fillUpTo_zeroRequest_reverts() public {
        _fund(IN_, OUT_);
        Order memory order = _plainOrder(2, address(tA), address(tB), IN_, OUT_);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(OrderState.ZeroFill.selector);
        settlement.fillUpTo(order, sig, 0, address(0), 0, "");
    }

    // ──────────────────── The clamp ────────────────────

    /// @dev The race case this entry exists for: a competing fill landed first,
    ///      the aggregator's requested amount exceeds what's left — the fill
    ///      executes the remainder instead of reverting the whole route.
    function test_fillUpTo_clampsOnRace() public {
        _fund(IN_, OUT_);
        Order memory order = _plainOrder(3, address(tA), address(tB), IN_, OUT_);
        bytes memory sig = _sign(order);

        // Competing fill takes 60% first.
        vm.prank(solver);
        settlement.fill(order, sig, (IN_ * 60) / 100);

        uint256 aBefore = tA.balanceOf(solver);
        vm.prank(solver);
        (uint256 delta, uint256[] memory received, uint256[] memory paid) =
            settlement.fillUpTo(order, sig, IN_, address(0), 0, "");

        uint256 rem = (IN_ * 40) / 100;
        assertEq(delta, rem, "clamped to the remaining 40%");
        assertEq(received[0], tA.balanceOf(solver) - aBefore, "receipt matches balance delta");
        assertEq(received[0], rem, "fixed anchor leg receipt = delta");
        assertEq(paid[0], (OUT_ * 40) / 100, "paid the pro-rata output");
        assertEq(lens.remaining(order), 0, "order now exhausted");
    }

    function test_fillUpTo_overRequest_clampsToFull() public {
        _fund(IN_, OUT_);
        Order memory order = _plainOrder(4, address(tA), address(tB), IN_, OUT_);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        (uint256 delta,,) = settlement.fillUpTo(order, sig, IN_ * 3, address(0), 0, "");
        assertEq(delta, IN_, "over-request clamps to the whole order");
    }

    /// @dev A full-fill-only order (`minFillAnchor == anchor` — the SETTLE-item
    ///      shape): an over-request clamps to exactly the full size and passes the
    ///      floor, so "fill whatever's there" works on indivisible orders too.
    function test_fillUpTo_fullFillOnlyOrder_overRequest_succeeds() public {
        _fund(IN_, OUT_);
        Order memory order = _plainOrder(5, address(tA), address(tB), IN_, OUT_);
        order.minFillAnchor = IN_;
        bytes memory sig = _sign(order);

        vm.prank(solver);
        (uint256 delta,,) = settlement.fillUpTo(order, sig, type(uint256).max, address(0), 0, "");
        assertEq(delta, IN_, "clamped exactly onto the full-fill floor");
    }

    /// @dev The maker-signed anti-dust floor still gates the CLAMPED delta: when a
    ///      race leaves less than `minFillAnchor`, the fill must revert, not
    ///      violate the floor. (Aggregators skip such orders via the lens.)
    function test_fillUpTo_clampBelowMinFill_reverts() public {
        _fund(IN_, OUT_);
        Order memory order = _plainOrder(6, address(tA), address(tB), IN_, OUT_);
        order.minFillAnchor = (IN_ * 30) / 100;
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, (IN_ * 80) / 100); // leaves 20% < 30% floor

        vm.prank(solver);
        vm.expectRevert(OrderState.FillTooSmall.selector);
        settlement.fillUpTo(order, sig, IN_, address(0), 0, "");
    }

    // ── dead orders fall through to the classic precise errors ──

    function test_fillUpTo_fullyFilled_reverts_OverFill() public {
        _fund(IN_, OUT_);
        Order memory order = _plainOrder(7, address(tA), address(tB), IN_, OUT_);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, IN_);

        vm.prank(solver);
        vm.expectRevert(OrderState.OverFill.selector);
        settlement.fillUpTo(order, sig, 1, address(0), 0, "");
    }

    function test_fillUpTo_cancelledByHash_reverts_OrderCancelled() public {
        _fund(IN_, OUT_);
        Order memory order = _plainOrder(8, address(tA), address(tB), IN_, OUT_);
        bytes memory sig = _sign(order);

        vm.prank(maker);
        settlement.cancelOrder(order);

        vm.prank(solver);
        vm.expectRevert(OrderState.OrderCancelled.selector);
        settlement.fillUpTo(order, sig, IN_, address(0), 0, "");
    }

    // ──────────────────── recipient: destination, never authority ────────────────────

    /// @dev Proceeds land at `recipient`; the fill's AUTHORITY (here: hard
    ///      exclusivity for `solver`) still keys on `msg.sender`.
    function test_fillUpTo_recipient_redirectsProceedsOnly() public {
        _fund(IN_, OUT_);
        Order memory order = _plainOrder(9, address(tA), address(tB), IN_, OUT_);
        order.exclusiveFiller = solver;
        _setExclusivityEnd(order, block.timestamp + 1 hours);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        (, uint256[] memory received,) = settlement.fillUpTo(order, sig, IN_, recipient, 0, "");

        assertEq(tA.balanceOf(recipient), IN_, "proceeds redirected to recipient");
        assertEq(tA.balanceOf(solver), 0, "nothing at the filler");
        assertEq(received[0], IN_, "receipt reported for the redirected leg");
    }

    /// @dev And a non-exclusive caller naming `recipient` still cannot fill — the
    ///      exclusivity gate reads the filler, not the payout destination.
    function test_fillUpTo_recipient_doesNotBypassExclusivity() public {
        _fund(IN_, OUT_);
        Order memory order = _plainOrder(10, address(tA), address(tB), IN_, OUT_);
        order.exclusiveFiller = address(0xD00D);
        _setExclusivityEnd(order, block.timestamp + 1 hours);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSignature("NotExclusiveFiller()"));
        settlement.fillUpTo(order, sig, IN_, address(0xD00D), 0, "");
    }

    // ──────────────────── received exactness under decay ────────────────────

    /// @dev BUY mid-auction: the filler's receipt is tick-dependent (rising
    ///      input) — exactly the case the return value exists for. The recomputed
    ///      `received` must equal the real balance delta to the wei.
    function test_fillUpTo_buy_receivedMatchesBalance_midDecay() public {
        uint256 startIn = 1_000e18;
        uint256 endIn = 2_000e18;
        uint256 out = 1e18;
        _fund(endIn, out); // maker funded to the auction ceiling

        Order memory order = _buyOrder(11, address(tA), address(tB), startIn, endIn, out);
        _setDecayStart(order, block.timestamp);
        _setDecayDuration(order, 1000);
        bytes memory sig = _sign(order);

        vm.warp(block.timestamp + 500); // mid-auction

        uint256 aBefore = tA.balanceOf(solver);
        vm.prank(solver);
        (uint256 delta, uint256[] memory received, uint256[] memory paid) =
            settlement.fillUpTo(order, sig, out, address(0), 0, "");

        assertEq(delta, out, "BUY delta in output units");
        assertEq(paid[0], out, "delivered the exact output");
        assertEq(received[0], tA.balanceOf(solver) - aBefore, "tick-priced receipt matches balance");
        assertGt(received[0], startIn, "auction has risen");
        assertLt(received[0], endIn, "but not to the ceiling");
    }

    /// @dev SELL with two input legs — the fixed anchor plus a RISING relayer-fee
    ///      leg: `received` covers every input leg, each matching its balance delta.
    function test_fillUpTo_risingFeeLeg_receivedBothLegs() public {
        _fund(IN_, OUT_);
        // Fee leg: maker also gives tC, rising 10e18 → 30e18 over the window.
        tC.mint(maker, 30e18);
        _makerApprove(address(settlement), address(tC), 30e18);

        Order memory order = _plainOrder(12, address(tA), address(tB), IN_, OUT_);
        LegIn[] memory legs = new LegIn[](2);
        legs[0] = LegIn(
            PackedEncode.getLegInToken(order.legsIn, 0),
            PackedEncode.getLegInStart(order.legsIn, 0),
            PackedEncode.getLegInEnd(order.legsIn, 0)
        );
        legs[1] = LegIn(address(tC), 10e18, 30e18);
        order.legsIn = PackedEncode.legsIn(legs);
        _setDecayStart(order, block.timestamp);
        _setDecayDuration(order, 1000);
        bytes memory sig = _sign(order);

        vm.warp(block.timestamp + 500);

        vm.prank(solver);
        (, uint256[] memory received,) = settlement.fillUpTo(order, sig, IN_, address(0), 0, "");

        assertEq(received.length, 2, "both input legs reported");
        assertEq(received[0], tA.balanceOf(solver), "anchor leg receipt");
        assertEq(received[1], tC.balanceOf(solver), "rising fee leg receipt");
        assertGt(received[1], 10e18, "fee auction has risen");
        assertLt(received[1], 30e18, "but not to the ceiling");
    }

    // ──────────────────── Fill-module orders: no core clamp ────────────────────

    /// @dev The proposal passes through unclamped — an over-remaining proposal
    ///      still hits the core's {OverFill} backstop (the module owns the clamp).
    function test_fillUpTo_moduleOrder_proposalNotClamped() public {
        _fund(IN_, OUT_);
        Order memory order = _plainOrder(13, address(tA), address(tB), IN_, OUT_);
        order.fillModule = address(new EchoFillModule());
        order.fillTotal = IN_;
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, (IN_ * 60) / 100);

        vm.prank(solver);
        vm.expectRevert(OrderState.OverFill.selector);
        settlement.fillUpTo(order, sig, IN_, address(0), 0, "");
    }

    /// @dev A module that clamps itself via `prevFilled` — the documented
    ///      module-side obligation — composes with `fillUpTo` cleanly.
    function test_fillUpTo_moduleOrder_moduleClampsItself() public {
        _fund(IN_, OUT_);
        Order memory order = _plainOrder(14, address(tA), address(tB), IN_, OUT_);
        order.fillModule = address(new ClampingFillModule());
        order.fillTotal = IN_;
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, (IN_ * 60) / 100);

        vm.prank(solver);
        (uint256 delta,,) = settlement.fillUpTo(order, sig, IN_, address(0), 0, "");
        assertEq(delta, (IN_ * 40) / 100, "module clamped to remaining");
    }

    // ──────────────────── Fuzz: returns ≡ balance deltas ────────────────────

    /// @dev For any pre-fill, request, and auction tick: `delta` is the clamped
    ///      progress and the returned `(received, paid)` equal the filler's real
    ///      balance deltas to the wei — the property an aggregator's accounting
    ///      relies on instead of snapshotting.
    function testFuzz_fillUpTo_returnsEqualBalanceDeltas(uint256 preFill, uint256 request, uint256 warp) public {
        uint256 outStart = 2e18;
        uint256 outEnd = 1e18; // SELL output decays 2 → 1 over the window
        preFill = bound(preFill, 1, IN_ - 1);
        request = bound(request, 1, IN_ * 2);
        warp = bound(warp, 0, 1500); // past the window too (clamps at end price)

        _fund(IN_, 2 * outStart); // solver funded for both fills at worst tick
        Order memory order = _plainOrder(15, address(tA), address(tB), IN_, outStart);
        order.legsOut = PackedEncode.setLegOutEnd(order.legsOut, 0, outEnd);
        _setDecayStart(order, block.timestamp);
        _setDecayDuration(order, 1000);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, preFill);

        vm.warp(block.timestamp + warp);

        uint256 aBefore = tA.balanceOf(solver);
        uint256 bBefore = tB.balanceOf(solver);
        vm.prank(solver);
        (uint256 delta, uint256[] memory received, uint256[] memory paid) =
            settlement.fillUpTo(order, sig, request, address(0), 0, "");

        uint256 rem = IN_ - preFill;
        assertEq(delta, request > rem ? rem : request, "delta = min(request, remaining)");
        assertEq(received[0], tA.balanceOf(solver) - aBefore, "received == balance gain");
        assertEq(paid[0], bBefore - tB.balanceOf(solver), "paid == balance spend");
        assertEq(settlement.filled(lens.hashOrder(order)), preFill + delta, "progress accounted");
    }

    // ──────────────────── minBumpBps: the filler's price floor ────────────────────

    /// @dev A decaying SELL (output 2e18 → 1e18 over 1000s) at mid-window: the
    ///      resolved bump is exactly 5000, so a floor AT the quote passes.
    function _minBumpOrder(uint256 nonce) internal view returns (Order memory order) {
        order = _plainOrder(nonce, address(tA), address(tB), IN_, OUT_);
        order.legsOut = PackedEncode.setLegOutEnd(order.legsOut, 0, OUT_ / 2);
        _setDecayStart(order, block.timestamp);
        _setDecayDuration(order, 1000);
    }

    function test_fillUpTo_minBump_atQuote_succeeds() public {
        _fund(IN_, OUT_);
        Order memory order = _minBumpOrder(20);
        bytes memory sig = _sign(order);
        vm.warp(block.timestamp + 500); // bump = 5000

        vm.prank(solver);
        (uint256 delta,,) = settlement.fillUpTo(order, sig, IN_, address(0), 5_000, "");
        assertEq(delta, IN_, "filled - resolved bump meets the floor exactly");
    }

    function test_fillUpTo_minBump_belowQuote_reverts() public {
        _fund(IN_, OUT_);
        Order memory order = _minBumpOrder(21);
        bytes memory sig = _sign(order);
        vm.warp(block.timestamp + 500); // bump = 5000

        vm.prank(solver);
        vm.expectRevert(Base.BumpTooLow.selector);
        settlement.fillUpTo(order, sig, IN_, address(0), 5_001, "");
    }

    /// @dev An all-fixed order never leaves bump 0, so any floor > 0 fails — the
    ///      filler asked for a price movement the order cannot express.
    function test_fillUpTo_minBump_fixedOrder_reverts() public {
        _fund(IN_, OUT_);
        Order memory order = _plainOrder(22, address(tA), address(tB), IN_, OUT_);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(Base.BumpTooLow.selector);
        settlement.fillUpTo(order, sig, IN_, address(0), 1, "");
    }

    /// @dev Zero floor is the pre-existing behaviour: no check, an all-fixed order
    ///      fills untouched.
    function test_fillUpTo_minBump_zero_noCheck() public {
        _fund(IN_, OUT_);
        Order memory order = _plainOrder(23, address(tA), address(tB), IN_, OUT_);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        (uint256 delta,,) = settlement.fillUpTo(order, sig, IN_, address(0), 0, "");
        assertEq(delta, IN_, "zero floor = no gate");
    }

    /// @dev A pricing-module order PINS its bump ({FillCtx.bump}); the floor must
    ///      be checked against the pinned value, not the clock. The order has NO
    ///      decay window (clock bump would be 0), the module answers 4000: a floor
    ///      of 4000 passes — proof the check reads the pin — and 4001 reverts.
    function test_fillUpTo_minBump_checksPinnedModuleBump() public {
        _fund(IN_, OUT_ * 2);
        RangePriceModule mod = new RangePriceModule(4_000, 10_000);

        Order memory order = _plainOrder(24, address(tA), address(tB), IN_, OUT_);
        order.legsOut = PackedEncode.setLegOutEnd(order.legsOut, 0, OUT_ / 2);
        order.pricingModule = address(mod);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(Base.BumpTooLow.selector);
        settlement.fillUpTo(order, sig, IN_ / 2, address(0), 4_001, "");

        vm.prank(solver);
        (uint256 delta,,) = settlement.fillUpTo(order, sig, IN_ / 2, address(0), 4_000, "");
        assertEq(delta, IN_ / 2, "pinned module bump meets the floor");
    }
}
