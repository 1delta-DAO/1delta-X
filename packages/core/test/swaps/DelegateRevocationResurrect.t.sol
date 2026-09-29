// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {Permit3} from "@core/permit3/Permit3.sol";
import {Settlement} from "@core/settlement/Settlement.sol";
import {Signatures} from "@core/settlement/Signatures.sol";
import {OrderState} from "@core/settlement/OrderState.sol";
import {DeployedBytecode} from "../shared/DeployedBytecode.sol";

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
contract DelegateRevocationResurrectTest is Test, DeployedBytecode {
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
        // Gas-neutral switch — see {DeployedBytecode}: under DEPLOYED_BYTECODE=1 the
        // helper CREATEs the shipped via-IR artifacts AS THIS CONTRACT and stores them into
        // these slots; otherwise the original `new` lines run, untouched.
        if (DEPLOYED_BYTECODE) {
            assembly ("memory-safe") {
                let plan := or(SHIP_BOTH, or(shl(8, permit3.offset), shl(16, permit3.slot))) // Permit3 offset | slot
                plan := or(plan, or(shl(80, settlement.offset), shl(88, settlement.slot))) // Settlement offset | slot
                mstore(0x00, DEPLOY_PLAN_SELECTOR)
                mstore(0x04, plan)
                if iszero(delegatecall(gas(), DEPLOYED_BYTECODE_HELPER, 0x00, 0x24, 0x00, 0x00)) {
                    returndatacopy(0x00, 0x00, returndatasize())
                    revert(0x00, returndatasize())
                }
            }
        } else {
            permit3 = new Permit3();
            settlement = new Settlement(address(permit3));
        }
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

    /// THE RELAYED TWIN, F29. {OrderState.setOrderSigner} normalises a lapsed expiry
    /// to a revocation; the relayed path used to mirror that — and because the
    /// RELAYER picks when a permit lands, a nomination relayed after its own
    /// `expiry` turned into a revocation that burned the delegate's word AND cleared
    /// a live direct nomination (finding 7). A permit whose `expiry` has passed now
    /// authorises nothing and is refused. The gasless revocation is spelled
    /// `expiry == 0` (the SDK's only spelling; see
    /// `test_relayedZeroRevocation_burnsThePermitWord`).
    function test_relayedPastExpiryPermit_isRefused() public {
        uint256 deadline = block.timestamp + 30 days;
        uint256 nonceB = _pn(delegate, 8);
        bytes memory permitB = _signPermit(delegate, block.timestamp - 1, nonceB, deadline);

        vm.prank(relayer);
        vm.expectRevert(Signatures.SignerPermitExpired.selector);
        settlement.setOrderSignerWithSig(maker, delegate, block.timestamp - 1, nonceB, deadline, permitB);
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

    /// F29 finding 7 — a stale nomination held by a third party can no longer
    /// revoke a LIVE delegate. The maker nominates directly after signing the
    /// permit; the relayer lands the lapsed permit later; the live nomination and
    /// the delegate's gasless path both survive.
    function test_relayedStalePermit_cannotRevokeALiveDelegate() public {
        uint256 shortExpiry = block.timestamp + 1 hours;
        uint256 deadline = block.timestamp + 30 days;
        uint256 nonce = _pn(delegate, 7);
        bytes memory permit = _signPermit(delegate, shortExpiry, nonce, deadline);

        // Meanwhile the maker nominates the same desk key directly, for a year.
        uint256 live = block.timestamp + 365 days;
        vm.prank(maker);
        settlement.setOrderSigner(delegate, live);

        // The relayer sits on the permit until the nomination it carries has lapsed.
        vm.warp(block.timestamp + 2 hours);
        vm.prank(relayer);
        vm.expectRevert(Signatures.SignerPermitExpired.selector);
        settlement.setOrderSignerWithSig(maker, delegate, shortExpiry, nonce, deadline, permit);

        assertEq(settlement.orderSignerExpiry(maker, delegate), live, "the live nomination is untouched");

        // ...and the gasless path for this delegate is still open.
        uint256 nonce2 = _pn(delegate, 9);
        bytes memory permit2 = _signPermit(delegate, block.timestamp + 365 days, nonce2, deadline);
        vm.prank(relayer);
        settlement.setOrderSignerWithSig(maker, delegate, block.timestamp + 365 days, nonce2, deadline, permit2);
        assertEq(settlement.orderSignerExpiry(maker, delegate), block.timestamp + 365 days, "gasless renewal works");
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

    // ───────── A relayed nomination only ever EXTENDS (re-audit 2026-09-29) ─────────

    /// The case F29-7 left open: a SHORTER permit relayed BEFORE its own expiry.
    /// The maker signs "until T+1h" (never relayed), later nominates the same
    /// delegate directly "until T+365d"; anyone holding the old permit relays it at
    /// T+59min. It used to overwrite the live nomination and cut the desk key off
    /// at T+1h. Now it is refused and the year stands.
    function test_relayedShorterPermit_cannotCutALiveDelegate() public {
        uint256 shortExpiry = block.timestamp + 1 hours;
        uint256 nonce = _pn(delegate, 3);
        uint256 deadline = block.timestamp + 30 days;
        bytes memory stale = _signPermit(delegate, shortExpiry, nonce, deadline);

        uint256 year = block.timestamp + 365 days;
        vm.prank(maker);
        settlement.setOrderSigner(delegate, year);

        vm.warp(block.timestamp + 59 minutes);
        vm.prank(relayer);
        vm.expectRevert(Signatures.SignerPermitExpired.selector);
        settlement.setOrderSignerWithSig(maker, delegate, shortExpiry, nonce, deadline, stale);
        assertEq(settlement.orderSignerExpiry(maker, delegate), year, "the live nomination stands");
    }

    /// A LONGER permit still lands: extending is what a relayed nomination is for.
    function test_relayedLongerPermit_stillExtends() public {
        vm.prank(maker);
        settlement.setOrderSigner(delegate, block.timestamp + 1 days);

        uint256 longer = block.timestamp + 30 days;
        uint256 nonce = _pn(delegate, 4);
        bytes memory permit = _signPermit(delegate, longer, nonce, block.timestamp + 1 hours);
        vm.prank(relayer);
        settlement.setOrderSignerWithSig(maker, delegate, longer, nonce, block.timestamp + 1 hours, permit);
        assertEq(settlement.orderSignerExpiry(maker, delegate), longer, "extended");
    }
}
