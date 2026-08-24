// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order, Settlement} from "@core/settlement/Settlement.sol";
import {OrderHash} from "@core/settlement/OrderHash.sol";
import {DestinationSettler7683} from "@periphery/DestinationSettler7683.sol";
import {OriginSettler7683} from "@periphery/OriginSettler7683.sol";
import {
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
        vm.prank(solver);
        destination.fill(orderId, abi.encode(p), "");

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
        vm.prank(solver);
        vm.expectRevert(DestinationSettler7683.OrderIdMismatch.selector);
        destination.fill(keccak256("not this order"), abi.encode(p), "");
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
        bytes memory originData = abi.encode(p);
        vm.startPrank(attacker);
        tB.approve(address(destination), 0); // supplies nothing
        vm.expectRevert();
        destination.fill(evilId, originData, "");
        vm.stopPrank();
        assertEq(tB.balanceOf(address(destination)), 500e18, "stranded balance untouched");
    }
}
