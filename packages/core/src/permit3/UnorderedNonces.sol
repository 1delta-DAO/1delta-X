// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Permit3Base} from "./Permit3Base.sol";

/// @title UnorderedNonces
/// @notice Replay protection for every signed message Permit3 accepts, ported from
///         Permit2's unordered-nonce bitmap. A nonce is a (word, bit) coordinate:
///         `word = nonce >> 8`, `bit = nonce & 0xff`. Signers pick nonces in any
///         order, so parallel in-flight signatures never queue behind each other.
///
/// @dev    ONE BITMAP PER OWNER, SHARED BY BOTH SIGNED FLOWS — allowance permits
///         ({SignedPermits}) and one-shot transfers ({SignatureTransfer}) draw from
///         the same space. That is deliberate: it makes `invalidateUnorderedNonces`
///         a complete kill switch for a nonce range regardless of what was signed
///         against it, and removes any chance of a message being replayed by
///         re-submitting it through the other flow. The cost is that off-chain
///         nonce allocation must be per-owner, not per-message-type.
///
///  PROVENANCE — Permit2 `SignatureTransfer`'s nonce half (Uniswap, MIT).
///  ─────────────────────────────────────────────────────────────────────────
///  FROM PERMIT2, semantics unchanged: the (word, bit) nonce encoding,
///  `invalidateUnorderedNonces(wordPos, mask)` and its event.
///  CHANGED:
///    • Extracted into its own layer, because BOTH signed flows use it — in
///      Permit2 the bitmap is private to `SignatureTransfer` and the allowance
///      permits use sequential nonces instead.
///    • `permitNonceBitmap` (Permit2: `nonceBitmap`), and `isPermitNonceUsed`
///      is a Permit3 addition — Permit2 exposes only the raw mapping.
///    • Read-check-set rather than Permit2's `_useUnorderedNonce` XOR-flip;
///      same effect, and it reverts `PermitNonceUsed` where Permit2 reverts
///      `InvalidNonce`. Permit2's `bitmapPositions` helper is inlined.
abstract contract UnorderedNonces is Permit3Base {
    /// @notice Permit replay-protection: owner → wordIndex → bitmap of used nonces.
    mapping(address => mapping(uint256 => uint256)) public permitNonceBitmap;

    function isPermitNonceUsed(address owner, uint256 nonce) external view override returns (bool) {
        return (permitNonceBitmap[owner][nonce >> 8] & (1 << (nonce & 0xff))) != 0;
    }

    /// @dev Ported from Permit2's `invalidateUnorderedNonces`.
    function invalidateUnorderedNonces(uint256 wordPos, uint256 mask) external override {
        permitNonceBitmap[msg.sender][wordPos] |= mask;
        emit UnorderedNonceInvalidation(msg.sender, wordPos, mask);
    }

    /// @dev Batched form for the combined {SignedPermits.lockdownAll}.
    function _invalidateNonces(address owner, uint256[] calldata wordPos, uint256[] calldata mask) internal {
        uint256 length = wordPos.length;
        if (length != mask.length) revert NonceArrayLengthMismatch();
        for (uint256 i; i < length;) {
            permitNonceBitmap[owner][wordPos[i]] |= mask[i];
            emit UnorderedNonceInvalidation(owner, wordPos[i], mask[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Marks `nonce` spent for `owner`, reverting if it already was.
    function _usePermitNonce(address owner, uint256 nonce) internal {
        uint256 wordIndex = nonce >> 8;
        uint256 bitIndex = nonce & 0xff;
        uint256 mask = 1 << bitIndex;
        uint256 word = permitNonceBitmap[owner][wordIndex];
        if (word & mask != 0) revert PermitNonceUsed();
        permitNonceBitmap[owner][wordIndex] = word | mask;
    }

    /// @dev Non-reverting predicate form of {_usePermitNonce}, for the idempotent
    ///      signed-permit path ({SignedPermits.permitBatchWithWitnessIfNeeded}).
    function _isPermitNonceUsed(address owner, uint256 nonce) internal view returns (bool) {
        return permitNonceBitmap[owner][nonce >> 8] & (1 << (nonce & 0xff)) != 0;
    }
}
