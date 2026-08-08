// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title PackedArrays
/// @notice Calldata readers for the protocol's PACKED array encoding — the format
///         that replaces `LegIn[] / LegOut[] / CurvePoint[] / Item[] / Validator[]`
///         (and Permit3's `TokenPermit[] / TakerPermit[]`) inside the SIGNED order
///         with opaque `bytes` blobs.
///
///  Why
///  ───
///  An EIP-712 array-of-struct member must be hashed element by element: one
///  `keccak256` per element, then one over the concatenated element hashes. A `bytes`
///  member is instead hashed as a SINGLE `keccak256` over the blob. Measured on the
///  real order shape, that takes the struct hash from 4,321 → 1,874 gas for a
///  one-leg-per-side order and 12,050 → 2,270 for a 4×4 order with items and
///  validators.
///
///  Reading is cheaper too, which was not the original motivation: indexed access
///  into a fixed-stride blob is plain offset arithmetic, where `legsIn[i].token`
///  makes solc re-resolve the array offset, re-check the length bound and recompute
///  the element offset on every field read. Measured 744 → 379 gas to read one leg's
///  three fields, 2,223 → 802 for four — INCLUDING the bounds check below.
///
///  Safety contract — READ THIS BEFORE ADDING A CALLER
///  ──────────────────────────────────────────────────
///  Moving off `LegIn[] calldata` gives up the ABI decoder's automatic bounds
///  checking, so it is replaced here by an explicit one. The rule is:
///
///      **Call `validateFixed` (or `validateRecords`) ONCE per blob, keep the
///      returned count, and only then use the element accessors.**
///
///  The accessors are deliberately unchecked — one length assertion up front covers
///  every element read that follows, which is what makes the encoding cheaper than
///  the ABI form rather than merely different. An accessor called with an index past
///  the validated count reads adjacent calldata as if it were order data, so the
///  count must always come from the validator, never from a caller-supplied number.
///
///  Layout
///  ──────
///  Every blob starts with a `uint8` element count, so a well-formed empty array is
///  the single byte `0x00` and a missing/zero-length blob is also treated as empty.
///  255 elements is the ceiling, matching the existing 255-item cap in
///  `Batch._assertMatchShape`.
///
///    FIXED-STRIDE (indexable in O(1)):
///      LegIn      84 = token(20) | startAmount(32) | endAmount(32)
///      LegOut    104 = token(20) | startAmount(32) | endAmount(32) | recipient(20)
///      CurvePoint  8 = timeDelta(4) | bumpBps(4)
///
///    (`startAmount`/`endAmount` are the `start`/`end` fields of {LegIn}/{LegOut};
///     spelled out here because the byte table sits next to a field that IS a time.)
///
///    ⚠ `start`/`end` on a leg are TOKEN AMOUNTS, not times — the two ends of that
///      leg's auction ramp, interpolated by the order's shared `bumpBps` clock
///      (0 = `start`, 10000 = `end`). Inputs RISE, outputs FALL, and `end == 0` is
///      the FIXED-leg sentinel meaning "no decay, always `start`". Only
///      `CurvePoint.timeDelta` above is a time. See {LegIn} / {LegOut}.
///
///    LENGTH-PREFIXED RECORDS (walked sequentially — the settler never random-
///    accesses these, and their trailing `bytes data` makes a stride impossible):
///      Item       op(1) | module(20) | amount(32) | recipient(20) | len(2) | data
///      Validator  target(20) | len(2) | data
library PackedArrays {
    /// @dev A blob is shorter than its own count prefix claims, or a record's declared
    ///      `data` length runs past the end of the blob. Either way the encoding is
    ///      malformed and nothing in it can be trusted.
    error MalformedPackedArray();

    /// @dev MEASURED, do not "optimize" by narrowing the amounts to `uint128` so the
    ///      pair shares one word (stride 52/72). It was tried: transaction calldata
    ///      drops 32 bytes per leg (~38% of the legs' bytes, worth ~128 gas on
    ///      mainnet since the bytes dropped are an amount's leading zeros), but the
    ///      shift-and-mask needed to split the shared word costs MORE than the
    ///      `calldataload` it saves, and the settler decodes a leg several times per
    ///      fill. Net +457..+685 gas on every fill, 335 of 423 tests worse.
    uint256 internal constant LEG_IN_STRIDE = 84;
    uint256 internal constant LEG_OUT_STRIDE = 104;
    uint256 internal constant CURVE_STRIDE = 8;

    /// @dev Fixed header of an {Item} record, before its `data`: op | module | amount
    ///      | recipient | dataLen.
    uint256 internal constant ITEM_HEAD = 1 + 20 + 32 + 20 + 2;
    /// @dev Fixed header of a {Validator} record: target | dataLen.
    uint256 internal constant VALIDATOR_HEAD = 20 + 2;

    // ──────────────────── Validation ────────────────────

    /// @notice The declared element count, WITHOUT validating the blob.
    /// @dev For "is this array empty?" tests only. `b.length != 0` is NOT that test —
    ///      a well-formed empty array is the single byte `0x00`, which has length 1.
    ///      Callers that go on to READ elements must use {validateFixed} /
    ///      {validateRecords} instead; this deliberately proves nothing about the
    ///      bytes that follow.
    function countUnchecked(bytes calldata b) internal pure returns (uint256 count) {
        if (b.length == 0) return 0;
        assembly {
            count := byte(0, calldataload(b.offset))
        }
    }

    /// @notice Bounds-check a FIXED-STRIDE blob and return its element count.
    /// @dev THE one check. Every `fixed*` accessor below assumes it has run and that
    ///      the index passed is `< count`. An empty blob (`b.length == 0`) reads as
    ///      zero elements, so an order that omits an optional array costs nothing.
    function validateFixed(bytes calldata b, uint256 stride) internal pure returns (uint256 count) {
        if (b.length == 0) return 0;
        assembly {
            count := byte(0, calldataload(b.offset))
        }
        // `1 + count * stride` cannot overflow: count ≤ 255 and stride is a small
        // constant, so the product is bounded by 255 * 104.
        unchecked {
            if (b.length < 1 + count * stride) revert MalformedPackedArray();
        }
    }

    // ──────────────────── Fixed-stride accessors ────────────────────

    /// @notice Element `i` of a packed `LegIn` blob. Unchecked — see the safety
    ///         contract; `i` MUST be below the count {validateFixed} returned.
    function legIn(bytes calldata b, uint256 i) internal pure returns (address token, uint256 start, uint256 end) {
        assembly {
            let p := add(add(b.offset, 1), mul(i, LEG_IN_STRIDE))
            token := shr(96, calldataload(p))
            start := calldataload(add(p, 20))
            end := calldataload(add(p, 52))
        }
    }

    /// @notice Just the `token` of element `i` — the common single-field read on the
    ///         settlement path, which should not pay to decode the amounts.
    function legInToken(bytes calldata b, uint256 i) internal pure returns (address token) {
        assembly {
            token := shr(96, calldataload(add(add(b.offset, 1), mul(i, LEG_IN_STRIDE))))
        }
    }

    /// @notice Element `i` of a packed `LegOut` blob. Unchecked — see {legIn}.
    function legOut(bytes calldata b, uint256 i)
        internal
        pure
        returns (address token, uint256 start, uint256 end, address recipient)
    {
        assembly {
            let p := add(add(b.offset, 1), mul(i, LEG_OUT_STRIDE))
            token := shr(96, calldataload(p))
            start := calldataload(add(p, 20))
            end := calldataload(add(p, 52))
            recipient := shr(96, calldataload(add(p, 84)))
        }
    }

    function legOutToken(bytes calldata b, uint256 i) internal pure returns (address token) {
        assembly {
            token := shr(96, calldataload(add(add(b.offset, 1), mul(i, LEG_OUT_STRIDE))))
        }
    }

    /// @notice Element `i` of a packed `CurvePoint` blob. Unchecked — see {legIn}.
    function curvePoint(bytes calldata b, uint256 i) internal pure returns (uint256 timeDelta, uint256 bumpBps) {
        assembly {
            let p := add(add(b.offset, 1), mul(i, CURVE_STRIDE))
            let w := calldataload(p)
            timeDelta := shr(224, w)
            bumpBps := and(shr(192, w), 0xffffffff)
        }
    }

    // ──────────────────── Length-prefixed records ────────────────────

    /// @notice Element count of a RECORD blob, and a validating walk over it.
    /// @dev Records are variable length, so unlike {validateFixed} this must actually
    ///      traverse the blob to prove every declared `data` length stays inside it.
    ///      Done once at the start of a fill; the sequential readers below then walk
    ///      the same blob without re-checking.
    /// @param headSize {ITEM_HEAD} or {VALIDATOR_HEAD}.
    function validateRecords(bytes calldata b, uint256 headSize) internal pure returns (uint256 count) {
        if (b.length == 0) return 0;
        uint256 len = b.length;
        assembly {
            count := byte(0, calldataload(b.offset))
        }
        uint256 cursor = 1;
        for (uint256 i; i < count;) {
            // Header must fit before its own `dataLen` field can be trusted.
            if (cursor + headSize > len) revert MalformedPackedArray();
            uint256 dataLen;
            assembly {
                // `dataLen` is the last 2 bytes of the header.
                dataLen := shr(240, calldataload(add(add(b.offset, cursor), sub(headSize, 2))))
            }
            unchecked {
                cursor += headSize + dataLen;
                ++i;
            }
            if (cursor > len) revert MalformedPackedArray();
        }
    }

    /// @notice Read the record starting at `cursor`, returning the next cursor.
    ///         Sequential by design — the settler iterates items and validators in
    ///         signed order and never indexes into them.
    /// @dev `op` is returned as a `uint256`, not the `uint8` the field actually is:
    ///      the EVM compares full words, so a narrow type only makes solc emit a
    ///      cleanup mask at every read and comparison. The assembly below already
    ///      yields a value in 0..255 by construction (`byte`), so nothing is lost.
    function itemAt(bytes calldata b, uint256 cursor)
        internal
        pure
        returns (uint256 op, address module, uint256 amount, address recipient, bytes calldata data, uint256 next)
    {
        uint256 dataLen;
        assembly {
            let p := add(b.offset, cursor)
            op := byte(0, calldataload(p))
            module := shr(96, calldataload(add(p, 1)))
            amount := calldataload(add(p, 21))
            recipient := shr(96, calldataload(add(p, 53)))
            dataLen := shr(240, calldataload(add(p, 73)))
            data.offset := add(p, ITEM_HEAD)
            data.length := dataLen
        }
        unchecked {
            next = cursor + ITEM_HEAD + dataLen;
        }
    }

    /// @notice Sequential {Validator} record reader — see {itemAt}.
    function validatorAt(bytes calldata b, uint256 cursor)
        internal
        pure
        returns (address target, bytes calldata data, uint256 next)
    {
        uint256 dataLen;
        assembly {
            let p := add(b.offset, cursor)
            target := shr(96, calldataload(p))
            dataLen := shr(240, calldataload(add(p, 20)))
            data.offset := add(p, VALIDATOR_HEAD)
            data.length := dataLen
        }
        unchecked {
            next = cursor + VALIDATOR_HEAD + dataLen;
        }
    }

    /// @notice Where the first record sits — after the one-byte count prefix.
    function recordsStart() internal pure returns (uint256) {
        return 1;
    }
}
