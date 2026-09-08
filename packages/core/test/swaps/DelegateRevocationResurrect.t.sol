// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {Permit3} from "@core/permit3/Permit3.sol";
import {Settlement} from "@core/settlement/Settlement.sol";
import {OrderState} from "@core/settlement/OrderState.sol";

/// @notice REGRESSION — {OrderState.setOrderSigner}'s NatSpec told makers that a
///         PAST expiry "reads identically to a revocation". It did not: only the
///         `expiry == 0` branch burns the delegate's nomination-permit bitmap word,
///         so revoking with a lapsed timestamp left every UNRELAYED gasless
///         nomination permit for that delegate replayable until its own deadline,
///         and relaying one resurrected the delegate the maker believed revoked.
///         The setter now normalises a lapsed expiry to `0`, so the two spellings
///         really are identical. Both tests below pinned the drift; they now pin
///         the fix.
///
///         `_setOrderSigner`'s own comment states the property this breaks:
///         "Clearing the registry alone is not enough ... A safety property that
///         depends on the caller making a second call is not a safety property."
contract DelegateRevocationResurrectTest is Test {
    Permit3 permit3;
    Settlement settlement;

    uint256 makerPk = 0xA11CE;
    address maker = vm.addr(makerPk);
    uint256 delegatePk = 0xDE1;
    address delegate = vm.addr(delegatePk);
    address relayer = address(0xBEEF);

    bytes32 constant SIGNER_TH =
        keccak256("OrderSignerPermit(address maker,address signer,uint256 expiry,uint256 nonce,uint256 deadline)");

    function setUp() public {
        permit3 = new Permit3();
        settlement = new Settlement(address(permit3));
        vm.warp(1_000_000);
    }

    /// @dev The MANDATORY permit-nonce derivation: `nonce >> 8 == uint160(signer)`.
    function _pn(address signer_, uint256 seq) internal pure returns (uint256) {
        return (uint256(uint160(signer_)) << 8) | seq;
    }

    function _signPermit(address signer_, uint256 expiry, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(SIGNER_TH, maker, signer_, expiry, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// Revoke with a lapsed expiry — what the NatSpec says is equivalent — and the
    /// unrelayed nomination permit is dead too.
    function test_pastExpiryRevocation_alsoBurnsUnrelayedPermits() public {
        uint256 farExpiry = block.timestamp + 365 days;
        uint256 nonce = _pn(delegate, 7);
        uint256 deadline = block.timestamp + 30 days;

        // The maker signs a gasless nomination and it is never relayed.
        bytes memory permit = _signPermit(delegate, farExpiry, nonce, deadline);

        // The maker "revokes" with an already-lapsed expiry. It is normalised to 0,
        // which is what burns the delegate's permit word.
        vm.prank(maker);
        settlement.setOrderSigner(delegate, block.timestamp - 1);
        assertEq(settlement.orderSignerExpiry(maker, delegate), 0, "lapsed expiry reads as revoked");

        // Anyone holding the permit relays it, before its own deadline — and it is
        // refused, because the revocation burned the delegate's whole permit word.
        vm.prank(relayer);
        vm.expectRevert(OrderState.NonceCancelled.selector);
        settlement.setOrderSignerWithSig(maker, delegate, farExpiry, nonce, deadline, permit);

        assertEq(settlement.orderSignerExpiry(maker, delegate), 0, "delegate was resurrected");
    }

    /// ⚠ THE RESIDUAL, PINNED SO IT IS NOT MISTAKEN FOR CLOSED. A nomination that
    /// lapses BY THE CLOCK is not a revocation and does not burn the permit word, so
    /// an unrelayed permit can still renew that delegate until its OWN deadline. That
    /// is inherent to gasless nomination — the maker signed the permit, and its
    /// deadline is the bound they chose. Only an explicit revocation (`0`, or a
    /// timestamp already in the past) is final.
    function test_expiryLapsingByTheClock_doesNotBurn_isTheAcceptedResidual() public {
        uint256 farExpiry = block.timestamp + 365 days;
        uint256 nonce = _pn(delegate, 7);
        uint256 deadline = block.timestamp + 30 days;
        bytes memory permit = _signPermit(delegate, farExpiry, nonce, deadline);

        // A genuine time-limited nomination: live now, lapsed in an hour.
        vm.prank(maker);
        settlement.setOrderSigner(delegate, block.timestamp + 1 hours);
        vm.warp(block.timestamp + 2 hours);

        vm.prank(relayer);
        settlement.setOrderSignerWithSig(maker, delegate, farExpiry, nonce, deadline, permit);
        assertEq(settlement.orderSignerExpiry(maker, delegate), farExpiry, "renewal is intended here");
    }

    /// The contrast: the `expiry == 0` form burns the delegate's whole permit word,
    /// so the identical replay is refused. The two forms the NatSpec calls
    /// interchangeable are not.
    function test_zeroRevocation_burnsThePermitWord() public {
        uint256 farExpiry = block.timestamp + 365 days;
        uint256 nonce = _pn(delegate, 7);
        uint256 deadline = block.timestamp + 30 days;
        bytes memory permit = _signPermit(delegate, farExpiry, nonce, deadline);

        vm.prank(maker);
        settlement.setOrderSigner(delegate, 0);

        vm.prank(relayer);
        vm.expectRevert(OrderState.NonceCancelled.selector);
        settlement.setOrderSignerWithSig(maker, delegate, farExpiry, nonce, deadline, permit);

        assertEq(settlement.orderSignerExpiry(maker, delegate), 0, "revocation stands");
    }
}
