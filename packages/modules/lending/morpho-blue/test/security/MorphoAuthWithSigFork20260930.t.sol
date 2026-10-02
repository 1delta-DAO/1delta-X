// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {DustHandler} from "@lib/DustHandler.sol";

import {MorphoModulesBase} from "../shared/MorphoModulesBase.t.sol";

interface IMorphoSigViews {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function nonce(address authorizer) external view returns (uint256);
    function isAuthorized(address authorizer, address authorized) external view returns (bool);
}

/// @title Audit 2026-09-30 L-CMT-5 (2) — a REAL Morpho Blue `setAuthorizationWithSig`
///        landed through the module
/// @notice The sig-auth tail was only exercised against mocks. Here the maker signs
///         Morpho Blue's own Authorization digest on the mainnet fork, makes NO
///         on-chain authorization, and a full withdraw-collateral fill lands the
///         signature in-fill (consuming the nonce). Also pins the durable revoke:
///         a signed `isAuthorized = false` at the CURRENT nonce burns the published
///         grant (L-CMT-3).
contract MorphoAuthWithSigFork20260930Test is MorphoModulesBase {
    bytes32 constant AUTH_TYPEHASH =
        keccak256("Authorization(address authorizer,address authorized,bool isAuthorized,uint256 nonce,uint256 deadline)");

    function _signAuth(address authorized, bool isAuthorized, uint256 nonce, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(abi.encode(AUTH_TYPEHASH, maker, authorized, isAuthorized, nonce, deadline));
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", IMorphoSigViews(address(MORPHO)).DOMAIN_SEPARATOR(), structHash));
        return vm.sign(makerPk, digest);
    }

    function test_audit_L_CMT_5_realMorphoSigAuthLandedInFill() public {
        uint256 wstethIn = 1 ether;
        uint256 usdcOut = 3_000e6;
        _seedCollateral(2 ether);
        assertFalse(IMorphoSigViews(address(MORPHO)).isAuthorized(maker, address(takerModule)), "no on-chain grant");

        uint256 n0 = IMorphoSigViews(address(MORPHO)).nonce(maker);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signAuth(address(takerModule), true, n0, deadline);
        // Exact mode: BalanceMode word explicit (0) so the auth block sits at 224.
        bytes memory data = abi.encodePacked(_withdrawData(), abi.encode(uint256(0)), abi.encode(n0, deadline, v, r, s));

        vm.startPrank(maker);
        IERC20(WSTETH).approve(address(permit3), type(uint256).max);
        permit3.approveTaker(address(settlement), address(takerModule), keccak256(data), uint160(wstethIn), 0);
        vm.stopPrank();
        deal(USDC, solver, usdcOut);
        _approveSolverSide(usdcOut, USDC);

        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.TAKE, module: address(takerModule), amount: wstethIn, recipient: address(0), data: data});
        Order memory o = _order(maker, 1, WSTETH, USDC, wstethIn, usdcOut, items);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        settlement.fill(o, sig, wstethIn);

        assertTrue(IMorphoSigViews(address(MORPHO)).isAuthorized(maker, address(takerModule)), "grant landed in-fill");
        assertEq(IMorphoSigViews(address(MORPHO)).nonce(maker), n0 + 1, "the published signature is consumed");
        assertEq(_collateral(maker), 1 ether, "one wstETH withdrawn");
        assertEq(IERC20(USDC).balanceOf(maker), usdcOut, "maker paid");

        // Durable revoke: a signed `false` at the CURRENT nonce — relayed by anyone.
        (v, r, s) = _signAuth(address(takerModule), false, n0 + 1, deadline);
        vm.prank(address(0xBEEF));
        (bool ok,) = address(MORPHO).call(
            abi.encodeWithSignature(
                "setAuthorizationWithSig((address,address,bool,uint256,uint256),(uint8,bytes32,bytes32))",
                maker,
                address(takerModule),
                false,
                n0 + 1,
                deadline,
                v,
                r,
                s
            )
        );
        assertTrue(ok, "nonce-consuming revoke landed");
        assertFalse(IMorphoSigViews(address(MORPHO)).isAuthorized(maker, address(takerModule)));
        assertEq(IMorphoSigViews(address(MORPHO)).nonce(maker), n0 + 2);
    }
}
