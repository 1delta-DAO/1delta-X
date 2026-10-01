// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, LegIn, LegOut} from "@core/settlement/Settlement.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";

import {NftSettlementModule} from "../src/NftSettlementModule.sol";
import {MockERC721} from "./NftModules.t.sol";

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";

/// @title Audit20260930NftTest
/// @notice Regression for audit 2026-09-30 MISC-MOD-2: {NftSettlementModule} ignored
///         the slice, so a 721 sale signed with `item.amount == anchor` (> 1) on a
///         partially fillable order handed the NFT to a one-unit filler.
contract Audit20260930NftTest is CoreSettlementBase {
    NftSettlementModule nft721;
    MockERC721 collection;

    uint256 constant PRICE = 2_000e6;
    uint256 constant ID = 7;

    function setUp() public override {
        super.setUp();
        nft721 = new NftSettlementModule(address(settlement));
        collection = new MockERC721();
        collection.mint(maker, ID);
        vm.prank(maker);
        collection.setApprovalForAll(address(nft721), true);
        deal(USDC, solver, PRICE);
        _approveSolverSide(PRICE, USDC);
    }

    /// BUY sale: fixed USDC output (the anchor), SETTLE item amount == anchor, and NO
    /// `minFillAnchor` — the shape the lens passes and the module used to accept.
    function _sale(uint256 nonce, bytes memory data) internal view returns (Order memory o) {
        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.SETTLE, address(nft721), PRICE, address(0), data);
        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(USDC, PRICE, 0, address(0));
        o = _sellOrder(nonce, maker, address(0), address(0), 0, 0, items);
        o.timing |= uint256(1) << 101; // BUY
        o.legsIn = PackedEncode.legsIn(new LegIn[](0));
        o.legsOut = PackedEncode.legsOut(legsOut);
    }

    /// A one-unit fill (slice = 1, non-zero, so SettleSliceZero never fires) can no
    /// longer take the NFT; the full fill still sells it at the signed price.
    function test_audit_MISC_MOD_2_oneUnitFill_cannotTakeTheNft() public {
        Order memory o = _sale(1, abi.encode(address(collection), ID, PRICE));
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(FullFillGuard.PartialFillUnsupported.selector, uint256(1), PRICE));
        settlement.fill(o, sig, 1);
        assertEq(collection.ownerOf(ID), maker, "the maker still owns the NFT");

        vm.prank(solver);
        settlement.fill(o, sig, PRICE);
        assertEq(collection.ownerOf(ID), solver, "sold on the full fill");
        assertEq(IERC20(USDC).balanceOf(maker), PRICE, "at the full price");
    }

    /// The legacy two-word blob carries no total, so it fails closed.
    function test_audit_MISC_MOD_2_legacyTwoWordData_failsClosed() public {
        Order memory o = _sale(2, abi.encode(address(collection), ID));
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(o, sig, 1);
        assertEq(collection.ownerOf(ID), maker);
    }
}
