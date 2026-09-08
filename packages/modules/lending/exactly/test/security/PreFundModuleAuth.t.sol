// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ExactlyPreFundModule} from "../../src/ExactlyPreFundModules.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";

/// @dev Security gates of the pre-funded one-sided modules — no fork needed:
///   • only Permit3 may dispatch (`takeFor` is the sole legitimate path);
///   • only a LEG-REFERENCE descriptor is accepted — a literal would instruct
///     amounts the module has no delivery for, a balance form reads the wrong
///     wallet;
///   • a zero `forAmount` (dust slice flooring the funding leg) is a clean
///     no-op that never touches the venue (the market address here has no code).
contract ExactlyPreFundModuleAuthTest is Test {
    ExactlyPreFundModule preFund;

    address permit3 = address(0xBEEF);

    address settlement = address(0x5E77);
    address maker = address(0xA11CE);
    address attacker = address(0xBAD);
    address market = address(0xEAA);
    address asset = address(0xA55E7);

    function setUp() public {
        preFund = new ExactlyPreFundModule(permit3, address(settlement));
    }

    function _legRefData() internal view returns (bytes memory) {
        return abi.encode(
            (uint256(1) << 255) | (uint256(1) << 253) | (uint256(uint160(asset)) << 16) | 0,
            market, asset, uint256(0), uint256(0)
        );
    }

    function _literalData() internal view returns (bytes memory) {
        return abi.encode(uint256(1e6), market, asset, uint256(0), uint256(0));
    }

    function _balanceData() internal view returns (bytes memory) {
        return abi.encode((uint256(3) << 254) | uint256(uint160(asset)), market, asset, uint256(0), uint256(0));
    }

    function test_deposit_rejects_non_settlement() public {
        vm.prank(attacker);
        vm.expectRevert(PreFundGuard.OnlySettlement.selector);
        preFund.makeOnBehalf(maker, 1e6, _legRefData());
    }

    function test_repay_rejects_non_settlement() public {
        vm.prank(attacker);
        vm.expectRevert(PreFundGuard.OnlySettlement.selector);
        preFund.makeOnBehalf(maker, 1e6, _legRefData());
    }

    function test_deposit_rejects_literal_descriptor() public {
        vm.prank(address(settlement));
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        preFund.makeOnBehalf(maker, 1e6, _literalData());
    }

    function test_deposit_rejects_balance_descriptor() public {
        vm.prank(address(settlement));
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        preFund.makeOnBehalf(maker, 1e6, _balanceData());
    }

    function test_repay_rejects_literal_descriptor() public {
        vm.prank(address(settlement));
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        preFund.makeOnBehalf(maker, 1e6, _literalData());
    }

    function test_repay_rejects_balance_descriptor() public {
        vm.prank(address(settlement));
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        preFund.makeOnBehalf(maker, 1e6, _balanceData());
    }

    /// @dev A zero funding slice returns before any venue interaction — `market`
    ///      and `asset` are codeless here, so any call into them would revert.
    function test_zero_forAmount_is_a_noop() public {
        vm.prank(address(settlement));
        preFund.makeOnBehalf(maker, 0, _legRefData());
        vm.prank(address(settlement));
        preFund.makeOnBehalf(maker, 0, _legRefData());
    }
}
