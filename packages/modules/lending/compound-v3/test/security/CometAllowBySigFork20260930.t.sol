// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";

import {CompoundV3ModulesBase} from "../shared/CompoundV3ModulesBase.t.sol";

interface ICometSig {
    function name() external view returns (string memory);
    function version() external view returns (string memory);
    function userNonce(address) external view returns (uint256);
    function isAllowed(address owner, address manager) external view returns (bool);
    function allow(address manager, bool isAllowed) external;
    function allowBySig(
        address owner,
        address manager,
        bool isAllowed,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

/// @title Audit 2026-09-30 L-CMT-5 (2) — a REAL Comet `allowBySig` landed through
///        the module
/// @notice The Comet sig-auth tail was only exercised on mocks. On the mainnet fork
///         the maker has NO standing `allow`, signs Comet's own Authorization
///         digest, and an Exact withdraw fill lands it in-fill (consuming
///         `userNonce`). Then the durable revoke of L-CMT-3: a signed
///         `isAllowed = false` at the CURRENT nonce, relayed by anyone.
contract CometAllowBySigFork20260930Test is CompoundV3ModulesBase {
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant AUTHORIZATION_TYPEHASH =
        keccak256("Authorization(address owner,address manager,bool isAllowed,uint256 nonce,uint256 expiry)");

    function _signAllow(bool isAllowed, uint256 nonce, uint256 expiry) internal view returns (uint8, bytes32, bytes32) {
        ICometSig c = ICometSig(COMET);
        bytes32 domain = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256(bytes(c.name())), keccak256(bytes(c.version())), block.chainid, COMET
            )
        );
        bytes32 structHash =
            keccak256(abi.encode(AUTHORIZATION_TYPEHASH, maker, address(takerModule), isAllowed, nonce, expiry));
        return vm.sign(makerPk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
    }

    function test_audit_L_CMT_5_realCometAllowBySigLandedInFill() public {
        uint256 wethIn = 1 ether;
        uint256 usdcOut = 2_000e6;
        _seedWethCollateral(2 ether);
        vm.prank(maker);
        ICometSig(COMET).allow(address(takerModule), false); // undo the base's standing grant
        assertFalse(ICometSig(COMET).isAllowed(maker, address(takerModule)));

        uint256 n0 = ICometSig(COMET).userNonce(maker);
        uint256 expiry = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signAllow(true, n0, expiry);
        // Exact: op@0, comet@32, asset@64, mode word@96 (0), allow block@128.
        bytes memory data = abi.encodePacked(_withdrawData(COMET, WETH), abi.encode(uint256(0)), abi.encode(n0, expiry, v, r, s));

        _approveMakerWithdrawSide(wethIn, keccak256(data), data);
        deal(USDC, solver, usdcOut);
        _approveSolverSide(usdcOut, USDC);

        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.TAKE, module: address(takerModule), amount: wethIn, recipient: address(0), data: data});
        Order memory o = _order(maker, 1, WETH, USDC, wethIn, usdcOut, items);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        settlement.fill(o, sig, wethIn);

        assertTrue(ICometSig(COMET).isAllowed(maker, address(takerModule)), "allow landed in-fill");
        assertEq(ICometSig(COMET).userNonce(maker), n0 + 1, "the published signature is consumed");
        assertApproxEqAbs(_wethCollateral(maker), 1 ether, 1, "one WETH withdrawn");
        assertEq(IERC20(USDC).balanceOf(maker), usdcOut);

        // Durable revoke: `allowBySig(false)` at the CURRENT nonce, by anyone.
        (v, r, s) = _signAllow(false, n0 + 1, expiry);
        vm.prank(address(0xBEEF));
        ICometSig(COMET).allowBySig(maker, address(takerModule), false, n0 + 1, expiry, v, r, s);
        assertFalse(ICometSig(COMET).isAllowed(maker, address(takerModule)));
        assertEq(ICometSig(COMET).userNonce(maker), n0 + 2, "nonce burned");
    }
}
