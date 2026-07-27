// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {LiquityV2TakerModule} from "../../src/LiquityV2Modules.sol";

/// @dev The taker module MUST reject any caller other than Permit3 — otherwise a
/// direct `takeOnBehalf` would bypass the Permit3 allowance gate and drain the
/// victim via their per-trove remove-manager grant. Runs without a fork.
contract LiquityV2TakerModuleAuthTest is Test {
    LiquityV2TakerModule taker;

    address permit3 = address(0xBEEF);
    address maker = address(0xA11CE);
    address attacker = address(0xBAD);
    address ops = address(0x0B5);
    uint256 troveId = uint256(keccak256("trove"));
    address token = address(0x5A7);

    function setUp() public {
        taker = new LiquityV2TakerModule(permit3);
    }

    function _borrowData() internal view returns (bytes memory) {
        return abi.encode(uint8(LiquityV2TakerModule.Op.Borrow), ops, troveId, token, uint256(1e16));
    }

    function _withdrawData() internal view returns (bytes memory) {
        return abi.encode(uint8(LiquityV2TakerModule.Op.WithdrawColl), ops, troveId, token);
    }

    function test_borrow_rejects_non_permit3() public {
        vm.prank(attacker);
        vm.expectRevert(LiquityV2TakerModule.OnlyPermit3.selector);
        taker.takeOnBehalf(maker, 1e18, attacker, _borrowData());
    }

    function test_withdraw_rejects_non_permit3() public {
        vm.prank(attacker);
        vm.expectRevert(LiquityV2TakerModule.OnlyPermit3.selector);
        taker.takeOnBehalf(maker, 1e18, attacker, _withdrawData());
    }
}
