// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {VenusModulesBase} from "../shared/VenusModulesBase.t.sol";
import {VenusTakerModule} from "../../src/VenusModules.sol";

/// @dev The taker module MUST reject any caller other than Permit3 — otherwise a
/// direct `takeOnBehalf(victim, amount, attacker, data)` would bypass the Permit3
/// allowance gate and drain the victim via their Venus `updateDelegate` grant.
contract VenusTakerModuleAuthTest is VenusModulesBase {
    address attacker = address(0xBAD);

    function test_borrow_rejects_non_permit3() public {
        vm.prank(attacker);
        vm.expectRevert(VenusTakerModule.OnlyPermit3.selector);
        takerModule.takeOnBehalf(maker, 1_000e6, attacker, _borrowData());
    }

    function test_withdraw_rejects_non_permit3() public {
        vm.prank(attacker);
        vm.expectRevert(VenusTakerModule.OnlyPermit3.selector);
        takerModule.takeOnBehalf(maker, 1 ether, attacker, _withdrawData());
    }
}
