// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title EIP712
/// @notice Ported from Uniswap's Permit2
///         (https://github.com/Uniswap/permit2 — src/EIP712.sol).
///         Caches the domain separator as an immutable value but recomputes it
///         if `block.chainid` changes (chain fork), so signatures cannot be
///         replayed against the wrong domain after a fork.
/// @dev    PROVENANCE — Permit2 `src/EIP712.sol` (Uniswap, MIT). The
///         caching/fork-recompute logic is verbatim. Two deviations:
///           • the domain values — name "Permit3", version "1" — so the
///             separator matches the pre-EIP712-base implementation, and no
///             signature is valid against both contracts;
///           • `_hashTypedData` builds its 66-byte preimage in scratch space
///             instead of `abi.encodePacked`, which allocated on every permit.
///             Identical digest; see the note on that function.
contract EIP712 {
    // Cache the domain separator as an immutable value, but also store the chain id that it
    // corresponds to, in order to invalidate the cached domain separator if the chain id changes.
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;

    bytes32 private constant _HASHED_NAME = keccak256("Permit3");
    bytes32 private constant _HASHED_VERSION = keccak256("1");
    bytes32 private constant _TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    constructor() {
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator();
    }

    /// @notice Returns the domain separator for the current chain.
    /// @dev Uses cached version if chainid and address are unchanged from construction.
    function DOMAIN_SEPARATOR() public view virtual returns (bytes32) {
        return block.chainid == _CACHED_CHAIN_ID ? _CACHED_DOMAIN_SEPARATOR : _buildDomainSeparator();
    }

    /// @notice Builds a domain separator using the current chainId and contract address.
    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(_TYPE_HASH, _HASHED_NAME, _HASHED_VERSION, block.chainid, address(this)));
    }

    /// @notice Creates an EIP-712 typed data hash
    /// @dev Built in SCRATCH SPACE rather than an allocated 66-byte buffer: the
    ///      preimage is a fixed 66 bytes, so `abi.encodePacked`'s allocation + copy
    ///      was pure overhead. Writes at 0x1e..0x60 (borrowing the free-memory-pointer
    ///      word, then restoring it) and hashes in place. Identical digest.
    ///
    ///      EQUIVALENT SOLIDITY:
    ///
    ///          return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), dataHash));
    function _hashTypedData(bytes32 dataHash) internal view returns (bytes32 digest) {
        bytes32 domain = DOMAIN_SEPARATOR();
        /// @solidity memory-safe-assembly
        assembly {
            let fmp := mload(0x40)
            mstore(0x00, 0x1901)
            mstore(0x20, domain)
            mstore(0x40, dataHash)
            digest := keccak256(0x1e, 0x42)
            mstore(0x40, fmp)
        }
    }
}
