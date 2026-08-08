// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LegIn, LegOut, CurvePoint, Item, Validator} from "@core/settlement/Structs.sol";

/// @title PackedEncode
/// @notice The ENCODER side of {PackedArrays} — typed structs in, packed blob out.
///
///  Lives in the test tree on purpose: the settler only ever DECODES (orders arrive
///  as calldata), so shipping an encoder in `Settlement` would spend EIP-170 budget on
///  something no fill path calls. Order construction is an off-chain job, and the
///  TypeScript SDK owns the production encoder — this is the on-chain mirror that lets
///  tests keep building readable typed arrays and pack them at the assignment.
///
///  ⚠ This is the reference the SDK must match byte-for-byte. If the two ever diverge,
///  the order hash diverges and every affected order becomes unfillable — which is
///  exactly what the golden-hash test and the SDK cross-check exist to catch.
library PackedEncode {
    function legsIn(LegIn[] memory legs) internal pure returns (bytes memory b) {
        b = abi.encodePacked(uint8(legs.length));
        for (uint256 i; i < legs.length; i++) {
            b = abi.encodePacked(b, legs[i].token, legs[i].start, legs[i].end);
        }
    }

    function legsOut(LegOut[] memory legs) internal pure returns (bytes memory b) {
        b = abi.encodePacked(uint8(legs.length));
        for (uint256 i; i < legs.length; i++) {
            b = abi.encodePacked(b, legs[i].token, legs[i].start, legs[i].end, legs[i].recipient);
        }
    }

    function curve(CurvePoint[] memory points) internal pure returns (bytes memory b) {
        b = abi.encodePacked(uint8(points.length));
        for (uint256 i; i < points.length; i++) {
            b = abi.encodePacked(b, points[i].timeDelta, points[i].bumpBps);
        }
    }

    function items(Item[] memory its) internal pure returns (bytes memory b) {
        b = abi.encodePacked(uint8(its.length));
        for (uint256 i; i < its.length; i++) {
            b = abi.encodePacked(
                b,
                uint8(its[i].op),
                its[i].module,
                its[i].amount,
                its[i].recipient,
                uint16(its[i].data.length),
                its[i].data
            );
        }
    }

    function validators(Validator[] memory vs) internal pure returns (bytes memory b) {
        b = abi.encodePacked(uint8(vs.length));
        for (uint256 i; i < vs.length; i++) {
            b = abi.encodePacked(b, vs[i].target, uint16(vs[i].data.length), vs[i].data);
        }
    }

    // ──────────────────── In-place mutators (memory) ────────────────────
    //
    // Tests routinely poke one field of one leg to build a malformed order. With
    // typed arrays that was `o.legsIn[0].start = 0`; a packed blob has to be rewritten
    // in place instead. These do the minimal word/address overwrite at the right
    // offset — same intent, and they keep the malformed-order tests readable.

    function setLegInStart(bytes memory b, uint256 i, uint256 v) internal pure returns (bytes memory) {
        _setWord(b, 1 + i * 84 + 20, v);
        return b;
    }

    function setLegInEnd(bytes memory b, uint256 i, uint256 v) internal pure returns (bytes memory) {
        _setWord(b, 1 + i * 84 + 52, v);
        return b;
    }

    function setLegInToken(bytes memory b, uint256 i, address a) internal pure returns (bytes memory) {
        _setAddr(b, 1 + i * 84, a);
        return b;
    }

    function setLegOutStart(bytes memory b, uint256 i, uint256 v) internal pure returns (bytes memory) {
        _setWord(b, 1 + i * 104 + 20, v);
        return b;
    }

    function setLegOutEnd(bytes memory b, uint256 i, uint256 v) internal pure returns (bytes memory) {
        _setWord(b, 1 + i * 104 + 52, v);
        return b;
    }

    function setLegOutToken(bytes memory b, uint256 i, address a) internal pure returns (bytes memory) {
        _setAddr(b, 1 + i * 104, a);
        return b;
    }

    function setLegOutRecipient(bytes memory b, uint256 i, address a) internal pure returns (bytes memory) {
        _setAddr(b, 1 + i * 104 + 84, a);
        return b;
    }

    function _setWord(bytes memory b, uint256 off, uint256 v) private pure {
        require(off + 32 <= b.length, "oob");
        assembly {
            mstore(add(add(b, 0x20), off), v)
        }
    }

    /// @dev Overwrite the 20 address bytes at `off` WITHOUT disturbing the 12 bytes
    ///      that follow — a packed blob has no padding, so the next field starts
    ///      immediately and a naive 32-byte store would corrupt it.
    function _setAddr(bytes memory b, uint256 off, address a) private pure {
        require(off + 20 <= b.length, "oob");
        assembly {
            let p := add(add(b, 0x20), off)
            let keep := and(mload(p), 0x0000000000000000000000000000000000000000ffffffffffffffffffffffff)
            mstore(p, or(shl(96, a), keep))
        }
    }

    // ──────────────────── Memory-side getters ────────────────────
    //
    // {PackedArrays} is calldata-only — that is where the settler reads orders from,
    // and keeping it so is what makes its accessors cheap. Tests hold orders in
    // MEMORY, so they need this mirror to read a field back out.

    function count(bytes memory b) internal pure returns (uint256 n) {
        if (b.length == 0) return 0;
        assembly {
            n := byte(0, mload(add(b, 0x20)))
        }
    }

    function getLegInToken(bytes memory b, uint256 i) internal pure returns (address a) {
        assembly {
            a := shr(96, mload(add(add(b, 0x21), mul(i, 84))))
        }
    }

    function getLegInStart(bytes memory b, uint256 i) internal pure returns (uint256 v) {
        assembly {
            v := mload(add(add(b, 0x35), mul(i, 84)))
        }
    }

    function getLegInEnd(bytes memory b, uint256 i) internal pure returns (uint256 v) {
        assembly {
            v := mload(add(add(b, 0x55), mul(i, 84)))
        }
    }

    function getLegOutToken(bytes memory b, uint256 i) internal pure returns (address a) {
        assembly {
            a := shr(96, mload(add(add(b, 0x21), mul(i, 104))))
        }
    }

    function getLegOutStart(bytes memory b, uint256 i) internal pure returns (uint256 v) {
        assembly {
            v := mload(add(add(b, 0x35), mul(i, 104)))
        }
    }

    function getLegOutEnd(bytes memory b, uint256 i) internal pure returns (uint256 v) {
        assembly {
            v := mload(add(add(b, 0x55), mul(i, 104)))
        }
    }

    function getLegOutRecipient(bytes memory b, uint256 i) internal pure returns (address a) {
        assembly {
            a := shr(96, mload(add(add(b, 0x75), mul(i, 104))))
        }
    }

    /// @dev Overwrite item `i`'s `amount`. Items are length-prefixed records, so this
    ///      walks to the record rather than indexing — only used by tests that poke a
    ///      single field to build a deliberately broken order.
    function setItemAmount(bytes memory b, uint256 i, uint256 v) internal pure returns (bytes memory) {
        uint256 cur = 1;
        for (uint256 k; k < i; k++) {
            uint256 dl;
            assembly {
                dl := shr(240, mload(add(add(b, 0x20), add(cur, 73))))
            }
            cur += 75 + dl;
        }
        _setWord(b, cur + 21, v); // op(1) + module(20)
        return b;
    }

    /// @dev `data` of record `i` in an item / validator blob. `headSize` is 75 for
    ///      items, 22 for validators (both include the 2-byte length field).
    function getRecordData(bytes memory b, uint256 i, uint256 headSize) internal pure returns (bytes memory out) {
        uint256 cur = 1;
        uint256 dl;
        for (uint256 k; k <= i; k++) {
            assembly {
                dl := shr(240, mload(add(add(b, 0x20), add(cur, sub(headSize, 2)))))
            }
            if (k == i) break;
            cur += headSize + dl;
        }
        out = new bytes(dl);
        uint256 src = cur + headSize;
        for (uint256 j; j < dl; j++) {
            out[j] = b[src + j];
        }
    }

    function getItemData(bytes memory b, uint256 i) internal pure returns (bytes memory) {
        return getRecordData(b, i, 75);
    }

    function getValidatorData(bytes memory b, uint256 i) internal pure returns (bytes memory) {
        return getRecordData(b, i, 22);
    }

    // ──────────────────── Convenience for the common shapes ────────────────────

    function oneLegIn(address token, uint256 start, uint256 end) internal pure returns (bytes memory) {
        LegIn[] memory l = new LegIn[](1);
        l[0] = LegIn(token, start, end);
        return legsIn(l);
    }

    function oneLegOut(address token, uint256 start, uint256 end, address recipient)
        internal
        pure
        returns (bytes memory)
    {
        LegOut[] memory l = new LegOut[](1);
        l[0] = LegOut(token, start, end, recipient);
        return legsOut(l);
    }

    function noItems() internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0));
    }

    function noValidators() internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0));
    }

    function noCurve() internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0));
    }
}
