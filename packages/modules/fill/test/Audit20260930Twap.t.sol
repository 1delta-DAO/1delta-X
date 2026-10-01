// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {Order} from "@core/settlement/Settlement.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {TwapFillModule} from "../src/TwapFillModule.sol";

/// @title Audit20260930TwapTest
/// @notice Regression for audit 2026-09-30 PRICE-7: {TwapFillModule} floor-divided
///         the part duration (up to ~2x schedule compression) and treated an unset
///         `decayStartTime == 0` as a schedule that started at the epoch (the whole
///         order released on the first fill). Asserted on `resolveFill` directly —
///         the module is the only thing that gates fill size by time.
contract Audit20260930TwapTest is Test {
    TwapFillModule twap;

    uint256 constant PARTS = 100;
    uint256 constant PART = 1e18;
    uint256 constant TOTAL = PARTS * PART;

    function setUp() public {
        twap = new TwapFillModule();
        vm.warp(1_800_000_000);
    }

    function _order(uint256 start, uint256 duration) internal pure returns (Order memory o) {
        o.legsIn = PackedEncode.oneLegIn(address(0xA), TOTAL, 0);
        o.legsOut = PackedEncode.oneLegOut(address(0xB), TOTAL, 0, address(0));
        o.fillTotal = TOTAL;
        o.minFillAnchor = PART;
        // timing[0:32) = decayStartTime, [32:64) = decayDuration (unix clock).
        o.timing = uint256(uint32(start)) | (uint256(uint32(duration)) << 32);
    }

    /// 199 ticks over 100 parts: the old floored `partDuration = 1` opened all 100
    /// parts by tick 99. Exact release opens part k only once k·199/100 ticks passed.
    function test_audit_PRICE_7_unevenWindow_neverReleasesEarly() public {
        uint256 t0 = block.timestamp;
        Order memory o = _order(t0, 199);

        vm.warp(t0 + 99);
        uint256 open = twap.resolveFill(o, 0, 0, "");
        // floor(99·100/199) + 1 = 50 parts — about half the window, half the parts.
        assertEq(open, 50 * PART, "half the window releases half the parts");

        // Every part k is gated until its exact share of the window has elapsed.
        for (uint256 k = 1; k < PARTS; k += 7) {
            uint256 opensAt = (k * 199 + PARTS - 1) / PARTS; // ceil(k·199/100)
            vm.warp(t0 + opensAt - 1);
            assertEq(twap.resolveFill(o, 0, 0, ""), k * PART, "part k+1 not yet open");
            vm.warp(t0 + opensAt);
            assertEq(twap.resolveFill(o, 0, 0, ""), (k + 1) * PART, "part k+1 opens on time");
        }

        vm.warp(t0 + 199);
        assertEq(twap.resolveFill(o, 0, 0, ""), TOTAL, "everything by the end of the window");
    }

    /// The even case is unchanged: 1000 ticks / 100 parts = one part per 10 ticks.
    function test_audit_PRICE_7_evenWindow_unchanged() public {
        uint256 t0 = block.timestamp;
        Order memory o = _order(t0, 1_000);
        vm.warp(t0 + 9);
        assertEq(twap.resolveFill(o, 0, 0, ""), PART);
        vm.warp(t0 + 10);
        assertEq(twap.resolveFill(o, 0, 0, ""), 2 * PART);
        vm.warp(t0 + 995);
        assertEq(twap.resolveFill(o, 0, 0, ""), TOTAL);
    }

    /// `decayStartTime == 0` used to saturate `partsOpen` and release the whole
    /// order at once; it is now an unconfigured schedule.
    function test_audit_PRICE_7_zeroStart_reverts() public {
        Order memory o = _order(0, 1_000);
        vm.expectRevert(TwapFillModule.TwapNotConfigured.selector);
        twap.resolveFill(o, 0, 0, "");
    }
}
