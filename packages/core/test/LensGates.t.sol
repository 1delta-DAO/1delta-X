// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "./shared/PackedEncode.sol";
import {Order, Item, ItemOp, LegIn, LegOut} from "@core/settlement/Settlement.sol";
import {Proportional} from "@core/settlement/Proportional.sol";
import {SettlementLens} from "@periphery/SettlementLens.sol";
import {MockSettlementBase} from "./shared/MockSettlementBase.t.sol";

/// @title LensGatesTest
/// @notice F29 finding 8 — every "the lens flags this off-chain" promise the core
///         makes must be kept. Each test here is one gate the settler enforces on
///         every fill and the lens used to wave through.
contract LensGatesTest is MockSettlementBase {
    uint256 constant IN = 100e18;
    uint256 constant OUT = 300e18;

    function _order(uint256 nonce) internal view returns (Order memory) {
        return _plainOrder(nonce, address(tA), address(tB), IN, OUT);
    }

    function _reason(Order memory o) internal view returns (string memory why) {
        (, why) = lens.validateOrder(o);
    }

    // ── 8b: the reserved nonce half ──
    function test_lens_reservedNonce_isInvalid() public view {
        Order memory o = _order((uint256(1) << 255) | 7);
        assertEq(_reason(o), "nonce in the reserved signer-permit half");
    }

    // ── 8a: fill-once is whole or nothing ──
    function test_lens_fillOnce_previewsNoPartial() public {
        Order memory o = _order(1);
        o.timing |= uint256(1) << 100;
        tA.mint(maker, IN);
        _makerApprove(address(settlement), address(tA), IN);

        vm.expectRevert(SettlementLens.FillOnceMustBeFull.selector);
        lens.previewFill(o, IN / 2, solver, "");
        (uint256 delta,,) = lens.previewFill(o, IN, solver, "");
        assertEq(delta, IN, "a whole fill previews");
    }

    function test_lens_fillOnce_capBelowAnchor_readsUnfillable() public {
        Order memory o = _order(2);
        o.timing |= uint256(1) << 100;
        tA.mint(maker, IN);
        _makerApprove(address(settlement), address(tA), IN / 2); // half the anchor
        (SettlementLens.OrderStatus st, uint256 fillable,,) = lens.getOrderRelevantState(o, "", solver, "");
        assertEq(uint256(st), uint256(SettlementLens.OrderStatus.Fillable));
        assertEq(fillable, 0, "cannot fill whole => cannot fill at all");
    }

    // ── 8c: delta-verify rejects a same-token exit even with items ──
    function test_lens_deltaVerify_sameTokenWithItems_isInvalid() public view {
        Order memory o = _order(3);
        o.timing |= uint256(1) << 104;
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.MAKE, module: address(0xD1), amount: 1, recipient: address(0), data: abi.encode(address(0))});
        o.items = PackedEncode.items(items);
        o.legsOut = PackedEncode.setLegOutToken(o.legsOut, 0, address(tA));
        assertEq(_reason(o), "input token == output token");
    }

    // ── 8d: strict mode removes the direct-allowance capacity ──
    function test_lens_strictMode_ignoresDirectAllowance() public {
        Order memory o = _order(4);
        tA.mint(maker, IN);
        vm.startPrank(maker);
        tA.approve(address(settlement), IN); // direct allowance only
        vm.stopPrank();
        (, uint256 fillable,,) = lens.getOrderRelevantState(o, "", solver, "");
        assertEq(fillable, IN, "direct allowance funds the fallback pull");

        vm.prank(maker);
        permit3.setStrictModeToken(address(tA), true);
        (, fillable,,) = lens.getOrderRelevantState(o, "", solver, "");
        assertEq(fillable, 0, "strict mode: the fallback is refused, so the capacity is gone");
    }

    // ── 8e: item gates ──
    function test_lens_unknownItemOp_isInvalid() public view {
        Order memory o = _order(5);
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.MAKE, module: address(0xD1), amount: 1, recipient: address(0), data: ""});
        bytes memory packed = PackedEncode.items(items);
        packed[1] = bytes1(uint8(9)); // op byte above the enum
        o.items = packed;
        assertEq(_reason(o), "unknown item op");
    }

    function test_lens_indivisibleTakeFor_requiresFullFill() public view {
        Order memory o = _order(6);
        o.minFillAnchor = 1e18; // partial-fillable
        Item[] memory items = new Item[](1);
        // TAKE_FOR used to be unchecked here; it reverts on a zero slice like SETTLE.
        items[0] = Item({op: ItemOp.TAKE_FOR, module: address(0xD1), amount: 1, recipient: address(0), data: abi.encode(uint256(5))});
        o.items = PackedEncode.items(items);
        assertEq(_reason(o), "settle item requires full-fill");

        items[0].amount = IN; // divisible: allowed
        o.items = PackedEncode.items(items);
        (bool ok,) = lens.validateOrder(o);
        assertTrue(ok);
    }

    function test_lens_twoItemsOneLeg_isInvalid() public view {
        Order memory o = _order(7);
        uint256 desc = (uint256(5) << 253) | (uint256(uint160(address(tB))) << 16); // pre-fund leg 0
        Item[] memory items = new Item[](2);
        items[0] = Item({op: ItemOp.MAKE, module: address(0xD1), amount: 0, recipient: address(0), data: abi.encode(desc)});
        items[1] = Item({op: ItemOp.MAKE, module: address(0xD1), amount: 0, recipient: address(0), data: abi.encode(desc)});
        o.items = PackedEncode.items(items);
        o.legsOut = PackedEncode.oneLegOut(address(tB), OUT, 0, address(0xD1));
        assertEq(_reason(o), "two items fund from the same output leg");
    }

    function test_lens_preFundWithOverride_isInvalid() public view {
        Order memory o = _order(8);
        uint256 desc = (uint256(5) << 253) | (uint256(uint160(address(tB))) << 16);
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.MAKE, module: address(0xD1), amount: 0, recipient: address(0), data: abi.encode(desc)});
        o.items = PackedEncode.items(items);
        o.legsOut = PackedEncode.oneLegOut(address(tB), OUT, 0, address(0xD1));
        (bool ok,) = lens.validateOrder(o);
        assertTrue(ok, "pre-fund leg without override is fine");

        o.exclusiveFiller = address(0xB0B);
        o.params = 100; // overrideBps
        assertEq(_reason(o), "pre-funded leg with an exclusivity override (outsiders revert)");
    }

    // ── 8f: a proportional anchor at zero balance is "nothing yet", not "filled" ──
    function test_lens_proportionalZeroBalance_readsFillableZero() public view {
        Order memory o = _order(9);
        o.legsIn = PackedEncode.oneLegIn(address(tA), Proportional.encode(10_000), IN);
        (SettlementLens.OrderStatus st, uint256 fillable,,) = lens.getOrderRelevantState(o, "", solver, "");
        assertEq(uint256(st), uint256(SettlementLens.OrderStatus.Fillable));
        assertEq(fillable, 0);
    }
}
