// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {Order, Item, OrderSide} from "@core/settlement/UniversalSettlement.sol";
import {UniversalSettlement} from "@core/settlement/UniversalSettlement.sol";

import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

// ──────────────────── Canonical Gnosis Safe v1.3.0 (mainnet) ────────────────────
// Deterministic-deployment singletons, identical across chains and immutable.
interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

interface ISafe {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;
}

interface ISafeMessageHasher {
    /// @dev CompatibilityFallbackHandler helper: the EIP-712 `SafeMessage` hash the
    ///      owners must sign for `safe` to validate `message` via EIP-1271.
    function getMessageHashForSafe(address safe, bytes memory message) external view returns (bytes32);
}

/// @title SafeMakerForkTest
/// @notice Fork test proving a REAL Gnosis Safe works as a maker through the
///         EIP-1271 branch of {SignatureVerification} — the case a mock 1271 wallet
///         cannot fully exercise. Deploys a live 1-of-1 Safe (canonical v1.3.0
///         singleton + factory + CompatibilityFallbackHandler on mainnet), has its
///         owner sign the Safe-wrapped order digest, and settles a WETH→USDC order
///         where the Safe is the maker.
///
///         Exercises Safe specifics the mock can't: the fallback-handler routing of
///         `isValidSignature(bytes32,bytes)`, the `SafeMessage` re-wrapping of the
///         passed digest, `checkSignatures`, and the real `0x1626ba7e` magic value.
contract SafeMakerForkTest is CoreSettlementBase {
    address constant SAFE_FACTORY = 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2;
    address constant SAFE_SINGLETON = 0xd9Db270c1B5E3Bd161E8c8503c55cEABeE709552;
    address constant SAFE_FALLBACK_HANDLER = 0xf48f2B2d2a534e402487b3ee7C18c33Aec0Fe5e4;

    uint256 constant SELL_WETH = 1 ether;
    uint256 constant BUY_USDC = 2_000e6;

    uint256 safeOwnerPk = 0x5AFE0117;
    address safeOwner = vm.addr(safeOwnerPk);
    address safe;

    function setUp() public override {
        super.setUp();
        safe = _deploySafe(safeOwner);
        vm.label(safe, "gnosis-safe-maker");

        // Fund the Safe with WETH and wire its Permit3 allowance. Impersonated for
        // setup (this test is about the SIGNATURE path, not Safe's execTransaction);
        // the order authorization below uses the Safe's REAL EIP-1271 signature.
        deal(WETH, safe, 10 ether);
        vm.startPrank(safe);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), WETH, type(uint160).max, 0);
        vm.stopPrank();

        // Solver holds USDC to deliver (its Permit3 allowances are set in the base).
        deal(USDC, solver, 1_000_000e6);
    }

    function test_fork_gnosisSafe_maker_eip1271() public {
        Order memory order = _order(address(safe), 1, WETH, USDC, SELL_WETH, BUY_USDC, new Item[](0));

        bytes memory sig = _safeSign(order, safeOwnerPk);

        uint256 safeUsdcBefore = IERC20(USDC).balanceOf(safe);
        uint256 solverWethBefore = IERC20(WETH).balanceOf(solver);

        vm.prank(solver);
        settlement.fill(order, sig, SELL_WETH);

        assertEq(IERC20(USDC).balanceOf(safe) - safeUsdcBefore, BUY_USDC, "Safe maker received USDC");
        assertEq(IERC20(WETH).balanceOf(solver) - solverWethBefore, SELL_WETH, "solver received the Safe's WETH");
    }

    /// @dev A signature from a NON-owner key is rejected: `checkSignatures` fails
    ///      inside the Safe, `isValidSignature` reverts, and the fill unwinds.
    function test_fork_gnosisSafe_wrongOwnerRejected() public {
        Order memory order = _order(address(safe), 1, WETH, USDC, SELL_WETH, BUY_USDC, new Item[](0));
        bytes memory badSig = _safeSign(order, 0xB4D); // not the Safe owner

        vm.prank(solver);
        vm.expectRevert(); // Safe's checkSignatures reverts → verify() bubbles it up
        settlement.fill(order, badSig, SELL_WETH);
    }

    // ──────────────────── Helpers ────────────────────

    function _deploySafe(address owner) internal returns (address proxy) {
        address[] memory owners = new address[](1);
        owners[0] = owner;
        bytes memory initializer = abi.encodeCall(
            ISafe.setup,
            (owners, 1, address(0), "", SAFE_FALLBACK_HANDLER, address(0), 0, payable(address(0)))
        );
        proxy = ISafeProxyFactory(SAFE_FACTORY).createProxyWithNonce(SAFE_SINGLETON, initializer, 0);
    }

    /// @dev Produce the Safe's EIP-1271 signature over `order`. The owner signs the
    ///      Safe-wrapped hash of the settlement order digest — exactly what the
    ///      CompatibilityFallbackHandler recomputes inside `isValidSignature`.
    function _safeSign(Order memory order, uint256 ownerPk) internal view returns (bytes memory) {
        bytes32 orderDigest =
            keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(order)));
        bytes32 safeMsgHash =
            ISafeMessageHasher(SAFE_FALLBACK_HANDLER).getMessageHashForSafe(safe, abi.encode(orderDigest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, safeMsgHash);
        return abi.encodePacked(r, s, v);
    }
}
