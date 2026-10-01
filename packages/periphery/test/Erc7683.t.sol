// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order, Settlement} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {OrderGates} from "@core/settlement/OrderGates.sol";
import {OrderHash} from "@core/settlement/OrderHash.sol";
import {DestinationSettler7683} from "@periphery/DestinationSettler7683.sol";
import {OriginSettler7683} from "@periphery/OriginSettler7683.sol";
import {
    FillBounds,
    FillPayload,
    GaslessCrossChainOrder,
    OnchainCrossChainOrder,
    OrderPayload,
    ResolvedCrossChainOrder
} from "@periphery/Erc7683.sol";

import {SettlementLens} from "@periphery/SettlementLens.sol";

import {MockSettlementBase, MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";

/// @title Erc7683
/// @notice The ERC-7683 compatibility surface: a solver that speaks the standard can
///         resolve one of our orders and fill it, with no knowledge of our ABI.
contract Erc7683Test is MockSettlementBase {
    uint256 constant IN_AMT = 100e18;
    uint256 constant OUT_AMT = 250e18;

    OriginSettler7683 origin;
    DestinationSettler7683 destination;

    function setUp() public override {
        super.setUp();
        destination = new DestinationSettler7683(address(settlement), address(lens));
        origin = new OriginSettler7683(address(settlement), address(lens), address(destination));

        tA.mint(maker, IN_AMT);
        _makerApprove(address(settlement), address(tA), IN_AMT);
        tB.mint(solver, OUT_AMT);
    }

    function _payload(uint256 nonce) internal view returns (OrderPayload memory p, Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), IN_AMT, OUT_AMT);
        p = OrderPayload({order: o, signature: _sign(o), fillAmount: IN_AMT, takerData: ""});
    }

    function _onchain(OrderPayload memory p) internal view returns (OnchainCrossChainOrder memory) {
        return OnchainCrossChainOrder({
            fillDeadline: uint32(block.timestamp + 2 hours),
            orderDataType: OrderHash.ORDER_TYPEHASH,
            orderData: abi.encode(p)
        });
    }

    function _gasless(OrderPayload memory p) internal view returns (GaslessCrossChainOrder memory g) {
        g = GaslessCrossChainOrder({
            originSettler: address(origin),
            user: maker,
            nonce: p.order.nonce,
            originChainId: block.chainid,
            openDeadline: uint32(block.timestamp + 1 hours),
            fillDeadline: uint32(block.timestamp + 2 hours),
            orderDataType: OrderHash.ORDER_TYPEHASH,
            orderData: abi.encode(p)
        });
    }

    /// @dev The fill instruction's `originData` exactly as the origin publishes it —
    ///      the payload plus the bounds it was quoted at.
    function _published(OrderPayload memory p) internal view returns (bytes memory) {
        return origin.resolve(_onchain(p)).fillInstructions[0].originData;
    }

    /// @dev A hand-built `originData` with NO bound (every check switched off) — for
    ///      orders the origin refuses to quote, to reach the destination's own guards.
    function _unbounded(OrderPayload memory p, uint256 quotedDelta) internal pure returns (bytes memory) {
        uint256 nOut = uint8(p.order.legsOut[0]);
        uint256 nIn = uint8(p.order.legsIn[0]);
        uint256[] memory maxPaid = new uint256[](nOut);
        for (uint256 j; j < nOut; j++) {
            maxPaid[j] = type(uint256).max;
        }
        return abi.encode(
            FillPayload({
                payload: p,
                bounds: FillBounds({quotedDelta: quotedDelta, maxPaid: maxPaid, minReceived: new uint256[](nIn)})
            })
        );
    }

    // ════════════════════ deployment binding ════════════════════

    /// @dev A lens from another deployment would quote against a settlement nobody
    ///      fills on — and, on the destination side, size an approval for an order
    ///      the settlement is not charging. The pair is bound at construction.
    function test_constructor_rejectsForeignLens() public {
        // A REAL second deployment, not a stub: the lens constructor reads
        // `PERMIT3()` off its settlement, so a bare address would fail there instead
        // and prove nothing about the binding under test.
        Settlement other = new Settlement(address(permit3));
        SettlementLens foreign = new SettlementLens(address(other));
        vm.expectRevert(OriginSettler7683.LensSettlementMismatch.selector);
        new OriginSettler7683(address(settlement), address(foreign), address(destination));
        vm.expectRevert(DestinationSettler7683.LensSettlementMismatch.selector);
        new DestinationSettler7683(address(settlement), address(foreign));
    }

    // ════════════════════ resolve ════════════════════

    function test_resolve_reportsBothSidesAtTheCurrentTick() public view {
        (OrderPayload memory p,) = _payload(1);
        ResolvedCrossChainOrder memory r = origin.resolveFor(_gasless(p), "");

        assertEq(r.user, maker, "user");
        assertEq(r.originChainId, block.chainid, "chain");
        assertEq(r.orderId, lens.hashOrder(p.order), "orderId is the order hash");
        assertEq(r.maxSpent.length, 1, "one output");
        assertEq(r.maxSpent[0].amount, OUT_AMT, "filler spends the output leg");
        assertEq(address(uint160(uint256(r.maxSpent[0].token))), address(tB), "output token");
        assertEq(address(uint160(uint256(r.maxSpent[0].recipient))), maker, "output goes to the maker");
        assertEq(r.minReceived.length, 1, "one input");
        assertEq(r.minReceived[0].amount, IN_AMT, "filler receives the input leg");
        assertEq(r.fillInstructions.length, 1, "one instruction");
        assertEq(
            address(uint160(uint256(r.fillInstructions[0].destinationSettler))),
            address(destination),
            "instruction points at the destination settler"
        );
    }

    function test_resolve_rejectsForeignOrderType() public {
        (OrderPayload memory p,) = _payload(2);
        GaslessCrossChainOrder memory g = _gasless(p);
        g.orderDataType = keccak256("SomeOtherProtocolOrder(uint256 x)");
        vm.expectRevert(OriginSettler7683.UnsupportedOrderType.selector);
        origin.resolveFor(g, "");
    }

    // ════════════════════ open (broadcast, no escrow) ════════════════════

    function test_openFor_emitsOpen_andMovesNothing() public {
        (OrderPayload memory p,) = _payload(3);
        uint256 makerBefore = tA.balanceOf(maker);

        vm.recordLogs();
        origin.openFor(_gasless(p), p.signature, "");
        assertEq(tA.balanceOf(maker), makerBefore, "open takes no custody");
        assertEq(tA.balanceOf(address(origin)), 0, "the settler holds nothing");
        assertGt(vm.getRecordedLogs().length, 0, "Open was emitted");
    }

    function test_openFor_rejectsWrongSettler() public {
        (OrderPayload memory p,) = _payload(4);
        GaslessCrossChainOrder memory g = _gasless(p);
        g.originSettler = address(0xdead);
        vm.expectRevert(OriginSettler7683.WrongSettler.selector);
        origin.openFor(g, p.signature, "");
    }

    function test_openFor_rejectsUserMismatch() public {
        (OrderPayload memory p,) = _payload(5);
        GaslessCrossChainOrder memory g = _gasless(p);
        g.user = address(0xbeef);
        vm.expectRevert(OriginSettler7683.UserMismatch.selector);
        origin.openFor(g, p.signature, "");
    }

    function test_openFor_rejectsBadSignature() public {
        (OrderPayload memory p, Order memory o) = _payload(6);
        GaslessCrossChainOrder memory g = _gasless(p);
        // Signed BEFORE the expectation: `_signWith` itself calls the settlement for
        // the domain separator, and `expectRevert` binds to the very next call.
        bytes memory forged = _signWith(o, 0xBADBAD);
        vm.expectRevert();
        origin.openFor(g, forged, "");
    }

    // ════════════════════ fill through the standard ════════════════════

    function test_destinationFill_settlesTheOrder() public {
        (OrderPayload memory p,) = _payload(7);
        bytes32 orderId = lens.hashOrder(p.order);

        vm.prank(solver);
        tB.approve(address(destination), OUT_AMT);

        uint256 makerOutBefore = tB.balanceOf(maker);
        uint256 solverInBefore = tA.balanceOf(solver);
        bytes memory originData = _published(p);
        vm.prank(solver);
        destination.fill(orderId, originData, "");

        assertEq(tB.balanceOf(maker) - makerOutBefore, OUT_AMT, "maker received the output");
        assertEq(tA.balanceOf(solver) - solverInBefore, IN_AMT, "solver received the input");
        assertEq(settlement.filled(orderId), IN_AMT, "order recorded as filled");
        // The adapter is a pure conduit.
        assertEq(tA.balanceOf(address(destination)), 0, "no input residue");
        assertEq(tB.balanceOf(address(destination)), 0, "no output residue");
        assertEq(tB.allowance(address(destination), address(settlement)), 0, "no standing approval");
    }

    function test_destinationFill_rejectsIdMismatch() public {
        (OrderPayload memory p,) = _payload(8);
        vm.prank(solver);
        tB.approve(address(destination), OUT_AMT);
        bytes memory originData = _published(p);
        vm.prank(solver);
        vm.expectRevert(DestinationSettler7683.OrderIdMismatch.selector);
        destination.fill(keccak256("not this order"), originData, "");
    }

    /// @dev The floor makes a stranded balance unreachable: an attacker signing its
    ///      OWN order whose output leg names a token this contract happens to hold
    ///      still has to supply every unit itself.
    function test_destinationFill_cannotDrainStrandedBalance() public {
        tB.mint(address(destination), 500e18); // donated / stranded

        uint256 attackerPk = 0xA77ACC;
        address attacker = vm.addr(attackerPk);
        Order memory evil = _plainOrder(9, address(tA), address(tB), 1, 500e18);
        evil.maker = attacker;
        OrderPayload memory p =
            OrderPayload({order: evil, signature: _signWith(evil, attackerPk), fillAmount: 1, takerData: ""});

        bytes32 evilId = lens.hashOrder(evil);
        bytes memory originData = _unbounded(p, 1);
        vm.startPrank(attacker);
        tB.approve(address(destination), 0); // supplies nothing
        vm.expectRevert();
        destination.fill(evilId, originData, "");
        vm.stopPrank();
        assertEq(tB.balanceOf(address(destination)), 500e18, "stranded balance untouched");
    }

    // ════════════════════ filler-set exclusivity (audit 2026-09-29 E-2) ════════════════════

    address constant MEMBER2 = address(0x50172); // second set member
    address constant OUTSIDER = address(0x0DD); //  never in the set

    /// @dev A tA→tB order whose exclusivity window names the SET {solver, MEMBER2}
    ///      (`curve = [0x00] ‖ members`, see {OrderGates.FILLER_SET}); `overrideBps`
    ///      0 = HARD, else SOFT.
    function _fillerSetPayload(uint256 nonce, uint16 overrideBps) internal view returns (OrderPayload memory p) {
        Order memory o = _plainOrder(nonce, address(tA), address(tB), IN_AMT, OUT_AMT);
        o.exclusiveFiller = OrderGates.FILLER_SET;
        _setExclusivityEnd(o, block.timestamp + 10 minutes);
        o.curve = abi.encodePacked(uint8(0), solver, MEMBER2);
        o.params = overrideBps;
        p = OrderPayload({order: o, signature: _sign(o), fillAmount: IN_AMT, takerData: ""});
    }

    /// @dev SUPERSEDED BY AUDIT 2026-09-30 PERIPH-2. The 2026-09-29 E-2 fix quoted a
    ///      set order for a MEMBER, on the reasoning that "the member price is what the
    ///      order actually fills at". Through the published instruction it never is:
    ///      the settlement-level filler is always {DestinationSettler7683}, which is in
    ///      no set. So a HARD set order inside its window cannot fill through the
    ///      instruction at all, and is now refused rather than broadcast — the same
    ///      verdict the fill would reach. Members fill it on the settlement directly.
    function test_hardFillerSet_inWindow_refusedNotBroadcast() public {
        OrderPayload memory p = _fillerSetPayload(20, 0);

        vm.prank(OUTSIDER);
        vm.expectRevert(OrderGates.NotExclusiveFiller.selector);
        origin.resolve(_onchain(p));
        vm.prank(solver); // even a member asking
        vm.expectRevert(OrderGates.NotExclusiveFiller.selector);
        origin.resolveFor(_gasless(p), "");
        vm.prank(maker);
        vm.expectRevert(OrderGates.NotExclusiveFiller.selector);
        origin.open(_onchain(p));
        vm.expectRevert(OrderGates.NotExclusiveFiller.selector);
        origin.openFor(_gasless(p), p.signature, "");

        // Once the window lapses the instruction can execute, and it is broadcast.
        vm.warp(block.timestamp + 10 minutes);
        vm.recordLogs();
        vm.prank(OUTSIDER);
        origin.openFor(_gasless(p), p.signature, "");
        assertEq(vm.getRecordedLogs().length, 1, "Open emitted after the window");
    }

    /// @dev Every caller — member or not — gets the same quote: the destination
    ///      settler's, with the filler slot of `minReceived` left to whoever fills.
    function test_fillerSet_quoteIsTheInstructionsWhoeverAsks() public {
        OrderPayload memory p = _fillerSetPayload(21, 100);
        vm.prank(MEMBER2);
        ResolvedCrossChainOrder memory a = origin.resolve(_onchain(p));
        vm.prank(OUTSIDER);
        ResolvedCrossChainOrder memory b = origin.resolve(_onchain(p));
        assertEq(a.maxSpent[0].amount, b.maxSpent[0].amount, "same quote for every caller");
        assertEq(a.minReceived[0].recipient, bytes32(0), "the filler slot is open");
    }

    /// @dev A SOFT set order is quoted WITH the outsider premium — the price the
    ///      published instruction actually pays — and a fill through it pays exactly
    ///      the quoted `maxSpent` (the 2026-09-29 test asserted the premium-free member
    ///      price, which the instruction could never obtain).
    function test_softFillerSet_quotesThePremiumTheInstructionPays() public {
        OrderPayload memory p = _fillerSetPayload(22, 100); // 1% soft override
        (,, uint256[] memory outsiderPaid) = lens.previewFill(p.order, IN_AMT, OUTSIDER, "");
        assertEq(outsiderPaid[0], OUT_AMT * 10_100 / 10_000, "an outsider does pay the premium");

        vm.prank(OUTSIDER);
        ResolvedCrossChainOrder memory r = origin.resolve(_onchain(p));
        assertEq(r.maxSpent[0].amount, outsiderPaid[0], "resolve: the premium is quoted");
        r = origin.resolveFor(_gasless(p), "");
        assertEq(r.maxSpent[0].amount, outsiderPaid[0], "resolveFor: the premium is quoted");

        tB.mint(solver, outsiderPaid[0] - OUT_AMT);
        uint256 before = tB.balanceOf(solver);
        vm.startPrank(solver);
        tB.approve(address(destination), r.maxSpent[0].amount);
        destination.fill(r.orderId, r.fillInstructions[0].originData, "");
        vm.stopPrank();
        assertEq(before - tB.balanceOf(solver), r.maxSpent[0].amount, "paid exactly the quoted maxSpent");
    }

    // ════════════════════ delta-verify orders (audit 2026-09-29 G) ════════════════════

    /// @dev A tA→tB order with `timing` bit 104 set, naming `filler` as the only
    ///      party allowed to deliver it.
    function _deltaVerifyPayload(uint256 nonce, address filler) internal view returns (OrderPayload memory p) {
        Order memory o = _plainOrder(nonce, address(tA), address(tB), IN_AMT, OUT_AMT);
        o.exclusiveFiller = filler;
        o.timing |= uint256(1) << 104;
        p = OrderPayload({order: o, signature: _sign(o), fillAmount: IN_AMT, takerData: ""});
    }

    /// @dev Why the adapter refuses them: the destination settler fills through
    ///      `fillUpTo`, which has no callback to deliver in. Even an order that names
    ///      the adapter itself as its filler cannot be delivered — the pulled output
    ///      sits in the adapter, the maker's measured delta is zero.
    function test_destinationFill_cannotDeliverDeltaVerifyOrder() public {
        OrderPayload memory p = _deltaVerifyPayload(23, address(destination));
        bytes32 orderId = lens.hashOrder(p.order);
        bytes memory originData = _unbounded(p, IN_AMT);
        vm.startPrank(solver);
        tB.approve(address(destination), OUT_AMT);
        vm.expectRevert(Base.DeltaTooLow.selector);
        destination.fill(orderId, originData, "");
        vm.stopPrank();
    }

    /// @dev So no entry announces or quotes one: a broadcast would be a dead order to
    ///      every solver that reads it, and a resolve would point at a fill
    ///      instruction that cannot execute.
    function test_deltaVerifyOrder_refusedByEveryEntry() public {
        OrderPayload memory p = _deltaVerifyPayload(24, solver);

        vm.expectRevert(OriginSettler7683.DeltaVerifyNotSupported.selector);
        origin.resolve(_onchain(p));
        vm.expectRevert(OriginSettler7683.DeltaVerifyNotSupported.selector);
        origin.resolveFor(_gasless(p), "");
        vm.prank(maker);
        vm.expectRevert(OriginSettler7683.DeltaVerifyNotSupported.selector);
        origin.open(_onchain(p));
        vm.expectRevert(OriginSettler7683.DeltaVerifyNotSupported.selector);
        origin.openFor(_gasless(p), p.signature, "");
    }
}
