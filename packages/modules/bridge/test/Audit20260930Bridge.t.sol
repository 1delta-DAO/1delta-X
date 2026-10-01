// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";
import {Order, LegOut, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";

import {BridgedOrderInbox} from "../src/BridgedOrderInbox.sol";
import {CommitmentCodec} from "../src/CommitmentCodec.sol";
import {AcrossBridgeOutModule} from "../src/out/AcrossBridgeOutModule.sol";
import {LzOftBridgeOutModule} from "../src/out/LzOftBridgeOutModule.sol";
import {CctpBridgeOutModule} from "../src/out/CctpBridgeOutModule.sol";
import {IOFT} from "../src/vendor/ILayerZero.sol";
import {MockOFT, MockSpokePool, MockTokenMessenger} from "./shared/Mocks.t.sol";
import {BridgeTestBase} from "./shared/BridgeTestBase.t.sol";

/// @dev A LayerZero NATIVE OFT: it IS the token (`token() == address(this)`) and
///      `send` burns from its CALLER with no allowance — the shape that let a spec
///      with a junk `inputToken` spend the module's resident balance (BRIDGE-B-2).
contract MockNativeOFT is MockERC20 {
    uint256 public sentCount;

    constructor() MockERC20("nativeOFT") {}

    function token() external view returns (address) {
        return address(this);
    }

    function quoteSend(IOFT.SendParam calldata, bool) external pure returns (IOFT.MessagingFee memory) {
        return IOFT.MessagingFee({nativeFee: 0, lzTokenFee: 0});
    }

    function send(IOFT.SendParam calldata p, IOFT.MessagingFee calldata, address)
        external
        payable
        returns (IOFT.MessagingReceipt memory r, IOFT.OFTReceipt memory o)
    {
        balanceOf[msg.sender] -= p.amountLD; // OFTCore._debit → _burn(msg.sender, …)
        sentCount++;
        o.amountSentLD = p.amountLD;
        o.amountReceivedLD = p.amountLD;
        r.guid = bytes32(sentCount);
    }
}

/// @dev The REAL LayerZero V2 EndpointV2 compose surface (MessagingComposer).
interface IEndpointV2Compose {
    function sendCompose(address to, bytes32 guid, uint16 index, bytes calldata message) external;
    function lzCompose(
        address from,
        address to,
        bytes32 guid,
        uint16 index,
        bytes calldata message,
        bytes calldata extraData
    ) external payable;
    function composeQueue(address from, address to, bytes32 guid, uint16 index) external view returns (bytes32);
}

/// @dev Destination half of an OFT adapter (`OFTCore._lzReceive`) against the
///      REAL endpoint: credit the receiver, then queue the compose.
contract OftReceiveStandIn {
    MockERC20 public immutable token;
    IEndpointV2Compose public immutable endpoint;

    constructor(MockERC20 t, address ep) {
        token = t;
        endpoint = IEndpointV2Compose(ep);
    }

    function lzReceiveLike(
        bytes32 guid,
        uint64 nonce,
        uint32 srcEid,
        address to,
        uint256 amountLD,
        bytes calldata inner
    ) external returns (bytes memory message) {
        token.mint(to, amountLD);
        message = abi.encodePacked(nonce, srcEid, amountLD, bytes32(uint256(uint160(msg.sender))), inner);
        endpoint.sendCompose(to, guid, 0, message);
    }
}

/// @title Audit20260930BridgeTest
/// @notice Regression tests for the 2026-09-30 audit findings in the bridge
///         package whose fix changed an ABI (rescue bound, settleExpired token,
///         spec fields, sponsorship API, CCTP V2). Each asserts the SAFE end state
///         of the attack the finding (and, for BRIDGE-A-1, its PoC) describes.
contract Audit20260930BridgeTest is BridgeTestBase {
    uint256 constant X = 1_000e18;
    uint256 constant ORPHAN = 10e18;
    uint256 constant OUT = 900e18;

    address constant LZ_ENDPOINT_V2 = 0x1a44076050125825900e736c501f859c50fE728c; // Ethereum mainnet

    // ──────────────────── helpers ────────────────────

    function _dstOrderTo(uint256 nonce, uint256 amountIn, uint256 amountOut, address recipient)
        internal
        view
        returns (Order memory o)
    {
        o = _dstOrder(nonce, amountIn, amountOut);
        LegOut[] memory lo = new LegOut[](1);
        lo[0] = LegOut(address(tB), amountOut, 0, recipient);
        o.legsOut = PackedEncode.legsOut(lo);
    }

    function _commit(bytes32 h, address ben, uint32 expiry) internal pure returns (bytes memory) {
        return CommitmentCodec.encode(
            CommitmentCodec.Commitment({orderHash: h, beneficiary: ben, dstChainId: DST_CHAIN, expiry: expiry})
        );
    }

    /// @dev A user pays `amount` into `src` on the source side with `composeMsg`.
    function _lzSendVia(MockOFT src, address user, uint256 amount, bytes memory composeMsg)
        internal
        returns (uint256 idx)
    {
        tA.mint(user, amount);
        vm.startPrank(user);
        tA.approve(address(src), amount);
        src.send(
            IOFT.SendParam({
                dstEid: 30_101,
                to: bytes32(uint256(uint160(address(inbox)))),
                amountLD: amount,
                minAmountLD: amount,
                extraOptions: "",
                composeMsg: composeMsg,
                oftCmd: ""
            }),
            IOFT.MessagingFee(0, 0),
            user
        );
        vm.stopPrank();
        idx = src.sentCount() - 1;
    }

    function _lzSend(address user, uint256 amount, bytes memory composeMsg) internal returns (uint256) {
        return _lzSendVia(oft, user, amount, composeMsg);
    }

    /// @dev A genuinely unacceptable compose delivery of `amount`: Orphaned("payload").
    function _orphanPayload(uint256 amount) internal {
        tA.mint(address(inbox), amount);
        lzEndpoint.deliverCompose(
            address(inbox),
            address(oft),
            bytes32(uint256(0x77)),
            lzEndpoint.encodeCompose(9, 1, amount, bytes32(uint256(uint160(address(oft)))), hex"c0ffee")
        );
    }

    function _assertSolvent(string memory why) internal view {
        assertLe(inbox.liability(address(tA)), tA.balanceOf(address(inbox)), why);
    }

    // ═══════════════════ BRIDGE-A-1: rescue vs. in-flight composes ═══════════════════

    /// PoC (a): the honest owner refunds a 10-token orphan while a 1,000-token LZ
    /// delivery's compose is still queued. Only the orphan may move; when the
    /// compose lands its credit is fully backed and every row still fills.
    function test_audit_BRIDGE_A_1_orphanRefundCannotSweepQueuedCompose() public {
        address u1 = address(0xA1);
        address u3 = address(0xA3);
        address r1 = address(0xB1);
        address r3 = address(0xB3);
        address orphanOwner = address(0x0F0F);

        Order memory o3 = _dstOrderTo(3, X, OUT, r3);
        _acrossDeliver(X, _commit(_hashOrder(o3), u3, uint32(block.timestamp + 3 days)));
        inbox.activate(o3, u3);

        Order memory o1 = _dstOrderTo(1, X, OUT, r1);
        uint256 idx = _lzSend(u1, X, _commit(_hashOrder(o1), u1, uint32(block.timestamp + 3 days)));
        oft.deliverTokens(idx, X); // lzReceive; compose still queued

        _orphanPayload(ORPHAN);
        assertEq(inbox.orphaned(address(tA)), ORPHAN, "the orphan is announced");
        assertEq(inbox.rescuable(address(tA)), ORPHAN, "only the orphan is instantly rescuable");

        vm.prank(inboxOwner);
        uint256 got = inbox.rescue(address(tA), orphanOwner, type(uint256).max);
        assertEq(got, ORPHAN, "rescue took ONLY the orphan");
        assertEq(tA.balanceOf(orphanOwner), ORPHAN);

        oft.deliverCompose(idx, X); // permissionless, later
        assertEq(inbox.liability(address(tA)), 2 * X, "U1 credited");
        assertEq(tA.balanceOf(address(inbox)), 2 * X, "and backed");
        _assertSolvent("liability <= balance");

        inbox.activate(o1, u1);
        _fundSolverOut(2 * OUT);
        vm.startPrank(solver);
        settlement.fill(o1, "", X);
        settlement.fill(o3, "", X);
        vm.stopPrank();
        assertEq(tB.balanceOf(r1), OUT, "U1 filled");
        assertEq(tB.balanceOf(r3), OUT, "U3 filled from its own escrow");
    }

    /// PoC (b): a compromised owner key cannot self-loop an in-flight delivery
    /// (rescue it, then let its compose credit an unbacked row) — nothing is
    /// instantly rescuable, and the stray path is timelocked.
    function test_audit_BRIDGE_A_1_compromisedOwnerCannotSelfLoop() public {
        vm.warp(1_800_000_000);
        address victim = address(0xA3);
        address attacker = inboxOwner;
        bytes32 attackerHash = keccak256("any hash - no order needed");

        Order memory ov = _dstOrderTo(3, X, OUT, address(0xB3));
        _acrossDeliver(X, _commit(_hashOrder(ov), victim, uint32(block.timestamp + 3 days)));
        inbox.activate(ov, victim);

        uint256 idx = _lzSend(attacker, X, _commit(attackerHash, attacker, 1));
        oft.deliverTokens(idx, X);

        vm.startPrank(attacker);
        vm.expectRevert(BridgedOrderInbox.NothingToRescue.selector);
        inbox.rescue(address(tA), attacker, type(uint256).max);
        inbox.queueStrayRescue(address(tA), attacker, type(uint256).max);
        vm.expectRevert(BridgedOrderInbox.StrayRescueNotReady.selector);
        inbox.executeStrayRescue(address(tA));
        vm.stopPrank();

        oft.deliverCompose(idx, X);
        vm.prank(attacker);
        assertEq(inbox.settle(attackerHash, attacker, address(tA)), X, "own deposit back");
        assertEq(tA.balanceOf(attacker), X, "net zero: paid X, got X");
        _assertSolvent("still solvent");

        _fundSolverOut(OUT);
        vm.prank(solver);
        settlement.fill(ov, "", X);
        assertEq(tB.balanceOf(address(0xB3)), OUT, "victim filled");

        // Even after the delay the stray path finds nothing — the compose landed.
        vm.warp(block.timestamp + inbox.COMPOSE_SOURCE_DELAY());
        inbox.sync(_hashOrder(ov));
        vm.prank(attacker);
        vm.expectRevert(BridgedOrderInbox.NothingToRescue.selector);
        inbox.executeStrayRescue(address(tA));
    }

    /// PoC (c) / X-DIFF-REST-2: an instant source REMOVAL parks deliveries
    /// uncredited; rescue still cannot take them, and once the source is re-added
    /// the retried compose credits a backed row.
    function test_audit_BRIDGE_A_1_sourceRemovalParksButRescueCannotTake() public {
        address u1 = address(0xA1);
        address u3 = address(0xA3);
        Order memory o3 = _dstOrderTo(3, X, OUT, address(0xB3));
        bytes32 h3 = _hashOrder(o3);
        _acrossDeliver(X, _commit(h3, u3, uint32(block.timestamp + 30 days)));
        inbox.activate(o3, u3);

        bytes32 h1 = keccak256("u1 row");
        uint256 idx = _lzSend(u1, X, _commit(h1, u1, uint32(block.timestamp + 1)));
        oft.deliverTokens(idx, X);

        vm.prank(inboxOwner);
        inbox.setComposeSource(address(oft), address(0));
        vm.expectRevert(BridgedOrderInbox.UntrustedComposeSource.selector);
        oft.deliverCompose(idx, X);

        vm.prank(inboxOwner);
        vm.expectRevert(BridgedOrderInbox.NothingToRescue.selector);
        inbox.rescue(address(tA), inboxOwner, type(uint256).max);

        _registerComposeSource(address(oft), address(tA));
        oft.deliverCompose(idx, X);
        _assertSolvent("re-added source credits a backed row");

        vm.warp(block.timestamp + 2);
        assertEq(inbox.settle(h1, u1, address(tA)), X, "U1 refunded its own deposit");
        vm.warp(_expiry(o3) + 1);
        assertEq(inbox.settle(h3, u3, address(tA)), X, "U3 refunded in full");
        assertEq(tA.balanceOf(address(inbox)), 0);
    }

    /// BRIDGE-A-1.v1: deliveries through a source still QUEUED by the F30 timelock
    /// revert in lzCompose and sit uncredited for two days. An orphan refund in
    /// that window takes only the orphan; when the source goes live the parked
    /// delivery credits a backed row and the pool stays whole.
    function test_audit_BRIDGE_A_1_v1_queuedSourceWindow_orphanRefundTakesOnlyOrphan() public {
        address attacker = makeAddr("attacker");
        address victim = makeAddr("victim");
        uint256 P = 500_000e18;
        uint256 PX = 400_000e18;
        uint256 O = 10e18;

        bytes32 victimHash = keccak256("victim-order");
        _acrossDeliver(P, _commit(victimHash, victim, uint32(block.timestamp + 3 days)));

        MockOFT S = new MockOFT(address(tA), 0, lzEndpoint);
        vm.prank(inboxOwner);
        inbox.setComposeSource(address(S), address(tA));
        (, uint64 eta) = inbox.pendingComposeSource(address(S));

        bytes32 hx = keccak256("any-non-zero-hash");
        uint256 idx = _lzSendVia(S, attacker, PX, _commit(hx, attacker, 1));
        S.deliverTokens(idx, PX);
        vm.expectRevert(BridgedOrderInbox.UntrustedComposeSource.selector);
        S.deliverCompose(idx, PX);

        _orphanPayload(O);
        assertEq(inbox.rescuable(address(tA)), O, "rescuable is the orphan, not the parked delivery");
        vm.prank(inboxOwner);
        assertEq(inbox.rescue(address(tA), attacker, type(uint256).max), O, "orphan refund = O only");

        vm.warp(eta);
        inbox.applyComposeSource(address(S));
        S.deliverCompose(idx, PX);
        vm.prank(attacker);
        assertEq(inbox.settle(hx, attacker, address(tA)), PX, "attacker gets its own deposit");

        // It put in PX (bridged) + O (the orphan): it holds exactly that, no more.
        assertEq(tA.balanceOf(attacker), PX + O, "attacker net zero");
        assertEq(tA.balanceOf(address(inbox)), P, "pool whole");
        assertEq(inbox.liability(address(tA)), P, "owes exactly what it holds");
        vm.warp(block.timestamp + 3 days + 1);
        assertEq(inbox.settle(victimHash, victim, address(tA)), P, "victim refunded in full");
    }

    /// The delayed stray path re-evaluates its bound at EXECUTION: a delivery whose
    /// compose landed during the delay is liability by then and out of reach.
    function test_audit_BRIDGE_A_1_strayRescueReboundsAtExecution() public {
        MockOFT S = new MockOFT(address(tA), 0, lzEndpoint);
        vm.prank(inboxOwner);
        inbox.setComposeSource(address(S), address(tA));
        (, uint64 eta) = inbox.pendingComposeSource(address(S));

        address user = makeAddr("user");
        uint256 idx = _lzSendVia(S, user, X, _commit(keccak256("u"), user, uint32(block.timestamp + 10 days)));
        S.deliverTokens(idx, X);
        tA.mint(address(inbox), 7e18); // a genuine donation
        assertEq(inbox.strayBalance(address(tA)), X + 7e18, "both look unattributed");

        vm.prank(inboxOwner);
        inbox.queueStrayRescue(address(tA), inboxOwner, type(uint256).max);

        vm.warp(eta);
        inbox.applyComposeSource(address(S));
        S.deliverCompose(idx, X); // lands during the stray delay

        vm.prank(inboxOwner);
        assertEq(inbox.executeStrayRescue(address(tA)), 7e18, "only the donation");
        _assertSolvent("parked delivery stayed backed");
        assertEq(tA.balanceOf(address(inbox)), X);
    }

    /// The real EndpointV2 (mainnet fork): a queued compose is not rescuable and,
    /// executed permissionlessly later, credits a backed row.
    function __fork(string calldata rpc) external {
        vm.createSelectFork(rpc);
    }

    function test_audit_BRIDGE_A_1_fork_realEndpointV2_queuedComposeNotRescuable() public {
        string[3] memory rpcs = ["https://ethereum-rpc.publicnode.com", "https://eth.drpc.org", "https://1rpc.io/eth"];
        bool forked;
        for (uint256 i; i < rpcs.length && !forked; i++) {
            try this.__fork(rpcs[i]) {
                forked = true;
            } catch {}
        }
        if (!forked || LZ_ENDPOINT_V2.code.length == 0) {
            vm.skip(true); // no public RPC reachable from this runner
            return;
        }
        setUp();
        inbox = new BridgedOrderInbox(
            address(permit3), address(settlement), address(spokePool), LZ_ENDPOINT_V2, inboxOwner
        );
        vm.prank(inboxOwner);
        inbox.enableToken(address(tA));
        OftReceiveStandIn oftR = new OftReceiveStandIn(tA, LZ_ENDPOINT_V2);
        _registerComposeSource(address(oftR), address(tA));

        address victim = address(0xA3);
        address attacker = inboxOwner;
        bytes32 attackerHash = keccak256("attacker row");
        Order memory ov = _dstOrderTo(3, X, OUT, address(0xB3));
        bytes32 hv = _hashOrder(ov);
        _acrossDeliver(X, _commit(hv, victim, uint32(block.timestamp + 3 days)));
        inbox.activate(ov, victim);

        tA.mint(attacker, X);
        vm.prank(attacker);
        tA.transfer(address(oftR), X); // source-side lock

        bytes32 guid = keccak256("guid-1");
        bytes memory message =
            oftR.lzReceiveLike(guid, 1, 30_110, address(inbox), X, _commit(attackerHash, attacker, 1));
        assertEq(inbox.rescuable(address(tA)), 0, "in-flight delivery is not rescuable");

        vm.startPrank(attacker);
        vm.expectRevert(BridgedOrderInbox.NothingToRescue.selector);
        inbox.rescue(address(tA), attacker, type(uint256).max);
        IEndpointV2Compose(LZ_ENDPOINT_V2).lzCompose(address(oftR), address(inbox), guid, 0, message, "");
        assertEq(inbox.settle(attackerHash, attacker, address(tA)), X);
        vm.stopPrank();

        assertEq(tA.balanceOf(attacker), X, "attacker: paid X, got X");
        assertEq(tA.balanceOf(address(inbox)), X, "victim's escrow intact");
        vm.warp(_expiry(ov) + 1);
        assertEq(inbox.settle(hv, victim, address(tA)), X, "victim refunded");
    }

    // ═══════════════════ BRIDGE-A-2 / X-DIFF-REST-1: copycat expiry lock ═══════════════════

    /// A row credited in a token the order does not sell can never activate; a
    /// 1-wei copycat raised its only gate to 2106. settleExpired now takes the
    /// row's token and refunds such a row at once.
    function test_audit_BRIDGE_A_2_otherTokenRow_copycatCannotLock() public {
        vm.prank(inboxOwner);
        inbox.enableToken(address(tC));
        Order memory o = _dstOrder(1, X, OUT); // sells tA
        bytes32 h = _hashOrder(o);

        tC.mint(address(inbox), X + 1);
        vm.startPrank(address(spokePool));
        inbox.handleV3AcrossMessage(
            address(tC), X, address(0), _commit(h, beneficiary, uint32(block.timestamp + 1 hours))
        );
        inbox.handleV3AcrossMessage(address(tC), 1, address(0), _commit(h, beneficiary, type(uint32).max));
        vm.stopPrank();
        assertEq(inbox.refundAfter(h, beneficiary, address(tC)), type(uint32).max, "copycat raised the fallback");

        vm.expectRevert(BridgedOrderInbox.NotYetRefundable.selector);
        inbox.settle(h, beneficiary, address(tC));
        assertEq(inbox.settleExpired(o, beneficiary, address(tC)), X + 1, "refunded at once: can never activate");
        assertEq(tC.balanceOf(beneficiary), X + 1);

        // The order's OWN token row of a live order is still gated.
        _acrossDeliver(X, _commit(h, beneficiary, uint32(block.timestamp + 1 hours)));
        vm.expectRevert(BridgedOrderInbox.NotYetRefundable.selector);
        inbox.settleExpired(o, beneficiary, address(tA));
    }

    /// A never-expiring destination order (`deadline == type(uint48).max`) can no
    /// longer activate, so its rows are refundable at once instead of waiting out
    /// a copycat-inflated fallback.
    function test_audit_X_DIFF_REST_1_neverExpiringOrderRow_refundableAtOnce() public {
        Order memory o = _dstOrder(1, X, OUT);
        _setExpiry(o, type(uint48).max);
        bytes32 h = _hashOrder(o);
        _acrossDeliver(X, _commit(h, beneficiary, uint32(block.timestamp + 1 hours)));
        _acrossDeliver(1, _commit(h, beneficiary, type(uint32).max));

        vm.expectRevert(BridgedOrderInbox.UnsupportedOrderShape.selector);
        inbox.activate(o, beneficiary);
        assertEq(inbox.settleExpired(o, beneficiary, address(tA)), X + 1, "refunded at once");
    }

    // ═══════════════════ BRIDGE-B-2: native OFT token binding ═══════════════════

    function _lzSpecFor(address oftAddr, address inputToken) internal view returns (bytes memory) {
        return abi.encode(
            LzOftBridgeOutModule.LzSpec({
                oft: oftAddr,
                inputToken: inputToken,
                dstEid: 30_101,
                dstChainId: DST_CHAIN,
                dstRecipient: maker, // the attacker's own address on the destination
                maxSlippageBps: 0,
                maxNativeFee: 0,
                feePayer: maker,
                extraOptions: "",
                dstOrderHash: bytes32(0),
                beneficiary: maker,
                commitmentExpiry: 0,
                totalAmount: 0
            })
        );
    }

    /// The shared LZ module holds a resident native-OFT balance (a mis-send). A
    /// self-signed order pulling a junk token but naming the native OFT used to
    /// burn THAT balance to the attacker. The venue/token binding refuses it.
    function test_audit_BRIDGE_B_2_junkInputTokenCannotBurnResidentOft() public onSourceChain {
        uint256 B = 100e18;
        MockNativeOFT T = new MockNativeOFT();
        T.mint(address(lzOut), B); // resident stray balance

        Order memory src = _srcOrder(1, 500e18, B, address(lzOut), _lzSpecFor(address(T), address(tA)));
        _wireSourceParties(address(lzOut), 500e18, B);
        bytes memory sig = _sign(src);

        vm.prank(solver);
        vm.expectRevert(LzOftBridgeOutModule.OftTokenMismatch.selector);
        settlement.fill(src, sig, 500e18);
        assertEq(T.balanceOf(address(lzOut)), B, "resident balance untouched");
        assertEq(T.sentCount(), 0, "nothing sent");
    }

    /// The correct binding still works for a native OFT (inputToken == oft).
    function test_audit_BRIDGE_B_2_nativeOftWithMatchingTokenStillSends() public onSourceChain {
        uint256 B = 100e18;
        MockNativeOFT T = new MockNativeOFT();
        T.mint(address(lzOut), B); // resident stray balance — must survive
        Order memory src = _blank(1);
        src.legsIn = _legsIn1(address(tC), 500e18);
        src.legsOut = _legsOut1(address(T), B);
        src.items = PackedEncode.items(_oneMake(address(lzOut), B, _lzSpecFor(address(T), address(T))));
        tC.mint(maker, 500e18);
        _makerApprove(address(settlement), address(tC), type(uint160).max);
        _makerApprove(address(lzOut), address(T), type(uint160).max);
        T.mint(solver, B);
        _solverApprove(address(settlement), address(T), type(uint160).max);
        bytes memory sig = _sign(src);
        vm.prank(solver);
        settlement.fill(src, sig, 500e18);
        assertEq(T.sentCount(), 1, "sent");
        assertEq(T.balanceOf(address(lzOut)), B, "resident balance still untouched");
    }

    function _oneMake(address module, uint256 amount, bytes memory data) internal pure returns (Item[] memory it) {
        it = new Item[](1);
        it[0] = Item({op: ItemOp.MAKE, module: module, amount: amount, recipient: address(0), data: data});
    }

    // ═══════════════════ X-DIFF-REST-3: fee sponsorship ═══════════════════

    function _sponsoredSpec(bytes32 dstHash, uint256 total) internal view returns (bytes memory) {
        return abi.encode(
            LzOftBridgeOutModule.LzSpec({
                oft: address(oft),
                inputToken: address(tA),
                dstEid: 30_101,
                dstChainId: DST_CHAIN,
                dstRecipient: address(inbox),
                maxSlippageBps: 50,
                maxNativeFee: 0.05 ether,
                feePayer: solver,
                extraOptions: "",
                dstOrderHash: dstHash,
                beneficiary: beneficiary,
                commitmentExpiry: uint32(block.timestamp) + COMMITMENT_EXPIRY_OFFSET,
                totalAmount: total
            })
        );
    }

    function _sponsor(uint256 allowance, uint256 perSend) internal {
        vm.deal(solver, 1 ether);
        vm.startPrank(solver);
        lzOut.topUpFor{value: 0.5 ether}(solver);
        lzOut.approveFeeSponsorship(maker, allowance, perSend);
        vm.stopPrank();
    }

    /// A filler splitting a sponsored order into slices used to charge the
    /// sponsor one messaging fee per slice. A sponsored send is the whole item.
    function test_audit_X_DIFF_REST_3_sponsoredSendCannotBeSliced() public onSourceChain {
        _sponsor(0.2 ether, 0.05 ether);
        Order memory src = _srcOrder(1, 500e18, 100e18, address(lzOut), _sponsoredSpec(keccak256("d"), 100e18));
        _wireSourceParties(address(lzOut), 500e18, 100e18);
        bytes memory sig = _sign(src);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(FullFillGuard.PartialFillUnsupported.selector, 5e18, 100e18));
        settlement.fill(src, sig, 25e18);
        assertEq(lzOut.feeAllowance(solver, maker), 0.2 ether, "sponsor not charged");

        vm.prank(solver);
        settlement.fill(src, sig, 500e18);
        assertEq(lzOut.feeAllowance(solver, maker), 0.19 ether, "charged exactly one message");
    }

    /// A sponsored send with no signed total fails closed.
    function test_audit_X_DIFF_REST_3_sponsoredSendWithoutTotalFailsClosed() public onSourceChain {
        _sponsor(0.2 ether, 0.05 ether);
        Order memory src = _srcOrder(1, 500e18, 100e18, address(lzOut), _sponsoredSpec(keccak256("d"), 0));
        _wireSourceParties(address(lzOut), 500e18, 100e18);
        bytes memory sig = _sign(src);
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(FullFillGuard.PartialFillUnsupported.selector, 100e18, 0));
        settlement.fill(src, sig, 500e18);
    }

    /// The sponsor's per-send cap binds whatever the maker's `maxNativeFee` says.
    function test_audit_X_DIFF_REST_3_perSendCapBinds() public onSourceChain {
        _sponsor(1 ether, 0.005 ether); // quote is 0.01
        Order memory src = _srcOrder(1, 500e18, 100e18, address(lzOut), _sponsoredSpec(keccak256("d"), 100e18));
        _wireSourceParties(address(lzOut), 500e18, 100e18);
        bytes memory sig = _sign(src);
        vm.prank(solver);
        vm.expectRevert(LzOftBridgeOutModule.FeeNotSponsored.selector);
        settlement.fill(src, sig, 500e18);
    }

    /// Relative adjustments avoid the absolute-set approve race.
    function test_audit_X_DIFF_REST_3_increaseDecreaseSponsorship() public {
        vm.startPrank(solver);
        lzOut.approveFeeSponsorship(maker, 0.03 ether, 0.01 ether);
        lzOut.increaseFeeSponsorship(maker, 0.02 ether);
        assertEq(lzOut.feeAllowance(solver, maker), 0.05 ether);
        lzOut.decreaseFeeSponsorship(maker, 0.01 ether);
        assertEq(lzOut.feeAllowance(solver, maker), 0.04 ether);
        lzOut.decreaseFeeSponsorship(maker, 1 ether);
        assertEq(lzOut.feeAllowance(solver, maker), 0, "floors at zero");
        assertEq(lzOut.maxFeePerSend(solver, maker), 0.01 ether, "cap kept");
        vm.stopPrank();
    }

    // ═══════════════════ PRICE-2.v2 / X-ARITH-2: Across slices ═══════════════════

    function _acrossSpec(bytes32 dstHash, address recipient, int8 scaling, uint16 feeBps, uint256 total)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            AcrossBridgeOutModule.AcrossSpec({
                inputToken: address(tA),
                outputToken: address(tA),
                dstChainId: DST_CHAIN,
                dstRecipient: recipient,
                exclusiveRelayer: address(0),
                maxRelayFeeBps: feeBps,
                dstScalingFactor: scaling,
                fillDeadlineOffset: 2 hours,
                exclusivityOffset: 0,
                dstOrderHash: dstHash,
                beneficiary: beneficiary,
                commitmentExpiry: uint32(block.timestamp) + COMMITMENT_EXPIRY_OFFSET,
                totalAmount: total
            })
        );
    }

    /// A filler can no longer carve an unrelayable dust slice out of an
    /// inbox-committed Across order (the 0.1% slice of the finding).
    function test_audit_PRICE_2_v2_inboxRoute_dustSliceRejected() public onSourceChain {
        uint256 S = 60_000e18;
        Order memory src =
            _srcOrder(1, 20e18, S, address(acrossOut), _acrossSpec(keccak256("H"), address(inbox), 0, 10, S));
        _wireSourceParties(address(acrossOut), 20e18, S);
        bytes memory sig = _sign(src);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(FullFillGuard.PartialFillUnsupported.selector, 60e18, S));
        settlement.fill(src, sig, 0.02e18);
        assertEq(spokePool.depositCount(), 0, "no deposit made");

        vm.prank(solver);
        settlement.fill(src, sig, 20e18);
        assertEq(spokePool.depositCount(), 1, "one whole deposit");
        assertEq(spokePool.depositAt(0).outputAmount, S - (S * 10) / 10_000, "the whole-order floor");
    }

    /// An inbox-committed spec with no signed total fails closed.
    function test_audit_PRICE_2_v2_inboxRouteWithoutTotalFailsClosed() public onSourceChain {
        Order memory src =
            _srcOrder(1, 500e18, 100e18, address(acrossOut), _acrossSpec(keccak256("H"), address(inbox), 0, 10, 0));
        _wireSourceParties(address(acrossOut), 500e18, 100e18);
        bytes memory sig = _sign(src);
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(FullFillGuard.PartialFillUnsupported.selector, 100e18, 0));
        settlement.fill(src, sig, 500e18);
    }

    /// A funnel deposit (no commitment) may still partial-fill when its maker
    /// leaves `totalAmount` at zero.
    function test_audit_PRICE_2_v2_funnelRoute_partialStillAllowed() public onSourceChain {
        Order memory src =
            _srcOrder(1, 500e18, 100e18, address(acrossOut), _acrossSpec(bytes32(0), address(0xF0), 0, 10, 0));
        _wireSourceParties(address(acrossOut), 500e18, 100e18);
        bytes memory sig = _sign(src);
        vm.startPrank(solver);
        settlement.fill(src, sig, 250e18);
        settlement.fill(src, sig, 250e18);
        vm.stopPrank();
        assertEq(spokePool.depositCount(), 2, "two funnel slices");
    }

    /// X-ARITH-2: 18 → 6 decimals (`dstScalingFactor = -12`). Three uneven slices
    /// used to floor to 2_999_998 against a 3_000_000 anchor. Now the slice is
    /// refused and the single deposit carries exactly the whole-order floor.
    function test_audit_X_ARITH_2_negativeScaling_slicesRejected_fullFillHitsAnchor() public {
        uint256 S = 3e18;
        uint256 anchor = 3_000_000;
        Order memory dst = _dstOrder(1, anchor, OUT);
        bytes32 h = _hashOrder(dst);
        Order memory src = _srcOrder(1, S, S, address(acrossOut), _acrossSpec(h, address(inbox), -12, 0, S));
        _wireSourceParties(address(acrossOut), S, S);

        vm.chainId(SRC_CHAIN);
        bytes memory sig = _sign(src);
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(FullFillGuard.PartialFillUnsupported.selector, 1e18 - 1, S));
        settlement.fill(src, sig, 1e18 - 1);
        vm.prank(solver);
        settlement.fill(src, sig, S);
        vm.chainId(DST_CHAIN);

        assertEq(spokePool.depositAt(0).outputAmount, anchor, "exactly the anchor");
        spokePool.relay(0);
        inbox.activate(dst, beneficiary); // not Underfunded
        assertTrue(settlement.orderApproved(address(inbox), h));
    }

    // ═══════════════════ BRIDGE-B-6: CCTP V2 ═══════════════════

    /// The module now speaks the V2 TokenMessenger (V1 halts 2026-12-01): seven
    /// arguments, a maker-bounded `maxFee`, the finality threshold, and an open
    /// `destinationCaller` so the solver can submit the mint.
    function test_audit_BRIDGE_B_6_cctpV2Burn() public onSourceChain {
        MockTokenMessenger messenger = new MockTokenMessenger();
        CctpBridgeOutModule cctpOut = new CctpBridgeOutModule(address(permit3), address(settlement), address(messenger));
        bytes memory spec = abi.encode(
            CctpBridgeOutModule.CctpSpec({
                inputToken: address(tA),
                dstChainId: DST_CHAIN,
                dstDomain: 3,
                dstRecipient: address(0xF0AAE1),
                maxFeeBps: 5,
                minFinalityThreshold: 1000
            })
        );
        Order memory src = _srcOrder(2, 500e18, 100e18, address(cctpOut), spec);
        _wireSourceParties(address(cctpOut), 500e18, 100e18);
        bytes memory sig = _sign(src);

        vm.expectEmit(true, true, true, true, address(cctpOut));
        emit CctpBridgeOutModule.CctpBurn(3, address(0xF0AAE1), address(tA), 100e18, 0.05e18, 1000);
        vm.prank(solver);
        settlement.fill(src, sig, 500e18);

        MockTokenMessenger.Burn memory b = messenger.burnAt(0);
        assertEq(b.amount, 100e18);
        assertEq(b.maxFee, 0.05e18, "5 bps of the slice");
        assertEq(b.minFinalityThreshold, 1000, "Fast transfer");
        assertEq(b.destinationCaller, bytes32(0), "anyone may submit the mint");
        assertEq(tA.balanceOf(address(cctpOut)), 0, "module ends empty");
    }
}
