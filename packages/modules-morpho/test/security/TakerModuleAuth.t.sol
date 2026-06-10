// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MorphoBlueWithdrawCollateralModule, MorphoBlueBorrowModule} from "../../src/MorphoBlueModules.sol";
import {MorphoModulesBase} from "../shared/MorphoModulesBase.t.sol";

/// @dev Taker module security. The `msg.sender == permit3` check is load-bearing:
/// without it, a direct `takeOnBehalf` call would bypass the Permit3 taker-allowance
/// gate. This bites harder on Morpho than Aave, because the maker's standing
/// `setAuthorization(module, true)` lets the module move the position with no token
/// allowance at all — the sender gate is the only thing standing between an
/// attacker and a delegated borrow/withdraw.
contract TakerModuleAuthTest is MorphoModulesBase {
    function test_withdraw_takeOnBehalf_rejectsDirectCall() public {
        // Seed collateral and grant the (coarse) Morpho authorization, simulating a
        // maker who has authorised the withdraw module but signed no taker permit.
        _seedCollateral(1 ether);
        vm.prank(maker);
        MORPHO.setAuthorization(address(withdrawModule), true);

        address attacker = address(0xDEAD);
        vm.prank(attacker);
        vm.expectRevert(MorphoBlueWithdrawCollateralModule.OnlyPermit3.selector);
        withdrawModule.takeOnBehalf(maker, 1 ether, attacker, _marketData());
    }

    function test_borrow_takeOnBehalf_rejectsDirectCall() public {
        // Collateral + authorization but no taker permit.
        _seedCollateral(2 ether);
        vm.prank(maker);
        MORPHO.setAuthorization(address(borrowModule), true);

        address attacker = address(0xDEAD);
        vm.prank(attacker);
        vm.expectRevert(MorphoBlueBorrowModule.OnlyPermit3.selector);
        borrowModule.takeOnBehalf(maker, 1_000e6, attacker, _marketData());
    }
}
