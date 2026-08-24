// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOrderValidator} from "@core/interfaces/IOrderValidator.sol";
import {IERC1271} from "@core/interfaces/IERC1271.sol";
import {Order} from "@core/settlement/Settlement.sol";

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
///  address inside takerData), validates `sig` against the maker-signed
///  `attester`, and passes iff it is valid and the credential is unexpired.
///
///  Attester signer breadth
///  ───────────────────────
///  The `attester` may be ANY kind of signer — the maker is free to trust a
///  contract. Validation mirrors the core `SignatureVerification` used for orders
///  and permits: ECDSA is tried FIRST (a positive match short-circuits), then
///  EIP-1271 as a fallback. So all of these work as attesters:
///    • plain EOA                              → ecrecover
///    • EIP-7702 account signing with its key  → ecrecover (account address ==
///                                               the key's address, even though it
///                                               now carries bytecode — this is the
///                                               Permit2 7702 failure mode, avoided)
///    • standard multisig / Gnosis Safe        → EIP-1271 isValidSignature
///    • EIP-7702 account delegated to a wallet → EIP-1271 isValidSignature
///      implementing isValidSignature
///
///  Security properties (enforced below, do not weaken)
///  ───────────────────────────────────────────────────
///  • Filler-binding: the digest hashes the on-chain `filler` (the fill's
///    msg.sender / batch caller). A credential the attester issued to filler A
///    therefore produces a digest for A only — if filler B replays A's exact
///    `(expiry, sig)`, B's digest differs so the signature no longer validates as
///    `attester`, and it fails. A credential is non-transferable between fillers.
///  • Domain-binding: the EIP-712 domain includes `address(this)` and
///    `block.chainid`, so a signature minted for one validator instance (or chain)
///    cannot be replayed against another — even with the same attester/filler.
///  • takerData is adversarial: it is unsigned by the maker and fully
///    filler-controlled. The ONLY thing that makes it trustworthy is that we
///    recover a maker-chosen `attester` over a domain-bound, filler-bound digest.
///    Nothing is read from takerData and trusted without that recovery.
///  • Composes cleanly: a malformed / non-validating signature — including a
///    contract attester whose `isValidSignature` reverts — returns `false` (never
///    reverts), so this gate AND-composes with other validators the way the
///    settlement expects.
///  • Signature malleability is intentionally NOT rejected here (unlike a
///    nonce-consuming permit): the credential is a stateless yes/no check, never
///    stored or consumed, so a second (malleated) signature over the same digest
///    grants nothing the holder of the original didn't already have.
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
///       the attester's EIP-712 signature over `FillerAttestation(filler, listId, expiry)`:
///       a 64/65-byte ECDSA signature, or an EIP-1271 signature of any length.
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

    /// @dev EIP-2098 mask: `0x7f` followed by 31 bytes of `0xff`. Clears the top
    ///      bit of `s` (the packed `yParity`) when decoding a 64-byte compact sig.
    bytes32 private constant _UPPER_BIT_MASK = 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

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
        //    credential issued to A from being replayed by B) and validate `sig`
        //    against the maker-signed attester. `_isValidAttestation` accepts EOA,
        //    EIP-1271 contract-wallet, and EIP-7702 attesters and never reverts.
        return _isValidAttestation(_digest(filler, listId, expiry), sig, attester);
    }

    /// @dev Validate `sig` over `digest` as coming from `attester`, across the full
    ///      breadth of signer types and WITHOUT ever reverting — a malformed, wrong-
    ///      length, or non-matching signature (or a contract wallet whose
    ///      `isValidSignature` reverts) simply returns false, so the gate fails
    ///      cleanly under AND-composition rather than blowing up the fill:
    ///
    ///        • plain EOA attester                     → ecrecover
    ///        • EIP-7702 attester signing w/ own key   → ecrecover (account address
    ///                                                    == its key's address)
    ///        • multisig / Safe / smart account        → EIP-1271 isValidSignature
    ///        • EIP-7702 attester delegated to a 1271  → EIP-1271 isValidSignature
    ///          wallet
    ///
    ///      ECDSA is tried FIRST and only short-circuits on a positive match, so a
    ///      7702 attester's regular signature is honoured even though the account
    ///      now carries bytecode — avoiding the Permit2 failure mode where a code-
    ///      length-first branch misroutes it into the 1271 path. Accepts 65-byte and
    ///      64-byte (EIP-2098 compact) ECDSA signatures; 1271 sigs may be any length.
    function _isValidAttestation(bytes32 digest, bytes memory sig, address attester) private view returns (bool) {
        // An attester of address(0) can never be matched — a failed ecrecover also
        // yields address(0), so it must be rejected explicitly.
        if (attester == address(0)) return false;

        // 1) ECDSA first — plain EOA and EIP-7702 raw-key attesters.
        uint256 len = sig.length;
        if (len == 65 || len == 64) {
            bytes32 r;
            bytes32 s;
            uint8 v;
            if (len == 65) {
                /// @solidity memory-safe-assembly
                assembly {
                    r := mload(add(sig, 0x20))
                    s := mload(add(sig, 0x40))
                    v := byte(0, mload(add(sig, 0x60)))
                }
            } else {
                // EIP-2098 compact: (r, vs) where vs packs s and yParity.
                bytes32 vs;
                /// @solidity memory-safe-assembly
                assembly {
                    r := mload(add(sig, 0x20))
                    vs := mload(add(sig, 0x40))
                }
                s = vs & _UPPER_BIT_MASK;
                v = uint8(uint256(vs >> 255)) + 27;
            }
            address signer = ecrecover(digest, v, r, s);
            if (signer != address(0) && signer == attester) return true;
        }

        // 2) EIP-1271 fallback — contract-wallet and 7702-delegated attesters. A
        //    plain EOA has no code and nothing to fall back to. Done as a low-level
        //    staticcall so a reverting / missing implementation returns false rather
        //    than bubbling up and breaking AND-composition.
        if (attester.code.length == 0) return false;
        (bool ok, bytes memory ret) = attester.staticcall(abi.encodeCall(IERC1271.isValidSignature, (digest, sig)));
        return ok && ret.length >= 32 && abi.decode(ret, (bytes4)) == IERC1271.isValidSignature.selector;
    }
}
