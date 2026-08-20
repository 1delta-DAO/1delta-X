// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order} from "@core/settlement/Settlement.sol";
import {OrderGates} from "@core/settlement/OrderGates.sol";

import {MockSettlementBase} from "../shared/MockSettlementBase.t.sol";
import {PackedEncode} from "../shared/PackedEncode.sol";

/// @title FillerSetExclusivity
/// @notice The inline filler-SET exclusivity: `exclusiveFiller == address(1)`
///         (={OrderGates.FILLER_SET}) reads a maker-signed set from the `curve`
///         blob — `[0x00] ‖ [20-byte filler]×N` — against the existing window
///         (`timing` bits [64:96)) and the existing soft override (`params` bits
///         [0:16)). Under test: any member fills in-window, outsiders are blocked
///         (hard) or surcharged (SOFT — the capability the validator variant could
///         not express), the window opens to everyone on the order's own clock,
///         the zero count byte keeps the DECAY CLOCK blind to the set bytes, and
///         every malformed set shape is loudly unfillable.
contract FillerSetExclusivityTest is MockSettlementBase {
    uint256 constant AMOUNT_IN = 100e18; //  tA maker gives
    uint256 constant AMOUNT_OUT = 300e18; // tB maker gets
    uint32 constant WINDOW = 600; //         exclusivity, seconds (blocks under bit 102)

    address solver2 = address(0x50172); // second set member
    address outsider = address(0x0DD); // never in the set

    function setUp() public override {
        super.setUp();
        tA.mint(maker, 1_000e18);
        _makerApprove(address(settlement), address(tA), type(uint160).max);

        // Everyone can deliver tokenOut, so the ONLY thing separating the three
        // fillers is the set gate.
        address[3] memory fillers = [solver, solver2, outsider];
        for (uint256 i; i < 3; i++) {
            tB.mint(fillers[i], 1_000e18);
            vm.startPrank(fillers[i]);
            tB.approve(address(permit3), type(uint256).max);
            permit3.approveToken(address(settlement), address(tB), type(uint160).max, 0);
            vm.stopPrank();
        }
    }

    // ──────────────────── Helpers ────────────────────

    /// @dev `curve = [0x00] ‖ fillers` — the count byte is ZERO so the decay clock
    ///      reads "no curve points" and never parses the set bytes.
    function _setBlob(address[] memory fillers) internal pure returns (bytes memory blob) {
        blob = abi.encodePacked(uint8(0));
        for (uint256 i; i < fillers.length; i++) {
            blob = abi.encodePacked(blob, fillers[i]);
        }
    }

    function _two(address a, address b) internal pure returns (address[] memory fillers) {
        fillers = new address[](2);
        fillers[0] = a;
        fillers[1] = b;
    }

    /// @dev Plain tA→tB order whose exclusivity names a SET until `end`.
    function _setOrder(uint256 nonce, uint256 end, address[] memory fillers) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        o.exclusiveFiller = OrderGates.FILLER_SET;
        _setExclusivityEnd(o, end);
        o.curve = _setBlob(fillers);
    }

    // ──────────────── In-window: the set, and only the set ────────────────

    function test_fillerSet_firstMemberFills() public {
        Order memory o = _setOrder(1, block.timestamp + WINDOW, _two(solver, solver2));
        bytes memory sig = _sign(o);
        vm.prank(solver);
        settlement.fill(o, sig, AMOUNT_IN);
        assertEq(tA.balanceOf(solver), AMOUNT_IN, "first set member filled");
    }

    function test_fillerSet_secondMemberFills() public {
        Order memory o = _setOrder(2, block.timestamp + WINDOW, _two(solver, solver2));
        bytes memory sig = _sign(o);
        vm.prank(solver2);
        settlement.fill(o, sig, AMOUNT_IN);
        assertEq(tA.balanceOf(solver2), AMOUNT_IN, "second set member filled");
    }

    function test_fillerSet_outsiderBlockedInWindow() public {
        Order memory o = _setOrder(3, block.timestamp + WINDOW, _two(solver, solver2));
        bytes memory sig = _sign(o);
        vm.prank(outsider);
        vm.expectRevert(OrderGates.NotExclusiveFiller.selector);
        settlement.fill(o, sig, AMOUNT_IN);
    }

    /// @dev The liveness property the window exists for: the whole set walking away
    ///      costs the maker the window, not the order.
    function test_fillerSet_outsiderFillsAfterWindow() public {
        Order memory o = _setOrder(4, block.timestamp + WINDOW, _two(solver, solver2));
        bytes memory sig = _sign(o);
        vm.warp(block.timestamp + WINDOW); // `>=` — open at exactly the deadline
        vm.prank(outsider);
        settlement.fill(o, sig, AMOUNT_IN);
        assertEq(tA.balanceOf(outsider), AMOUNT_IN, "open to everyone past the window");
    }

    // ──────────────── SOFT set exclusivity — the inline dividend ────────────────

    /// @dev A non-zero `exclusivityOverrideBps` makes the SET soft, exactly as it
    ///      does a single filler: an unlisted in-window filler fills, but must
    ///      IMPROVE the maker's price by the override — on this fixed-input SELL,
    ///      the maker's output is lifted by 1% ({Pricing.outputAt}). This is the
    ///      capability that justified inlining — a pass/fail validator cannot
    ///      reach pricing.
    function test_fillerSet_softOverride_outsiderPaysImprovement() public {
        Order memory o = _setOrder(5, block.timestamp + WINDOW, _two(solver, solver2));
        o.params = 100; // overrideBps, params bits [0:16)
        bytes memory sig = _sign(o);

        uint256 before_ = tB.balanceOf(maker);
        vm.prank(outsider);
        settlement.fill(o, sig, AMOUNT_IN);
        assertEq(tB.balanceOf(maker) - before_, AMOUNT_OUT * 10_100 / 10_000, "maker lifted by the override");
        assertEq(tA.balanceOf(outsider), AMOUNT_IN, "input side unchanged (exact-input SELL)");
    }

    /// @dev Set members never pay the override — soft applies only to outsiders.
    function test_fillerSet_softOverride_memberFillsForFree() public {
        Order memory o = _setOrder(6, block.timestamp + WINDOW, _two(solver, solver2));
        o.params = 100;
        bytes memory sig = _sign(o);
        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver2);
        settlement.fill(o, sig, AMOUNT_IN);
        assertEq(tB.balanceOf(maker) - before_, AMOUNT_OUT, "member delivers the plain price");
    }

    // ──────────────── The order's own clock ────────────────

    /// @dev Under `timing` bit 102 the window end is a BLOCK NUMBER. The timestamp
    ///      is warped far past the end VALUE while blocks stay inside it — a
    ///      seconds-clock reading would open the order; the block clock keeps it
    ///      exclusive.
    function test_fillerSet_blockClock_windowCountsBlocks() public {
        Order memory o = _setOrder(7, block.number + 10, _two(solver, solver2));
        o.timing |= uint256(1) << 102;
        bytes memory sig = _sign(o);

        vm.warp(block.timestamp + block.number + 10 + WINDOW);
        vm.prank(outsider);
        vm.expectRevert(OrderGates.NotExclusiveFiller.selector);
        settlement.fill(o, sig, AMOUNT_IN);

        vm.roll(block.number + 10); // NOW the order's clock reaches the end
        vm.prank(outsider);
        settlement.fill(o, sig, AMOUNT_IN);
        assertEq(tA.balanceOf(outsider), AMOUNT_IN, "opened on the block clock");
    }

    // ──────────────── The decay clock stays blind to the set ────────────────

    /// @dev A DECAYING set order prices on the plain linear clock: the zero count
    ///      byte means {DutchAuction.bumpBps} sees no curve points and never parses
    ///      the trailing set bytes as {CurvePoint}s. Half the window ⇒ the midpoint
    ///      price, exactly as if `curve` were empty.
    function test_fillerSet_decayIgnoresSetBytes() public {
        uint256 outEnd = 150e18;
        Order memory o = _setOrder(8, block.timestamp + 1 hours, _two(solver, solver2));
        o.legsOut = PackedEncode.oneLegOut(address(tB), AMOUNT_OUT, outEnd, address(0));
        _setDecayStart(o, block.timestamp);
        _setDecayDuration(o, 1000);
        bytes memory sig = _sign(o);

        vm.warp(block.timestamp + 500); // half the decay window
        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, AMOUNT_IN);
        assertEq(tB.balanceOf(maker) - before_, (AMOUNT_OUT + outEnd) / 2, "linear midpoint, set bytes ignored");
    }

    // ──────────────── Malformed sets: loudly unfillable ────────────────

    /// @dev An EMPTY set (just the count byte) is refused, not read as "open": the
    ///      maker signed exclusivity, and a decode gap must not un-sign it.
    function test_fillerSet_emptySet_isMalformed() public {
        Order memory o = _setOrder(9, block.timestamp + WINDOW, new address[](0));
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(OrderGates.MalformedFillerSet.selector);
        settlement.fill(o, sig, AMOUNT_IN);
    }

    /// @dev A truncated entry cannot silently shorten the set.
    function test_fillerSet_truncatedEntry_isMalformed() public {
        Order memory o = _setOrder(10, block.timestamp + WINDOW, _two(solver, solver2));
        bytes memory whole = o.curve;
        bytes memory truncated = new bytes(whole.length - 1);
        for (uint256 i; i < truncated.length; i++) {
            truncated[i] = whole[i];
        }
        o.curve = truncated;
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(OrderGates.MalformedFillerSet.selector);
        settlement.fill(o, sig, AMOUNT_IN);
    }

    /// @dev A NON-ZERO count byte would hand the same bytes to the curve parser as
    ///      real {CurvePoint}s — one blob with two readings. Refused as a set.
    function test_fillerSet_nonZeroCountByte_isMalformed() public {
        Order memory o = _setOrder(11, block.timestamp + WINDOW, _two(solver, solver2));
        bytes memory blob = o.curve;
        blob[0] = 0x01;
        o.curve = blob;
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(OrderGates.MalformedFillerSet.selector);
        settlement.fill(o, sig, AMOUNT_IN);
    }

    /// @dev Past the window a malformed set no longer gates anything — the whole
    ///      branch is window-scoped, so expiry heals a bad blob into an open order.
    function test_fillerSet_malformedHealsAfterWindow() public {
        Order memory o = _setOrder(12, block.timestamp + WINDOW, new address[](0));
        bytes memory sig = _sign(o);
        vm.warp(block.timestamp + WINDOW);
        vm.prank(outsider);
        settlement.fill(o, sig, AMOUNT_IN);
        assertEq(tA.balanceOf(outsider), AMOUNT_IN, "window expiry opens even a malformed set");
    }

    // ──────────────── Lens agreement on the set blob ────────────────

    /// @dev REGRESSION. The set rides `curve` behind a ZERO count byte, so
    ///      {PackedArrays.validateFixed} reports "no curve points" and every
    ///      curve-shaped rule in {SettlementLens.validateOrder} skips it. That left
    ///      the lens with NO view of the set at all: a malformed one was reported
    ///      valid and then reverted {OrderGates.MalformedFillerSet} on every fill.
    function test_lens_acceptsWellFormedSet() public view {
        Order memory o = _setOrder(40, block.timestamp + WINDOW, _two(solver, solver2));
        (bool ok, string memory reason) = lens.validateOrder(o);
        assertTrue(ok, reason);
    }

    /// @dev A trailing entry that is not a whole 20 bytes. The lens must now agree
    ///      with the settler instead of blessing an order that cannot be filled.
    function test_lens_rejectsMalformedSet_andSoDoesTheFill() public {
        Order memory o = _setOrder(41, block.timestamp + WINDOW, _two(solver, solver2));
        o.curve = abi.encodePacked(o.curve, bytes19(0)); // 19 stray bytes
        (bool ok, string memory reason) = lens.validateOrder(o);
        assertFalse(ok, "lens must reject a malformed set");
        assertEq(reason, "malformed filler set");

        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(OrderGates.MalformedFillerSet.selector);
        settlement.fill(o, sig, AMOUNT_IN);
    }

    /// @dev An EMPTY set (`curve` is just the count byte, or absent). The settler
    ///      refuses it rather than reading "empty ⇒ open" — the maker signed
    ///      exclusivity and a decode gap must not un-sign it. The lens agrees.
    function test_lens_rejectsEmptySet() public view {
        Order memory o = _setOrder(42, block.timestamp + WINDOW, _two(solver, solver2));
        o.curve = abi.encodePacked(uint8(0)); // count byte, no members
        (bool okCount,) = lens.validateOrder(o);
        assertFalse(okCount, "a set with no members is malformed");

        o.curve = "";
        (bool okEmpty,) = lens.validateOrder(o);
        assertFalse(okEmpty, "an absent set blob is malformed");
    }

    /// @dev The deliberate strictness: once the window lapses the set is never parsed,
    ///      so a malformed one FILLS fine — but the lens still reports it. Pinned so
    ///      the asymmetry is a decision rather than a surprise. It matches the two
    ///      exclusivity shape rules beside it, which are unconditional for the same
    ///      reason: the shape section reports what the maker signed.
    function test_lens_malformedSet_reportedEvenAfterWindowLapses() public {
        Order memory o = _setOrder(43, block.timestamp + WINDOW, _two(solver, solver2));
        o.curve = abi.encodePacked(o.curve, bytes19(0));
        bytes memory sig = _sign(o);

        vm.warp(block.timestamp + WINDOW + 1); // window closed — gate never runs
        (bool ok, string memory reason) = lens.validateOrder(o);
        assertFalse(ok, "still reported");
        assertEq(reason, "malformed filler set");

        // ...and the fill genuinely succeeds, which is what makes this strictness.
        vm.prank(outsider);
        settlement.fill(o, sig, AMOUNT_IN);
        assertEq(tA.balanceOf(outsider), AMOUNT_IN, "lapsed window opens to anyone");
    }
}
