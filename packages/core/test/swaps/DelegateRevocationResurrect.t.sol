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

    /// REGRESSION — THE RELAYED TWIN. Every test above drives the DIRECT setter, and
    /// that is exactly how the gap survived: {OrderState.setOrderSigner} normalises a
    /// lapsed expiry to `0`, but {Signatures.setOrderSignerWithSig} used to store the
    /// signed value verbatim. A maker revoking GASLESSLY — the entire audience for
    /// that entrypoint — therefore cleared the registry without burning the delegate's
    /// permit word, and any older unrelayed nomination resurrected the delegate.
    ///
    /// Same scenario as `test_pastExpiryRevocation_alsoBurnsUnrelayedPermits`, routed
    /// through the relayed path instead of the direct one.
    function test_relayedPastExpiryRevocation_alsoBurnsUnrelayedPermits() public {
        uint256 farExpiry = block.timestamp + 365 days;
        uint256 deadline = block.timestamp + 30 days;

        // Permit A: a real nomination, signed and handed to a relayer, never landed.
        uint256 nonceA = _pn(delegate, 7);
        bytes memory permitA = _signPermit(delegate, farExpiry, nonceA, deadline);

        // Permit B: the maker's GASLESS revocation, spelled as an already-past
        // timestamp rather than `0`. A different coordinate in the same word.
        uint256 nonceB = _pn(delegate, 8);
        bytes memory permitB = _signPermit(delegate, block.timestamp - 1, nonceB, deadline);

        vm.prank(relayer);
        settlement.setOrderSignerWithSig(maker, delegate, block.timestamp - 1, nonceB, deadline, permitB);
        assertEq(settlement.orderSignerExpiry(maker, delegate), 0, "lapsed expiry reads as revoked");

        // Permit A must now be dead: the revocation burned the delegate's whole word.
        vm.prank(relayer);
        vm.expectRevert(OrderState.NonceCancelled.selector);
        settlement.setOrderSignerWithSig(maker, delegate, farExpiry, nonceA, deadline, permitA);

        assertEq(settlement.orderSignerExpiry(maker, delegate), 0, "delegate was resurrected");
    }

    /// The relayed `expiry == 0` spelling, for symmetry with
    /// `test_zeroRevocation_burnsThePermitWord`.
    function test_relayedZeroRevocation_burnsThePermitWord() public {
        uint256 farExpiry = block.timestamp + 365 days;
        uint256 deadline = block.timestamp + 30 days;
        uint256 nonceA = _pn(delegate, 7);
        bytes memory permitA = _signPermit(delegate, farExpiry, nonceA, deadline);

        uint256 nonceB = _pn(delegate, 8);
        bytes memory permitB = _signPermit(delegate, 0, nonceB, deadline);

        vm.prank(relayer);
        settlement.setOrderSignerWithSig(maker, delegate, 0, nonceB, deadline, permitB);

        vm.prank(relayer);
        vm.expectRevert(OrderState.NonceCancelled.selector);
        settlement.setOrderSignerWithSig(maker, delegate, farExpiry, nonceA, deadline, permitA);

        assertEq(settlement.orderSignerExpiry(maker, delegate), 0, "revocation stands");
    }

    /// ⚠ THE COST OF THE NORMALISATION, PINNED SO IT IS A KNOWN PROPERTY AND NOT A
    /// SURPRISE. On the relayed path the CALLER picks when a permit lands, so a
    /// nomination relayed after its own `expiry` (but before its `deadline`) is now
    /// read as a revocation and burns the delegate's word. Anyone holding a stale
    /// permit can therefore end GASLESS nomination of that delegate address.
    ///
    /// This is the over-revoke direction, never the under-revoke one, and it is not a
    /// lockout — the direct setter still nominates the same delegate, because it
    /// consumes no bitmap coordinate. The direct path has no equivalent window: only
    /// the maker can call it.
    function test_relayedStalePermit_burnsTheWord_isTheAcceptedCost() public {
        uint256 shortExpiry = block.timestamp + 1 hours;
        uint256 deadline = block.timestamp + 30 days;
        uint256 nonce = _pn(delegate, 7);
        bytes memory permit = _signPermit(delegate, shortExpiry, nonce, deadline);

        // The relayer sits on it until the nomination it carries has lapsed.
        vm.warp(block.timestamp + 2 hours);
        vm.prank(relayer);
        settlement.setOrderSignerWithSig(maker, delegate, shortExpiry, nonce, deadline, permit);

        // Read as a revocation rather than stored as a dead expiry.
        assertEq(settlement.orderSignerExpiry(maker, delegate), 0, "lapsed nomination normalises to 0");

        // The gasless path for THIS delegate is now closed...
        uint256 nonce2 = _pn(delegate, 9);
        bytes memory permit2 = _signPermit(delegate, block.timestamp + 365 days, nonce2, deadline);
        vm.prank(relayer);
        vm.expectRevert(OrderState.NonceCancelled.selector);
        settlement.setOrderSignerWithSig(maker, delegate, block.timestamp + 365 days, nonce2, deadline, permit2);

        // ...but the maker is NOT locked out: the direct setter still works.
        vm.prank(maker);
        settlement.setOrderSigner(delegate, block.timestamp + 365 days);
        assertEq(
            settlement.orderSignerExpiry(maker, delegate),
            block.timestamp + 365 days,
            "direct nomination is unaffected"
        );
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
