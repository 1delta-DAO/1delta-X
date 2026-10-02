// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IProceedsAsset} from "@core/interfaces/IProceedsAsset.sol";
import {MorphoBlueTakerModule} from "../../src/MorphoBlueModules.sol";
import {MarketParams} from "../../src/interfaces/IMorphoBlue.sol";

/// @title Audit 2026-09-30 L-CMT-6 — MorphoBlueTakerModule names its proceeds asset
/// @notice The lens' F22 proceeds check ({SettlementLensChecks._proceedsItemAt}) can
///         only flag a TAKE whose delivered token no input leg consumes if the module
///         says which token it delivers.
contract MorphoProceedsAsset20260930Test is Test {
    MorphoBlueTakerModule module;
    address constant LOAN = address(0x10A);
    address constant COLL = address(0xC011);

    function setUp() public {
        module = new MorphoBlueTakerModule(address(0x3), address(0x4));
    }

    function _data(uint8 op) internal pure returns (bytes memory) {
        return abi.encode(op, MarketParams({loanToken: LOAN, collateralToken: COLL, oracle: address(1), irm: address(2), lltv: 0.8e18}));
    }

    function test_audit_L_CMT_6_proceedsAssetPerOp() public view {
        IProceedsAsset p = IProceedsAsset(address(module));
        assertEq(p.proceedsAsset(_data(0)), LOAN, "Borrow delivers the loan token");
        assertEq(p.proceedsAsset(_data(1)), COLL, "WithdrawCollateral delivers the collateral token");
        assertEq(p.proceedsAsset(_data(2)), LOAN, "Withdraw delivers the loan token");
    }

    function test_audit_L_CMT_6_unknownOpRefused() public {
        vm.expectRevert();
        IProceedsAsset(address(module)).proceedsAsset(_data(3));
    }
}
