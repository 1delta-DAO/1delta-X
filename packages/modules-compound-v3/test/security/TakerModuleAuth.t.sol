// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CometTakerModule} from "../../src/CompoundV3Modules.sol";
import {CompoundV3ModulesBase} from "../shared/CompoundV3ModulesBase.t.sol";

/// @dev Taker module security. The `msg.sender == permit3` check is load-bearing:
/// without it, a direct takeOnBehalf call would bypass the Permit3 taker-allowance
/// gate and drain the victim — here, via the victim's `comet.allow` grant to the
/// module (set in setUp).
contract TakerModuleAuthTest is CompoundV3ModulesBase {
    function test_takeOnBehalf_rejectsDirectCall() public {
        // Seed position so a successful drain would actually move tokens. The
        // maker already granted `comet.allow(takerModule, true)` in setUp.
        _seedWethCollateral(1 ether);

        bytes memory data = _withdrawData(COMET, WETH);

        // Attacker tries to invoke the module directly, pointing `receiver` at themselves.
        address attacker = address(0xDEAD);
        vm.prank(attacker);
        vm.expectRevert(CometTakerModule.OnlyPermit3.selector);
        takerModule.takeOnBehalf(maker, 1 ether, attacker, data);
    }
}
