// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SignatureVerification} from "../permit3/SignatureVerification.sol";
import {OrderState} from "./OrderState.sol";

/// @title Signatures
/// @notice Order AUTHORIZATION verification, isolated: the EIP-712 domain and the
///         `_verifySignature` gate that every fill runs. Two ways to authorize an
///         order are accepted here:
///           1. a signature over the EIP-712 digest — EOA (ecrecover), EIP-1271
///              contract wallets, and EIP-7702 accounts, via {SignatureVerification};
///           2. an EMPTY `sig`, authorized against the maker's on-chain
///              {OrderState.approveOrder} record (the signature-less path).
///
///         The domain separator is cached at deploy and rebuilt only if
///         `block.chainid` changes (a fork), so a signature can never be replayed
///         against the wrong domain. This layer owns NO settlement logic and moves
///         NO tokens — it only answers "is this order authorized by its maker?".
abstract contract Signatures is OrderState {
    /// @dev EIP-712 domain, cached at deploy but recomputed if `block.chainid`
    ///      changes (chain fork) so an order signature can never be replayed
    ///      against the wrong domain after a split. Mirrors Permit3's EIP712 base;
    ///      exposed via the `DOMAIN_SEPARATOR()` view below.
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;
    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _HASHED_NAME = keccak256("Settlement");
    bytes32 private constant _HASHED_VERSION = keccak256("1");

    /// @dev An empty `sig` was supplied for a fill, but the maker has no matching
    ///      on-chain {OrderState.approveOrder} record for this order.
    error OrderNotApproved();

    constructor() {
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator();
    }

    /// @notice EIP-712 domain separator for the current chain. Returns the cached
    ///         value unless `block.chainid` has changed since deployment (fork),
    ///         in which case it is rebuilt so signatures stay domain-bound.
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return block.chainid == _CACHED_CHAIN_ID ? _CACHED_DOMAIN_SEPARATOR : _buildDomainSeparator();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(_DOMAIN_TYPEHASH, _HASHED_NAME, _HASHED_VERSION, block.chainid, address(this)));
    }

    /// @dev `keccak256(abi.encodePacked("\x19\x01", domain, structHash))` built in
    ///      SCRATCH SPACE instead of an allocated 66-byte buffer. `encodePacked`
    ///      allocated + copied on every fill for a fixed 66-byte preimage; this
    ///      writes it at 0x1e..0x60 (borrowing the free-memory-pointer word, then
    ///      restoring it) and hashes in place. Identical digest.
    ///
    ///      EQUIVALENT SOLIDITY:
    ///
    ///          return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    function _hashTypedData(bytes32 structHash) private view returns (bytes32 digest) {
        bytes32 domain = DOMAIN_SEPARATOR();
        /// @solidity memory-safe-assembly
        assembly {
            let fmp := mload(0x40)
            mstore(0x00, 0x1901)
            mstore(0x20, domain)
            mstore(0x40, structHash)
            digest := keccak256(0x1e, 0x42)
            mstore(0x40, fmp) // restore the free-memory pointer
        }
    }

    /// @dev Authorize `orderHash` for `expected` (the order's maker). Either the
    ///      empty-sig on-chain-approval path or a real signature over the domain-
    ///      bound digest; reverts if neither authorizes.
    function _verifySignature(bytes32 orderHash, bytes calldata sig, address expected) internal view {
        // Signature-less path: an EMPTY `sig` authorizes against the maker's on-chain
        // {approveOrder} record instead of a signature. No valid signature has zero
        // length (the shared verifier rejects it), so the sentinel can never collide
        // with a real one. This lets a maker that cannot sign — e.g. a multisig
        // without EIP-1271 — still place orders. Every other fill gate is unchanged.
        if (sig.length == 0) {
            if (!orderApproved[expected][orderHash]) revert OrderNotApproved();
            return;
        }
        bytes32 digest = _hashTypedData(orderHash);
        // Shared verifier: EOA (ecrecover), EIP-1271 contract wallets, and
        // EIP-7702 accounts (raw-key or delegated-1271) are all accepted.
        SignatureVerification.verify(sig, digest, expected);
    }
}
