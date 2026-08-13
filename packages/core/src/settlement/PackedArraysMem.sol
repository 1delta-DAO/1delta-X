// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedArrays} from "./PackedArrays.sol";

/// @title PackedArraysMem
/// @notice MEMORY-side readers for the packed leg blobs — the mirror of
///         {PackedArrays}, which is deliberately calldata-only.
///
///  The settler always reads orders straight out of calldata, and keeping
///  {PackedArrays} restricted to that is what lets its accessors be plain offset
///  arithmetic with no copying. Peripheral contracts are different: a solver receives
///  an order at an external boundary and then passes it around as `Order memory`, so
///  it needs to read the same blobs from memory.
///
///  Only the fields those callers actually use are mirrored. If you need more, add
///  them here rather than widening {PackedArrays} — the split is what keeps the hot
///  path free of memory handling.
///
///  ⚠ Same safety contract as {PackedArrays}: call {count} (or a validating read on
///  the calldata side) before indexing, and never pass an index at or beyond it. A
///  memory read past the blob returns whatever follows in memory rather than
///  reverting.
library PackedArraysMem {
    /// @dev Element count from the blob's one-byte prefix. `b.length` is the BYTE
    ///      length and is NOT the count — a well-formed empty array is `0x00`.
    function count(bytes memory b) internal pure returns (uint256 n) {
        if (b.length == 0) return 0;
        assembly {
            n := byte(0, mload(add(b, 0x20)))
        }
    }

    /// @notice `token` of input leg `i`.
    function legInToken(bytes memory b, uint256 i) internal pure returns (address a) {
        uint256 stride = PackedArrays.LEG_IN_STRIDE;
        assembly {
            // 0x20 array header + 1 count byte = 0x21
            a := shr(96, mload(add(add(b, 0x21), mul(i, stride))))
        }
    }

    /// @notice `token` of output leg `j`.
    function legOutToken(bytes memory b, uint256 j) internal pure returns (address a) {
        uint256 stride = PackedArrays.LEG_OUT_STRIDE;
        assembly {
            a := shr(96, mload(add(add(b, 0x21), mul(j, stride))))
        }
    }

    /// @notice `recipient` of output leg `j` — needed by the ERC-7683 adapter, which
    ///         must name each output's destination in a {ResolvedCrossChainOrder}.
    function legOutRecipient(bytes memory b, uint256 j) internal pure returns (address a) {
        uint256 stride = PackedArrays.LEG_OUT_STRIDE;
        assembly {
            // token(20) | start(32) | end(32) = 84 bytes into the element
            a := shr(96, mload(add(add(add(b, 0x21), mul(j, stride)), 84)))
        }
    }
}
