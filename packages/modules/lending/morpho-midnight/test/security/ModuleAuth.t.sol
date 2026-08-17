// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    MidnightSupplyCollateralModule,
    MidnightRepayModule,
    MidnightLendModule,
    MidnightTakerModule,
    MidnightBorrowModule
} from "../../src/MidnightModules.sol";
import {MidnightModulesBase} from "../shared/MidnightModulesBase.t.sol";
import {MidnightMock} from "../shared/MidnightMock.sol";

/// @dev The load-bearing gates: MAKE modules must reject any caller that is not
/// Settlement (`NotSettlement`); TAKE modules must reject any caller that is not
/// Permit3 (`OnlyPermit3`). Without them a direct call bypasses the Permit3
/// allowance gate and, combined with the maker's standing Midnight authorization,
/// could drain a delegated withdraw/borrow. Also asserts the Midnight
/// `setIsAuthorized` gate is real: an un-authorized taker module cannot withdraw.
contract ModuleAuthTest is MidnightModulesBase {
    function test_make_modules_reject_non_settlement() public {
        bytes memory supplyData = _supplyData();
        bytes memory repayData = _repayData();
        bytes memory lendData = _lendData(1e6);

        vm.startPrank(address(0xBAD));

        vm.expectRevert(MidnightSupplyCollateralModule.NotSettlement.selector);
        supplyModule.makeOnBehalf(maker, 1e18, supplyData);

        vm.expectRevert(MidnightRepayModule.NotSettlement.selector);
        repayModule.makeOnBehalf(maker, 1e6, repayData);

        vm.expectRevert(MidnightLendModule.NotSettlement.selector);
        lendModule.makeOnBehalf(maker, 1e6, lendData);

        vm.stopPrank();
    }

    function test_taker_modules_reject_non_permit3() public {
        bytes memory wcData = _withdrawCollateralData(0);
        bytes memory borrowData = _borrowData(1e6);

        vm.startPrank(address(0xBAD));

        vm.expectRevert(MidnightTakerModule.OnlyPermit3.selector);
        takerModule.takeOnBehalf(maker, 1e18, address(0xBAD), wcData);

        vm.expectRevert(MidnightBorrowModule.OnlyPermit3.selector);
        borrowModule.takeOnBehalf(maker, 1e6, address(0xBAD), borrowData);

        vm.stopPrank();
    }

    /// @dev Even called by Permit3, a withdraw against a position that never
    ///      authorized the module reverts inside Midnight — the coarse
    ///      `setIsAuthorized` boolean is a second, independent gate.
    function test_withdraw_without_midnight_auth_reverts() public {
        _seedCollateral(maker, 1e18);

        bytes memory wcData = _withdrawCollateralData(0);
        _makerApproveTaker(address(takerModule), keccak256(wcData), 1e18);
        // NB: no `_makerAuthorize(takerModule)`.

        vm.prank(address(permit3));
        vm.expectRevert(MidnightMock.Unauthorized.selector);
        takerModule.takeOnBehalf(maker, 1e18, solver, wcData);
    }

    function _seedCollateral(address who, uint256 amount) internal {
        COLL.mint(address(this), amount);
        COLL.approve(address(midnight), amount);
        midnight.seedCollateral(_market(), who, 0, amount);
    }
}
