// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order} from "@core/settlement/Settlement.sol";

import {LzOftBridgeOutModule} from "../src/out/LzOftBridgeOutModule.sol";
import {BridgedOrderInbox} from "../src/BridgedOrderInbox.sol";
import {MockOFT} from "./shared/Mocks.t.sol";
import {BridgeTestBase} from "./shared/BridgeTestBase.t.sol";

/// @title LzPathTest
/// @notice The LayerZero leg — one module covering both Stargate V2 (taxi) and a
///         plain OFT such as USDT0, since they share the `IOFT` send surface.
///
///         The behaviour that distinguishes this path from Across is SPLIT
///         ARRIVAL: tokens land in the `lzReceive` transaction and the commitment
///         in a later `lzCompose` one. A permanent revert in the compose handler
///         would therefore strand already-delivered tokens, which is why the
///         inbox parks failures as orphans instead. Those cases are the bulk of
///         this suite.
contract LzPathTest is BridgeTestBase {
    uint256 constant PAY = 500e18;
    uint256 constant BRIDGE = 100e18;
    uint16 constant SLIPPAGE_BPS = 50; // 0.5%
    uint256 constant DELIVERED = BRIDGE - (BRIDGE * SLIPPAGE_BPS) / 10_000;
    uint256 constant DST_OUT = 300e18;

    uint32 constant DST_EID = 30_101;
    bytes constant EXTRA_OPTIONS = hex"00030100110100000000000000000000000000030d40";

    function _spec(bytes32 dstOrderHash) internal view returns (bytes memory) {
        return abi.encode(
            LzOftBridgeOutModule.LzSpec({
                oft: address(oft),
                inputToken: address(tA),
                dstEid: DST_EID,
                dstChainId: DST_CHAIN,
                dstRecipient: address(inbox),
                maxSlippageBps: SLIPPAGE_BPS,
                maxNativeFee: 0.05 ether,
                feePayer: maker,
                extraOptions: EXTRA_OPTIONS,
                dstOrderHash: dstOrderHash,
                beneficiary: beneficiary,
                commitmentExpiry: uint32(block.timestamp) + COMMITMENT_EXPIRY_OFFSET
            })
        );
    }

    function _fillSource(bytes32 dstOrderHash) internal onSourceChain {
        Order memory src = _srcOrder(1, PAY, BRIDGE, address(lzOut), _spec(dstOrderHash));
        _wireSourceParties(address(lzOut), PAY, BRIDGE);
        vm.deal(maker, 1 ether);
        vm.prank(maker);
        lzOut.topUpFor{value: 0.1 ether}(maker);

        bytes memory sig = _sign(src);
        vm.prank(solver);
        settlement.fill(src, sig, PAY);
    }

    // ──────────────────── End to end ────────────────────

    function test_endToEnd_splitArrival_thenFill() public {
        Order memory dst = _dstOrder(1, DELIVERED, DST_OUT);
        bytes32 dstHash = _hashOrder(dst);

        _fillSource(dstHash);

        MockOFT.Sent memory s = oft.sentAt(0);
        assertEq(s.dstEid, DST_EID, "destination endpoint id");
        assertEq(s.to, bytes32(uint256(uint160(address(inbox)))), "addressed to the inbox");
        assertEq(s.amountLD, BRIDGE, "full delivered amount sent");
        assertEq(s.minAmountLD, DELIVERED, "floor from the signed slippage bound");
        assertEq(s.composeMsg, _commitmentFor(dstHash), "commitment rides as the compose message");
        assertEq(s.extraOptions, EXTRA_OPTIONS, "maker-signed executor options passed through");
        assertEq(s.refundAddress, maker, "executor change returns to the fee payer");
        assertEq(lzOut.nativeCredit(maker), 0.1 ether - 0.01 ether, "fee drawn from the payer's credit");

        // lzReceive: tokens land with NO attribution yet.
        oft.deliverTokens(0, DELIVERED);
        assertEq(inbox.liability(address(tA)), 0, "not yet credited");
        assertEq(inbox.rescuable(address(tA)), DELIVERED, "loose until the compose lands");

        // lzCompose: the separate transaction that attributes them.
        oft.deliverCompose(0, DELIVERED);
        assertEq(inbox.rescuable(address(tA)), 0, "now owed to the commitment");
        assertEq(inbox.missingFunding(dstHash, DELIVERED), 0, "fully funded");

        inbox.activate(dst);
        _fundSolverOut(DST_OUT);
        vm.prank(solver);
        settlement.fill(dst, "", DELIVERED);

        assertEq(tB.balanceOf(endUser), DST_OUT, "end user received the destination output");
    }

    // ──────────────────── Compose must not revert ────────────────────

    function _deliverComposeRaw(bytes memory payload) internal {
        tA.mint(address(inbox), DELIVERED); // the lzReceive leg already happened
        lzEndpoint.deliverCompose(address(inbox), address(oft), bytes32(uint256(1)), payload);
    }

    function _wrap(bytes memory inner) internal view returns (bytes memory) {
        return lzEndpoint.encodeCompose(1, 1, DELIVERED, bytes32(uint256(uint160(address(oft)))), inner);
    }

    /// @dev A malformed commitment must NOT revert — the tokens are already here,
    ///      and a revert would leave them unreachable forever.
    function test_compose_malformedPayload_doesNotRevert() public {
        _deliverComposeRaw(_wrap(hex"c0ffee"));
        assertEq(inbox.liability(address(tA)), 0, "nothing credited");
        assertEq(inbox.rescuable(address(tA)), DELIVERED, "recoverable via rescue");
    }

    function test_compose_wrongChain_doesNotRevert() public {
        Order memory dst = _dstOrder(1, DELIVERED, DST_OUT);
        _deliverComposeRaw(_wrap(_commitmentFor(_hashOrder(dst), uint64(block.chainid) + 1)));
        assertEq(inbox.liability(address(tA)), 0, "not credited");
        assertEq(inbox.rescuable(address(tA)), DELIVERED, "recoverable");
    }

    /// @dev A payload too short to even hold the LayerZero header would make a
    ///      naive slice revert.
    function test_compose_truncatedHeader_doesNotRevert() public {
        tA.mint(address(inbox), DELIVERED);
        lzEndpoint.deliverCompose(address(inbox), address(oft), bytes32(uint256(1)), hex"0001");
        assertEq(inbox.rescuable(address(tA)), DELIVERED, "recoverable");
    }

    function test_compose_disabledToken_doesNotRevert() public {
        vm.prank(inboxOwner);
        inbox.setComposeSource(address(oft), address(tC)); // registered, but tC is not enabled

        Order memory dst = _dstOrder(1, DELIVERED, DST_OUT);
        tC.mint(address(inbox), DELIVERED);
        lzEndpoint.deliverCompose(
            address(inbox), address(oft), bytes32(uint256(1)), _wrap(_commitmentFor(_hashOrder(dst)))
        );
        assertEq(inbox.liability(address(tC)), 0, "not credited");
    }

    /// @dev A token mismatch against an existing commitment parks rather than
    ///      reverting, unlike the Across path where reverting is safe.
    function test_compose_tokenMismatch_doesNotRevert() public {
        Order memory dst = _dstOrder(1, DELIVERED, DST_OUT);
        bytes32 h = _hashOrder(dst);
        _acrossDeliver(DELIVERED, _commitmentFor(h)); // commit is now bound to tA

        vm.startPrank(inboxOwner);
        inbox.enableToken(address(tC));
        inbox.setComposeSource(address(oft), address(tC));
        vm.stopPrank();

        tC.mint(address(inbox), 5e18);
        lzEndpoint.deliverCompose(address(inbox), address(oft), bytes32(uint256(9)), _wrap(_commitmentFor(h)));
        assertEq(inbox.rescuable(address(tC)), 5e18, "parked, not credited");
    }

    /// @dev Orphaned deliveries are exactly what {rescue} exists for.
    function test_orphan_isRecoverableByRescue() public {
        _deliverComposeRaw(_wrap(hex"c0ffee"));
        vm.prank(inboxOwner);
        uint256 got = inbox.rescue(address(tA), inboxOwner);
        assertEq(got, DELIVERED, "recovered the orphan");
    }

    // ──────────────────── Compose authorization ────────────────────

    /// @dev Authorization failures DO revert: a call that is not from the endpoint
    ///      never delivered anything, so there is nothing to strand.
    function test_compose_onlyEndpoint() public {
        Order memory dst = _dstOrder(1, DELIVERED, DST_OUT);
        bytes memory payload = _wrap(_commitmentFor(_hashOrder(dst))); // built first: it is itself a call
        vm.prank(solver);
        vm.expectRevert(BridgedOrderInbox.NotEndpoint.selector);
        inbox.lzCompose(address(oft), bytes32(uint256(1)), payload, address(0), "");
    }

    function test_compose_untrustedSource_reverts() public {
        Order memory dst = _dstOrder(1, DELIVERED, DST_OUT);
        bytes memory payload = _wrap(_commitmentFor(_hashOrder(dst)));
        vm.expectRevert(BridgedOrderInbox.UntrustedComposeSource.selector);
        lzEndpoint.deliverCompose(address(inbox), address(0xBAD), bytes32(uint256(1)), payload);
    }

    /// @dev The endpoint's `composeQueue` is keyed by (sender, receiver, guid,
    ///      INDEX), so one send can carry several compose messages under a single
    ///      GUID — and `lzCompose` is not handed the index. Deduping on the GUID
    ///      alone would silently drop everything after the first and orphan its
    ///      tokens, so the replay key includes the payload.
    function test_compose_distinctPayloadsUnderOneGuid_bothCredit() public {
        Order memory d1 = _dstOrder(1, DELIVERED, DST_OUT);
        Order memory d2 = _dstOrder(2, DELIVERED, DST_OUT);
        bytes memory p1 = _wrap(_commitmentFor(_hashOrder(d1)));
        bytes memory p2 = _wrap(_commitmentFor(_hashOrder(d2)));

        tA.mint(address(inbox), DELIVERED * 2);
        bytes32 guid = bytes32(uint256(5));
        lzEndpoint.deliverCompose(address(inbox), address(oft), guid, p1);
        lzEndpoint.deliverCompose(address(inbox), address(oft), guid, p2);

        assertEq(inbox.liability(address(tA)), DELIVERED * 2, "both credited under one guid");
        assertEq(inbox.missingFunding(_hashOrder(d1), DELIVERED), 0, "first funded");
        assertEq(inbox.missingFunding(_hashOrder(d2), DELIVERED), 0, "second funded");
    }

    function test_compose_duplicateGuid_ignored() public {
        Order memory dst = _dstOrder(1, DELIVERED, DST_OUT);
        bytes32 h = _hashOrder(dst);
        bytes memory payload = _wrap(_commitmentFor(h));

        tA.mint(address(inbox), DELIVERED);
        lzEndpoint.deliverCompose(address(inbox), address(oft), bytes32(uint256(7)), payload);
        assertEq(inbox.liability(address(tA)), DELIVERED, "credited once");

        lzEndpoint.deliverCompose(address(inbox), address(oft), bytes32(uint256(7)), payload);
        assertEq(inbox.liability(address(tA)), DELIVERED, "replay is a no-op");
    }

    // ──────────────────── Native fee ledger ────────────────────

    function test_fee_withoutCredit_reverts() public onSourceChain {
        Order memory dst = _dstOrder(1, DELIVERED, DST_OUT);
        Order memory src = _srcOrder(1, PAY, BRIDGE, address(lzOut), _spec(_hashOrder(dst)));
        _wireSourceParties(address(lzOut), PAY, BRIDGE);
        bytes memory sig = _sign(src);

        vm.prank(solver);
        vm.expectRevert(LzOftBridgeOutModule.InsufficientNativeCredit.selector);
        settlement.fill(src, sig, PAY);
    }

    function test_fee_aboveCap_reverts() public onSourceChain {
        oft.setFee(1 ether); // quote blows past the maker's signed ceiling

        Order memory dst = _dstOrder(1, DELIVERED, DST_OUT);
        Order memory src = _srcOrder(1, PAY, BRIDGE, address(lzOut), _spec(_hashOrder(dst)));
        _wireSourceParties(address(lzOut), PAY, BRIDGE);
        vm.deal(maker, 5 ether);
        vm.prank(maker);
        lzOut.topUpFor{value: 2 ether}(maker);
        bytes memory sig = _sign(src);

        vm.prank(solver);
        vm.expectRevert(LzOftBridgeOutModule.FeeAboveCap.selector);
        settlement.fill(src, sig, PAY);
    }

    /// @dev The ledger is per-payer, so one order can never spend another's
    ///      deposit — the reason it is not a pooled float.
    function test_fee_creditIsPerPayer() public onSourceChain {
        vm.deal(solver, 1 ether);
        vm.prank(solver);
        lzOut.topUpFor{value: 0.5 ether}(solver);

        Order memory dst = _dstOrder(1, DELIVERED, DST_OUT);
        Order memory src = _srcOrder(1, PAY, BRIDGE, address(lzOut), _spec(_hashOrder(dst)));
        _wireSourceParties(address(lzOut), PAY, BRIDGE);
        bytes memory sig = _sign(src);

        // The spec names `maker` as fee payer; the solver's balance is untouchable.
        vm.prank(solver);
        vm.expectRevert(LzOftBridgeOutModule.InsufficientNativeCredit.selector);
        settlement.fill(src, sig, PAY);
        assertEq(lzOut.nativeCredit(solver), 0.5 ether, "solver's credit intact");
    }

    function test_fee_withdrawUnspent() public {
        vm.deal(maker, 1 ether);
        vm.startPrank(maker);
        lzOut.topUpFor{value: 0.3 ether}(maker);
        lzOut.withdrawNative(0.3 ether);
        vm.stopPrank();
        assertEq(lzOut.nativeCredit(maker), 0, "credit cleared");
        assertEq(maker.balance, 1 ether, "funds returned");
    }

    function test_fee_cannotWithdrawSomeoneElses() public {
        vm.deal(maker, 1 ether);
        vm.prank(maker);
        lzOut.topUpFor{value: 0.3 ether}(maker);

        vm.prank(solver);
        vm.expectRevert(LzOftBridgeOutModule.InsufficientNativeCredit.selector);
        lzOut.withdrawNative(0.3 ether);
    }
}
