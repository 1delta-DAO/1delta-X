// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOrderValidator} from "../interfaces/IOrderValidator.sol";
import {Order} from "../settlement/UniversalSettlement.sol";

/// @title FillerAttestationValidator
/// @notice Reference validator that gates an order on an OFF-CHAIN attestation
///         about the filler, delivered by the filler at fill time through the
///         `takerData` channel. The canonical example of the taker-supplied data
///         pattern: the maker signs *who* it trusts to vouch for fillers (an
///         `attester`) and *which* credential class (`listId`); the filler carries
///         a fresh signature from that attester in `takerData`. Neither the maker
///         nor the settlement needs the credential on-chain in advance.
///
///  Off-chain issuance
///  ──────────────────
///  An `attester` (a compliance desk, a KYC provider, a reputation service — the
///  maker chooses whom to trust) signs an EIP-712 `FillerAttestation(filler,
///  listId, expiry)` over THIS validator's domain, off-chain, and hands the
///  `(expiry, sig)` to the filler it vetted. There is no on-chain registry write:
///  issuance is a signature, revocation is a short `expiry` (the attester simply
///  stops re-issuing). This keeps credentials cheap, private, and instantly
///  revocable without any transaction.
///
///  On-chain verification
///  ─────────────────────
///  At fill time the filler submits `takerData = abi.encode(expiry, sig)`. This
///  validator rebuilds the digest from the ON-CHAIN `filler` argument (NOT any
///  address inside takerData), recovers the signer, and passes iff it equals the
///  maker-signed `attester` and the credential is unexpired.
///
///  Security properties (enforced below, do not weaken)
///  ───────────────────────────────────────────────────
///  • Filler-binding: the digest hashes the on-chain `filler` (the fill's
///    msg.sender / batch caller). A credential the attester issued to filler A
///    therefore produces a digest for A only — if filler B replays A's exact
///    `(expiry, sig)`, B's digest differs and recovery does NOT equal `attester`,
///    so it fails. A credential is non-transferable between fillers.
///  • Domain-binding: the EIP-712 domain includes `address(this)` and
///    `block.chainid`, so a signature minted for one validator instance (or chain)
///    cannot be replayed against another — even with the same attester/filler.
///  • takerData is adversarial: it is unsigned by the maker and fully
///    filler-controlled. The ONLY thing that makes it trustworthy is that we
///    recover a maker-chosen `attester` over a domain-bound, filler-bound digest.
///    Nothing is read from takerData and trusted without that recovery.
///  • Composes cleanly: a malformed / wrong-length / non-recovering signature
///    returns `false` (never reverts), so this gate AND-composes with other
///    validators the way the settlement expects.
///
///  Liveness fallback (Fusion-style open-up)
///  ────────────────────────────────────────
///  `openAfter == 0` — hard: an attestation is required forever.
///  `openAfter != 0` — once `block.timestamp >= openAfter` the order opens to
///  everyone with NO attestation needed (empty `takerData` is fine), so an
///  attester that stops issuing cannot strand the order past the window.
///
/// @dev  Maker-signed  `data      = abi.encode(address attester, uint256 listId, uint256 openAfter)`.
///       Filler-supplied `takerData = abi.encode(uint256 expiry, bytes sig)` — `sig` is
///       the attester's 65-byte EIP-712 signature over `FillerAttestation(filler, listId, expiry)`.
contract FillerAttestationValidator is IOrderValidator {
    // ──────────────────── EIP-712 (mirrors permit3/EIP712.sol) ────────────────────

    /// @dev Cached at deploy, recomputed if `block.chainid` changes (fork) so an
    ///      attestation can never be replayed against the wrong domain after a split.
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;

    bytes32 private constant _HASHED_NAME = keccak256("FillerAttestationValidator");
    bytes32 private constant _HASHED_VERSION = keccak256("1");
    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @notice The struct the attester signs. Binds the credential to a specific
    ///         `filler`, credential class `listId`, and `expiry`.
    bytes32 public constant ATTEST_TYPEHASH =
        keccak256("FillerAttestation(address filler,uint256 listId,uint256 expiry)");

    /// @dev Half the curve order — reject high-`s` (malleable) signatures.
    uint256 private constant _HALF_N = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    constructor() {
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator();
    }

    /// @notice EIP-712 domain separator for the current chain (fork-safe, cached).
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return block.chainid == _CACHED_CHAIN_ID ? _CACHED_DOMAIN_SEPARATOR : _buildDomainSeparator();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(_DOMAIN_TYPEHASH, _HASHED_NAME, _HASHED_VERSION, block.chainid, address(this)));
    }

    /// @notice Recompute the digest an attester must sign to vouch for `filler`
    ///         under `listId` until `expiry`. Exposed so an off-chain issuer (or a
    ///         test) can build the exact bytes to sign for THIS validator instance.
    function attestationDigest(address filler, uint256 listId, uint256 expiry) external view returns (bytes32) {
        return _digest(filler, listId, expiry);
    }

    function _digest(address filler, uint256 listId, uint256 expiry) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(ATTEST_TYPEHASH, filler, listId, expiry));
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    // ──────────────────── Validation ────────────────────

    /// @inheritdoc IOrderValidator
    function validate(Order calldata, address filler, bytes calldata data, bytes calldata takerData)
        external
        view
        override
        returns (bool)
    {
        (address attester, uint256 listId, uint256 openAfter) = abi.decode(data, (address, uint256, uint256));

        // 1) Open-up fallback: past the window, any filler passes with no credential.
        if (openAfter != 0 && block.timestamp >= openAfter) return true;

        // 2) Otherwise a fresh attester credential is required in takerData.
        if (takerData.length == 0) return false; // no credential presented
        (uint256 expiry, bytes memory sig) = abi.decode(takerData, (uint256, bytes));
        if (block.timestamp > expiry) return false; // credential expired

        // 3) Rebuild the digest from the ON-CHAIN filler (the binding that stops a
        //    credential issued to A from being replayed by B) and recover the signer.
        address signer = _recover(_digest(filler, listId, expiry), sig);

        // 4) Pass iff the recovered signer is the maker-signed attester. `signer`
        //    is never address(0) here (recovery failures return address(0)), so an
        //    attester of address(0) can never be "matched" by a bad signature.
        return signer != address(0) && signer == attester;
    }

    /// @dev ecrecover a 65-byte `(r,s,v)` signature, returning `address(0)` on any
    ///      malformation (wrong length, bad `v`, malleable high-`s`) instead of
    ///      reverting — so a garbage `takerData` fails the gate cleanly under
    ///      AND-composition rather than blowing up the whole fill differently.
    function _recover(bytes32 digest, bytes memory sig) private pure returns (address) {
        if (sig.length != 65) return address(0);
        bytes32 r;
        bytes32 s;
        uint8 v;
        /// @solidity memory-safe-assembly
        assembly {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
        if (uint256(s) > _HALF_N) return address(0); // reject malleable high-s
        if (v != 27 && v != 28) return address(0);
        return ecrecover(digest, v, r, s); // returns address(0) on failure
    }
}
