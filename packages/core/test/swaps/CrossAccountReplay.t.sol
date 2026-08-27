// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC1271} from "@core/interfaces/IERC1271.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {Order} from "@core/settlement/Settlement.sol";

import {MockSettlementBase} from "../shared/MockSettlementBase.t.sol";

/// @dev The NAIVE EIP-1271 wallet ERC-7739 warns about: it validates by recovering
///      to a fixed owner EOA and does NOT mix its own address into the check, so two
///      instances sharing an owner accept the identical signature over the identical
///      digest. A Safe rehashes with its own domain and is immune; testing only the
///      immune shape would prove nothing.
contract NaiveWallet is IERC1271 {
    address public immutable owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function isValidSignature(bytes32 hash, bytes memory sig) external view override returns (bytes4) {
        if (sig.length != 65) return 0xffffffff;
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
        return ecrecover(hash, v, r, s) == owner ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }
}

/// @title CrossAccountReplay
/// @notice S2 (ERC-7739): a signed permit whose digest does not commit to the
///         ACCOUNT is replayable across accounts that share a validation rule —
///         the shape ERC-7739 names Permit2 for. Permit3 inherits Permit2's
///         type strings verbatim: `PermitBatchWitness(...)` carries NO owner field
///         and the owner is a verified argument, so at the RAW permit layer the
///         exposure is real for naive 1271 wallets.
///
///  THE POINT OF THIS FILE: the settlement path closes that gap the exact way
///  Permit2 tells apps to — by putting the account into the WITNESS. Our witness is
///  the order hash, and the {Order} typehash binds `address maker`, so the digest a
///  maker signs is account-specific. A permit signed for wallet A cannot be replayed
///  against a sibling wallet B, even when both are naive wallets with the same owner
///  key. This pins that binding so a refactor cannot silently drop it — dropping
///  `maker` from the witnessed digest would revive the cross-account drain.
contract CrossAccountReplayTest is MockSettlementBase {
    uint256 constant OWNER_PK = 0xA11CE;
    uint256 constant IN_AMT = 100e18;
    uint256 constant OUT_AMT = 300e18;

    address ownerEOA;
    NaiveWallet walletA;
    NaiveWallet walletB;

    function setUp() public override {
        super.setUp();
        ownerEOA = vm.addr(OWNER_PK);
        walletA = new NaiveWallet(ownerEOA);
        walletB = new NaiveWallet(ownerEOA);

        // Both wallets hold input and let Permit3 pull it. The signed permit grants
        // Settlement its Permit3-level allowance; this is just the outer ERC-20 leg.
        for (uint256 i; i < 2; i++) {
            address w = i == 0 ? address(walletA) : address(walletB);
            tA.mint(w, IN_AMT);
            vm.prank(w);
            tA.approve(address(permit3), type(uint256).max);
        }
        tB.mint(solver, OUT_AMT * 2);
        _solverApprove(address(settlement), address(tB), OUT_AMT * 2);
    }

    function _order(address makerWallet) internal view returns (Order memory o) {
        o = _plainOrder(1, address(tA), address(tB), IN_AMT, OUT_AMT);
        o.maker = makerWallet;
    }

    /// @dev ONE permit batch, reused for both wallets: spender = Settlement, pull tA.
    ///      It names no owner (that is the Permit2 shape), so it is byte-identical
    ///      whichever wallet it is meant for — the whole reason the WITNESS has to
    ///      carry the account.
    function _batch() internal view returns (IPermit3.PermitBatch memory) {
        IPermit3.TokenPermit[] memory tp =
            _tokenPermit1(address(settlement), address(tA), IN_AMT, uint48(block.timestamp + 1 hours));
        return _buildBatch(tp, 0, block.timestamp + 1 hours);
    }

    /// @dev Vacuity guard: the two wallets ARE the naive/replayable shape. A raw
    ///      owner-key signature over an arbitrary hash validates against BOTH — so
    ///      any protection below comes from the digest, not from the wallets.
    function test_precondition_naiveWalletsAreCrossAccountReplayable() public view {
        bytes32 h = keccak256("an arbitrary message");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, h);
        bytes memory sig = abi.encodePacked(r, s, v);
        assertEq(walletA.isValidSignature(h, sig), IERC1271.isValidSignature.selector, "A validates");
        assertEq(walletB.isValidSignature(h, sig), IERC1271.isValidSignature.selector, "B validates too");
    }

    /// @dev Positive control: the witnessed permit fills wallet A's own order.
    function test_witnessedPermit_fillsTheSignersOwnOrder() public {
        Order memory oA = _order(address(walletA));
        IPermit3.PermitBatch memory batch = _batch();
        bytes memory sig = _signPermitWitnessWith(batch, _hashOrder(oA), OWNER_PK);

        vm.prank(solver);
        settlement.fillWithPermit(oA, batch, sig, IN_AMT);

        assertEq(tA.balanceOf(address(walletA)), 0, "A's input was pulled");
        assertEq(tB.balanceOf(address(walletA)), OUT_AMT, "A received output");
        assertEq(tA.balanceOf(address(walletB)), IN_AMT, "B untouched");
    }

    /// @dev THE PROPERTY. The permit for A's order — signed by the owner both wallets
    ///      share, with a batch that names no owner — cannot be replayed to drain the
    ///      sibling wallet B. The witnessed digest embeds `hash(orderA)`, which binds
    ///      `maker == A`, so verifying it against B (`owner = orderB.maker`) recovers
    ///      a different digest and B's naive wallet rejects it. Nothing is pulled.
    function test_witnessedPermit_cannotBeReplayedToASiblingWallet() public {
        // The owner signs a permit witnessed to A's order.
        Order memory oA = _order(address(walletA));
        IPermit3.PermitBatch memory batch = _batch();
        bytes memory sigForA = _signPermitWitnessWith(batch, _hashOrder(oA), OWNER_PK);

        // Attacker retargets it at B: same identical batch, same signature, but an
        // order whose maker is B. (Everything else about oB equals oA.)
        Order memory oB = _order(address(walletB));

        uint256 bBefore = tA.balanceOf(address(walletB));
        vm.prank(solver);
        vm.expectRevert(); // B's 1271 rejects a signature over A's (maker-bound) digest
        settlement.fillWithPermit(oB, batch, sigForA, IN_AMT);

        assertEq(tA.balanceOf(address(walletB)), bBefore, "sibling wallet B was NOT drained");
    }

    /// @dev And the binding is symmetric: the owner CAN authorise B directly, by
    ///      witnessing the permit to B's order. This proves B was genuinely
    ///      drainable-by-its-owner and the revert above was the maker binding, not an
    ///      unrelated failure.
    function test_witnessedPermit_ownerCanAuthorizeBDirectly() public {
        Order memory oB = _order(address(walletB));
        IPermit3.PermitBatch memory batch = _batch();
        bytes memory sigForB = _signPermitWitnessWith(batch, _hashOrder(oB), OWNER_PK);

        vm.prank(solver);
        settlement.fillWithPermit(oB, batch, sigForB, IN_AMT);
        assertEq(tA.balanceOf(address(walletB)), 0, "B fills under a permit witnessed to B's own order");
    }
}
