// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Order, Item} from "@core/settlement/Settlement.sol";
import {SignatureVerification} from "@core/permit3/SignatureVerification.sol";
import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @dev {Core.fillCompact} — the EIP-2098 compact-signature entry. Covers that it
///      settles identically to {Core.fill}, that it rejects a wrong signer, and that
///      it is genuinely cheaper in calldata (the whole point of having it).
contract FillCompactTest is CoreSettlementBase {
    function _plainSwapOrder(uint256 nonce, uint256 usdcIn, uint256 wethOut) internal view returns (Order memory) {
        return _order(maker, nonce, USDC, WETH, usdcIn, wethOut, new Item[](0));
    }

    /// @dev Maker only needs to let Settlement pull tokenIn; the bare ERC20 approve to
    ///      Permit3 is already granted in `setUp`.
    function _approveMakerPlainSwap(uint256 usdcCap) internal {
        vm.prank(maker);
        permit3.approveToken(address(settlement), USDC, uint160(usdcCap), 0);
    }

    /// @dev Maker's order signature as an EIP-2098 compact `(r, vs)` pair.
    function _sign2098(Order memory o) internal view returns (bytes32 r, bytes32 vs) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(o)));
        uint8 v;
        bytes32 s;
        (v, r, s) = vm.sign(makerPk, digest);
        // vs = s with the top bit carrying (v - 27).
        vs = bytes32(uint256(s) | (uint256(v - 27) << 255));
    }

    function test_fillCompact_settlesLikeFill() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;

        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);
        _approveMakerPlainSwap(usdcIn);
        _approveSolverSide(wethOut, WETH);

        Order memory order = _plainSwapOrder(0, usdcIn, wethOut);
        (bytes32 r, bytes32 vs) = _sign2098(order);

        vm.prank(solver);
        uint256 paid = settlement.fillCompact(order, r, vs, usdcIn)[0];

        assertEq(paid, wethOut, "solver paid exactly wethOut");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "maker USDC spent");
        assertEq(IERC20(WETH).balanceOf(maker), wethOut, "maker received WETH");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver received USDC");
    }

    /// @dev A compact signature from the wrong key must not authorize the maker's order.
    function test_fillCompact_wrongSigner_reverts() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;

        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);
        _approveMakerPlainSwap(usdcIn);
        _approveSolverSide(wethOut, WETH);

        Order memory order = _plainSwapOrder(0, usdcIn, wethOut);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(order)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBADBEEF, digest);
        bytes32 vs = bytes32(uint256(s) | (uint256(v - 27) << 255));

        vm.prank(solver);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        settlement.fillCompact(order, r, vs, usdcIn);
    }

    /// @dev Both `v` parities must round-trip through the 2098 packing. Loops fresh
    ///      nonces until each parity has been exercised, so the test cannot silently
    ///      cover only one branch.
    function test_fillCompact_bothSignatureParities() public {
        bool sawZero;
        bool sawOne;
        for (uint256 nonce; nonce < 12 && !(sawZero && sawOne); nonce++) {
            uint256 usdcIn = 1_000e6;
            uint256 wethOut = 0.5 ether;

            deal(USDC, maker, usdcIn);
            deal(WETH, solver, wethOut);
            _approveMakerPlainSwap(usdcIn);
            _approveSolverSide(wethOut, WETH);

            Order memory order = _plainSwapOrder(nonce, usdcIn, wethOut);
            bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(order)));
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, digest);
            if (v == 27) sawZero = true;
            else sawOne = true;

            vm.prank(solver);
            settlement.fillCompact(order, r, bytes32(uint256(s) | (uint256(v - 27) << 255)), usdcIn);
        }
        assertTrue(sawZero && sawOne, "did not exercise both v parities");
    }

    /// @dev The reason this entry exists: the compact form is 96 bytes smaller on the
    ///      wire than the `bytes sig` form, which is the dominant cost on rollups.
    function test_fillCompact_calldataIsSmaller() public view {
        Order memory order = _plainSwapOrder(0, 2_000e6, 1 ether);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(order)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, digest);
        bytes32 vs = bytes32(uint256(s) | (uint256(v - 27) << 255));

        uint256 compactLen = abi.encodeCall(settlement.fillCompact, (order, r, vs, 2_000e6)).length;
        uint256 bytesLen =
            abi.encodeWithSignature(
            "fill((address,uint8,uint256,uint256,(address,uint256,uint256)[],(address,uint256,uint256,address)[],uint256,address,uint256,uint256,(uint32,uint32)[],uint256,uint256,(uint8,address,uint256,address,bytes)[],(address,bytes)[],(address,bytes)[],address,uint256),bytes,uint256)",
            order,
            abi.encodePacked(r, s, v),
            uint256(2_000e6)
        )
        .length;

        assertEq(bytesLen - compactLen, 96, "compact form should save exactly 96 calldata bytes");
    }
}
