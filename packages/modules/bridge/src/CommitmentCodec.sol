// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title CommitmentCodec
/// @notice The 64-byte payload a source-chain fill bridges to the destination
///         {BridgedOrderInbox}. Deliberately packed: LayerZero prices messages
///         per byte, and `abi.encode` would double this to 128.
///
///         Layout, big-endian:
///           [0  : 32)  orderHash    bytes32   destination order, EIP-712 struct hash
///           [32 : 52)  beneficiary  address   refund target on the DESTINATION chain
///           [52 : 60)  dstChainId   uint64    replay guard, see below
///           [60 : 64)  expiry       uint32    refund unlock if no order ever activates
///
///         `dstChainId` is not redundant. The EIP-712 *digest* is chain-bound via
///         the domain separator, but the raw `orderHash` is not — and the
///         signature-less approval path the inbox uses never computes a digest.
///         With a CREATE2 inbox deployed at the same address on several chains, a
///         replayed bridge message would otherwise credit the same order twice.
library CommitmentCodec {
    uint256 internal constant LENGTH = 64;

    struct Commitment {
        bytes32 orderHash;
        address beneficiary;
        uint64 dstChainId;
        uint32 expiry;
    }

    function encode(Commitment memory c) internal pure returns (bytes memory) {
        return abi.encodePacked(c.orderHash, c.beneficiary, c.dstChainId, c.expiry);
    }

    /// @notice Non-reverting decode. Returns `ok = false` rather than reverting so
    ///         the LayerZero compose path — where a revert strands already-
    ///         delivered tokens — can park a malformed payload instead of
    ///         rejecting it. The Across path checks `ok` and reverts itself, which
    ///         is safe there (the relayer's fill unwinds and the origin deposit
    ///         refunds).
    function tryDecode(bytes calldata b) internal pure returns (bool ok, Commitment memory c) {
        if (b.length != LENGTH) return (false, c);
        c.orderHash = bytes32(b[0:32]);
        c.beneficiary = address(bytes20(b[32:52]));
        c.dstChainId = uint64(bytes8(b[52:60]));
        c.expiry = uint32(bytes4(b[60:64]));
        // A zero order hash or beneficiary is a malformed payload, not a valid
        // commitment: the first can never match a real order, the second would
        // burn the refund.
        ok = c.orderHash != bytes32(0) && c.beneficiary != address(0);
    }
}
