// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TellerPoolDepositModule, TellerRepayModule} from "../../src/TellerModules.sol";

/// @dev The MAKE modules MUST reject any caller other than Settlement — otherwise
/// a direct `makeOnBehalf` could pull the victim's Permit3 token allowance. Runs
/// without a fork.
contract TellerMakerModuleAuthTest is Test {
    TellerPoolDepositModule deposit;
    TellerRepayModule repay;

    address permit3 = address(0xBEEF);
    address settlement = address(0x5E77);
    address maker = address(0xA11CE);
    address attacker = address(0xBAD);

    function setUp() public {
        deposit = new TellerPoolDepositModule(permit3, settlement);
        repay = new TellerRepayModule(permit3, settlement);
    }

    function test_deposit_rejects_non_settlement() public {
        vm.prank(attacker);
        vm.expectRevert(TellerPoolDepositModule.NotSettlement.selector);
        deposit.makeOnBehalf(maker, 1e18, abi.encode(address(0x9001), address(0xA55E7)));
    }

    function test_repay_rejects_non_settlement() public {
        vm.prank(attacker);
        vm.expectRevert(TellerRepayModule.NotSettlement.selector);
        repay.makeOnBehalf(maker, 1e18, abi.encode(address(0x7E11E2), address(0xA55E7), uint256(42), true));
    }
}
