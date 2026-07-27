// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ListaTakerModule} from "../../src/ListaModules.sol";
import {MarketParams} from "../../src/interfaces/ILista.sol";

/// @dev The taker module MUST reject any caller other than Permit3 — otherwise a
/// direct `takeOnBehalf` would bypass the Permit3 allowance gate and drain the
/// victim via their Moolah authorization / broker credit. Runs without a fork.
contract ListaTakerModuleAuthTest is Test {
    ListaTakerModule taker;

    address permit3 = address(0xBEEF);
    address maker = address(0xA11CE);
    address attacker = address(0xBAD);

    function setUp() public {
        taker = new ListaTakerModule(permit3);
    }

    function _borrowData() internal pure returns (bytes memory) {
        return abi.encode(uint8(ListaTakerModule.Op.Borrow), address(0xB40E7), uint256(1_700000000));
    }

    function _withdrawData() internal pure returns (bytes memory) {
        MarketParams memory mp =
            MarketParams(address(0x1041), address(0xC011), address(0x02AC), address(0x121A), 860000000000000000);
        return abi.encode(uint8(ListaTakerModule.Op.WithdrawCollateral), address(0x3011A), mp);
    }

    function test_borrow_rejects_non_permit3() public {
        vm.prank(attacker);
        vm.expectRevert(ListaTakerModule.OnlyPermit3.selector);
        taker.takeOnBehalf(maker, 1e18, attacker, _borrowData());
    }

    function test_withdraw_rejects_non_permit3() public {
        vm.prank(attacker);
        vm.expectRevert(ListaTakerModule.OnlyPermit3.selector);
        taker.takeOnBehalf(maker, 1e18, attacker, _withdrawData());
    }
}
