// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ExactlyTakerModule} from "../../src/ExactlyModules.sol";

/// @dev The taker module MUST reject any caller other than Permit3 — otherwise a
/// direct `takeOnBehalf` would bypass the Permit3 allowance gate and drain the
/// victim via their Exactly share allowance. Runs without a fork.
contract ExactlyTakerModuleAuthTest is Test {
    ExactlyTakerModule taker;

    address permit3 = address(0xBEEF);
    address maker = address(0xA11CE);
    address attacker = address(0xBAD);
    address market = address(0x3AC); // placeholder
    address asset = address(0xA55E7);

    function setUp() public {
        taker = new ExactlyTakerModule(permit3);
    }

    function _borrowData() internal view returns (bytes memory) {
        return abi.encode(uint8(ExactlyTakerModule.Op.Borrow), market, asset, uint256(0), uint256(0));
    }

    function _withdrawData() internal view returns (bytes memory) {
        return abi.encode(uint8(ExactlyTakerModule.Op.Withdraw), market, asset, uint256(0), uint256(0));
    }

    function test_borrow_rejects_non_permit3() public {
        vm.prank(attacker);
        vm.expectRevert(ExactlyTakerModule.OnlyPermit3.selector);
        taker.takeOnBehalf(maker, 1_000e6, attacker, _borrowData());
    }

    function test_withdraw_rejects_non_permit3() public {
        vm.prank(attacker);
        vm.expectRevert(ExactlyTakerModule.OnlyPermit3.selector);
        taker.takeOnBehalf(maker, 1_000e6, attacker, _withdrawData());
    }
}
