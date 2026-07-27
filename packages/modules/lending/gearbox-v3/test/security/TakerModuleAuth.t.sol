// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {GearboxPoolWithdrawModule, GearboxCreditBorrowModule} from "../../src/GearboxV3Modules.sol";

/// @dev Both taker modules MUST reject any caller other than Permit3. Runs
/// without a fork.
contract GearboxV3TakerModuleAuthTest is Test {
    GearboxPoolWithdrawModule poolWithdraw;
    GearboxCreditBorrowModule creditBorrow;

    address permit3 = address(0xBEEF);
    address maker = address(0xA11CE);
    address attacker = address(0xBAD);

    function setUp() public {
        poolWithdraw = new GearboxPoolWithdrawModule(permit3);
        creditBorrow = new GearboxCreditBorrowModule(permit3);
    }

    function test_pool_withdraw_rejects_non_permit3() public {
        vm.prank(attacker);
        vm.expectRevert(GearboxPoolWithdrawModule.OnlyPermit3.selector);
        poolWithdraw.takeOnBehalf(maker, 1e18, attacker, abi.encode(address(0x9001), address(0xA55E7)));
    }

    function test_credit_borrow_rejects_non_permit3() public {
        vm.prank(attacker);
        vm.expectRevert(GearboxCreditBorrowModule.OnlyPermit3.selector);
        creditBorrow.takeOnBehalf(maker, 1e18, attacker, abi.encode(address(0xFACADE), address(0xCA), address(0xA55E7)));
    }
}
