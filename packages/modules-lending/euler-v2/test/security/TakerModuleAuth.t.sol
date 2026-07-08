// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EulerV2ModulesBase} from "../shared/EulerV2ModulesBase.t.sol";
import {EulerV2TakerModule, EulerV2BatchModule} from "../../src/EulerV2Modules.sol";

/// @dev The taker modules MUST reject any caller other than Permit3 — otherwise a
/// direct `takeOnBehalf(victim, amount, attacker, data)` would bypass the Permit3
/// allowance gate and drain the victim via their EVC operator grant.
contract EulerTakerModuleAuthTest is EulerV2ModulesBase {
    address attacker = address(0xBAD);

    function test_borrow_rejects_non_permit3() public {
        vm.prank(attacker);
        vm.expectRevert(EulerV2TakerModule.OnlyPermit3.selector);
        takerModule.takeOnBehalf(
            maker, 1_000e6, attacker, abi.encode(uint8(EulerV2TakerModule.Op.Borrow), address(EUSDC))
        );
    }

    function test_withdraw_rejects_non_permit3() public {
        vm.prank(attacker);
        vm.expectRevert(EulerV2TakerModule.OnlyPermit3.selector);
        takerModule.takeOnBehalf(
            maker, 1 ether, attacker, abi.encode(uint8(EulerV2TakerModule.Op.Withdraw), address(EWETH))
        );
    }

    function test_batch_rejects_non_permit3() public {
        EulerV2BatchModule.BatchData memory p = EulerV2BatchModule.BatchData({
            mode: uint256(EulerV2BatchModule.BatchMode.Close),
            collateralVault: address(EWETH),
            borrowVault: address(EUSDC),
            sideAmount: 1_000e6
        });
        vm.prank(attacker);
        vm.expectRevert(EulerV2BatchModule.OnlyPermit3.selector);
        batchModule.takeOnBehalf(maker, 1 ether, attacker, abi.encode(p));
    }
}
