// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SiloTakerModule} from "../../src/SiloModules.sol";

/// @dev The taker module MUST reject any caller other than Permit3 — otherwise a
/// direct `takeOnBehalf(victim, amount, attacker, data)` would bypass the Permit3
/// allowance gate and drain the victim via their Silo receive-approval / share
/// allowance. Runs without a fork (pure gate check).
contract SiloTakerModuleAuthTest is Test {
    SiloTakerModule taker;

    address permit3 = address(0xBEEF);
    address maker = address(0xA11CE);
    address attacker = address(0xBAD);
    address silo = address(0x5110);
    address asset = address(0xA55E7);

    function setUp() public {
        taker = new SiloTakerModule(permit3);
    }

    function _borrowData() internal view returns (bytes memory) {
        return abi.encode(uint8(SiloTakerModule.Op.Borrow), silo, asset);
    }

    function _withdrawData() internal view returns (bytes memory) {
        return abi.encode(uint8(SiloTakerModule.Op.Withdraw), silo, asset);
    }

    function test_borrow_rejects_non_permit3() public {
        vm.prank(attacker);
        vm.expectRevert(SiloTakerModule.OnlyPermit3.selector);
        taker.takeOnBehalf(maker, 1e18, attacker, _borrowData());
    }

    function test_withdraw_rejects_non_permit3() public {
        vm.prank(attacker);
        vm.expectRevert(SiloTakerModule.OnlyPermit3.selector);
        taker.takeOnBehalf(maker, 1e18, attacker, _withdrawData());
    }
}
