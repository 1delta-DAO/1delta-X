// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdError} from "forge-std/StdError.sol";

import {Order} from "@core/settlement/Settlement.sol";
import {OrderHash} from "@core/settlement/OrderHash.sol";
import {SettlementLens} from "@periphery/SettlementLens.sol";
import {OriginSettler7683} from "@periphery/OriginSettler7683.sol";
import {DestinationSettler7683} from "@periphery/DestinationSettler7683.sol";
import {OrderPayload, OnchainCrossChainOrder} from "@periphery/Erc7683.sol";

import {MockSettlementBase} from "@coretest/shared/MockSettlementBase.t.sol";

/// @title LensLifecycleAndOpen
/// @notice Two preflight-drift regressions and one broadcast-integrity one.
///
///  ⚠ THE CLASS. Any second implementation of the settler's rules — this lens, the
///  SDK, an orderbook filter — that disagrees with the settler fails QUIETLY, in
///  whichever direction, and nothing catches it. `docs/reference-audits.md` §C13
///  records that this codebase has already been bitten by it once (two lens copies
///  had silently drifted, which is why the shared rules moved into `OrderGates`).
///  These are three more instances found by the same reading.
///
///   1. `remaining()` answered `Panic(0x11)` for a per-hash-cancelled order, because
///      the `type(uint256).max` sentinel underflowed a checked subtraction.
///   2. `_orderState` read only the NONCE axis, so an order cancelled by HASH — whose
///      sentinel is trivially ≥ any denominator — was reported as **Filled**.
///   3. `OriginSettler7683.open` emitted `Open` without the signature check its
///      sibling `openFor` performs, so it could advertise an unfillable order.
contract LensLifecycleAndOpenTest is MockSettlementBase {
    uint256 constant IN_ = 1_000e18;
    uint256 constant OUT_ = 2e18;

    OriginSettler7683 origin;
    DestinationSettler7683 destination;

    function setUp() public virtual override {
        super.setUp();
        destination = new DestinationSettler7683(address(settlement), address(lens));
        origin = new OriginSettler7683(address(settlement), address(lens), address(destination));
        tA.mint(maker, IN_);
        _makerApprove(address(settlement), address(tA), IN_);
    }

    function _cancelledOrder(uint256 nonce) internal returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), IN_, OUT_);
        vm.prank(maker);
        settlement.cancelOrder(o);
    }

    // ════════════════════ 1. remaining() ════════════════════

    /// The sentinel is ABOVE any real denominator, so the subtraction underflowed.
    function test_remaining_cancelledOrder_revertsPrecisely() public {
        Order memory o = _cancelledOrder(1);
        vm.expectRevert(SettlementLens.OrderCancelled.selector);
        lens.remaining(o);
    }

    /// Control: the ordinary answers are unchanged.
    function test_remaining_liveAndPartiallyFilledOrders() public {
        Order memory o = _plainOrder(2, address(tA), address(tB), IN_, OUT_);
        assertEq(lens.remaining(o), IN_, "untouched order: the whole denominator");

        tB.mint(solver, OUT_);
        _solverApprove(address(settlement), address(tB), OUT_);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        settlement.fill(o, sig, IN_ / 4);

        assertEq(lens.remaining(o), IN_ - IN_ / 4, "partial fill: the remainder");
    }

    // ════════════════════ 2. the two lifecycle axes ════════════════════

    /// Before the fix this returned `Filled`, because `filled == max >= anchor`.
    function test_orderState_hashCancelled_reportsCancelled() public {
        Order memory o = _cancelledOrder(3);
        bytes memory sig = _sign(o);

        (SettlementLens.OrderStatus status, uint256 fillable,,) =
            lens.getOrderRelevantState(o, sig, solver, "");

        assertEq(uint256(status), uint256(SettlementLens.OrderStatus.Cancelled), "cancelled, not filled");
        assertEq(fillable, 0, "nothing fillable");
    }

    /// `validateOrder` carried the same conflation in its reason string.
    function test_validateOrder_hashCancelled_saysCancelled() public {
        Order memory o = _cancelledOrder(4);
        (bool ok, string memory reason) = lens.validateOrder(o);
        assertFalse(ok, "rejected");
        assertEq(reason, "order cancelled", "names the cancellation, not a phantom fill");
    }

    /// Control: a genuinely completed order still reports `Filled`, and a
    /// nonce-cancelled one still reports `Cancelled` — the fix narrowed neither.
    function test_orderState_filledAndNonceCancelled_unchanged() public {
        Order memory filledOrder = _plainOrder(5, address(tA), address(tB), IN_, OUT_);
        tB.mint(solver, OUT_);
        _solverApprove(address(settlement), address(tB), OUT_);
        bytes memory sig = _sign(filledOrder);
        vm.prank(solver);
        settlement.fill(filledOrder, sig, IN_);

        (SettlementLens.OrderStatus s1,,,) = lens.getOrderRelevantState(filledOrder, sig, solver, "");
        assertEq(uint256(s1), uint256(SettlementLens.OrderStatus.Filled), "still Filled");

        Order memory nonceCancelled = _plainOrder(6, address(tA), address(tB), IN_, OUT_);
        uint256[] memory nonces = new uint256[](1);
        nonces[0] = 6;
        vm.prank(maker);
        settlement.cancelOrders(nonces);
        bytes memory sig2 = _sign(nonceCancelled);

        (SettlementLens.OrderStatus s2,,,) = lens.getOrderRelevantState(nonceCancelled, sig2, solver, "");
        assertEq(uint256(s2), uint256(SettlementLens.OrderStatus.Cancelled), "still Cancelled");
    }

    // ════════════════════ 3. open() broadcast integrity ════════════════════

    function _onchain(OrderPayload memory p) internal view returns (OnchainCrossChainOrder memory) {
        return OnchainCrossChainOrder({
            fillDeadline: uint32(block.timestamp + 2 hours),
            orderDataType: OrderHash.ORDER_TYPEHASH,
            orderData: abi.encode(p)
        });
    }

    /// A maker self-opening with a signature that does not recover to it can no
    /// longer broadcast an `Open` for an order the settler will refuse to fill.
    function test_open_rejectsUnverifiableSignature() public {
        Order memory o = _plainOrder(7, address(tA), address(tB), IN_, OUT_);
        // A well-formed 65-byte signature that simply is not the maker's.
        bytes memory forged = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)), uint8(27));
        OnchainCrossChainOrder memory oc = _onchain(
            OrderPayload({order: o, signature: forged, fillAmount: IN_, takerData: ""})
        );

        vm.prank(maker);
        vm.expectRevert();
        origin.open(oc);
    }

    /// Control: the ordinary self-open still works.
    function test_open_acceptsTheMakersOwnSignature() public {
        Order memory o = _plainOrder(8, address(tA), address(tB), IN_, OUT_);
        OnchainCrossChainOrder memory oc = _onchain(
            OrderPayload({order: o, signature: _sign(o), fillAmount: IN_, takerData: ""})
        );

        vm.prank(maker);
        origin.open(oc); // does not revert
    }

    /// ⚠ THE PATH THE CHECK MUST NOT BREAK. A maker that cannot sign at all records
    /// intent on-chain with `approveOrder` and opens with an EMPTY signature —
    /// `checkSignature` routes that to the settler's `orderApproved` record, so the
    /// added verification passes by construction rather than by exception.
    function test_open_signatureLessMakerStillWorks() public {
        Order memory o = _plainOrder(9, address(tA), address(tB), IN_, OUT_);
        vm.prank(maker);
        settlement.approveOrder(o);

        OnchainCrossChainOrder memory oc = _onchain(
            OrderPayload({order: o, signature: "", fillAmount: IN_, takerData: ""})
        );

        vm.prank(maker);
        origin.open(oc); // does not revert
    }

    /// And an empty signature WITHOUT the on-chain approval is exactly the case that
    /// should now fail — otherwise the sigless path would be a hole, not a feature.
    function test_open_emptySignatureWithoutApproval_reverts() public {
        Order memory o = _plainOrder(10, address(tA), address(tB), IN_, OUT_);
        OnchainCrossChainOrder memory oc = _onchain(
            OrderPayload({order: o, signature: "", fillAmount: IN_, takerData: ""})
        );

        vm.prank(maker);
        vm.expectRevert(SettlementLens.OrderNotApproved.selector);
        origin.open(oc);
    }
}
