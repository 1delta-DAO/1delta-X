// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order, LegOut} from "@core/settlement/Settlement.sol";
import {ChainlinkPeggedPriceModule} from "../src/ChainlinkPeggedPriceModule.sol";

import {MockSettlementBase} from "@coretest/shared/MockSettlementBase.t.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {PriceFeed} from "./ChainlinkPeggedPrice.t.sol";

/// @title ReviewPeggedFeeFirst
/// @notice Review 2026-10-05 S3, the pricing-module instance: {ChainlinkPeggedPriceModule}
///         read `legsOut[0]` by INDEX as the maker's band / anchor. With an in-kind
///         sourcing fee signed as the first output leg the peg silently degraded to a
///         fixed limit at the maker's ambition. The band is now the first
///         maker-addressed output leg.
contract ReviewPeggedFeeFirstTest is MockSettlementBase {
    uint256 constant SELL_IN = 1_000e18;
    uint256 constant OUT_START = 2_000e18;
    uint256 constant OUT_END = 1_000e18;
    uint256 constant FEE = 10e18;
    address constant ORIGINATOR = address(0x0F1C);

    PriceFeed feed;

    function setUp() public override {
        super.setUp();
        feed = new PriceFeed();
    }

    function _sellMod() internal returns (ChainlinkPeggedPriceModule) {
        return new ChainlinkPeggedPriceModule(address(feed), 1 hours, 0.5e18, 3e18, 1, 1e18, true, 0, address(0), 0);
    }

    function _buyMod() internal returns (ChainlinkPeggedPriceModule) {
        return new ChainlinkPeggedPriceModule(address(feed), 1 hours, 0.5e18, 5e18, 1, 1e18, false, 0, address(0), 0);
    }

    /// SELL with the fee leg FIRST: [tA 10 → originator (fixed), tB 2000→1000 → maker].
    function _feeFirstSell(uint256 nonce) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), SELL_IN, OUT_START);
        LegOut[] memory lo = new LegOut[](2);
        lo[0] = LegOut(address(tA), FEE, 0, ORIGINATOR);
        lo[1] = LegOut(address(tB), OUT_START, OUT_END, address(0));
        o.legsOut = PackedEncode.legsOut(lo);
    }

    function test_review_S3_sellFeeLegFirst_pegsTheMakerLeg() public {
        feed.set(1.5e18, block.timestamp); // fair = 1_500e18, midway in [1_000e18, 2_000e18]
        ChainlinkPeggedPriceModule mod = _sellMod();
        Order memory o = _feeFirstSell(1);
        uint256 bps = mod.bump(_hashOrder(o), maker, solver, 0, SELL_IN, o.timing, o.legsIn, o.legsOut, "");
        // Index-0 read saw the FIXED fee leg (end == 0) and returned 0 — the peg was gone.
        assertEq(bps, 5_000, "the maker's leg is the band, wherever it is listed");

        // Identical to the same order with the fee leg second.
        LegOut[] memory lo = new LegOut[](2);
        lo[0] = LegOut(address(tB), OUT_START, OUT_END, address(0));
        lo[1] = LegOut(address(tA), FEE, 0, ORIGINATOR);
        o.legsOut = PackedEncode.legsOut(lo);
        assertEq(mod.bump(_hashOrder(o), maker, solver, 0, SELL_IN, o.timing, o.legsIn, o.legsOut, ""), 5_000);
    }

    /// BUY with the fee leg FIRST: anchor is the maker's 1_000e18 tB leg, not the 30e18 fee.
    function test_review_S3_buyFeeLegFirst_anchorsOnTheMakerLeg() public {
        feed.set(3e18, block.timestamp); // 1 tB = 3 tA ⇒ fair input = 3_000e18, midway in [2_900, 3_100]
        ChainlinkPeggedPriceModule mod = _buyMod();
        Order memory o = _buyOrder(2, address(tA), address(tB), 2_900e18, 3_100e18, 1_000e18);
        LegOut[] memory lo = new LegOut[](2);
        lo[0] = LegOut(address(tA), 30e18, 0, ORIGINATOR);
        lo[1] = LegOut(address(tB), 1_000e18, 0, address(0));
        o.legsOut = PackedEncode.legsOut(lo);
        uint256 bps = mod.bump(_hashOrder(o), maker, solver, 0, 1_000e18, o.timing, o.legsIn, o.legsOut, "");
        // Index-0 read anchored on 30e18 ⇒ fair 90e18 ≤ start ⇒ 0: the maker paid `start` forever.
        assertEq(bps, 5_000, "the maker's leg is the anchor");
    }

    /// An order whose every output leg goes to third parties has nothing to peg.
    function test_review_S3_noMakerLeg_reverts() public {
        feed.set(1.5e18, block.timestamp);
        ChainlinkPeggedPriceModule mod = _sellMod();
        Order memory o = _plainOrder(3, address(tA), address(tB), SELL_IN, OUT_START);
        o.legsOut = PackedEncode.oneLegOut(address(tB), OUT_START, OUT_END, ORIGINATOR);
        vm.expectRevert(ChainlinkPeggedPriceModule.NoBand.selector);
        mod.bump(_hashOrder(o), maker, solver, 0, SELL_IN, o.timing, o.legsIn, o.legsOut, "");
    }

    /// A leg addressed to the maker EXPLICITLY (recipient == maker) is the maker's leg too.
    function test_review_S3_explicitMakerRecipient_isTheMakerLeg() public {
        feed.set(1.5e18, block.timestamp);
        ChainlinkPeggedPriceModule mod = _sellMod();
        Order memory o = _plainOrder(4, address(tA), address(tB), SELL_IN, OUT_START);
        LegOut[] memory lo = new LegOut[](2);
        lo[0] = LegOut(address(tA), FEE, 0, ORIGINATOR);
        lo[1] = LegOut(address(tB), OUT_START, OUT_END, maker);
        o.legsOut = PackedEncode.legsOut(lo);
        assertEq(mod.bump(_hashOrder(o), maker, solver, 0, SELL_IN, o.timing, o.legsIn, o.legsOut, ""), 5_000);
    }
}
