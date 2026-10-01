// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {Order, Item, ItemOp, LegOut} from "@core/settlement/Settlement.sol";

import {BridgedOrderInbox} from "../src/BridgedOrderInbox.sol";
import {CommitmentCodec} from "../src/CommitmentCodec.sol";
import {PositionFunnel} from "../src/funnel/PositionFunnel.sol";
import {PositionFunnelFactory} from "../src/funnel/PositionFunnelFactory.sol";
import {FunnelGrantModule} from "../src/funnel/FunnelGrantModule.sol";
import {BridgeTestBase} from "./shared/BridgeTestBase.t.sol";

/// @title Audit20260930BridgeBehaviourTest
/// @notice Regression tests for the 2026-09-30 audit findings whose fix changed
///         BEHAVIOUR behind an unchanged ABI — so each one runs, and fails, against
///         the pre-fix sources too. (Findings whose fix changed an ABI live in
///         {Audit20260930BridgeTest}.)
contract Audit20260930BridgeBehaviourTest is BridgeTestBase {
    uint256 constant AMT = 100e18;
    uint256 constant OUT = 90e18;

    function _commit(bytes32 h, address who, uint32 expiry) internal pure returns (bytes memory) {
        return CommitmentCodec.encode(
            CommitmentCodec.Commitment({orderHash: h, beneficiary: who, dstChainId: DST_CHAIN, expiry: expiry})
        );
    }

    // ──────────────────── BRIDGE-A-2: zero credit cannot move the clock ────────────────────

    /// A zero-amount copycat credit adds nothing to the row, so it must not be able
    /// to raise the row's fallback expiry (to 2106) either.
    function test_audit_BRIDGE_A_2_zeroAmountCreditCannotRaiseExpiry() public {
        Order memory o = _dstOrder(1, AMT, OUT);
        bytes32 h = _hashOrder(o);
        uint32 honest = uint32(block.timestamp) + 3 days;
        _acrossDeliver(AMT, _commit(h, beneficiary, honest));

        _acrossDeliver(0, _commit(h, beneficiary, type(uint32).max)); // free "lock until 2106"
        assertEq(inbox.refundAfter(h, beneficiary, address(tA)), honest, "fallback unchanged by a 0 credit");

        vm.warp(honest + 1);
        assertEq(_settle(h), AMT, "refunds on the honest fallback");
    }

    // ──────────────────── X-ASM-1: truncated packed legs ────────────────────

    /// `legsIn` declares one 84-byte leg but carries only 52 bytes after the count.
    /// The `end` word then comes from the blob's unhashed ABI padding / the next
    /// tail — one `orderHash`, caller-chosen decoding. Must be refused.
    function test_audit_X_ASM_1_truncatedLegsInBlob_isRejected() public {
        Order memory o = _dstOrder(1, AMT, OUT);
        o.legsIn = abi.encodePacked(uint8(1), address(tA), AMT); // 53 bytes, needs 85
        bytes32 h = _hashOrder(o);
        _acrossDeliver(AMT, _commit(h, beneficiary, uint32(block.timestamp) + 3 days));

        vm.expectRevert(BridgedOrderInbox.UnsupportedOrderShape.selector);
        inbox.activate(o, beneficiary);
        assertFalse(settlement.orderApproved(address(inbox), h), "never approved");
    }

    /// Same rule for `legsOut`: the recipient loop must be bounded by a count the
    /// bytes back.
    function test_audit_X_ASM_1_truncatedLegsOutBlob_isRejected() public {
        Order memory o = _dstOrder(1, AMT, OUT);
        o.legsOut = abi.encodePacked(uint8(1), address(tB), OUT); // 53 bytes, needs 105
        bytes32 h = _hashOrder(o);
        _acrossDeliver(AMT, _commit(h, beneficiary, uint32(block.timestamp) + 3 days));

        vm.expectRevert(BridgedOrderInbox.UnsupportedOrderShape.selector);
        inbox.activate(o, beneficiary);
    }

    // ──────────────────── BRIDGE-A-3: identical second compose under one GUID ────────────────────

    /// The endpoint already forbids replaying one compose slot; two indices under
    /// one GUID with identical payloads are two real deliveries and both credit.
    function test_audit_BRIDGE_A_3_identicalSecondComposeIsCredited() public {
        bytes32 h = _hashOrder(_dstOrder(1, AMT, OUT));
        bytes memory payload = lzEndpoint.encodeCompose(
            1,
            1,
            AMT,
            bytes32(uint256(uint160(address(oft)))),
            _commit(h, beneficiary, uint32(block.timestamp) + 1 days)
        );
        tA.mint(address(inbox), 2 * AMT);
        lzEndpoint.deliverCompose(address(inbox), address(oft), bytes32(uint256(7)), payload);
        lzEndpoint.deliverCompose(address(inbox), address(oft), bytes32(uint256(7)), payload);
        assertEq(inbox.liability(address(tA)), 2 * AMT, "both deliveries attributed");
    }

    // ──────────────────── BRIDGE-A-4: native value on lzCompose ────────────────────

    /// The inbox has no native liabilities and no native exit, so a value-bearing
    /// compose must revert (and stay retryable without value) instead of locking it.
    function test_audit_BRIDGE_A_4_composeWithValueReverts_retryWithoutValueCredits() public {
        bytes32 h = _hashOrder(_dstOrder(1, AMT, OUT));
        bytes memory payload = lzEndpoint.encodeCompose(
            1,
            1,
            AMT,
            bytes32(uint256(uint160(address(oft)))),
            _commit(h, beneficiary, uint32(block.timestamp) + 1 days)
        );
        tA.mint(address(inbox), AMT);
        vm.deal(address(lzEndpoint), 1 ether);

        vm.prank(address(lzEndpoint));
        vm.expectRevert();
        inbox.lzCompose{value: 1 ether}(address(oft), bytes32(uint256(1)), payload, address(0), "");
        assertEq(address(inbox).balance, 0, "no native locked in the inbox");

        vm.prank(address(lzEndpoint));
        inbox.lzCompose(address(oft), bytes32(uint256(1)), payload, address(0), "");
        assertEq(inbox.liability(address(tA)), AMT, "zero-value retry credits");
    }

    // ──────────────────── BRIDGE-B-1: the funnel implementation's EIP-1271 ────────────────────

    function _factory() internal returns (PositionFunnelFactory f, FunnelGrantModule g) {
        g = new FunnelGrantModule(address(settlement));
        f = new PositionFunnelFactory(address(permit3), address(settlement), address(lens), address(g));
    }

    /// Called on the implementation, `owner()` is the zero padding of the 65-byte
    /// signature and an unrecoverable signature "recovers" to zero — so the
    /// implementation used to answer the magic value to Settlement and the lens.
    function test_audit_BRIDGE_B_1_implementationRejectsGarbageSignature() public {
        (PositionFunnelFactory f,) = _factory();
        PositionFunnel impl = PositionFunnel(payable(f.IMPLEMENTATION()));
        bytes32 digest = keccak256("any order digest");

        vm.prank(address(settlement));
        assertEq(impl.isValidSignature(digest, new bytes(65)), bytes4(0xffffffff), "settlement: v=0 rejected");
        vm.prank(address(lens));
        assertEq(impl.isValidSignature(digest, new bytes(65)), bytes4(0xffffffff), "lens: v=0 rejected");
        vm.prank(address(settlement));
        assertEq(impl.isValidSignature(digest, new bytes(64)), bytes4(0xffffffff), "64-byte form too");
    }

    /// End to end: an order whose maker is the implementation must not verify.
    function test_audit_BRIDGE_B_1_orderMadeByImplementationDoesNotFill() public {
        (PositionFunnelFactory f,) = _factory();
        address impl = f.IMPLEMENTATION();
        Order memory o = _blank(1);
        o.maker = impl;
        o.legsIn = _legsIn1(address(tA), 1);
        o.legsOut = _legsOut1(address(tB), 1);
        tA.mint(impl, 1);
        _fundSolverOut(1);

        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(o, new bytes(65), 1);
    }

    /// A real funnel keeps working: the guard is the implementation / zero owner only.
    function test_audit_BRIDGE_B_1_realFunnelStillVerifiesOwner() public {
        (PositionFunnelFactory f,) = _factory();
        PositionFunnel funnel = PositionFunnel(payable(f.deploy(maker, bytes32(0))));
        bytes32 digest = keccak256("digest");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, digest);
        vm.prank(address(settlement));
        assertEq(funnel.isValidSignature(digest, abi.encodePacked(r, s, v)), bytes4(0x1626ba7e), "owner sig ok");
        vm.prank(address(settlement));
        assertEq(funnel.isValidSignature(digest, new bytes(65)), bytes4(0xffffffff), "garbage refused");
    }

    // ──────────────────── BRIDGE-B-7: grant must not clobber enableToken ────────────────────

    /// Two live orders on one token; the first carries a Settlement-spender grant
    /// item. Before the fix that grant overwrote the standing (max, never) allowance
    /// with (slice, now), and the second order could not be pulled.
    function test_audit_BRIDGE_B_7_settlementGrantKeepsStandingAllowance() public {
        (PositionFunnelFactory f, FunnelGrantModule g) = _factory();
        PositionFunnel funnel = PositionFunnel(payable(f.deploy(maker, bytes32(uint256(7)))));
        funnel.enableToken(address(tA));
        tA.mint(address(funnel), 2 * AMT);
        _fundSolverOut(2 * AMT);

        Order memory o1 = _blank(1);
        o1.maker = address(funnel);
        o1.legsIn = _legsIn1(address(tA), AMT);
        LegOut[] memory lo = new LegOut[](1);
        lo[0] = LegOut(address(tB), AMT, 0, maker);
        o1.legsOut = PackedEncode.legsOut(lo);
        Item[] memory it = new Item[](1);
        it[0] = Item({
            op: ItemOp.MAKE,
            module: address(g),
            amount: AMT,
            recipient: address(0),
            data: abi.encode(
                FunnelGrantModule.GrantSpec({
                    spender: address(settlement), module: address(0), token: address(tA), taker: false, ref: bytes32(0)
                })
            )
        });
        o1.items = PackedEncode.items(it);

        Order memory o2 = _blank(2);
        o2.maker = address(funnel);
        o2.legsIn = _legsIn1(address(tA), AMT);
        o2.legsOut = PackedEncode.legsOut(lo);

        bytes memory sig1 = _signWith(o1, makerPk);
        bytes memory sig2 = _signWith(o2, makerPk);
        vm.prank(solver);
        settlement.fill(o1, sig1, AMT);

        (uint160 amt, uint48 exp) = permit3.tokenAllowance(address(funnel), address(settlement), address(tA));
        assertEq(amt, type(uint160).max, "standing allowance not downgraded");
        assertEq(exp, 0, "still never expires");

        vm.warp(block.timestamp + 1);
        vm.prank(solver);
        settlement.fill(o2, sig2, AMT);
        assertEq(tA.balanceOf(address(funnel)), 0, "second order filled too");
        assertEq(tB.balanceOf(maker), 2 * AMT, "owner received both outputs");
    }
}
