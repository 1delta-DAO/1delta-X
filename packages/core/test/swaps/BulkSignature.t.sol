// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order} from "@core/settlement/Settlement.sol";
import {SignatureVerification} from "@core/permit3/SignatureVerification.sol";

import {MockSettlementBase} from "../shared/MockSettlementBase.t.sol";

/// @title BulkSignature
/// @notice ONE signature authorizing N orders through a Merkle root — the ladder /
///         bracket / quote-refresh primitive. Covers the envelope shape, the proof,
///         what a wrong proof does, and that a bulk signature grants no authority a
///         single signature would not.
contract BulkSignatureTest is MockSettlementBase {
    uint256 constant IN_AMT = 100e18;
    uint256 constant OUT_AMT = 200e18;

    function _fund(uint256 n) internal {
        tA.mint(maker, IN_AMT * n);
        _makerApprove(address(settlement), address(tA), IN_AMT * n);
        tB.mint(solver, OUT_AMT * n);
        _solverApprove(address(settlement), address(tB), OUT_AMT * n);
    }

    /// @dev Sorted-pair hash — the OpenZeppelin convention the settler folds with.
    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// @dev A 4-leaf tree, and the proof for leaf `i`.
    function _tree(bytes32[4] memory leaves, uint256 i)
        internal
        pure
        returns (bytes32 root, bytes32[] memory proof)
    {
        bytes32 l01 = _pair(leaves[0], leaves[1]);
        bytes32 l23 = _pair(leaves[2], leaves[3]);
        root = _pair(l01, l23);
        proof = new bytes32[](2);
        if (i == 0) (proof[0], proof[1]) = (leaves[1], l23);
        else if (i == 1) (proof[0], proof[1]) = (leaves[0], l23);
        else if (i == 2) (proof[0], proof[1]) = (leaves[3], l01);
        else (proof[0], proof[1]) = (leaves[2], l01);
    }

    /// @dev The bulk envelope: `innerSig(65) ‖ proof ‖ 0xB0`.
    function _bulkSig(uint256 pk, bytes32 root, bytes32[] memory proof) internal view returns (bytes memory sig) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _rootDigest(root));
        sig = abi.encodePacked(r, s, v);
        for (uint256 k; k < proof.length; k++) {
            sig = abi.encodePacked(sig, proof[k]);
        }
        sig = abi.encodePacked(sig, bytes1(0xB0));
    }

    function _rootDigest(bytes32 root) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(keccak256("OrderRoot(bytes32 root)"), root));
        return keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), structHash));
    }

    function _ladder() internal view returns (Order[4] memory os, bytes32[4] memory leaves) {
        for (uint256 i; i < 4; i++) {
            os[i] = _plainOrder(i + 1, address(tA), address(tB), IN_AMT, OUT_AMT);
            leaves[i] = lens.hashOrder(os[i]);
        }
    }

    // ════════════════════ the happy path ════════════════════

    function test_bulkSignature_fillsEveryLeaf() public {
        _fund(4);
        (Order[4] memory os, bytes32[4] memory leaves) = _ladder();

        for (uint256 i; i < 4; i++) {
            (bytes32 root, bytes32[] memory proof) = _tree(leaves, i);
            bytes memory sig = _bulkSig(makerPk, root, proof);
            vm.prank(solver);
            settlement.fill(os[i], sig, IN_AMT);
            assertEq(settlement.filled(leaves[i]), IN_AMT, "leaf filled under one signature");
        }
        assertEq(tB.balanceOf(maker), OUT_AMT * 4, "every slice of the ladder delivered");
    }

    // ════════════════════ what must NOT work ════════════════════

    /// @dev An order that is not in the tree cannot borrow the root's authority: the
    ///      fold produces a root the maker never signed.
    function test_bulkSignature_orderOutsideTree_reverts() public {
        _fund(5);
        (, bytes32[4] memory leaves) = _ladder();
        (bytes32 root, bytes32[] memory proof) = _tree(leaves, 0);
        bytes memory sig = _bulkSig(makerPk, root, proof);

        Order memory outsider = _plainOrder(99, address(tA), address(tB), IN_AMT, OUT_AMT);
        vm.prank(solver);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        settlement.fill(outsider, sig, IN_AMT);
    }

    /// @dev A root signed by anyone other than the maker (or one of its delegates) is
    ///      worth nothing — the same rule a single signature lives under.
    function test_bulkSignature_foreignSigner_reverts() public {
        _fund(4);
        (Order[4] memory os, bytes32[4] memory leaves) = _ladder();
        (bytes32 root, bytes32[] memory proof) = _tree(leaves, 1);
        bytes memory sig = _bulkSig(0xBADBAD, root, proof); // not the maker

        vm.prank(solver);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        settlement.fill(os[1], sig, IN_AMT);
    }

    /// @dev Drop the marker byte and the payload is just an unrecognised signature —
    ///      the branch is opt-in, so nothing silently reinterprets an ordinary one.
    function test_bulkSignature_withoutMarker_reverts() public {
        _fund(4);
        (Order[4] memory os, bytes32[4] memory leaves) = _ladder();
        (bytes32 root, bytes32[] memory proof) = _tree(leaves, 2);
        bytes memory sig = _bulkSig(makerPk, root, proof);
        bytes memory noMarker = new bytes(sig.length - 1);
        for (uint256 k; k < noMarker.length; k++) {
            noMarker[k] = sig[k];
        }
        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(os[2], noMarker, IN_AMT);
    }

    /// @dev A DELEGATE the maker nominated may sign the root, exactly as it may sign
    ///      one order — the bulk path reuses the ordinary signer set.
    function test_bulkSignature_delegateMaySignRoot() public {
        _fund(4);
        uint256 delegatePk = 0xDE1E6A7E;
        vm.prank(maker);
        settlement.setOrderSigner(vm.addr(delegatePk), block.timestamp + 1 days);

        (Order[4] memory os, bytes32[4] memory leaves) = _ladder();
        (bytes32 root, bytes32[] memory proof) = _tree(leaves, 3);
        bytes memory sig = _bulkSig(delegatePk, root, proof);

        vm.prank(solver);
        settlement.fill(os[3], sig, IN_AMT);
        assertEq(settlement.filled(leaves[3]), IN_AMT, "delegate-signed root authorizes the leaf");
    }

    /// @dev Cancellation is unaffected: a root does not outrank `cancelOrder`.
    function test_bulkSignature_cancelledLeafStillCancelled() public {
        _fund(4);
        (Order[4] memory os, bytes32[4] memory leaves) = _ladder();
        vm.prank(maker);
        settlement.cancelOrder(os[0]);

        (bytes32 root, bytes32[] memory proof) = _tree(leaves, 0);
        bytes memory sig = _bulkSig(makerPk, root, proof);
        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(os[0], sig, IN_AMT);
    }

    // ════════ Seaport C4 #168: an internal node passed off as a leaf ════════

    /// @dev PROVENANCE — Code4rena, OpenSea Seaport (#168): "Merkle tree criteria can
    ///      be resolved by wrong tokenIDs". Seaport's criteria trees took the LEAF as
    ///      a caller-supplied `tokenId`, with no check that the supplied value was a
    ///      leaf rather than an internal node — so a fulfiller could hand in an
    ///      INTERMEDIATE HASH, prove it with the remaining (shorter) path, and trade
    ///      an NFT the maker never listed.
    ///
    ///      We are structurally immune, and this pins why: our leaf is not supplied
    ///      at all. {Signatures._verifySignature} folds `_foldProof(orderHash, …)`,
    ///      where `orderHash` is the EIP-712 hash of the ORDER BEING FILLED. A filler
    ///      controls only the proof, never the leaf, so there is no field in which to
    ///      submit an internal node. To exploit it one would have to author an order
    ///      whose struct hash EQUALS a chosen 256-bit node — a second-preimage search.
    ///
    ///      The practical form of the attack is the shortened proof: treat the
    ///      sub-root `l01` as if it were a leaf and prove it with the one remaining
    ///      sibling. Rejected, because the fold starts from the order's own hash and
    ///      a 1-level fold from a real leaf cannot reach the 2-level root.
    function test_bulkSignature_internalNodeCannotBeUsedAsALeaf() public {
        _fund(4);
        (Order[4] memory os, bytes32[4] memory leaves) = _ladder();
        (bytes32 root,) = _tree(leaves, 0);

        // The internal node an attacker would want to pass off as a leaf.
        bytes32 l01 = _pair(leaves[0], leaves[1]);
        bytes32 l23 = _pair(leaves[2], leaves[3]);
        assertEq(_pair(l01, l23), root, "precondition: l01 really is an internal node");

        // No order in the ladder hashes to it — the value is unreachable as a leaf.
        for (uint256 i; i < 4; i++) {
            assertTrue(leaves[i] != l01, "an internal node must not collide with a leaf");
        }

        // The shortened proof: one sibling (`l23`), as if `l01` were the leaf. The
        // settler folds from order 0's OWN hash instead, lands somewhere else, and
        // the recovered root is one the maker never signed.
        bytes32[] memory shortProof = new bytes32[](1);
        shortProof[0] = l23;
        bytes memory sig = _bulkSig(makerPk, root, shortProof);

        vm.prank(solver);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        settlement.fill(os[0], sig, IN_AMT);
    }

    /// @dev The same property from the other side: the leaf is DERIVED, so tampering
    ///      with the order after the fact moves the leaf and breaks the fold, even
    ///      though the proof and the signature are untouched and genuinely the
    ///      maker's.
    function test_bulkSignature_leafFollowsTheOrder_notTheProof() public {
        _fund(4);
        (Order[4] memory os, bytes32[4] memory leaves) = _ladder();
        (bytes32 root, bytes32[] memory proof) = _tree(leaves, 0);
        bytes memory sig = _bulkSig(makerPk, root, proof);

        // Sanity: unmodified, this fills.
        vm.prank(solver);
        settlement.fill(os[0], sig, IN_AMT);

        // Now re-point the SAME proof at a materially different order.
        Order memory tampered = _plainOrder(1, address(tA), address(tB), IN_AMT, OUT_AMT / 2);
        vm.prank(solver);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        settlement.fill(tampered, sig, IN_AMT);
    }

    // ════════ The first-fill skip, applied to the bulk envelope ════════

    /// @dev THE A4 CELL of `docs/edge-case-matrix.md` M1, and the closest living
    ///      relative of F13.
    ///
    ///      {Signatures._verifySignature} returns early once `filled[orderHash] != 0`
    ///      — some earlier fill already presented valid authorisation for a hash that
    ///      commits to `maker`, so re-deriving the digest proves nothing new and costs
    ///      ~2,860 gas per later fill. The skip is reached by ANY non-empty `sig`,
    ///      which means the proof is folded EXACTLY ONCE, on the first fill, and every
    ///      subsequent fill of that leaf accepts arbitrary bytes.
    ///
    ///      That is not a bypass today, and the reason is narrow enough to be worth
    ///      writing down: a signed Merkle ROOT, like a signed order hash, cannot be
    ///      withdrawn. The maker's kill switches are elsewhere entirely
    ///      ({cancelOrder}, nonce cancellation, the expiry, Permit3), and all of them
    ///      still run on every fill — see `test_bulkSignature_cancelledLeafStillCancelled`.
    ///
    ///  ⚠ WHAT WOULD MAKE IT A BYPASS. Any future ROOT-LEVEL revocation — a
    ///      root-invalidation registry for quote refresh has been discussed — turns the
    ///      root into a WITHDRAWABLE credential, and a withdrawable credential behind
    ///      this skip is precisely F13. Should that land, this test must be inverted
    ///      rather than deleted: it is the tripwire, and it is meant to fail loudly.
    function test_bulkSignature_afterFirstFill_anyBytesAreAccepted() public {
        _fund(4);
        (Order[4] memory os, bytes32[4] memory leaves) = _ladder();
        (bytes32 root, bytes32[] memory proof) = _tree(leaves, 0);
        bytes memory sig = _bulkSig(makerPk, root, proof);

        // First fill: the real envelope, the proof genuinely folded to the root.
        vm.prank(solver);
        settlement.fill(os[0], sig, IN_AMT / 2);
        assertEq(settlement.filled(lens.hashOrder(os[0])), IN_AMT / 2, "leaf 0 is now touched");

        // Second fill: 65 bytes that authorise nothing. Accepted, because the
        // counter is the proof.
        bytes memory garbage = new bytes(65);
        garbage[64] = bytes1(uint8(27));
        vm.prank(solver);
        settlement.fill(os[0], garbage, IN_AMT / 2);
        assertEq(settlement.filled(lens.hashOrder(os[0])), IN_AMT, "the remainder settled on no authorisation");
        assertEq(tB.balanceOf(maker), OUT_AMT, "and the maker was paid in full for both halves");
    }

    /// @dev The contrast that makes the property above precise rather than alarming:
    ///      an UNTOUCHED sibling leaf of the very same tree refuses the same bytes.
    ///      The skip is bounded by `filled != 0` and by nothing else — it is not a
    ///      per-tree or per-maker relaxation.
    function test_bulkSignature_untouchedSibling_stillRefusesGarbage() public {
        _fund(4);
        (Order[4] memory os, bytes32[4] memory leaves) = _ladder();
        (bytes32 root, bytes32[] memory proof) = _tree(leaves, 0);
        // Hoisted: `_bulkSig` makes an external call (`DOMAIN_SEPARATOR`), and that
        // would eat the `vm.prank` below.
        bytes memory sig = _bulkSig(makerPk, root, proof);

        vm.prank(solver);
        settlement.fill(os[0], sig, IN_AMT / 2);

        bytes memory garbage = new bytes(65);
        garbage[64] = bytes1(uint8(27));
        vm.prank(solver);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        settlement.fill(os[1], garbage, IN_AMT); // leaf 1 — same tree, never filled
    }
}
