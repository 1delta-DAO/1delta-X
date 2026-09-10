// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {ListaNativeSupplyCollateralModule, ListaNativeCollateralTakerModule} from "../../src/ListaNativeModules.sol";
import {ListaSmartSupplyCollateralModule, ListaSmartTakerModule} from "../../src/ListaSmartModules.sol";
import {MarketParams} from "../../src/interfaces/ILista.sol";

/// @dev The dispatcher pins on Lista's PROVIDER-shape modules — the native
/// (wrap/unwrap) pair and the SmartLP pair.
///
/// These four are the package's least-exercised contracts and each one holds a
/// standing capability: the two MAKE modules pull the maker's coin through their
/// own Permit3 token allowance, and the two TAKE modules spend the maker's Moolah
/// `setAuthorization` grant. Without the pin, `makeOnBehalf` / `takeOnBehalf` are
/// public functions that anyone can point at any position those grants cover —
/// the allowance gate never runs, because it lives in the caller Permit3/Settlement
/// that was bypassed. The Moolah-shaped siblings have carried this coverage since
/// they shipped ({ListaTakerModuleAuthTest}); these did not. Runs without a fork.
contract ListaProviderModuleAuthTest is Test {
    ListaNativeSupplyCollateralModule nativeSupply;
    ListaNativeCollateralTakerModule nativeTaker;
    ListaSmartSupplyCollateralModule smartSupply;
    ListaSmartTakerModule smartTaker;

    address permit3 = address(0xBEEF);
    address settlement = address(0x5E77);
    address maker = address(0xA11CE);
    address attacker = address(0xBAD);

    function setUp() public {
        nativeSupply = new ListaNativeSupplyCollateralModule(permit3, settlement);
        nativeTaker = new ListaNativeCollateralTakerModule(permit3);
        smartSupply = new ListaSmartSupplyCollateralModule(permit3, settlement);
        smartTaker = new ListaSmartTakerModule(permit3);
    }

    function _mp() internal pure returns (MarketParams memory) {
        return MarketParams(address(0x1041), address(0xC011), address(0x02AC), address(0x121A), 860000000000000000);
    }

    function _nativeSupplyData() internal pure returns (bytes memory) {
        return abi.encode(address(0x9809), _mp());
    }

    function _nativeWithdrawData() internal pure returns (bytes memory) {
        return abi.encode(address(0x9809), address(0x3011A), _mp());
    }

    function _smartSupplyData() internal pure returns (bytes memory) {
        return abi.encode(address(0x9809), address(0xC011), uint256(0), uint256(1e18), _mp());
    }

    function _smartWithdrawData() internal pure returns (bytes memory) {
        return abi.encode(address(0x9809), address(0x3011A), uint256(0), uint256(1e18), _mp());
    }

    // ──────────────── MAKE: Settlement is the only dispatcher ────────────────

    function test_nativeSupply_rejects_nonSettlement() public {
        vm.prank(attacker);
        vm.expectRevert(ListaNativeSupplyCollateralModule.NotSettlement.selector);
        nativeSupply.makeOnBehalf(maker, 1e18, _nativeSupplyData());
    }

    function test_smartSupply_rejects_nonSettlement() public {
        vm.prank(attacker);
        vm.expectRevert(ListaSmartSupplyCollateralModule.NotSettlement.selector);
        smartSupply.makeOnBehalf(maker, 1e18, _smartSupplyData());
    }

    // ──────────────── TAKE: Permit3 is the only dispatcher ────────────────

    function test_nativeWithdraw_rejects_nonPermit3() public {
        vm.prank(attacker);
        vm.expectRevert(ListaNativeCollateralTakerModule.OnlyPermit3.selector);
        nativeTaker.takeOnBehalf(maker, 1e18, attacker, _nativeWithdrawData());
    }

    function test_smartWithdraw_rejects_nonPermit3() public {
        vm.prank(attacker);
        vm.expectRevert(ListaSmartTakerModule.OnlyPermit3.selector);
        smartTaker.takeOnBehalf(maker, 1e18, attacker, _smartWithdrawData());
    }

    /// @dev The pin is on the CALLER, not on `onBehalfOf`: an attacker naming
    ///      themselves as the position owner is rejected just the same, which is
    ///      what makes the check a gate rather than a filter.
    function test_pins_areOnTheCaller_notThePositionOwner() public {
        vm.startPrank(attacker);
        vm.expectRevert(ListaNativeSupplyCollateralModule.NotSettlement.selector);
        nativeSupply.makeOnBehalf(attacker, 1e18, _nativeSupplyData());
        vm.expectRevert(ListaNativeCollateralTakerModule.OnlyPermit3.selector);
        nativeTaker.takeOnBehalf(attacker, 1e18, attacker, _nativeWithdrawData());
        vm.expectRevert(ListaSmartSupplyCollateralModule.NotSettlement.selector);
        smartSupply.makeOnBehalf(attacker, 1e18, _smartSupplyData());
        vm.expectRevert(ListaSmartTakerModule.OnlyPermit3.selector);
        smartTaker.takeOnBehalf(attacker, 1e18, attacker, _smartWithdrawData());
        vm.stopPrank();
    }
}
