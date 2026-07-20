// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item} from "@core/settlement/UniversalSettlement.sol";
import {SettlementBase} from "@core/settlement/SettlementBase.sol";
import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @dev Per-order-hash cancellation ({cancelOrder}) — the 0x-orderbook "nonce OR
/// hash" model. Proves it cancels EXACTLY one order (leaving a sibling that shares
/// its nonce fillable), only the maker can do it, and it works on a partial fill —
/// all gas-free on the hot path (it reuses the `filled` SLOAD via the max sentinel).
contract CancelOrderTest is CoreSettlementBase {
    uint256 constant WETH_IN = 1 ether;

    function setUp() public override {
        super.setUp();
        deal(WETH, maker, 10 ether);
        _approveMakerToSettlement(WETH, 10 ether);
        _approveSolverSide(type(uint128).max, USDC);
        deal(USDC, solver, 1_000_000e6);
    }

    // Two DISTINCT orders (different output → different hash) sharing nonce 5.
    function _orderA() internal view returns (Order memory) {
        return _order(maker, 5, WETH, USDC, WETH_IN, 2_000e6, new Item[](0));
    }

    function _orderB() internal view returns (Order memory) {
        return _order(maker, 5, WETH, USDC, WETH_IN, 2_100e6, new Item[](0));
    }

    // ── Cancel A by hash; A can't fill, but B (same nonce) still fills. ──
    function test_cancelOrder_cancelsOneNotTheSharedNonce() public {
        Order memory a = _orderA();
        Order memory b = _orderB();
        bytes memory sigA = _sign(a);
        bytes memory sigB = _sign(b);

        vm.prank(maker);
        bytes32 h = settlement.cancelOrder(a);
        assertEq(h, _hashOrder(a), "returns the cancelled hash");

        // A is dead.
        vm.prank(solver);
        vm.expectRevert(SettlementBase.OrderCancelled.selector);
        settlement.fill(a, sigA, WETH_IN);

        // B — same maker, same nonce 5 — is untouched and fills.
        vm.prank(solver);
        settlement.fill(b, sigB, WETH_IN);
        assertEq(IERC20(USDC).balanceOf(maker), 2_100e6, "B filled at its own price");
    }

    // ── Contrast: nonce cancellation drops BOTH siblings. ──
    function test_nonceCancel_dropsBothSiblings() public {
        Order memory a = _orderA();
        Order memory b = _orderB();

        bytes memory sigA = _sign(a);
        bytes memory sigB = _sign(b);

        uint256[] memory nonces = new uint256[](1);
        nonces[0] = 5;
        vm.prank(maker);
        settlement.cancelOrders(nonces);

        vm.prank(solver);
        vm.expectRevert(); // NonceCancelled
        settlement.fill(a, sigA, WETH_IN);
        vm.prank(solver);
        vm.expectRevert(); // NonceCancelled
        settlement.fill(b, sigB, WETH_IN);
    }

    // ── Only the maker may cancel their own order. ──
    function test_cancelOrder_onlyMaker() public {
        Order memory a = _orderA();
        vm.prank(solver);
        vm.expectRevert(SettlementBase.NotOrderMaker.selector);
        settlement.cancelOrder(a);
    }

    // ── A partially-filled order is cancellable — its remainder becomes dead. ──
    function test_cancelOrder_onPartialFill() public {
        // Partial-fillable order (minFillAnchor 0), sell 2 WETH.
        Order memory o = _order(maker, 7, WETH, USDC, 2 ether, 4_000e6, new Item[](0));
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fill(o, sig, 1 ether); // fill half
        assertEq(IERC20(USDC).balanceOf(maker), 2_000e6, "half filled");

        vm.prank(maker);
        settlement.cancelOrder(o);

        vm.prank(solver);
        vm.expectRevert(SettlementBase.OrderCancelled.selector);
        settlement.fill(o, sig, 1 ether); // remaining half now dead
    }
}
