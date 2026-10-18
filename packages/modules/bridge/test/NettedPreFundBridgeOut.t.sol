// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";

import {Order, Item, ItemOp, LegIn, LegOut, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";

import {AcrossBridgeOutModule} from "../src/out/AcrossBridgeOutModule.sol";
import {CctpBridgeOutModule} from "../src/out/CctpBridgeOutModule.sol";
import {LzOftBridgeOutModule} from "../src/out/LzOftBridgeOutModule.sol";
import {MockSpokePool, MockOFT, MockTokenMessenger} from "./shared/Mocks.t.sol";
import {BridgeTestBase} from "./shared/BridgeTestBase.t.sol";

/// @title NettedPreFundBridgeOutTest
/// @notice The PRE-FUNDED bridge-out branches on the NETTED path (`matchSettle`,
///         review 2026-10-18 M-6 style). The counterparty is a CoW order that sells
///         exactly what the bridging makers buy, so the solver fronts NOTHING — no
///         token inventory, no native float, no flash — and every maker grants the
///         bridge module nothing.
///
///         What the netted path adds over `fill` is that the SOLVER writes the
///         schedule. Between a maker's DELIVER and its ITEM the shared module can
///         hold other orders' in-flight deliveries; these tests pin that
///
///           • interleaved (DELIVER A, DELIVER B, ITEM B, ITEM A): each item bridges
///             exactly its own core-sized delivery and residue stays put;
///           • an item scheduled before its OWN order's DELIVER fails closed
///             (`ForLegInvalid`) even with a sibling's delivery parked on the module;
///           • the LayerZero fee comes from a wrapped-native leg the CoW side sells,
///             and an out-of-order schedule (send before fee credit) fails closed.
contract NettedPreFundBridgeOutTest is BridgeTestBase {
    uint256 bobPk = 0xB0B;
    address bob = vm.addr(bobPk);
    uint256 carolPk = 0xCA201;
    address carol = vm.addr(carolPk);

    // Unequal on purpose, so a mix-up between the two makers shows in every assert.
    uint256 constant PAY_A = 500e18;
    uint256 constant OUT_A = 100e18;
    uint256 constant PAY_B = 300e18;
    uint256 constant OUT_B = 40e18;
    uint256 constant RESIDUE = 7e18;
    uint256 constant FEE_BUDGET = 0.03 ether;
    uint256 constant LZ_FEE = 0.01 ether;

    CctpBridgeOutModule cctpOut;
    MockTokenMessenger messenger;

    function setUp() public override {
        super.setUp();
        messenger = new MockTokenMessenger();
        cctpOut = new CctpBridgeOutModule(address(permit3), address(settlement), address(messenger));
        vm.label(bob, "bob");
        vm.label(carol, "carol");
    }

    // ──────────────────── builders ────────────────────

    function _forLeg(address token, uint256 j) internal pure returns (uint256) {
        return (uint256(5) << 253) | (uint256(uint160(token)) << 16) | j;
    }

    function _step(uint256 kind, uint256 a, uint256 b) internal pure returns (uint256) {
        return MatchStep.pack(kind, a, b);
    }

    function _approveSettlement(address who, address token) internal {
        vm.startPrank(who);
        MockERC20(token).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), token, type(uint160).max, 0);
        vm.stopPrank();
    }

    function _acrossData(uint256 total) internal view returns (bytes memory) {
        return abi.encode(
            _forLeg(address(tA), 0),
            AcrossBridgeOutModule.AcrossSpec({
                inputToken: address(tA),
                outputToken: address(tA),
                dstChainId: DST_CHAIN,
                dstRecipient: address(inbox),
                exclusiveRelayer: address(0),
                maxRelayFeeBps: 100,
                dstScalingFactor: 0,
                fillDeadlineOffset: 2 hours,
                exclusivityOffset: 0,
                dstOrderHash: keccak256(abi.encode("dst", total)),
                beneficiary: beneficiary,
                commitmentExpiry: uint32(block.timestamp) + COMMITMENT_EXPIRY_OFFSET,
                totalAmount: total
            })
        );
    }

    /// @dev `who` pays `pay` tC; `out` tA is delivered to `module` and bridged by one
    ///      pre-funded item. Nothing granted to the module.
    function _bridger(address who, uint256 nonce, uint256 pay, uint256 out, address module, bytes memory data)
        internal
        view
        returns (Order memory o)
    {
        o = _blank(nonce);
        o.maker = who;
        o.legsIn = PackedEncode.oneLegIn(address(tC), pay, 0);
        o.legsOut = PackedEncode.oneLegOut(address(tA), out, 0, module);
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.MAKE, module: module, amount: 0, recipient: address(0), data: data});
        o.items = PackedEncode.items(items);
    }

    /// @dev Carol, the CoW side: sells `tA` (and optionally wrapped native) for tC.
    function _carol(uint256 nonce, uint256 sellA, uint256 sellWeth, uint256 wantC)
        internal
        view
        returns (Order memory o)
    {
        o = _blank(nonce);
        o.maker = carol;
        if (sellWeth == 0) {
            o.legsIn = PackedEncode.oneLegIn(address(tA), sellA, 0);
        } else {
            LegIn[] memory ins = new LegIn[](2);
            ins[0] = LegIn(address(tA), sellA, 0);
            ins[1] = LegIn(address(weth), sellWeth, 0);
            o.legsIn = PackedEncode.legsIn(ins);
        }
        o.legsOut = PackedEncode.oneLegOut(address(tC), wantC, 0, address(0));
    }

    function _plan(Order[] memory orders, uint256[] memory pks, uint256[] memory fills, uint256[] memory schedule)
        internal
        view
        returns (MatchPlan memory p)
    {
        bytes[] memory sigs = new bytes[](orders.length);
        for (uint256 i; i < orders.length; i++) {
            sigs[i] = _signWith(orders[i], pks[i]);
        }
        p = MatchPlan({
            orders: orders,
            sigs: sigs,
            fillAmounts: fills,
            takerDatas: new bytes[](0),
            schedule: schedule,
            callTargets: new address[](0),
            callDatas: new bytes[](0),
            profitRecipient: address(0)
        });
    }

    function _match(MatchPlan memory p) internal onSourceChain {
        vm.prank(solver);
        settlement.matchSettle(p);
    }

    function _expectMatchRevert(MatchPlan memory p, bytes memory err) internal onSourceChain {
        vm.expectRevert(err);
        vm.prank(solver);
        settlement.matchSettle(p);
    }

    function _assertZeroSolverCapital() internal view {
        assertEq(tA.balanceOf(solver) + tC.balanceOf(solver) + weth.balanceOf(solver), 0, "solver holds nothing");
        assertEq(solver.balance, 0, "solver fronted no native");
    }

    function _assertNoGrant(address who, address module) internal view {
        (uint160 amt,) = permit3.tokenAllowance(who, module, address(tA));
        assertEq(amt, 0, "maker granted the module nothing");
    }

    // ──────────────────── Across ────────────────────

    /// One bridging maker and the CoW side: PULL both, DELIVER the tA to the module,
    /// run the pre-funded deposit, pay Carol. Zero solver capital, zero maker grant.
    function _acrossPlan(uint256[] memory schedule) internal returns (MatchPlan memory) {
        tC.mint(maker, PAY_A);
        _approveSettlement(maker, address(tC));
        tA.mint(carol, OUT_A);
        _approveSettlement(carol, address(tA));
        Order[] memory orders = new Order[](2);
        orders[0] = _bridger(maker, 1, PAY_A, OUT_A, address(acrossOut), _acrossData(OUT_A));
        orders[1] = _carol(1, OUT_A, 0, PAY_A);
        uint256[] memory pks = new uint256[](2);
        pks[0] = makerPk;
        pks[1] = carolPk;
        uint256[] memory fills = new uint256[](2);
        fills[0] = PAY_A;
        fills[1] = OUT_A;
        return _signedPlan(orders, pks, fills, schedule);
    }

    function _signedPlan(Order[] memory orders, uint256[] memory pks, uint256[] memory fills, uint256[] memory s)
        internal
        onSourceChain
        returns (MatchPlan memory)
    {
        return _plan(orders, pks, fills, s);
    }

    function test_netted_across_preFund_zeroCapital() public {
        tA.mint(address(acrossOut), RESIDUE);
        uint256[] memory s = new uint256[](5);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.DELIVER, 0, 0);
        s[3] = _step(MatchStep.ITEM, 0, 0);
        s[4] = _step(MatchStep.DELIVER, 1, 0);
        _match(_acrossPlan(s));

        MockSpokePool.Deposit memory d = spokePool.depositAt(0);
        assertEq(d.inputAmount, OUT_A, "bridged exactly the delivery");
        assertEq(d.depositor, maker, "origin refunds to the maker");
        assertEq(tA.balanceOf(address(acrossOut)), RESIDUE, "module ends where it started");
        assertEq(tC.balanceOf(carol), PAY_A, "carol paid by the maker");
        assertEq(tA.balanceOf(maker), 0, "never transited the wallet");
        _assertZeroSolverCapital();
        _assertNoGrant(maker, address(acrossOut));
    }

    /// The item scheduled BEFORE its own order's DELIVER fails closed — the core's
    /// empty ledger refuses the leg reference although nothing else is in the way.
    function test_netted_across_itemBeforeOwnDeliver_failsClosed() public {
        tA.mint(address(acrossOut), OUT_A); // residue that would cover it
        uint256[] memory s = new uint256[](5);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.ITEM, 0, 0);
        s[3] = _step(MatchStep.DELIVER, 0, 0);
        s[4] = _step(MatchStep.DELIVER, 1, 0);
        _expectMatchRevert(_acrossPlan(s), abi.encodeWithSelector(Base.ForLegInvalid.selector));
    }

    /// Two bridging makers on one singleton, interleaved: DELIVER A, DELIVER B,
    /// ITEM B, ITEM A. While ITEM B runs the module holds residue + A's + B's
    /// deliveries; B bridges exactly OUT_B and A's delivery is still there for A.
    /// Then: ITEM B before DELIVER B, with A's delivery parked — refused.
    function _twoMakerPlan(uint256[] memory mid) internal returns (MatchPlan memory) {
        tC.mint(maker, PAY_A);
        tC.mint(bob, PAY_B);
        _approveSettlement(maker, address(tC));
        _approveSettlement(bob, address(tC));
        tA.mint(carol, OUT_A + OUT_B);
        _approveSettlement(carol, address(tA));

        Order[] memory orders = new Order[](3);
        orders[0] = _bridger(maker, 1, PAY_A, OUT_A, address(acrossOut), _acrossData(OUT_A));
        orders[1] = _bridger(bob, 1, PAY_B, OUT_B, address(acrossOut), _acrossData(OUT_B));
        orders[2] = _carol(1, OUT_A + OUT_B, 0, PAY_A + PAY_B);
        uint256[] memory pks = new uint256[](3);
        pks[0] = makerPk;
        pks[1] = bobPk;
        pks[2] = carolPk;
        uint256[] memory fills = new uint256[](3);
        fills[0] = PAY_A;
        fills[1] = PAY_B;
        fills[2] = OUT_A + OUT_B;
        uint256[] memory s = new uint256[](mid.length + 4);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.PULL, 2, 0);
        for (uint256 i; i < mid.length; i++) {
            s[3 + i] = mid[i];
        }
        s[s.length - 1] = _step(MatchStep.DELIVER, 2, 0);
        return _signedPlan(orders, pks, fills, s);
    }

    function test_netted_across_interleaved_eachBridgesExactlyItsOwn() public {
        tA.mint(address(acrossOut), RESIDUE);
        uint256[] memory mid = new uint256[](4);
        mid[0] = _step(MatchStep.DELIVER, 0, 0);
        mid[1] = _step(MatchStep.DELIVER, 1, 0);
        mid[2] = _step(MatchStep.ITEM, 1, 0); // reverse order on purpose
        mid[3] = _step(MatchStep.ITEM, 0, 0);
        _match(_twoMakerPlan(mid));

        assertEq(spokePool.depositCount(), 2, "two deposits");
        MockSpokePool.Deposit memory first = spokePool.depositAt(0);
        MockSpokePool.Deposit memory second = spokePool.depositAt(1);
        assertEq(first.depositor, bob, "B ran first");
        assertEq(first.inputAmount, OUT_B, "B bridged exactly its own delivery");
        assertEq(second.depositor, maker, "then A");
        assertEq(second.inputAmount, OUT_A, "A bridged exactly its own delivery");
        assertEq(tA.balanceOf(address(acrossOut)), RESIDUE, "residue untouched");
        _assertZeroSolverCapital();
        _assertNoGrant(maker, address(acrossOut));
        _assertNoGrant(bob, address(acrossOut));
    }

    function test_netted_across_itemBeforeOwnDeliver_withSiblingParked_refused() public {
        uint256[] memory mid = new uint256[](4);
        mid[0] = _step(MatchStep.DELIVER, 0, 0); // A's OUT_A now parked on the module
        mid[1] = _step(MatchStep.ITEM, 1, 0); //    B's item before B's delivery
        mid[2] = _step(MatchStep.DELIVER, 1, 0);
        mid[3] = _step(MatchStep.ITEM, 0, 0);
        _expectMatchRevert(_twoMakerPlan(mid), abi.encodeWithSelector(Base.ForLegInvalid.selector));
    }

    // ──────────────────── CCTP ────────────────────

    function test_netted_cctp_preFund_zeroCapital() public {
        tC.mint(maker, PAY_A);
        _approveSettlement(maker, address(tC));
        tA.mint(carol, OUT_A);
        _approveSettlement(carol, address(tA));
        address funnel = makeAddr("dstFunnel");
        bytes memory data = abi.encode(
            _forLeg(address(tA), 0),
            CctpBridgeOutModule.CctpSpec({
                inputToken: address(tA),
                dstChainId: DST_CHAIN,
                dstDomain: 3,
                dstRecipient: funnel,
                maxFeeBps: 0,
                minFinalityThreshold: 2000
            })
        );
        Order[] memory orders = new Order[](2);
        orders[0] = _bridger(maker, 1, PAY_A, OUT_A, address(cctpOut), data);
        orders[1] = _carol(1, OUT_A, 0, PAY_A);
        uint256[] memory pks = new uint256[](2);
        pks[0] = makerPk;
        pks[1] = carolPk;
        uint256[] memory fills = new uint256[](2);
        fills[0] = PAY_A;
        fills[1] = OUT_A;
        uint256[] memory s = new uint256[](5);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.DELIVER, 0, 0);
        s[3] = _step(MatchStep.ITEM, 0, 0);
        s[4] = _step(MatchStep.DELIVER, 1, 0);
        _match(_signedPlan(orders, pks, fills, s));

        assertEq(messenger.burnAt(0).amount, OUT_A, "burned exactly the delivery");
        assertEq(tA.balanceOf(address(cctpOut)), 0, "nothing stranded");
        _assertZeroSolverCapital();
        _assertNoGrant(maker, address(cctpOut));
    }

    // ──────────────────── LayerZero: pre-funded send, fee from legs ────────────────────

    /// The maker's order buys `[tA → lzOut, WETH → lzOut]` for tC; Carol sells both.
    /// Item 0 unwraps the WETH leg into the maker's fee credit, item 1 sends the tA
    /// leg and pays the fee from it. Nobody parks a native float: not the maker (no
    /// `topUpFor`), not the solver (no sponsorship).
    function _lzPlan(bool feeFirst) internal returns (MatchPlan memory) {
        tC.mint(maker, PAY_A);
        _approveSettlement(maker, address(tC));
        tA.mint(carol, OUT_A);
        _approveSettlement(carol, address(tA));
        vm.deal(carol, FEE_BUDGET);
        vm.prank(carol);
        weth.deposit{value: FEE_BUDGET}();
        _approveSettlement(carol, address(weth));

        Order memory a = _blank(1);
        a.legsIn = PackedEncode.oneLegIn(address(tC), PAY_A, 0);
        LegOut[] memory outs = new LegOut[](2);
        outs[0] = LegOut(address(tA), OUT_A, 0, address(lzOut));
        outs[1] = LegOut(address(weth), FEE_BUDGET, 0, address(lzOut));
        a.legsOut = PackedEncode.legsOut(outs);
        Item[] memory items = new Item[](2);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(lzOut),
            amount: 0,
            recipient: address(0),
            data: abi.encode(_forLeg(address(weth), 1) | (lzOut.OP_FEE_CREDIT() << 244))
        });
        items[1] = Item({
            op: ItemOp.MAKE,
            module: address(lzOut),
            amount: 0,
            recipient: address(0),
            data: abi.encode(
                _forLeg(address(tA), 0),
                LzOftBridgeOutModule.LzSpec({
                    oft: address(oft),
                    inputToken: address(tA),
                    dstEid: 30_101,
                    dstChainId: DST_CHAIN,
                    dstRecipient: address(inbox),
                    maxSlippageBps: 50,
                    maxNativeFee: 0.05 ether,
                    feePayer: maker,
                    extraOptions: hex"0003",
                    dstOrderHash: keccak256("d"),
                    beneficiary: beneficiary,
                    commitmentExpiry: uint32(block.timestamp) + COMMITMENT_EXPIRY_OFFSET,
                    totalAmount: OUT_A
                })
            )
        });
        a.items = PackedEncode.items(items);

        Order[] memory orders = new Order[](2);
        orders[0] = a;
        orders[1] = _carol(1, OUT_A, FEE_BUDGET, PAY_A);
        uint256[] memory pks = new uint256[](2);
        pks[0] = makerPk;
        pks[1] = carolPk;
        uint256[] memory fills = new uint256[](2);
        fills[0] = PAY_A;
        fills[1] = OUT_A;
        uint256[] memory s = new uint256[](7);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.PULL, 1, 1);
        s[3] = _step(MatchStep.DELIVER, 0, 0);
        s[4] = _step(MatchStep.ITEM, 0, feeFirst ? 0 : 1);
        s[5] = _step(MatchStep.ITEM, 0, feeFirst ? 1 : 0);
        s[6] = _step(MatchStep.DELIVER, 1, 0);
        return _signedPlan(orders, pks, fills, s);
    }

    function test_netted_lz_preFund_feeFromLegs_zeroCapital() public {
        assertEq(address(lzOut).balance, 0, "no native float before the plan");
        _match(_lzPlan(true));

        MockOFT.Sent memory sent = oft.sentAt(0);
        assertEq(sent.amountLD, OUT_A, "bridged exactly the delivery");
        assertEq(sent.nativeFee, LZ_FEE, "fee paid from the delivered leg");
        assertEq(sent.refundAddress, maker, "self-paid");
        assertEq(lzOut.nativeCredit(maker), FEE_BUDGET - LZ_FEE, "unused budget is the maker's credit");
        assertEq(address(lzOut).balance, FEE_BUDGET - LZ_FEE, "native held == ledger");
        assertEq(weth.balanceOf(address(lzOut)), 0, "wrapped leg fully unwrapped");
        assertEq(tA.balanceOf(address(lzOut)), 0, "nothing stranded");
        assertEq(tC.balanceOf(carol), PAY_A, "carol paid");
        _assertZeroSolverCapital();
        _assertNoGrant(maker, address(lzOut));
    }

    /// The solver schedules the send before the fee credit: the maker has no credit
    /// yet, so the send fails closed instead of drawing anyone else's.
    function test_netted_lz_sendBeforeFeeCredit_failsClosed() public {
        address other = makeAddr("other");
        vm.deal(other, 1 ether);
        vm.prank(other);
        lzOut.topUpFor{value: 1 ether}(other);
        _expectMatchRevert(
            _lzPlan(false), abi.encodeWithSelector(LzOftBridgeOutModule.InsufficientNativeCredit.selector)
        );
    }
}
