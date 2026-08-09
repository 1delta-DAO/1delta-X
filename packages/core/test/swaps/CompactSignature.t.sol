// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Order, Item} from "@core/settlement/Settlement.sol";
import {SignatureVerification} from "@core/permit3/SignatureVerification.sol";
import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @dev {Core.fill} accepts an EIP-2098 COMPACT (64-byte) signature, not just the
///      classic 65-byte form — so a caller gets the calldata saving without needing a
///      separate entrypoint.
///
///      A dedicated `fillCompact(order, r, vs, amount)` was written and then removed:
///      it bought only the ABI offset + length words over what these tests prove
///      (~64 bytes, ~280 gas on mainnet) and cost a SECOND authorization path that had
///      to stay in sync with {Signatures._verifySignature} forever. On the code that
///      decides whether a maker's signature authorizes a fill, that duplication is
///      worth more than the gas. Compact support lives where it belongs, inside the
///      one shared verifier.
///
///      These tests exist to keep that decision safe: if the 64-byte branch of
///      {SignatureVerification.verify} ever regresses, the saving silently disappears
///      and nothing else would notice.
contract CompactSignatureTest is CoreSettlementBase {
    function _plainSwapOrder(uint256 nonce, uint256 usdcIn, uint256 wethOut) internal view returns (Order memory) {
        return _order(maker, nonce, USDC, WETH, usdcIn, wethOut, new Item[](0));
    }

    function _approveMakerPlainSwap(uint256 usdcCap) internal {
        vm.prank(maker);
        permit3.approveToken(address(settlement), USDC, uint160(usdcCap), 0);
    }

    /// @dev EIP-2098: `vs` is `s` with the top bit carrying `v - 27`, so the 65-byte
    ///      (r, s, v) triple packs into two words.
    function _sign2098(Order memory o) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(o)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, digest);
        return abi.encodePacked(r, bytes32(uint256(s) | (uint256(v - 27) << 255)));
    }

    function _fund(uint256 usdcIn, uint256 wethOut) internal {
        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);
        _approveMakerPlainSwap(usdcIn);
        _approveSolverSide(wethOut, WETH);
    }

    function test_fill_acceptsCompact64ByteSignature() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        _fund(usdcIn, wethOut);

        Order memory order = _plainSwapOrder(0, usdcIn, wethOut);
        bytes memory sig = _sign2098(order);
        assertEq(sig.length, 64, "compact signature is 64 bytes");

        vm.prank(solver);
        assertEq(settlement.fill(order, sig, usdcIn)[0], wethOut, "solver paid wethOut");

        assertEq(IERC20(WETH).balanceOf(maker), wethOut, "maker received WETH");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver received USDC");
    }

    // Both `v` parities through the 2098 packing are covered by
    // {Permit3Test.test_permitBatch_compactSig_2098}, which exercises the same
    // 64-byte branch of the same {SignatureVerification.verify}. Not duplicated here.

    /// @dev A compact signature from the wrong key must not authorize the maker.
    function test_fill_compact_wrongSigner_reverts() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        _fund(usdcIn, wethOut);

        Order memory order = _plainSwapOrder(0, usdcIn, wethOut);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(order)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBADBEEF, digest);
        bytes memory sig = abi.encodePacked(r, bytes32(uint256(s) | (uint256(v - 27) << 255)));

        vm.prank(solver);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        settlement.fill(order, sig, usdcIn);
    }

    /// @dev The reason to prefer compact off-chain: 32 fewer calldata bytes than the
    ///      65-byte form, through the SAME entrypoint.
    function test_compact_isSmallerOnTheWire() public view {
        Order memory order = _plainSwapOrder(0, 2_000e6, 1 ether);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(order)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, digest);

        // Only the `bytes sig` tail differs between the two calls — the order and the
        // amount encode identically — so comparing the encoded blobs isolates the
        // saving without having to name the overloaded `fill` selector.
        uint256 classicLen = abi.encode(abi.encodePacked(r, s, v)).length; // 65B → len + 3 words
        uint256 compactLen = abi.encode(abi.encodePacked(r, bytes32(uint256(s) | (uint256(v - 27) << 255)))).length;

        assertEq(classicLen - compactLen, 32, "compact saves exactly one word on the wire");
    }
}
