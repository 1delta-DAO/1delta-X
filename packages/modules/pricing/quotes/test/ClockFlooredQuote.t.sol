// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order, CurvePoint} from "@core/settlement/Settlement.sol";
import {ClockFlooredQuoteModule} from "../src/ClockFlooredQuoteModule.sol";
import {CosignedQuotePriceModule} from "../src/CosignedQuotePriceModule.sol";

import {OrderGates} from "@core/settlement/OrderGates.sol";
import {MockSettlementBase} from "@coretest/shared/MockSettlementBase.t.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

/// @title ClockFlooredQuote
/// @notice {ClockFlooredQuoteModule} — the cosigned quote with the dutch clock as a
///         ceiling on the bump, so a quote can only ever improve on plain dutch.
///
///  The property under test throughout: WHATEVER the cosigner signs, the maker
///  never does worse than it would have on the built-in clock. That is what makes
///  the module safe to point at a cosigner the maker does not fully trust, and it
///  is the difference from {CosignedQuotePriceModule}, whose pinned bump REPLACES
///  the clock (asserted head-to-head in `test_versusCosigned_...` below).
contract ClockFlooredQuoteTest is MockSettlementBase {
    uint256 constant SELL_IN = 1_000e18; //   the maker's fixed input (anchor)
    uint256 constant OUT_START = 2_000e18; // best-for-maker output
    uint256 constant OUT_END = 1_000e18; //   the maker's floor
    uint256 constant DURATION = 1_000; //     decay window, seconds

    uint256 constant COSIGNER_PK = 0xC05161;

    ClockFlooredQuoteModule mod;

    function setUp() public override {
        super.setUp();
        mod = new ClockFlooredQuoteModule(vm.addr(COSIGNER_PK));
        vm.label(address(mod), "clockFlooredQuoteModule");
    }

    function _fund(uint256 outAmount) internal {
        tA.mint(maker, SELL_IN);
        _makerApprove(address(settlement), address(tA), SELL_IN);
        tB.mint(solver, outAmount);
        _solverApprove(address(settlement), address(tB), outAmount);
    }

    /// @dev A decaying SELL priced by `module`: fixed input, output falling
    ///      OUT_START → OUT_END over DURATION seconds from now.
    function _order(uint256 nonce, address module) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), SELL_IN, OUT_START);
        o.legsOut = PackedEncode.oneLegOut(address(tB), OUT_START, OUT_END, address(0));
        _setDecayStart(o, block.timestamp);
        _setDecayDuration(o, DURATION);
        o.pricingModule = module;
    }

    /// @dev `takerData = filler(20) ‖ bumpBps(32) ‖ deadline(32) ‖ sig`, cosigned for
    ///      whichever module instance is passed (the digest binds `address(this)`).
    function _quote(address module, bytes32 orderHash, uint256 bumpBps) internal view returns (bytes memory) {
        uint256 deadline = block.timestamp + 5 minutes;
        bytes32 digest = ClockFlooredQuoteModule(module).quoteDigest(orderHash, solver, bumpBps, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(COSIGNER_PK, digest);
        return abi.encodePacked(solver, bumpBps, deadline, r, s, v);
    }

    /// @dev The output the maker receives for a `bps` bump on this band.
    function _outAt(uint256 bps) internal pure returns (uint256) {
        return OUT_START - ((OUT_START - OUT_END) * bps) / 10_000;
    }

    // ════════════════ the quote is an improvement channel ════════════════

    /// @dev Quote BETTER than the clock ⇒ the quote wins. Half-way through the
    ///      window the clock is at 5000 bps; a 2500 bps quote is a real improvement
    ///      and the maker gets it.
    function test_quoteBetterThanClock_wins() public {
        _fund(OUT_START);
        Order memory o = _order(1, address(mod));
        bytes memory sig = _sign(o);
        bytes32 orderHash = lens.hashOrder(o);

        vm.warp(block.timestamp + DURATION / 2);
        bytes memory takerData = _quote(address(mod), orderHash, 2_500);

        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN, takerData);
        assertEq(tB.balanceOf(maker) - before_, _outAt(2_500), "the better quote, not the clock");
    }

    /// @dev Quote WORSE than the clock ⇒ the clock wins. This is the whole point:
    ///      the cosigner cannot charge the maker more than time already has.
    function test_quoteWorseThanClock_isIgnored() public {
        _fund(OUT_START);
        Order memory o = _order(2, address(mod));
        bytes memory sig = _sign(o);
        bytes32 orderHash = lens.hashOrder(o);

        vm.warp(block.timestamp + DURATION / 4); // clock = 2500 bps
        bytes memory takerData = _quote(address(mod), orderHash, 8_000);

        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN, takerData);
        assertEq(tB.balanceOf(maker) - before_, _outAt(2_500), "floored by the clock");
    }

    /// @dev THE SECURITY PROPERTY. A fully hostile cosigner — colluding with the
    ///      filler, signing the maker's floor on the first tick of the auction —
    ///      still cannot do better than the clock would have on its own.
    function test_hostileCosigner_cannotBeatTheClock() public {
        _fund(OUT_START);
        Order memory o = _order(3, address(mod));
        bytes memory sig = _sign(o);
        bytes32 orderHash = lens.hashOrder(o);

        vm.warp(block.timestamp + DURATION / 10); // clock = 1000 bps
        bytes memory takerData = _quote(address(mod), orderHash, 10_000); // the maker's FLOOR

        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN, takerData);
        assertEq(tB.balanceOf(maker) - before_, _outAt(1_000), "the clock, not the floor");
    }

    /// @dev No quote at all ⇒ an ordinary dutch fill. The cosigner is an improver,
    ///      never a gatekeeper, and its absence costs the maker nothing.
    function test_noQuote_isPlainDutch() public {
        _fund(OUT_START);
        Order memory o = _order(4, address(mod));
        bytes memory sig = _sign(o);

        vm.warp(block.timestamp + DURATION / 2);
        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN);
        assertEq(tB.balanceOf(maker) - before_, _outAt(5_000), "the clock midpoint");
    }

    /// @dev The head-to-head. Same order, same instant, same absent quote:
    ///      {CosignedQuotePriceModule} configured `FALLBACK_BPS = BPS` hands the
    ///      filler the maker's FLOOR with no decay ramp (its documented footgun);
    ///      this module hands it the clock. The footgun does not exist here because
    ///      there is no fallback to misconfigure — `min(anything, clock)` is the
    ///      clock.
    function test_versusCosigned_unquotedFillIsNotTheFloor() public {
        CosignedQuotePriceModule legacy = new CosignedQuotePriceModule(vm.addr(COSIGNER_PK), 10_000);

        _fund(OUT_START);
        Order memory a = _order(5, address(legacy));
        bytes memory sigA = _sign(a);
        vm.warp(block.timestamp + DURATION / 2);
        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(a, sigA, SELL_IN);
        assertEq(tB.balanceOf(maker) - before_, OUT_END, "legacy: unquoted clears at the floor");

        _fund(OUT_START);
        Order memory b = _order(6, address(mod));
        bytes memory sigB = _sign(b);
        // `b`'s window opened at the same instant `a`'s did, so both are half-way in.
        _setDecayStart(b, block.timestamp - DURATION / 2);
        sigB = _sign(b);
        before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(b, sigB, SELL_IN);
        assertEq(tB.balanceOf(maker) - before_, _outAt(5_000), "floored: unquoted clears on the clock");
    }

    // ════════════════════════ shape and edge cases ════════════════════════

    /// @dev `decayDuration == 0` ⇒ the maker signed a fixed price ⇒ the clock ceiling
    ///      is 0 ⇒ no quote can extract any concession. Documented on the contract,
    ///      pinned here: a maker that wants an auction must sign a window for it.
    function test_noDecayWindow_admitsNoConcession() public {
        _fund(OUT_START);
        Order memory o = _order(7, address(mod));
        _setDecayDuration(o, 0);
        bytes memory sig = _sign(o);
        bytes32 orderHash = lens.hashOrder(o);
        bytes memory takerData = _quote(address(mod), orderHash, 5_000);

        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN, takerData);
        assertEq(tB.balanceOf(maker) - before_, OUT_START, "the maker's ambition, quote ignored");
    }

    /// @dev A quote the cosigner did not sign still reverts — the floor is a bound on
    ///      an HONEST quote, not a licence to skip verification.
    function test_forgedQuote_reverts() public {
        _fund(OUT_START);
        Order memory o = _order(8, address(mod));
        bytes memory sig = _sign(o);
        bytes32 orderHash = lens.hashOrder(o);

        vm.warp(block.timestamp + DURATION / 2);
        uint256 deadline = block.timestamp + 5 minutes;
        bytes32 digest = mod.quoteDigest(orderHash, solver, 2_500, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(uint256(0xBAD), digest);
        bytes memory takerData = abi.encodePacked(solver, uint256(2_500), deadline, r, s, v);

        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(o, sig, SELL_IN, takerData);
    }

    /// @dev A quote minted for a DIFFERENT module instance does not verify here: the
    ///      digest hashes `address(this)`.
    function test_quoteFromOtherInstance_reverts() public {
        ClockFlooredQuoteModule other = new ClockFlooredQuoteModule(vm.addr(COSIGNER_PK));
        _fund(OUT_START);
        Order memory o = _order(9, address(mod));
        bytes memory sig = _sign(o);
        bytes32 orderHash = lens.hashOrder(o);

        vm.warp(block.timestamp + DURATION / 2);
        bytes memory takerData = _quote(address(other), orderHash, 2_500);

        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(o, sig, SELL_IN, takerData);
    }

    /// @dev The ceiling is read on the order's OWN clock — blocks under `timing`
    ///      bit 102, with the timestamp deliberately untouched.
    function test_blockClock_ceilingCountsBlocks() public {
        _fund(OUT_START);
        Order memory o = _order(10, address(mod));
        _setDecayStart(o, block.number);
        _setDecayDuration(o, 10);
        o.timing |= uint256(1) << 102;
        bytes memory sig = _sign(o);
        bytes32 orderHash = lens.hashOrder(o);

        vm.roll(block.number + 5); // half the window, in BLOCKS
        bytes memory takerData = _quote(address(mod), orderHash, 9_000); // worse than the clock

        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN, takerData);
        assertEq(tB.balanceOf(maker) - before_, _outAt(5_000), "block-clock midpoint, quote floored");
    }

    /// @dev The lens must quote this module exactly as the fill prices it, or a book
    ///      publishes prices no fill can honour.
    function test_previewFill_matchesFill() public {
        _fund(OUT_START);
        Order memory o = _order(11, address(mod));
        bytes memory sig = _sign(o);
        bytes32 orderHash = lens.hashOrder(o);

        vm.warp(block.timestamp + DURATION / 3);
        bytes memory takerData = _quote(address(mod), orderHash, 1_000);

        // `received` is what the FILLER receives (the maker's inputs); `paid` is what it
        // delivers — the maker's output legs, which is the priced side here.
        (,, uint256[] memory paid) = lens.previewFill(o, SELL_IN, solver, takerData);
        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN, takerData);
        assertEq(tB.balanceOf(maker) - before_, paid[0], "preview == fill");
    }

    // ═══════════════════════════ the invariant ═══════════════════════════

    /// @dev THE INVARIANT, fuzzed over the whole window and the whole quote range:
    ///      an unquoted clock-floored fill pays the maker EXACTLY what the built-in
    ///      dutch clock would have, and a quoted one pays at least that much. No
    ///      cosigner behaviour anywhere in the range can make the maker worse off
    ///      than signing no price module at all.
    function testFuzz_neverWorseThanPlainDutch(uint32 elapsed, uint16 quotedBps) public {
        elapsed = uint32(bound(elapsed, 0, DURATION * 2));
        quotedBps = uint16(bound(quotedBps, 0, 10_000));

        // The baseline: the identical band with NO price module, i.e. the built-in
        // clock, filled at the same offset into its window.
        _fund(OUT_START);
        Order memory plain = _order(12, address(0));
        bytes memory sigPlain = _sign(plain);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + elapsed);
        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(plain, sigPlain, SELL_IN);
        uint256 dutchOut = tB.balanceOf(maker) - before_;

        // The module order, same band, same offset, plus an arbitrary quote.
        _fund(OUT_START);
        Order memory quoted = _order(13, address(mod));
        _setDecayStart(quoted, t0);
        bytes memory sigQuoted = _sign(quoted);
        bytes memory takerData = _quote(address(mod), lens.hashOrder(quoted), quotedBps);
        before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(quoted, sigQuoted, SELL_IN, takerData);
        uint256 quotedOut = tB.balanceOf(maker) - before_;

        assertGe(quotedOut, dutchOut, "a quote can never pay the maker less than the clock");
        if (quotedBps >= mod.clockBump(quoted.timing)) {
            assertEq(quotedOut, dutchOut, "a quote at or above the clock IS the clock");
        }
    }

    // ═════════════════ lens agreement (regression) ═════════════════

    /// @dev REGRESSION. {SettlementLens.validateOrder} used to reject any order
    ///      pairing a `pricingModule` with a decay window ("decay duration with price
    ///      module"), on the reasoning that a module pins the bump so the clock never
    ///      runs. That reasoning does not hold for a CLOCK-CONSUMING module: this one
    ///      reads `decayDuration` out of the `timing` word it is handed and uses it as
    ///      the ceiling. The old rule therefore called every WORKING quote-auction
    ///      order invalid, while blessing only `decayDuration == 0` — the one shape
    ///      whose ceiling is a constant 0 and whose quote channel is dead.
    ///
    ///      The lens is advisory (no fill is gated on it), but it is the validity
    ///      oracle a book or wallet screens with, so a false reject takes the feature
    ///      out of service just as effectively.
    function test_lens_acceptsFunctionalClockFlooredOrder() public view {
        Order memory o = _order(20, address(mod));
        // `decayDuration` = timing[32:64) — read directly; the {DutchAuction} accessor
        // takes `Order calldata` and this order is in memory.
        assertEq(uint256(uint32(o.timing >> 32)), DURATION, "precondition: a real decay window");
        (bool ok, string memory reason) = lens.validateOrder(o);
        assertTrue(ok, reason);
    }

    /// @dev The other half of the regression: the shape the old rule allowed is the
    ///      degenerate one. Still valid (a maker may legitimately sign a fixed price),
    ///      but its ceiling is 0 forever, so `min(quote, 0) == 0` pins the maker at
    ///      `start` whatever the cosigner says. Asserted so the two shapes cannot
    ///      quietly swap meanings.
    function test_lens_zeroWindowIsValidButHasNoQuoteChannel() public {
        Order memory o = _order(21, address(mod));
        _setDecayDuration(o, 0);
        (bool ok,) = lens.validateOrder(o);
        assertTrue(ok, "a fixed-price module order stays valid");
        assertEq(mod.clockBump(o.timing), 0, "ceiling is 0 at the start");
        vm.warp(block.timestamp + DURATION * 10);
        assertEq(mod.clockBump(o.timing), 0, "and 0 forever after");
    }

    /// @dev The boundary the fix deliberately KEEPS. {IPriceModule.bump} is handed
    ///      `order.timing` and the leg blobs and nothing else, so `order.curve` and
    ///      `order.params` are unreachable by ANY price module and a signed curve or
    ///      gas bump is provably inert — those stay rejected. Only `decayDuration`,
    ///      which lives in the `timing` word the module actually receives, was
    ///      wrongly called inert.
    function test_lens_stillRejectsProvablyInertFields() public view {
        CurvePoint[] memory pts = new CurvePoint[](2);
        pts[0] = CurvePoint({timeDelta: 0, bumpBps: 0});
        pts[1] = CurvePoint({timeDelta: uint32(DURATION), bumpBps: 10_000});
        Order memory withCurve = _order(22, address(mod));
        withCurve.curve = PackedEncode.curve(pts);
        (bool okCurve, string memory rCurve) = lens.validateOrder(withCurve);
        assertFalse(okCurve, "curve is unreachable by a price module");
        assertEq(rCurve, "price module with curve");

        // gasBumpBps = params[16:32), gasPriceRef = params[32:96) — a valid gas bump
        // so the generic gas-bump checks pass and we reach the price-module branch.
        Order memory withGas = _order(23, address(mod));
        withGas.params |= (uint256(500) << 16) | (uint256(1 gwei) << 32);
        (bool okGas, string memory rGas) = lens.validateOrder(withGas);
        assertFalse(okGas, "gas bump is unreachable by a price module");
        assertEq(rGas, "gas bump with price module");
    }

    // ─────────────── filler sets share the `curve` blob ───────────────

    /// @dev A {OrderGates.FILLER_SET} order keeps its filler set in `curve` behind a
    ///      zero count byte — the SAME field the "price module with curve" rule
    ///      guards. The rule keys on the curve POINT COUNT, which is 0 for a set, so
    ///      the two features compose: a set order can price off this module and still
    ///      gate who fills it. Pinned because the obvious "hardening" of that rule
    ///      (`curve.length != 0`) would silently kill the combination.
    function test_fillerSet_composesWithModulePricing() public view {
        address[] memory f = new address[](2);
        f[0] = solver;
        f[1] = address(0x50172);
        bytes memory set = abi.encodePacked(uint8(0), f[0], f[1]);

        Order memory o = _order(30, address(mod));
        o.exclusiveFiller = OrderGates.FILLER_SET;
        o.curve = set;
        _setExclusivityEnd(o, block.timestamp + DURATION / 2);

        (bool ok, string memory reason) = lens.validateOrder(o);
        assertTrue(ok, reason);
    }

    /// @dev And the set member's quote still prices through the clock floor: the set
    ///      changes WHO may fill, never at what price.
    function test_fillerSet_memberQuoteStillFlooredByClock() public {
        _fund(OUT_START);
        Order memory o = _order(31, address(mod));
        o.exclusiveFiller = OrderGates.FILLER_SET;
        o.curve = abi.encodePacked(uint8(0), solver, address(0x50172));
        _setExclusivityEnd(o, block.timestamp + DURATION);
        bytes memory sig = _sign(o);

        vm.warp(block.timestamp + DURATION / 2); // clock ceiling = 5000 bps
        // A quote WORSE than the clock is ignored; the clock still governs.
        bytes memory td = _quote(address(mod), lens.hashOrder(o), 9_000);
        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN, td);
        assertEq(tB.balanceOf(maker) - before_, _outAt(5_000), "clock floor holds inside a set");
    }
}
