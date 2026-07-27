// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {RiverTakerModule, RiverOpenModule} from "../../src/RiverModules.sol";

/// @dev The taker modules MUST reject any caller other than Permit3 — otherwise a
/// direct `takeOnBehalf` would bypass the Permit3 allowance gate and drain the
/// victim via their diamond delegate approval + satUSD/collateral token allowance.
/// Runs without a fork.
contract RiverTakerModuleAuthTest is Test {
    RiverTakerModule taker;
    RiverOpenModule opener;

    address permit3 = address(0xBEEF);
    address maker = address(0xA11CE);
    address attacker = address(0xBAD);
    address xapp = address(0x7A99);
    address tm = address(0x7A);
    address token = address(0x5A7);

    function setUp() public {
        taker = new RiverTakerModule(permit3);
        opener = new RiverOpenModule(permit3);
    }

    function _borrowData() internal view returns (bytes memory) {
        return abi.encode(
            uint8(RiverTakerModule.Op.Borrow), xapp, tm, token, uint256(1e16), address(0), address(0)
        );
    }

    function _withdrawData() internal view returns (bytes memory) {
        return abi.encode(uint8(RiverTakerModule.Op.WithdrawColl), xapp, tm, token, address(0), address(0));
    }

    function _openData() internal view returns (bytes memory) {
        return abi.encode(
            RiverOpenModule.OpenData(xapp, tm, token, token, 1e16, 1 ether, address(0), address(0))
        );
    }

    function test_borrow_rejects_non_permit3() public {
        vm.prank(attacker);
        vm.expectRevert(RiverTakerModule.OnlyPermit3.selector);
        taker.takeOnBehalf(maker, 1e18, attacker, _borrowData());
    }

    function test_withdraw_rejects_non_permit3() public {
        vm.prank(attacker);
        vm.expectRevert(RiverTakerModule.OnlyPermit3.selector);
        taker.takeOnBehalf(maker, 1e18, attacker, _withdrawData());
    }

    function test_open_rejects_non_permit3() public {
        vm.prank(attacker);
        vm.expectRevert(RiverOpenModule.OnlyPermit3.selector);
        opener.takeOnBehalf(maker, 1e18, attacker, _openData());
    }
}
