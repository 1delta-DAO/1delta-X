// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {Order} from "@core/settlement/Settlement.sol";
import {ConditionTreeValidator} from "@validators/ConditionTreeValidator.sol";

import {MocPriceBandValidator} from "../src/MocPriceBandValidator.sol";

/// @dev The one MoC read the validator makes.
contract MocCoreStub20260930 {
    uint256 public price;

    function set(uint256 p) external {
        price = p;
    }

    function getPACtp(address) external view returns (uint256) {
        return price;
    }
}

/// @title Audit 2026-09-30 VAL-2 — MocPriceBandValidator fails CLOSED
/// @notice A broken quote must revert, never answer a clean `false`: as a
///         ConditionTree NEGATE leaf a clean `false` makes `NOT(band)` pass exactly
///         when the feed is broken. Unit-level (no fork).
contract Audit20260930MocBandRevertTest is Test {
    MocPriceBandValidator band;
    MocCoreStub20260930 core;
    ConditionTreeValidator tree;
    Order empty;
    address constant TP = address(0x7B);

    function setUp() public {
        band = new MocPriceBandValidator();
        core = new MocCoreStub20260930();
        tree = new ConditionTreeValidator();
    }

    function _data(uint256 lo, uint256 hi) internal view returns (bytes memory) {
        return abi.encode(address(core), TP, lo, hi);
    }

    /// `NOT(band)` as a one-group, one-leaf DNF expression.
    function _notBand(uint256 lo, uint256 hi) internal view returns (bytes memory) {
        bytes memory d = _data(lo, hi);
        return abi.encodePacked(uint8(1), uint8(1), uint8(1), address(band), uint16(d.length), d);
    }

    function test_audit_VAL_2_zeroPriceRevertsNotFalse() public {
        core.set(0);
        vm.expectRevert(MocPriceBandValidator.ZeroPrice.selector);
        band.validate(empty, address(this), _data(0, 1e18), "");
        // As a negated leaf the tree aborts instead of passing.
        vm.expectRevert(ConditionTreeValidator.ConditionErrored.selector);
        tree.validate(empty, address(this), _notBand(0, 1e18), "");
    }

    function test_audit_VAL_2_reversedBandRevertsInvalidBand() public {
        core.set(5e16);
        vm.expectRevert(MocPriceBandValidator.InvalidBand.selector);
        band.validate(empty, address(this), _data(1e18, 1e16), "");
        vm.expectRevert(ConditionTreeValidator.ConditionErrored.selector);
        tree.validate(empty, address(this), _notBand(1e18, 1e16), "");
    }

    function test_audit_VAL_2_healthyOutOfBandIsAPlainFalse() public {
        core.set(5e16);
        assertFalse(band.validate(empty, address(this), _data(1e17, 1e18), ""), "healthy, out of band");
        assertTrue(tree.validate(empty, address(this), _notBand(1e17, 1e18), ""), "NOT(out of band) = true");
        assertTrue(band.validate(empty, address(this), _data(1e16, 1e17), ""), "in band");
    }
}
