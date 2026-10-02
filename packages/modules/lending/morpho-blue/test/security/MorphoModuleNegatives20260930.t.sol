// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {PreFundGuard} from "@lib/PreFundGuard.sol";

import {MorphoModulesBase} from "../shared/MorphoModulesBase.t.sol";
import {MorphoBluePreFundModule} from "../../src/MorphoBluePreFundModules.sol";
import {MorphoBlueRepayModule, MorphoBlueSupplyModule} from "../../src/MorphoBlueModules.sol";

/// @title Audit 2026-09-30 L-CMT-5 (3) — the Morpho Blue negatives the suite lacked
/// @notice `BufferTooSmall` on the repay callback, the pre-fund module's caller and
///         descriptor gates, and a FUNCTIONAL (fork) `MorphoBlueSupplyModule` supply.
contract MorphoModuleNegatives20260930Test is MorphoModulesBase {
    function test_audit_L_CMT_5_repayCallbackRefusesAboveTheSignedCeiling() public {
        // Morpho asks for one wei more than the signed ceiling the module put in
        // the callback data: refused, nothing pulled.
        bytes memory cb = abi.encode(maker, uint256(100e6), USDC);
        vm.prank(address(MORPHO));
        vm.expectRevert(MorphoBlueRepayModule.BufferTooSmall.selector);
        repayModule.onMorphoRepay(100e6 + 1, cb);
        // And only Morpho may invoke it.
        vm.prank(address(0xBAD));
        vm.expectRevert(MorphoBlueRepayModule.OnlyMorpho.selector);
        repayModule.onMorphoRepay(1, cb);
    }

    function test_audit_L_CMT_5_preFundModuleGates() public {
        MorphoBluePreFundModule preFund = new MorphoBluePreFundModule(address(permit3), address(settlement));
        uint256 legRef =
            (uint256(1) << 255) | (uint256(1) << 253) | (uint256(uint160(USDC)) << 16) | uint256(0);
        bytes memory ok = abi.encode(legRef, marketParams);
        vm.prank(address(0xBAD));
        vm.expectRevert(PreFundGuard.OnlySettlement.selector);
        preFund.makeOnBehalf(maker, 1, ok);

        bytes memory literal = abi.encode(uint256(1e6), marketParams);
        vm.prank(address(settlement));
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        preFund.makeOnBehalf(maker, 1, literal);
    }

    function test_audit_L_CMT_5_supplyModuleCreditsEarnPositionOnFork() public {
        MorphoBlueSupplyModule supply = new MorphoBlueSupplyModule(address(permit3), address(MORPHO), address(settlement));
        uint256 amt = 5_000e6;
        deal(USDC, maker, amt);
        vm.startPrank(maker);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(supply), USDC, uint160(amt), 0);
        vm.stopPrank();
        uint256 before = _supplyAssets(maker);

        vm.prank(address(settlement));
        supply.makeOnBehalf(maker, amt, _marketData());

        assertApproxEqAbs(_supplyAssets(maker) - before, amt, 1, "lend balance credited to the maker");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "pulled from the maker");
        assertEq(IERC20(USDC).balanceOf(address(supply)), 0, "nothing left on the module");
        // (The module keeps a standing approval to the IMMUTABLE Morpho singleton by
        // design: an exact-assets `supply` pulls exactly `amount` from the module, and
        // no order data can name a different venue.)
    }
}
