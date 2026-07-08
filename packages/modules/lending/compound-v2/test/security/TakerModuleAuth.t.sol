// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CompoundV2ModulesBase} from "../shared/CompoundV2ModulesBase.t.sol";
import {CompoundV2WithdrawModule} from "../../src/CompoundV2Modules.sol";

/// @dev The withdraw taker module MUST reject any caller other than Permit3 —
/// otherwise a direct `takeOnBehalf(victim, amount, attacker, data)` would bypass
/// the Permit3 allowance gate and drain the victim's cToken approval.
contract CompoundV2TakerModuleAuthTest is CompoundV2ModulesBase {
    address attacker = address(0xBAD);

    function test_withdraw_rejects_non_permit3() public {
        vm.prank(attacker);
        vm.expectRevert(CompoundV2WithdrawModule.OnlyPermit3.selector);
        withdrawModule.takeOnBehalf(maker, 500e6, attacker, _withdrawUsdcData());
    }
}
