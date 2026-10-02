// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order} from "@core/settlement/Settlement.sol";
import {ChainlinkPeggedPriceModule} from "../src/ChainlinkPeggedPriceModule.sol";
import {FullFillModule} from "@modules/fill/src/FullFillModule.sol";

import {MockSettlementBase} from "@coretest/shared/MockSettlementBase.t.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

/// @dev Controllable Chainlink-shaped feed (duplicated so this suite stays independent).
contract AuditPegFeed {
    int256 public answer;
    uint256 public updatedAt;

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (10, answer, 0, updatedAt, 10);
    }
}

/// @title Audit20260930PeggedTest
/// @notice Regression tests for the 2026-09-30 audit findings on
///         {ChainlinkPeggedPriceModule}:
///         - PRICE-1 / X-ARITH-1: the fair price was computed against the FILL
///           DENOMINATOR (`total`), so any `fillTotal` order cleared at the floor (SELL)
///           or the cap (BUY).
///         - PRICE-1.v3 / X-ARITH-1.v2: a SELL whose `legsIn[0]` RISES was priced as if
///           the anchor were fixed, so the maker paid above the peg.
///         - PRICE-9: the constructor accepted `NUM == 0` (always the floor).
///         Each test asserts the SAFE end state and fails on the pre-fix module.
contract Audit20260930PeggedTest is MockSettlementBase {
    uint256 constant SELL_IN = 1_000e18; //   maker's input anchor (tA)
    uint256 constant OUT_START = 2_000e18; // best-for-maker output (tB)
    uint256 constant OUT_END = 1_000e18; //   maker's floor
    uint256 constant PEG_OUT = 1_500e18; //   1_000 tA · 1.5

    AuditPegFeed feed;
    ChainlinkPeggedPriceModule sellMod;
    ChainlinkPeggedPriceModule buyMod;
    FullFillModule fullFill;

    function setUp() public override {
        super.setUp();
        feed = new AuditPegFeed();
        feed.set(1.5e18, block.timestamp); // 1 tA = 1.5 tB
        sellMod = new ChainlinkPeggedPriceModule(address(feed), 1 hours, 0.5e18, 3e18, 1, 1e18, true, 0, address(0), 0);
        buyMod = new ChainlinkPeggedPriceModule(address(feed), 1 hours, 0.5e18, 3e18, 1, 1e18, false, 0, address(0), 0);
        fullFill = new FullFillModule();
    }

    function _fundSell(uint256 makerIn) internal {
        tA.mint(maker, makerIn);
        _makerApprove(address(settlement), address(tA), makerIn);
        tB.mint(solver, OUT_START);
        _solverApprove(address(settlement), address(tB), OUT_START);
    }

    function _peggedSell(uint256 nonce) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), SELL_IN, OUT_START);
        o.legsOut = PackedEncode.oneLegOut(address(tB), OUT_START, OUT_END, address(0));
        o.pricingModule = address(sellMod);
    }

    // ───────────────────────── PRICE-1 / X-ARITH-1 ─────────────────────────

    /// FullFillModule with `fillTotal = 1` (the unit its NatSpec recommends) now
    /// clears at the PEG (1_500 tB), not the floor (1_000 tB).
    function test_audit_PRICE_1_fullFillModuleFillTotal1_clearsAtPeg() public {
        _fundSell(SELL_IN);
        Order memory o = _peggedSell(2);
        o.fillModule = address(fullFill);
        o.fillTotal = 1;
        bytes memory sig = _sign(o);

        // The module is now independent of the progress unit it is handed.
        bytes32 h = _hashOrder(o);
        assertEq(sellMod.bump(h, maker, solver, 0, 1, o.timing, o.legsIn, o.legsOut, ""), 5_000, "total=1");
        assertEq(sellMod.bump(h, maker, solver, 0, SELL_IN, o.timing, o.legsIn, o.legsOut, ""), 5_000, "total=leg");

        // Lens and fill agree on the peg.
        (,, uint256[] memory quotedPaid) = lens.previewFill(o, 1, solver, "");
        assertEq(quotedPaid[0], PEG_OUT, "lens quotes the peg");

        uint256 makerB0 = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, 1);
        assertEq(tB.balanceOf(maker) - makerB0, PEG_OUT, "maker received the oracle peg");
        assertEq(tA.balanceOf(solver), SELL_IN, "filler received the whole input");
    }

    /// X-ARITH-1 variant: a bps-style `fillTotal` with no fill module. A half fill
    /// pays the pro-rata PEG (750 tB), not the pro-rata floor (500 tB).
    function test_audit_X_ARITH_1_bpsFillTotal_halfFillAtPeg() public {
        _fundSell(SELL_IN);
        Order memory o = _peggedSell(3);
        o.fillTotal = 10_000;
        bytes memory sig = _sign(o);

        uint256 makerB0 = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, 5_000);
        assertEq(tA.balanceOf(solver), SELL_IN / 2, "filler received half the input");
        assertEq(tB.balanceOf(maker) - makerB0, PEG_OUT / 2, "maker received the pro-rata peg");
    }

    /// The BUY mirror: `fillTotal` larger than the leg used to make the maker pay
    /// its full input CAP; now it pays the peg (1_500 tA for 1_000 tB).
    function test_audit_PRICE_1_buyLargeFillTotal_paysPegNotCap() public {
        uint256 outFixed = 1_000e18;
        uint256 inStart = 1_000e18;
        uint256 inCap = 2_000e18;
        tA.mint(maker, inCap);
        _makerApprove(address(settlement), address(tA), inCap);
        tB.mint(solver, outFixed);
        _solverApprove(address(settlement), address(tB), outFixed);

        Order memory o = _buyOrder(4, address(tA), address(tB), inStart, inCap, outFixed);
        o.pricingModule = address(buyMod);
        o.fillModule = address(fullFill);
        o.fillTotal = 1e24;
        bytes memory sig = _sign(o);

        uint256 makerA0 = tA.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, 1e24);
        assertEq(tB.balanceOf(maker), outFixed, "maker received its fixed output");
        assertEq(makerA0 - tA.balanceOf(maker), 1_500e18, "maker paid the peg, not its cap");
    }

    // ─────────────────────── PRICE-1.v3 / X-ARITH-1.v2 ───────────────────────

    /// A SELL with a RISING `legsIn[0]` (1_000 → 2_000 tA). The old module returned
    /// bump 5000: the maker paid 1_500 tA for 1_500 tB (rate 1.0 against a 1.5 peg).
    /// Solved jointly, the bump is 2000: 1_200 tA for 1_800 tB — exactly the peg.
    function test_audit_PRICE_1_v3_risingAnchor_clearsAtPeg() public {
        _fundSell(2_000e18);
        Order memory o = _peggedSell(5);
        o.legsIn = PackedEncode.oneLegIn(address(tA), SELL_IN, 2_000e18);
        bytes memory sig = _sign(o);

        assertEq(
            sellMod.bump(_hashOrder(o), maker, solver, 0, SELL_IN, o.timing, o.legsIn, o.legsOut, ""),
            2_000,
            "joint peg bump"
        );

        uint256 makerA0 = tA.balanceOf(maker);
        uint256 makerB0 = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN);
        uint256 paid = makerA0 - tA.balanceOf(maker);
        uint256 got = tB.balanceOf(maker) - makerB0;
        assertEq(paid, 1_200e18, "input charged");
        assertEq(got, 1_800e18, "output received");
        // Realised rate == peg (got / paid == 1.5).
        assertEq(got * 2, paid * 3, "cleared exactly at the oracle peg");
    }

    /// The milder band from X-ARITH-1.v2 (1_000 → 1_100 tA): the maker used to receive
    /// 1.4286 tB per tA. Now the realised rate is never below the peg.
    function test_audit_X_ARITH_1_v2_mildRisingAnchor_neverBelowPeg() public {
        _fundSell(1_100e18);
        Order memory o = _peggedSell(6);
        o.legsIn = PackedEncode.oneLegIn(address(tA), SELL_IN, 1_100e18);
        bytes memory sig = _sign(o);

        uint256 makerA0 = tA.balanceOf(maker);
        uint256 makerB0 = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN);
        uint256 paid = makerA0 - tA.balanceOf(maker);
        uint256 got = tB.balanceOf(maker) - makerB0;
        assertGe(got * 2, paid * 3, "maker's realised rate is at least the peg");
        // ...and only rounding away from it (< 1 bp of the band).
        assertLe(got * 2 - paid * 3, (OUT_START - OUT_END) * 3 / 10_000, "within a bp of the peg");
    }

    /// The joint solve degenerates to the floor when even the input's cap cannot
    /// reach the peg, and to `start` when the oracle beats the maker's ambition.
    function test_audit_PRICE_1_v3_risingAnchor_boundaries() public {
        bytes memory legsIn = PackedEncode.oneLegIn(address(tA), SELL_IN, 2_000e18);
        bytes memory legsOut = PackedEncode.oneLegOut(address(tB), OUT_START, OUT_END, address(0));
        uint256 timing = _peggedSell(7).timing;
        // fair(1_000) = 2_500 ≥ start → 0
        ChainlinkPeggedPriceModule rich =
            new ChainlinkPeggedPriceModule(address(feed), 1 hours, 0.5e18, 3e18, 5, 3e18, true, 0, address(0), 0);
        assertEq(rich.bump(bytes32(0), maker, solver, 0, SELL_IN, timing, legsIn, legsOut, ""), 0);
        // r = 0.4: r·cap = 800 ≤ end (1_000) → BPS
        ChainlinkPeggedPriceModule poor =
            new ChainlinkPeggedPriceModule(address(feed), 1 hours, 0.5e18, 3e18, 4, 15e18, true, 0, address(0), 0);
        assertEq(poor.bump(bytes32(0), maker, solver, 0, SELL_IN, timing, legsIn, legsOut, ""), 10_000);
    }

    // ──────────────────────────────── PRICE-9 ────────────────────────────────

    /// `NUM == 0` is now rejected at construction, like the validators' ZeroRatio.
    function test_audit_PRICE_9_numZero_rejected() public {
        vm.expectRevert(ChainlinkPeggedPriceModule.InvalidConfig.selector);
        new ChainlinkPeggedPriceModule(address(feed), 1 hours, 0.5e18, 3e18, 0, 1, true, 0, address(0), 0);
    }

    /// The same silent-floor outcome through an over-scaled DEN (fair truncates to
    /// 0) is refused at pricing time instead of clearing at the floor.
    function test_audit_PRICE_9_fairTruncatesToZero_reverts() public {
        ChainlinkPeggedPriceModule over =
            new ChainlinkPeggedPriceModule(address(feed), 1 hours, 0.5e18, 3e18, 1, 1e60, true, 0, address(0), 0);
        Order memory o = _peggedSell(8);
        vm.expectRevert(ChainlinkPeggedPriceModule.ImplausiblePrice.selector);
        over.bump(bytes32(0), maker, solver, 0, SELL_IN, o.timing, o.legsIn, o.legsOut, "");
    }
}
