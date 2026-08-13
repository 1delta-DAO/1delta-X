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
}
