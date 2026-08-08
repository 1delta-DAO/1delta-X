// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PackedArrays} from "@core/settlement/PackedArrays.sol";

/// @dev External wrapper so every read happens against real `calldata` (the library
///      is calldata-only by design; an internal call from a test would not exercise
///      the same offsets).
contract PackedReader {
    using PackedArrays for bytes;

    function legsInCount(bytes calldata b) external pure returns (uint256) {
        return PackedArrays.validateFixed(b, PackedArrays.LEG_IN_STRIDE);
    }

    function legsOutCount(bytes calldata b) external pure returns (uint256) {
        return PackedArrays.validateFixed(b, PackedArrays.LEG_OUT_STRIDE);
    }

    function curveCount(bytes calldata b) external pure returns (uint256) {
        return PackedArrays.validateFixed(b, PackedArrays.CURVE_STRIDE);
    }

    function readLegIn(bytes calldata b, uint256 i) external pure returns (address, uint256, uint256) {
        return PackedArrays.legIn(b, i);
    }

    function readLegInToken(bytes calldata b, uint256 i) external pure returns (address) {
        return PackedArrays.legInToken(b, i);
    }

    function readLegOut(bytes calldata b, uint256 i) external pure returns (address, uint256, uint256, address) {
        return PackedArrays.legOut(b, i);
    }

    function readCurve(bytes calldata b, uint256 i) external pure returns (uint256, uint256) {
        return PackedArrays.curvePoint(b, i);
    }

    function itemsCount(bytes calldata b) external pure returns (uint256) {
        return PackedArrays.validateRecords(b, PackedArrays.ITEM_HEAD);
    }

    function validatorsCount(bytes calldata b) external pure returns (uint256) {
        return PackedArrays.validateRecords(b, PackedArrays.VALIDATOR_HEAD);
    }

    /// @dev Walk every item and return a digest of what was read, so a decode error
    ///      anywhere in the walk shows up as a mismatch.
    function walkItems(bytes calldata b) external pure returns (bytes32 digest, uint256 n) {
        n = PackedArrays.validateRecords(b, PackedArrays.ITEM_HEAD);
        uint256 cursor = PackedArrays.recordsStart();
        for (uint256 i; i < n; i++) {
            (uint256 op, address module, uint256 amount, address recipient, bytes calldata data, uint256 next) =
                PackedArrays.itemAt(b, cursor);
            // `op` is digested as uint8 to match the encoder side; the library returns
            // it widened to uint256 purely to avoid solc's cleanup masks.
            digest = keccak256(abi.encodePacked(digest, uint8(op), module, amount, recipient, data));
            cursor = next;
        }
    }

    function walkValidators(bytes calldata b) external pure returns (bytes32 digest, uint256 n) {
        n = PackedArrays.validateRecords(b, PackedArrays.VALIDATOR_HEAD);
        uint256 cursor = PackedArrays.recordsStart();
        for (uint256 i; i < n; i++) {
            (address target, bytes calldata data, uint256 next) = PackedArrays.validatorAt(b, cursor);
            digest = keccak256(abi.encodePacked(digest, target, data));
            cursor = next;
        }
    }
}

contract PackedArraysTest is Test {
    PackedReader reader;

    function setUp() public {
        reader = new PackedReader();
    }

    // ──────────────────── Encoders (the reference the SDK must mirror) ────────────────────

    function _packLegsIn(address[] memory t, uint256[] memory s, uint256[] memory e)
        internal
        pure
        returns (bytes memory b)
    {
        b = abi.encodePacked(uint8(t.length));
        for (uint256 i; i < t.length; i++) {
            b = abi.encodePacked(b, t[i], s[i], e[i]);
        }
    }

    // ──────────────────── Fixed stride ────────────────────

    function testFuzz_legsIn_roundTrip(uint8 n, uint256 seed) public view {
        n = uint8(bound(n, 0, 20));
        address[] memory t = new address[](n);
        uint256[] memory s = new uint256[](n);
        uint256[] memory e = new uint256[](n);
        for (uint256 i; i < n; i++) {
            t[i] = address(uint160(uint256(keccak256(abi.encode(seed, "t", i)))));
            s[i] = uint256(keccak256(abi.encode(seed, "s", i)));
            e[i] = uint256(keccak256(abi.encode(seed, "e", i)));
        }
        bytes memory b = _packLegsIn(t, s, e);

        assertEq(reader.legsInCount(b), n, "count");
        for (uint256 i; i < n; i++) {
            (address token, uint256 start, uint256 end) = reader.readLegIn(b, i);
            assertEq(token, t[i], "token");
            assertEq(start, s[i], "start");
            assertEq(end, e[i], "end");
            assertEq(reader.readLegInToken(b, i), t[i], "single-field token read agrees");
        }
    }

    function testFuzz_legsOut_roundTrip(uint8 n, uint256 seed) public view {
        n = uint8(bound(n, 0, 20));
        bytes memory b = abi.encodePacked(uint8(n));
        address[] memory t = new address[](n);
        address[] memory r = new address[](n);
        uint256[] memory s = new uint256[](n);
        uint256[] memory e = new uint256[](n);
        for (uint256 i; i < n; i++) {
            t[i] = address(uint160(uint256(keccak256(abi.encode(seed, "t", i)))));
            s[i] = uint256(keccak256(abi.encode(seed, "s", i)));
            e[i] = uint256(keccak256(abi.encode(seed, "e", i)));
            r[i] = address(uint160(uint256(keccak256(abi.encode(seed, "r", i)))));
            b = abi.encodePacked(b, t[i], s[i], e[i], r[i]);
        }
        assertEq(reader.legsOutCount(b), n, "count");
        for (uint256 i; i < n; i++) {
            (address token, uint256 start, uint256 end, address recip) = reader.readLegOut(b, i);
            assertEq(token, t[i]);
            assertEq(start, s[i]);
            assertEq(end, e[i]);
            assertEq(recip, r[i]);
        }
    }

    function testFuzz_curve_roundTrip(uint8 n, uint256 seed) public view {
        n = uint8(bound(n, 0, 30));
        bytes memory b = abi.encodePacked(uint8(n));
        uint32[] memory td = new uint32[](n);
        uint32[] memory bp = new uint32[](n);
        for (uint256 i; i < n; i++) {
            td[i] = uint32(uint256(keccak256(abi.encode(seed, "td", i))));
            bp[i] = uint32(uint256(keccak256(abi.encode(seed, "bp", i))));
            b = abi.encodePacked(b, td[i], bp[i]);
        }
        assertEq(reader.curveCount(b), n, "count");
        for (uint256 i; i < n; i++) {
            (uint256 a, uint256 c) = reader.readCurve(b, i);
            assertEq(a, td[i], "timeDelta");
            assertEq(c, bp[i], "bumpBps");
        }
    }

    /// @dev The LAST element must decode correctly — that is where an off-by-one in
    ///      the stride arithmetic or a `calldataload` running past the blob would show
    ///      up (calldataload zero-pads instead of reverting, so this cannot be left to
    ///      chance).
    function test_lastElement_decodesExactly() public view {
        address[] memory t = new address[](3);
        uint256[] memory s = new uint256[](3);
        uint256[] memory e = new uint256[](3);
        for (uint256 i; i < 3; i++) {
            t[i] = address(uint160(0xAAA0 + i));
            s[i] = 1e18 * (i + 1);
            e[i] = type(uint256).max - i; // all-ones tail: catches truncation
        }
        bytes memory b = _packLegsIn(t, s, e);
        (address token, uint256 start, uint256 end) = reader.readLegIn(b, 2);
        assertEq(token, t[2]);
        assertEq(start, s[2]);
        assertEq(end, type(uint256).max - 2, "last field must not be zero-padded");
    }

    // ──────────────────── Malformed input ────────────────────

    /// @dev The whole safety argument rests on this: a blob whose count prefix
    ///      overstates its contents must REVERT, not read adjacent calldata as legs.
    function test_truncatedBlob_reverts() public {
        address[] memory t = new address[](2);
        uint256[] memory s = new uint256[](2);
        uint256[] memory e = new uint256[](2);
        bytes memory good = _packLegsIn(t, s, e);

        // Claim 3 legs while carrying 2.
        bytes memory lying = good;
        lying[0] = bytes1(uint8(3));
        vm.expectRevert(PackedArrays.MalformedPackedArray.selector);
        reader.legsInCount(lying);

        // Chop a byte off the tail while keeping the honest count.
        bytes memory chopped = new bytes(good.length - 1);
        for (uint256 i; i < chopped.length; i++) {
            chopped[i] = good[i];
        }
        vm.expectRevert(PackedArrays.MalformedPackedArray.selector);
        reader.legsInCount(chopped);
    }

    function test_emptyAndZeroCount_areBothEmpty() public view {
        assertEq(reader.legsInCount(""), 0, "absent blob");
        assertEq(reader.legsInCount(abi.encodePacked(uint8(0))), 0, "explicit zero count");
        assertEq(reader.itemsCount(""), 0);
        assertEq(reader.validatorsCount(abi.encodePacked(uint8(0))), 0);
    }

    // ──────────────────── Length-prefixed records ────────────────────

    function testFuzz_items_roundTrip(uint8 n, uint256 seed) public view {
        n = uint8(bound(n, 0, 8));
        bytes memory b = abi.encodePacked(uint8(n));
        bytes32 expected;
        for (uint256 i; i < n; i++) {
            uint8 op = uint8(uint256(keccak256(abi.encode(seed, "op", i))) % 3);
            address module = address(uint160(uint256(keccak256(abi.encode(seed, "m", i)))));
            uint256 amount = uint256(keccak256(abi.encode(seed, "a", i)));
            address recipient = address(uint160(uint256(keccak256(abi.encode(seed, "r", i)))));
            uint256 dl = uint256(keccak256(abi.encode(seed, "dl", i))) % 100;
            bytes memory data = new bytes(dl);
            for (uint256 k; k < dl; k++) {
                data[k] = bytes1(uint8(uint256(keccak256(abi.encode(seed, i, k)))));
            }
            b = abi.encodePacked(b, op, module, amount, recipient, uint16(dl), data);
            expected = keccak256(abi.encodePacked(expected, op, module, amount, recipient, data));
        }
        (bytes32 digest, uint256 count) = reader.walkItems(b);
        assertEq(count, n, "item count");
        assertEq(digest, expected, "items walked back exactly as encoded");
    }

    function testFuzz_validators_roundTrip(uint8 n, uint256 seed) public view {
        n = uint8(bound(n, 0, 8));
        bytes memory b = abi.encodePacked(uint8(n));
        bytes32 expected;
        for (uint256 i; i < n; i++) {
            address target = address(uint160(uint256(keccak256(abi.encode(seed, "t", i)))));
            uint256 dl = uint256(keccak256(abi.encode(seed, "dl", i))) % 130;
            bytes memory data = new bytes(dl);
            for (uint256 k; k < dl; k++) {
                data[k] = bytes1(uint8(uint256(keccak256(abi.encode(seed, i, k)))));
            }
            b = abi.encodePacked(b, target, uint16(dl), data);
            expected = keccak256(abi.encodePacked(expected, target, data));
        }
        (bytes32 digest, uint256 count) = reader.walkValidators(b);
        assertEq(count, n, "validator count");
        assertEq(digest, expected, "validators walked back exactly as encoded");
    }

    /// @dev A record whose declared `data` length runs past the blob must revert
    ///      during validation, before any walk reads it.
    function test_recordOverrunningTheBlob_reverts() public {
        // One validator claiming 500 bytes of data but carrying none.
        bytes memory b = abi.encodePacked(uint8(1), address(0xE1), uint16(500));
        vm.expectRevert(PackedArrays.MalformedPackedArray.selector);
        reader.validatorsCount(b);

        // Same for items.
        bytes memory bi = abi.encodePacked(uint8(1), uint8(0), address(0xD1), uint256(1), address(0), uint16(500));
        vm.expectRevert(PackedArrays.MalformedPackedArray.selector);
        reader.itemsCount(bi);
    }

    /// @dev A record blob whose count outruns the bytes present must revert even when
    ///      each individual header looks well-formed.
    function test_recordCountOverstated_reverts() public {
        bytes memory b = abi.encodePacked(uint8(3), address(0xE1), uint16(0)); // says 3, carries 1
        vm.expectRevert(PackedArrays.MalformedPackedArray.selector);
        reader.validatorsCount(b);
    }
}
