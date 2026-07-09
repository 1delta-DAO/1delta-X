// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {FeeConfig} from "@core/utils/FeeConfig.sol";

contract FeeConfigTest is Test {
    function test_zero_isNoFee() public pure {
        (address r, uint256 bps) = FeeConfig.unpack(bytes32(0));
        assertEq(r, address(0));
        assertEq(bps, 0);
    }

    function test_pack_unpack_roundtrip() public pure {
        address r = address(0xC0FFEE);
        uint256 bps = 750;
        (address r2, uint256 bps2) = FeeConfig.unpack(FeeConfig.pack(r, bps));
        assertEq(r2, r, "recipient survives");
        assertEq(bps2, bps, "bps survives");
    }

    function test_layout_recipientInLow160_feeInHigh() public pure {
        bytes32 packed = FeeConfig.pack(address(0xABCD), 42);
        // Low 160 bits are the address; high bits are the fee.
        assertEq(address(uint160(uint256(packed))), address(0xABCD), "low = recipient");
        assertEq(uint256(packed) >> 160, 42, "high = fee");
    }

    function testFuzz_roundtrip(address r, uint96 bps) public pure {
        (address r2, uint256 bps2) = FeeConfig.unpack(FeeConfig.pack(r, bps));
        assertEq(r2, r);
        assertEq(bps2, bps);
    }
}
