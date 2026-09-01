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
///  ⚠ Same safety contract as {PackedArrays}: call {validateLegsIn} /
///  {validateLegsOut} before indexing, and never pass an index at or beyond what
///  they return. A memory read past the blob returns whatever follows in memory
///  rather than reverting, so an unvalidated count is not a bound — it is a number
///  the blob's author chose.
///
///  This header used to point callers at `count`, which is the memory twin of
///  {PackedArrays.countUnchecked} — the function the calldata library explicitly
///  forbids as a bound ("deliberately proves nothing about the bytes that follow…
///  the count must always come from the validator"). `bytes.concat(hex"03")`
///  reports three legs while holding none. The unchecked reader is still here, now
///  named to say so; every caller that goes on to index was repointed at a
///  validator. See `docs/audit-2026-09-leads.md` B-5.
library PackedArraysMem {
    /// @notice The declared element count, WITHOUT validating the blob.
    /// @dev For "is this array empty?" tests ONLY, exactly as
    ///      {PackedArrays.countUnchecked}. Callers that index MUST use
    ///      {validateLegsIn} / {validateLegsOut} instead.
    function countUnchecked(bytes memory b) internal pure returns (uint256 n) {
        if (b.length == 0) return 0;
        assembly {
            n := byte(0, mload(add(b, 0x20)))
        }
    }

    /// @notice Bounds-check a fixed-stride MEMORY blob and return its element count.
    /// @dev The memory mirror of {PackedArrays.validateFixed}, and the only sound
    ///      source of a bound for the accessors below. An empty blob reads as zero
    ///      elements, so an order that omits an optional array costs nothing.
    function validateFixed(bytes memory b, uint256 stride) internal pure returns (uint256 n) {
        if (b.length == 0) return 0;
        assembly {
            n := byte(0, mload(add(b, 0x20)))
        }
        // `1 + n * stride` cannot overflow: n <= 255 and stride is a small constant.
        unchecked {
            if (b.length < 1 + n * stride) revert PackedArrays.MalformedPackedArray();
        }
    }

    /// @notice Validated element count of a packed `LegIn` blob.
    function validateLegsIn(bytes memory b) internal pure returns (uint256) {
        return validateFixed(b, PackedArrays.LEG_IN_STRIDE);
    }

    /// @notice Validated element count of a packed `LegOut` blob.
    function validateLegsOut(bytes memory b) internal pure returns (uint256) {
        return validateFixed(b, PackedArrays.LEG_OUT_STRIDE);
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
