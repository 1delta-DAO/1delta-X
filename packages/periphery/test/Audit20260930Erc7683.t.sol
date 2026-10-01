// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {Order, Item, ItemOp, LegOut} from "@core/settlement/Structs.sol";
import {Base} from "@core/settlement/Base.sol";
import {OrderGates} from "@core/settlement/OrderGates.sol";
import {OrderHash} from "@core/settlement/OrderHash.sol";
import {OrderState} from "@core/settlement/OrderState.sol";
import {Proportional} from "@core/settlement/Proportional.sol";
import {IPriceModule} from "@core/interfaces/IPriceModule.sol";
import {DestinationSettler7683} from "@periphery/DestinationSettler7683.sol";
import {OriginSettler7683} from "@periphery/OriginSettler7683.sol";
import {SettlementLens} from "@periphery/SettlementLens.sol";
import {
    FillBounds,
    FillerData,
    FillPayload,
    GaslessCrossChainOrder,
    OnchainCrossChainOrder,
    Order7683,
    OrderPayload,
    ResolvedCrossChainOrder
} from "@periphery/Erc7683.sol";
import {ProportionalSweepModule} from "@modules/transfer/src/ProportionalSweepModule.sol";

import {MockSettlementBase, MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

/// @dev Maker-chosen price module that quotes the floor (`end`) to every filler
///      except the 7683 destination adapter, which it quotes at `start`.
contract AdapterKeyedPriceModule20260930 is IPriceModule {
    address public immutable ADAPTER;

    constructor(address adapter) {
        ADAPTER = adapter;
    }

    function bump(bytes32, address, address filler, uint256, uint256, uint256, bytes calldata, bytes calldata, bytes calldata)
        external
        view
        override
        returns (uint256)
    {
        return filler == ADAPTER ? 0 : 10_000;
    }
}

/// @dev Maker-chosen price module that detects a SIMULATION: the floor at gas price
///      0 (a default `eth_call`), the signed `start` in any real transaction — so even
///      a resolve priced for the adapter itself quotes a price the fill will not see.
contract SimulationAwarePriceModule20260930 is IPriceModule {
    function bump(bytes32, address, address, uint256, uint256, uint256, bytes calldata, bytes calldata, bytes calldata)
        external
        view
        override
        returns (uint256)
    {
        return tx.gasprice == 0 ? 10_000 : 0;
    }
}

/// @dev A token that rejects zero-value transfers (several real tokens do).
contract ZeroRejectToken20260930 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(amount != 0, "zero transfer");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(amount != 0, "zero transfer");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @title Audit 2026-09-30 — ERC-7683 adapter remediation
/// @notice Regression tests for PERIPH-1 (no filler bound), PERIPH-2 / A-FLEX-1 /
///         CORE-FILLER-1 (quoted for a filler the instruction never fills as),
///         PERIPH-2.v2 (pre-funded leg under a live override), PERIPH-3 (maker-published
///         any-size sentinel on a Proportional order), PERIPH-4 (SETTLE-item receipts
///         stranded in the adapter), PERIPH-5 (reserved nonce broadcast), PERIPH-6
///         (unsigned envelope), PERIPH-7 / X-TOKENS-9 (zero legs, open filler slot).
///         Each starts from the audit's PoC and asserts the SAFE end state.
contract Audit20260930Erc7683Test is MockSettlementBase {
    uint256 constant IN_AMT = 100e18;
    uint256 constant OUT_END = 250e18;
    uint256 constant OUT_START = 25_000e18;
    address constant DEAD = address(0xdEaD);

    OriginSettler7683 origin;
    DestinationSettler7683 destination;

    bytes32 constant OPEN_SIG = keccak256(
        "Open(bytes32,(address,uint256,uint32,uint32,bytes32,(bytes32,uint256,bytes32,uint256)[],(bytes32,uint256,bytes32,uint256)[],(uint64,bytes32,bytes)[]))"
    );

    function setUp() public override {
        super.setUp();
        destination = new DestinationSettler7683(address(settlement), address(lens));
        origin = new OriginSettler7683(address(settlement), address(lens), address(destination));
        tA.mint(maker, IN_AMT);
        _makerApprove(address(settlement), address(tA), type(uint160).max);
    }

    // ───────────────────────── helpers ─────────────────────────

    function _onchain(OrderPayload memory p) internal view returns (OnchainCrossChainOrder memory) {
        return OnchainCrossChainOrder({
            fillDeadline: uint32(block.timestamp + 2 hours),
            orderDataType: OrderHash.ORDER_TYPEHASH,
            orderData: abi.encode(p)
        });
    }

    function _gasless(OrderPayload memory p) internal view returns (GaslessCrossChainOrder memory) {
        return GaslessCrossChainOrder({
            originSettler: address(origin),
            user: p.order.maker,
            nonce: p.order.nonce,
            originChainId: block.chainid,
            openDeadline: uint32(block.timestamp + 1 hours),
            fillDeadline: uint32(block.timestamp + 2 hours),
            orderDataType: OrderHash.ORDER_TYPEHASH,
            orderData: abi.encode(p)
        });
    }

    function _payload(Order memory o, uint256 fillAmount) internal view returns (OrderPayload memory) {
        return OrderPayload({order: o, signature: _sign(o), fillAmount: fillAmount, takerData: ""});
    }

    /// @dev SELL 100 A for a decaying B leg, start 25,000 → end 250.
    function _decayingSell(uint256 nonce) internal view returns (Order memory o) {
        o = _blank(nonce);
        o.legsIn = PackedEncode.oneLegIn(address(tA), IN_AMT, 0);
        o.legsOut = PackedEncode.oneLegOut(address(tB), OUT_START, OUT_END, address(0));
    }

    function _window(Order memory o, address exFiller, uint16 overrideBps) internal pure {
        o.exclusiveFiller = exFiller;
        _setExclusivityEnd(o, _expiry(o));
        o.params = overrideBps;
    }

    /// @dev Relayer broadcast; returns what the `Open` event told the solver fleet.
    function _openFor(OrderPayload memory p) internal returns (ResolvedCrossChainOrder memory r) {
        vm.recordLogs();
        vm.prank(address(0xBEEF));
        origin.openFor(_gasless(p), p.signature, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(origin) && logs[i].topics[0] == OPEN_SIG) {
                r = abi.decode(logs[i].data, (ResolvedCrossChainOrder));
                found = true;
            }
        }
        assertTrue(found, "Open emitted");
    }

    function _bounds(uint256 q, uint256 maxPaid0, uint256 minReceived0) internal pure returns (FillBounds memory b) {
        b.quotedDelta = q;
        b.maxPaid = new uint256[](1);
        b.maxPaid[0] = maxPaid0;
        b.minReceived = new uint256[](1);
        b.minReceived[0] = minReceived0;
    }

    function _fundSolver(MockERC20 t, uint256 amt) internal {
        t.mint(solver, amt);
        vm.prank(solver);
        t.approve(address(destination), type(uint256).max); // a standing approval
    }

    // ═══════════════ PERIPH-1: the fill is held to the published bound ═══════════════

    /// @dev PoC (a): priority auction, scale 1 wei. The resolve (gas price 0) quotes
    ///      `end`; the solver's 1 gwei tip clears at `start`. It used to pull 25,000 B
    ///      from the standing approval. Now the published bound reverts the fill.
    function test_audit_PERIPH_1_priorityAuction_fillAboveQuote_reverts() public {
        Order memory o = _decayingSell(1);
        o.timing |= uint256(1) << 103; // priority auction
        o.params = uint256(1) << 96; // priorityScale = 1 wei
        OrderPayload memory p = _payload(o, IN_AMT);
        _fundSolver(tB, OUT_START);

        vm.fee(0);
        vm.txGasPrice(0);
        vm.prank(solver);
        ResolvedCrossChainOrder memory r = origin.resolve(_onchain(p));
        assertEq(r.maxSpent[0].amount, OUT_END, "quote at gas price 0 = end");

        vm.txGasPrice(1 gwei);
        bytes memory originData = r.fillInstructions[0].originData;
        vm.prank(solver, solver);
        vm.expectRevert(abi.encodeWithSelector(DestinationSettler7683.BoundExceeded.selector, true, 0));
        destination.fill(r.orderId, originData, "");
        assertEq(tB.balanceOf(solver), OUT_START, "solver inventory untouched");
        assertEq(tB.balanceOf(maker), 0, "maker extracted nothing");
    }

    /// @dev The other side of the same rule: a priority BIDDER moves the price itself,
    ///      so it states its own bound in `fillerData` and the fill goes through at it.
    function test_audit_PERIPH_1_priorityBidder_ownBoundsFill() public {
        Order memory o = _decayingSell(2);
        o.timing |= uint256(1) << 103;
        o.params = uint256(1) << 96;
        OrderPayload memory p = _payload(o, IN_AMT);
        _fundSolver(tB, OUT_START);
        vm.fee(0);
        vm.txGasPrice(0);
        ResolvedCrossChainOrder memory r = origin.resolve(_onchain(p));

        vm.txGasPrice(1 gwei);
        bytes memory fd = abi.encode(FillerData({payTo: address(0), minBumpBps: 0, bounds: _bounds(IN_AMT, OUT_START, IN_AMT)}));
        bytes memory originData = r.fillInstructions[0].originData;
        vm.prank(solver, solver);
        destination.fill(r.orderId, originData, fd);
        assertEq(tB.balanceOf(maker), OUT_START, "filled at the bidder's own bound");
        assertEq(tA.balanceOf(solver), IN_AMT, "and paid the input");
    }

    /// @dev PoC (b), sharpened: a module that answers the floor in a simulation and
    ///      `start` in a real transaction defeats even a quote priced for the adapter.
    ///      The bound is what stops it.
    function test_audit_PERIPH_1_simulationAwareModule_reverts() public {
        Order memory o = _decayingSell(3);
        o.pricingModule = address(new SimulationAwarePriceModule20260930());
        OrderPayload memory p = _payload(o, IN_AMT);
        _fundSolver(tB, OUT_START);

        vm.txGasPrice(0);
        ResolvedCrossChainOrder memory r = origin.resolve(_onchain(p));
        assertEq(r.maxSpent[0].amount, OUT_END, "simulated quote = end");

        vm.txGasPrice(1 gwei);
        bytes memory originData = r.fillInstructions[0].originData;
        vm.prank(solver, solver);
        vm.expectRevert(abi.encodeWithSelector(DestinationSettler7683.BoundExceeded.selector, true, 0));
        destination.fill(r.orderId, originData, "");
        assertEq(tB.balanceOf(solver), OUT_START, "solver inventory untouched");
    }

    /// @dev PoC (b) as written: a module keyed on `filler == adapter`. The quote is now
    ///      priced FOR the adapter, so it publishes the price the fill really charges,
    ///      and the fill never charges more than the published `maxSpent`.
    function test_audit_PERIPH_1_adapterKeyedModule_quotedAtItsRealPrice() public {
        Order memory o = _decayingSell(4);
        o.pricingModule = address(new AdapterKeyedPriceModule20260930(address(destination)));
        OrderPayload memory p = _payload(o, IN_AMT);
        _fundSolver(tB, OUT_START);

        vm.prank(solver);
        ResolvedCrossChainOrder memory r = origin.resolve(_onchain(p));
        assertEq(r.maxSpent[0].amount, OUT_START, "the adapter's price is what is published");

        uint256 before = tB.balanceOf(solver);
        bytes memory originData = r.fillInstructions[0].originData;
        vm.prank(solver, solver);
        destination.fill(r.orderId, originData, "");
        assertLe(before - tB.balanceOf(solver), r.maxSpent[0].amount, "never above maxSpent");
    }

    /// @dev The PoC's "a solver cannot pass a bound" contrast, inverted: a tighter
    ///      `maxPaid` and a `minBumpBps` floor in `fillerData` are both enforced.
    function test_audit_PERIPH_1_fillerDataBoundsAndFloorEnforced() public {
        Order memory o = _decayingSell(5);
        o.timing |= uint256(1) << 103;
        o.params = uint256(1) << 96;
        OrderPayload memory p = _payload(o, IN_AMT);
        _fundSolver(tB, OUT_START);
        vm.fee(0);
        vm.txGasPrice(0);
        ResolvedCrossChainOrder memory r = origin.resolve(_onchain(p));
        bytes memory originData = r.fillInstructions[0].originData;

        // Tighter than the published bound: refused even at the quoted price.
        bytes memory tight =
            abi.encode(FillerData({payTo: address(0), minBumpBps: 0, bounds: _bounds(IN_AMT, OUT_END - 1, 0)}));
        vm.prank(solver, solver);
        vm.expectRevert(abi.encodeWithSelector(DestinationSettler7683.BoundExceeded.selector, true, 0));
        destination.fill(r.orderId, originData, tight);

        // The price floor reaches `fillUpTo`: a 1 gwei bid prices at bump 0, below a
        // floor of 10,000 (the no-bid price), so the settlement refuses it.
        vm.txGasPrice(1 gwei);
        bytes memory floored = abi.encode(
            FillerData({payTo: address(0), minBumpBps: 10_000, bounds: _bounds(0, 0, 0)}) // quotedDelta 0 = published
        );
        vm.prank(solver, solver);
        vm.expectRevert(OrderState.BumpTooLow.selector);
        destination.fill(r.orderId, originData, floored);
    }

    // ═══════════ PERIPH-2 / A-FLEX-1 / CORE-FILLER-1: quoted as the real filler ═══════════

    /// @dev PoC 1 (BUY, soft, override 10_000). The quote used to promise 100 A for
    ///      0xdEaD's price; the instruction paid the solver 0. Now the published
    ///      `minReceived` IS what the instruction pays, so nobody is misled — and a
    ///      solver that insists on 100 A is refused rather than robbed.
    function test_audit_PERIPH_2_buySoftMaxOverride_quoteIsWhatTheFillPays() public {
        Order memory o = _buyOrder(10, address(tA), address(tB), IN_AMT, 0, OUT_END);
        _window(o, DEAD, 10_000);
        OrderPayload memory p = _payload(o, OUT_END);

        ResolvedCrossChainOrder memory r = _openFor(p);
        (, uint256[] memory rcv, uint256[] memory paid) = lens.previewFill(o, OUT_END, address(destination), "");
        assertEq(r.minReceived[0].amount, rcv[0], "minReceived = the instruction's real receipt");
        assertEq(r.minReceived[0].amount, 0, "which here is nothing - published, not hidden");
        assertEq(r.maxSpent[0].amount, paid[0], "maxSpent = the instruction's real charge");
        assertEq(r.minReceived[0].recipient, bytes32(0), "filler slot open (PERIPH-7)");

        // A solver that wants the 100 A the old quote promised states it, and is refused.
        _fundSolver(tB, OUT_END);
        bytes memory want = abi.encode(
            FillerData({payTo: address(0), minBumpBps: 0, bounds: _bounds(OUT_END, type(uint256).max, IN_AMT)})
        );
        bytes memory originData = r.fillInstructions[0].originData;
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(DestinationSettler7683.BoundExceeded.selector, false, 0));
        destination.fill(r.orderId, originData, want);
        assertEq(tB.balanceOf(solver), OUT_END, "solver kept its output");
    }

    /// @dev PoC 2 (SELL, soft, override 10_000): the 2x charge is now the published
    ///      `maxSpent`, and the fill never exceeds it. A solver holding the OLD
    ///      premium-free bound is refused instead of charged double.
    function test_audit_PERIPH_2_sellSoftMaxOverride_chargeNeverExceedsQuote() public {
        Order memory o = _plainOrder(11, address(tA), address(tB), IN_AMT, OUT_END);
        _window(o, DEAD, 10_000);
        OrderPayload memory p = _payload(o, IN_AMT);
        ResolvedCrossChainOrder memory r = _openFor(p);
        assertEq(r.maxSpent[0].amount, 2 * OUT_END, "the premium is quoted");
        _fundSolver(tB, 2 * OUT_END);

        bytes memory stale =
            abi.encode(FillerData({payTo: address(0), minBumpBps: 0, bounds: _bounds(IN_AMT, OUT_END, IN_AMT)}));
        bytes memory originData = r.fillInstructions[0].originData;
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(DestinationSettler7683.BoundExceeded.selector, true, 0));
        destination.fill(r.orderId, originData, stale);

        uint256 before = tB.balanceOf(solver);
        vm.prank(solver);
        destination.fill(r.orderId, originData, "");
        assertEq(before - tB.balanceOf(solver), r.maxSpent[0].amount, "charged exactly maxSpent");
    }

    /// @dev PoC 3 (honest maker, 1% soft, the solver is the named filler): resolve
    ///      used to omit the premium the instruction pays; it is quoted now.
    function test_audit_PERIPH_2_honestSoft_premiumQuoted() public {
        Order memory o = _plainOrder(12, address(tA), address(tB), IN_AMT, OUT_END);
        _window(o, solver, 100);
        OrderPayload memory p = _payload(o, IN_AMT);
        vm.prank(address(0x0DD));
        ResolvedCrossChainOrder memory r = origin.resolve(_onchain(p));
        assertEq(r.maxSpent[0].amount, OUT_END * 10_100 / 10_000, "premium in the quote");
        _fundSolver(tB, 2 * OUT_END);
        uint256 before = tB.balanceOf(solver);
        bytes memory originData = r.fillInstructions[0].originData;
        vm.prank(solver);
        destination.fill(r.orderId, originData, "");
        assertEq(before - tB.balanceOf(solver), r.maxSpent[0].amount, "resolve == fill");
    }

    /// @dev PoC 4 (HARD window): the instruction can never execute in-window, so the
    ///      order is no longer broadcast or quoted there.
    function test_audit_PERIPH_2_hardWindow_notBroadcast() public {
        Order memory o = _plainOrder(13, address(tA), address(tB), IN_AMT, OUT_END);
        _window(o, solver, 0);
        OrderPayload memory p = _payload(o, IN_AMT);
        GaslessCrossChainOrder memory g = _gasless(p);
        vm.expectRevert(OrderGates.NotExclusiveFiller.selector);
        origin.openFor(g, p.signature, "");
        vm.expectRevert(OrderGates.NotExclusiveFiller.selector);
        origin.resolve(_onchain(p));
    }

    // ═══════════ PERIPH-2.v2: pre-funded leg under a live soft override ═══════════

    /// @dev A BUY whose output leg funds a PRE-FUND MAKE (descriptor `>> 253 == 5`)
    ///      under a soft window: the core refuses every in-window outsider with
    ///      `ForLegInvalid`, deep in item execution. The lens now mirrors it, so the
    ///      origin refuses to broadcast an order every 7683 fill of which reverts.
    function test_audit_PERIPH_2_v2_preFundUnderSoftOverride_refused() public {
        address module = address(0x5EED); // the descriptor's module; never reached
        Order memory o = _buyOrder(14, address(tA), address(tB), IN_AMT, IN_AMT + 10e18, 10e18);
        o.legsOut = PackedEncode.oneLegOut(address(tB), 10e18, 0, module);
        uint256 desc = (uint256(5) << 253) | (uint256(uint160(address(tB))) << 16); // pre-fund, leg 0
        Item[] memory its = new Item[](1);
        its[0] = Item({op: ItemOp.MAKE, module: module, amount: 0, recipient: address(0), data: abi.encode(desc)});
        o.items = PackedEncode.items(its);
        _window(o, DEAD, 50);

        vm.expectRevert(Base.ForLegInvalid.selector);
        lens.previewFill(o, 10e18, address(destination), "");
        lens.previewFill(o, 10e18, DEAD, ""); // the named filler is not refused

        OrderPayload memory p = _payload(o, 10e18);
        vm.prank(maker);
        vm.expectRevert(Base.ForLegInvalid.selector);
        origin.open(_onchain(p));

        // ...and the lens agrees with the settler: a direct outsider fill reverts there.
        tB.mint(solver, 10e18);
        _solverApprove(address(settlement), address(tB), 10e18);
        vm.prank(solver);
        vm.expectRevert(Base.ForLegInvalid.selector);
        settlement.fillUpTo(o, p.signature, 10e18, address(0), 0, "");
    }

    // ═══════════ PERIPH-3: maker-published any-size sentinel ═══════════

    function _propPayload(uint256 nonce, uint256 cap, uint256 fillAmount) internal view returns (OrderPayload memory) {
        Order memory o = _plainOrder(nonce, address(tA), address(tB), 1, 2_500e18);
        o.legsIn = PackedEncode.oneLegIn(address(tA), Proportional.encode(10_000), cap);
        return _payload(o, fillAmount);
    }

    /// @dev The PoC: `fillAmount = max` published by the maker, then a front-run
    ///      moving all but 1 wei out. The solver used to pay the full 2,500 B for 1 wei.
    ///      The per-unit bound now reverts it.
    function test_audit_PERIPH_3_sentinelFrontRun_reverts() public {
        OrderPayload memory p = _propPayload(20, IN_AMT, type(uint256).max);
        ResolvedCrossChainOrder memory r = _openFor(p);
        assertEq(r.minReceived[0].amount, IN_AMT, "quoted at the full balance");
        _fundSolver(tB, 2_500e18);

        vm.prank(maker);
        tA.transfer(address(0xACC0), IN_AMT - 1); // the front-run

        bytes memory originData = r.fillInstructions[0].originData;
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(DestinationSettler7683.BoundExceeded.selector, true, 0));
        destination.fill(r.orderId, originData, "");
        assertEq(tB.balanceOf(solver), 2_500e18, "solver kept its output");
        assertEq(settlement.filled(r.orderId), 0, "nothing settled");
    }

    /// @dev The PoC's griefing half: with the sentinel, a stranger's 1-wei donation no
    ///      longer bricks the published payload — the anchor grows, the price improves,
    ///      and the fill goes through.
    function test_audit_PERIPH_3_sentinelDonation_stillFills() public {
        OrderPayload memory p = _propPayload(21, type(uint128).max, type(uint256).max);
        ResolvedCrossChainOrder memory r = _openFor(p);
        _fundSolver(tB, 2_500e18);
        tA.mint(maker, 1); // the donation

        bytes memory originData = r.fillInstructions[0].originData;
        vm.prank(solver);
        destination.fill(r.orderId, originData, "");
        assertEq(tA.balanceOf(solver), IN_AMT + 1, "the whole (larger) balance");
        assertEq(tB.balanceOf(maker), 2_500e18, "maker paid in full");
    }

    // ═══════════ PERIPH-4 / CORE-FILLER-3: SETTLE receipts ═══════════

    /// @dev The documented multi-token sweep (proportional USDC leg + a USDT SETTLE
    ///      item). Through the adapter the USDT landed on the adapter forever. Neither
    ///      adapter carries a SETTLE item now: nothing is broadcast, nothing strands.
    function test_audit_PERIPH_4_settleItem_refusedNothingStranded() public {
        ProportionalSweepModule sweep = new ProportionalSweepModule(address(settlement), address(permit3));
        tC.mint(maker, 5_000e6);
        _makerApprove(address(sweep), address(tC), type(uint160).max);
        Order memory o = _plainOrder(30, address(tA), address(tB), 1, 1e18);
        o.legsIn = PackedEncode.oneLegIn(address(tA), Proportional.encode(10_000), IN_AMT);
        Item[] memory its = new Item[](1);
        its[0] = Item({
            op: ItemOp.SETTLE,
            module: address(sweep),
            amount: 10_000e6,
            recipient: address(0),
            data: abi.encode(address(tC), Proportional.encode(10_000))
        });
        o.items = PackedEncode.items(its);
        OrderPayload memory p = _payload(o, IN_AMT);

        vm.expectRevert(Order7683.SettleItemUnsupported.selector);
        origin.resolve(_onchain(p));
        vm.prank(maker);
        vm.expectRevert(Order7683.SettleItemUnsupported.selector);
        origin.open(_onchain(p));

        // A hand-built payload reaches the destination's own guard.
        uint256[] memory maxPaid = new uint256[](1);
        maxPaid[0] = type(uint256).max;
        bytes memory originData = abi.encode(
            FillPayload({
                payload: p,
                bounds: FillBounds({quotedDelta: IN_AMT, maxPaid: maxPaid, minReceived: new uint256[](1)})
            })
        );
        _fundSolver(tB, 1e18);
        bytes32 orderId = lens.hashOrder(o);
        vm.prank(solver);
        vm.expectRevert(Order7683.SettleItemUnsupported.selector);
        destination.fill(orderId, originData, "");
        assertEq(tC.balanceOf(address(destination)), 0, "nothing stranded");
        assertEq(tC.balanceOf(maker), 5_000e6, "maker kept its USDT");
    }

    // ═══════════ PERIPH-5: reserved nonce ═══════════

    function test_audit_PERIPH_5_reservedNonce_notBroadcast() public {
        Order memory o = _plainOrder((uint256(1) << 255) | 7, address(tA), address(tB), IN_AMT, OUT_END);
        OrderPayload memory p = _payload(o, IN_AMT);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(OriginSettler7683.OrderNotFillable.selector, "nonce reserved"));
        origin.open(_onchain(p));
        GaslessCrossChainOrder memory g = _gasless(p);
        vm.expectRevert(abi.encodeWithSelector(OriginSettler7683.OrderNotFillable.selector, "nonce reserved"));
        origin.openFor(g, p.signature, "");
    }

    // ═══════════ PERIPH-6: the unsigned envelope ═══════════

    function test_audit_PERIPH_6_envelopeBoundToTheOrder() public {
        OrderPayload memory p = _payload(_plainOrder(40, address(tA), address(tB), IN_AMT, OUT_END), IN_AMT);

        GaslessCrossChainOrder memory g = _gasless(p);
        g.nonce = 41; // not the order's nonce
        vm.expectRevert(OriginSettler7683.UserMismatch.selector);
        origin.openFor(g, p.signature, "");

        g = _gasless(p);
        g.originSettler = address(0xdead);
        vm.expectRevert(OriginSettler7683.WrongSettler.selector);
        origin.resolveFor(g, ""); // resolveFor now applies openFor's envelope checks

        g = _gasless(p);
        g.user = address(0xbeef);
        vm.expectRevert(OriginSettler7683.UserMismatch.selector);
        origin.resolveFor(g, "");

        g = _gasless(p);
        g.fillDeadline = uint32(block.timestamp); // already over
        vm.expectRevert(abi.encodeWithSelector(OriginSettler7683.OrderNotFillable.selector, "fill deadline"));
        origin.openFor(g, p.signature, "");
    }

    /// @dev A relayer can still publish a 1-wei `fillAmount`: harmless, because the
    ///      bound is a PRICE. A solver re-sizes the payload and is held to the same
    ///      per-unit terms.
    function test_audit_PERIPH_6_dustPayloadResizedAtTheSamePrice() public {
        OrderPayload memory p = _payload(_plainOrder(42, address(tA), address(tB), IN_AMT, OUT_END), 1);
        ResolvedCrossChainOrder memory r = _openFor(p);
        FillPayload memory fp = abi.decode(r.fillInstructions[0].originData, (FillPayload));
        assertEq(fp.bounds.quotedDelta, 1, "quoted for the relayer's 1 wei");
        fp.payload.fillAmount = IN_AMT; // the solver re-sizes
        _fundSolver(tB, OUT_END);
        vm.prank(solver);
        destination.fill(r.orderId, abi.encode(fp), "");
        assertEq(tA.balanceOf(solver), IN_AMT, "whole order at the quoted price");
    }

    // ═══════════ PERIPH-7 / X-TOKENS-9: a zero-priced leg ═══════════

    /// @dev A second output leg that prices to 0, in a token that rejects zero-value
    ///      transfers. The core skips it; the adapter used to pull it anyway and revert.
    function test_audit_X_TOKENS_9_zeroLegSkipped() public {
        ZeroRejectToken20260930 z = new ZeroRejectToken20260930();
        Order memory o = _plainOrder(50, address(tA), address(tB), IN_AMT, OUT_END);
        LegOut[] memory lo = new LegOut[](2);
        lo[0] = LegOut(address(tB), OUT_END, 0, address(0));
        lo[1] = LegOut(address(z), 0, 0, address(0xFEE)); // a zero fee leg
        o.legsOut = PackedEncode.legsOut(lo);
        OrderPayload memory p = _payload(o, IN_AMT);
        ResolvedCrossChainOrder memory r = origin.resolve(_onchain(p));
        assertEq(r.maxSpent[1].amount, 0, "the fee leg prices to 0");
        _fundSolver(tB, OUT_END);
        bytes memory originData = r.fillInstructions[0].originData;
        vm.prank(solver);
        destination.fill(r.orderId, originData, "");
        assertEq(tB.balanceOf(maker), OUT_END, "filled");
    }
}
