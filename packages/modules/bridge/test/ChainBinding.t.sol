// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order} from "@core/settlement/Settlement.sol";
import {SignatureVerification} from "@core/permit3/SignatureVerification.sol";

import {AcrossBridgeOutModule} from "../src/out/AcrossBridgeOutModule.sol";
import {LzOftBridgeOutModule} from "../src/out/LzOftBridgeOutModule.sol";
import {BridgeOutBase} from "../src/out/BridgeOutBase.sol";
import {BridgeTestBase} from "./shared/BridgeTestBase.t.sol";

/// @title ChainBindingTest
/// @notice Two things that matter more once every contract is deployed to the
///         SAME address on every chain: that a signature cannot cross chains, and
///         that a destination field which is wrong on every chain is refused
///         before any funds move.
///
///         With identical addresses, two orders for two chains are byte-identical
///         structs — the only difference is the `chainId` inside the domain
///         separator. These tests assert that difference is load-bearing rather
///         than decorative.
///
///         Note what is deliberately NOT guarded on-chain: whether `dstEid` and
///         `dstChainId` name the same chain, and whether the destination actually
///         has the funnel factory deployed. Neither is knowable from the source
///         chain, so both belong to the off-chain preflight. What stays here is
///         only the set of encodings that are wrong under every configuration.
contract ChainBindingTest is BridgeTestBase {
    uint256 constant PAY = 500e18;
    uint256 constant BRIDGE = 100e18;

    function _acrossSpec(address dstRecipient, uint256 dstChainId) internal view returns (bytes memory) {
        return abi.encode(
            AcrossBridgeOutModule.AcrossSpec({
                inputToken: address(tA),
                outputToken: address(tA),
                dstChainId: dstChainId,
                dstRecipient: dstRecipient,
                exclusiveRelayer: address(0),
                maxRelayFeeBps: 100,
                fillDeadlineOffset: 2 hours,
                exclusivityOffset: 0,
                dstOrderHash: bytes32(0),
                beneficiary: address(0),
                commitmentExpiry: 0
            })
        );
    }

    function _lzSpec(address dstRecipient, uint256 dstChainId, uint32 dstEid)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            LzOftBridgeOutModule.LzSpec({
                oft: address(oft),
                inputToken: address(tA),
                dstEid: dstEid,
                dstChainId: dstChainId,
                dstRecipient: dstRecipient,
                maxSlippageBps: 50,
                maxNativeFee: 0.05 ether,
                feePayer: maker,
                extraOptions: hex"0003",
                dstOrderHash: bytes32(0),
                beneficiary: address(0),
                commitmentExpiry: 0
            })
        );
    }

    function _expectBadDestination(address module, bytes memory spec) internal onSourceChain {
        Order memory src = _srcOrder(1, PAY, BRIDGE, module, spec);
        _wireSourceParties(module, PAY, BRIDGE);
        vm.deal(maker, 1 ether);
        vm.prank(maker);
        lzOut.topUpFor{value: 0.1 ether}(maker);

        bytes memory sig = _sign(src);
        vm.prank(solver);
        vm.expectRevert(BridgeOutBase.BadDestination.selector);
        settlement.fill(src, sig, PAY);
    }

    // ──────────────────── Destination-shape guards ────────────────────

    /// @dev The only guard here that prevents an outright loss rather than an
    ///      inconvenience: both bridges would deliver into the zero address.
    function test_across_zeroRecipient_reverts() public {
        _expectBadDestination(address(acrossOut), _acrossSpec(address(0), DST_CHAIN));
    }

    function test_lz_zeroRecipient_reverts() public {
        _expectBadDestination(address(lzOut), _lzSpec(address(0), DST_CHAIN, 30_101));
    }

    function test_across_zeroChainId_reverts() public {
        _expectBadDestination(address(acrossOut), _acrossSpec(address(inbox), 0));
    }

    /// @dev Bridging to the chain you are already on. Whatever was intended, it
    ///      was not this.
    function test_across_selfChain_reverts() public {
        _expectBadDestination(address(acrossOut), _acrossSpec(address(inbox), SRC_CHAIN));
    }

    function test_lz_selfChain_reverts() public {
        _expectBadDestination(address(lzOut), _lzSpec(address(inbox), SRC_CHAIN, 30_101));
    }

    function test_lz_zeroEid_reverts() public {
        _expectBadDestination(address(lzOut), _lzSpec(address(inbox), DST_CHAIN, 0));
    }

    // ──────────────────── Signatures do not cross chains ────────────────────

    /// @dev THE property that makes same-address deployment safe. The source order
    ///      here is byte-identical to one a user might sign for the destination
    ///      chain — same maker, same legs, same module addresses, since every
    ///      contract is at the same address. Only the domain separator's chain id
    ///      differs, and that is enough: the signature does not verify.
    function test_sourceSignature_doesNotVerifyOnTheDestinationChain() public {
        Order memory src = _srcOrder(1, PAY, BRIDGE, address(acrossOut), _acrossSpec(address(inbox), DST_CHAIN));
        _wireSourceParties(address(acrossOut), PAY, BRIDGE);
        bytes memory sig = _signSource(src); // signed under SRC_CHAIN

        // Ambient chain is the destination. Same order, same signature, refused.
        vm.prank(solver);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        settlement.fill(src, sig, PAY);

        // And it settles perfectly well on the chain it was actually signed for.
        _fillSourceAs(src, sig, PAY);
        assertEq(spokePool.depositCount(), 1, "valid on its own chain");
    }

    /// @dev The mirror: an order signed for the destination cannot be filled on the
    ///      source. Together these mean a user cannot be made to authorise a chain
    ///      they did not intend, no matter how identical the two orders look.
    function test_destinationSignature_doesNotVerifyOnTheSourceChain() public {
        Order memory dst = _dstOrder(1, BRIDGE, 300e18);
        dst.maker = maker; // an EOA maker, so this is purely about the domain
        bytes memory sig = _sign(dst); // signed under DST_CHAIN (ambient)

        vm.chainId(SRC_CHAIN);
        vm.prank(solver);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        settlement.fill(dst, sig, BRIDGE);
        vm.chainId(DST_CHAIN);
    }

    /// @dev The order STRUCT hash is chain-independent by design — it is the
    ///      digest that carries the chain. Worth pinning, because the inbox's
    ///      commitment relies on the hash being stable across chains while the
    ///      signature is not.
    function test_orderHashIsChainIndependent_butTheDigestIsNot() public {
        Order memory o = _dstOrder(1, BRIDGE, 300e18);
        bytes32 hashOnDst = _hashOrder(o);
        bytes32 domainOnDst = settlement.DOMAIN_SEPARATOR();

        vm.chainId(SRC_CHAIN);
        assertEq(_hashOrder(o), hashOnDst, "struct hash is the same everywhere");
        assertTrue(settlement.DOMAIN_SEPARATOR() != domainOnDst, "the domain is not");
        vm.chainId(DST_CHAIN);
    }
}
