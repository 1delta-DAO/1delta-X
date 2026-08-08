// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "./shared/PackedEncode.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, OrderSide} from "@core/settlement/Settlement.sol";

import {CoreSettlementBase} from "./shared/CoreSettlementBase.t.sol";

/// @dev Unit tests for the off-chain `validateOrder` preview helper. Covers each
/// misparameterization branch plus the happy path and the time/state-dependent
/// fillability checks.
contract ValidateOrderTest is CoreSettlementBase {
    function _base() internal view returns (Order memory) {
        // Well-formed fixed-price plain swap: 2000 USDC -> 1 WETH.
        return _order(maker, 0, USDC, WETH, 2_000e6, 1 ether, new Item[](0));
    }

    function _assertInvalid(Order memory order, string memory expected) internal view {
        (bool ok, string memory reason) = lens.validateOrder(order);
        assertFalse(ok, expected);
        assertEq(reason, expected, "reason mismatch");
    }

    function test_validateOrder_acceptsWellFormed() public view {
        (bool ok, string memory reason) = lens.validateOrder(_base());
        assertTrue(ok, "well-formed order should validate");
        assertEq(reason, "", "no reason on success");
    }

    function test_validateOrder_structuralBranches() public view {
        Order memory o;

        o = _base();
        o.legsIn = PackedEncode.setLegInStart(o.legsIn, 0, 0);
        o.legsIn = PackedEncode.setLegInEnd(o.legsIn, 0, 0);
        _assertInvalid(o, "anchor amount is zero");

        o = _base();
        o.legsOut = PackedEncode.setLegOutStart(o.legsOut, 0, 0);
        o.legsOut = PackedEncode.setLegOutEnd(o.legsOut, 0, 0);
        _assertInvalid(o, "output start is zero (giveaway)");

        o = _base();
        o.legsOut = PackedEncode.setLegOutStart(o.legsOut, 0, 1 ether);
        o.legsOut = PackedEncode.setLegOutEnd(o.legsOut, 0, 2 ether); // start < end (output must fall)
        _assertInvalid(o, "output start < end (must fall)");

        o = _base();
        o.legsOut = PackedEncode.setLegOutToken(o.legsOut, 0, PackedEncode.getLegInToken(o.legsIn, 0)); // self-trade
        _assertInvalid(o, "input token == output token");

        o = _base();
        o.minFillAnchor = PackedEncode.getLegInStart(o.legsIn, 0) + 1;
        _assertInvalid(o, "minFillAnchor > anchor (unfillable)");

        o = _base();
        o.timing = uint256(100) << 32; // decayDuration = 100, decayStartTime = 0
        _assertInvalid(o, "decay set without decayStartTime");
    }

    function test_validateOrder_expiredAndCancelled() public {
        Order memory o = _base();
        o.deadline = block.timestamp - 1;
        _assertInvalid(o, "order expired");

        o = _base();
        o.nonce = 7;
        uint256[] memory nonces = new uint256[](1);
        nonces[0] = 7;
        vm.prank(maker);
        settlement.cancelOrders(nonces);
        _assertInvalid(o, "nonce cancelled");
    }

    function test_validateOrder_fullyFilled() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        Order memory o = _order(maker, 9, USDC, WETH, usdcIn, wethOut, new Item[](0));

        // Valid before filling.
        (bool ok,) = lens.validateOrder(o);
        assertTrue(ok, "valid before fill");

        // Fully fill it (plain swap).
        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);
        _approveMakerToSettlement(USDC, usdcIn);
        _approveSolverSide(wethOut, WETH);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        settlement.fill(o, sig, usdcIn);

        _assertInvalid(o, "order fully filled");
    }
}
