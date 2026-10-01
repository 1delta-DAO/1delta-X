// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order} from "@core/settlement/Settlement.sol";
import {ClockFlooredQuoteModule} from "../src/ClockFlooredQuoteModule.sol";
import {CosignedQuotePriceModule} from "../src/CosignedQuotePriceModule.sol";

import {MockSettlementBase} from "@coretest/shared/MockSettlementBase.t.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

/// @title Audit20260930QuotesTest
/// @notice Regressions for the 2026-09-30 audit findings on the quote modules:
///         - PRICE-6 / G-TS_FILLER-7: {ClockFlooredQuoteModule} returned the CLOCK on
///           an unquoted fill, so presenting a quote could only lower the filler's
///           take and the auction channel had no on-chain effect.
///         - PRICE-10: a cosigned quote was not bound to fill progress, so one quote
///           repriced every partial fill of the order until its deadline.
contract Audit20260930QuotesTest is MockSettlementBase {
    uint256 constant SELL_IN = 1_000e18;
    uint256 constant OUT_START = 2_000e18;
    uint256 constant OUT_END = 1_000e18;
    uint256 constant DURATION = 1_000;
    uint256 constant COSIGNER_PK = 0xC05161;

    bytes32 constant NEW_TYPEHASH =
        keccak256("PriceQuote(bytes32 orderHash,address filler,uint256 bumpBps,uint256 deadline,uint256 prevFilled)");

    ClockFlooredQuoteModule floored;
    CosignedQuotePriceModule cosigned;

    function setUp() public override {
        super.setUp();
        floored = new ClockFlooredQuoteModule(vm.addr(COSIGNER_PK));
        cosigned = new CosignedQuotePriceModule(vm.addr(COSIGNER_PK), 0);
    }

    function _fund() internal {
        tA.mint(maker, SELL_IN);
        _makerApprove(address(settlement), address(tA), SELL_IN);
        tB.mint(solver, OUT_START);
        _solverApprove(address(settlement), address(tB), OUT_START);
    }

    function _order(uint256 nonce, address module) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), SELL_IN, OUT_START);
        o.legsOut = PackedEncode.oneLegOut(address(tB), OUT_START, OUT_END, address(0));
        _setDecayStart(o, block.timestamp);
        _setDecayDuration(o, DURATION);
        o.pricingModule = module;
    }

    function _outAt(uint256 bps) internal pure returns (uint256) {
        return OUT_START - ((OUT_START - OUT_END) * bps) / 10_000;
    }

    /// @dev Quote for the FIRST fill, via the 4-arg digest both the old and new
    ///      modules expose.
    function _firstFillQuote(address module, bytes32 orderHash, uint256 bumpBps) internal view returns (bytes memory) {
        uint256 deadline = block.timestamp + 5 minutes;
        bytes32 digest = ClockFlooredQuoteModule(module).quoteDigest(orderHash, solver, bumpBps, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(COSIGNER_PK, digest);
        return abi.encodePacked(solver, bumpBps, deadline, r, s, v);
    }

    /// @dev Quote for the fill that starts at `prevFilled` (the PRICE-10 digest,
    ///      computed independently of the module's helper).
    function _progressQuote(address module, bytes32 orderHash, uint256 bumpBps, uint256 prevFilled)
        internal
        view
        returns (bytes memory)
    {
        uint256 deadline = block.timestamp + 5 minutes;
        bytes32 digest = keccak256(
            abi.encode(NEW_TYPEHASH, orderHash, solver, bumpBps, deadline, prevFilled, block.chainid, module)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(COSIGNER_PK, digest);
        return abi.encodePacked(solver, bumpBps, deadline, r, s, v);
    }

    // ───────────────────────── PRICE-6 / G-TS_FILLER-7 ─────────────────────────

    /// Half-way through the window (clock = 5000 bps) the auction's winning quote is
    /// 2500. The filler's best response must now be to PRESENT it: unquoted earns no
    /// concession (bump 0), quoted earns 2500. Before the fix the unquoted fill got
    /// 5000 — strictly more — so no rational filler ever presented a quote.
    function test_audit_PRICE_6_presentingTheQuoteIsTheFillersBestResponse() public {
        Order memory o = _order(1, address(floored));
        bytes32 h = lens.hashOrder(o);
        vm.warp(block.timestamp + DURATION / 2);
        bytes memory quote = _firstFillQuote(address(floored), h, 2_500);

        uint256 unquoted = floored.bump(h, maker, solver, 0, SELL_IN, o.timing, o.legsIn, o.legsOut, "");
        uint256 quoted = floored.bump(h, maker, solver, 0, SELL_IN, o.timing, o.legsIn, o.legsOut, quote);
        assertEq(unquoted, 0, "no quote, no concession");
        assertEq(quoted, 2_500, "the winning quote");
        assertGt(quoted, unquoted, "presenting the quote pays the filler more");
    }

    /// End to end: an unquoted fill mid-window clears at the maker's `start`, not at
    /// the clock; the quoted fill clears at the quote.
    function test_audit_PRICE_6_unquotedFill_clearsAtStart() public {
        _fund();
        Order memory o = _order(2, address(floored));
        bytes memory sig = _sign(o);
        vm.warp(block.timestamp + DURATION / 2);

        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN / 2);
        assertEq(tB.balanceOf(maker) - before_, OUT_START / 2, "unquoted half at `start`");
    }

    // ───────────────────────────────── PRICE-10 ─────────────────────────────────

    /// One quote, two partial fills: the quote prices the fill it was minted for and
    /// is dead for the next one; a quote minted for the new progress works.
    function test_audit_PRICE_10_quoteBoundToFillProgress_cosigned() public {
        _fund();
        Order memory o = _order(3, address(cosigned));
        bytes memory sig = _sign(o);
        bytes32 h = lens.hashOrder(o);
        bytes memory q0 = _firstFillQuote(address(cosigned), h, 2_500);

        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN / 2, q0);

        // Replaying the round-1 quote on the next part is refused.
        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(o, sig, SELL_IN / 2, q0);

        // A fresh quote for prevFilled = SELL_IN/2 prices the second half.
        bytes memory q1 = _progressQuote(address(cosigned), h, 4_000, SELL_IN / 2);
        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN / 2, q1);
        assertEq(tB.balanceOf(maker) - before_, _outAt(4_000) / 2, "second half at the second quote");
    }

    /// The same binding on the clock-capped module.
    function test_audit_PRICE_10_quoteBoundToFillProgress_clockFloored() public {
        _fund();
        Order memory o = _order(4, address(floored));
        bytes memory sig = _sign(o);
        bytes32 h = lens.hashOrder(o);
        vm.warp(block.timestamp + DURATION / 2);
        bytes memory q0 = _firstFillQuote(address(floored), h, 2_500);

        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN / 2, q0);

        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(o, sig, SELL_IN / 2, q0);
    }
}
