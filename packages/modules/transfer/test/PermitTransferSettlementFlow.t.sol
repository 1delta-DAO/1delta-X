// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {MockSettlementBase} from "@coretest/shared/MockSettlementBase.t.sol";

import {Order, Item, ItemOp, LegOut} from "@core/settlement/Settlement.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";

import {ERC20PermitTransferModule} from "../src/ERC20PermitTransferModule.sol";

/// @title PermitTransferSettlementFlowTest
/// @notice Audit 2026-09-30 MISC-MOD-6: the ERC20PermitTransferModule header promises
///         an order shape (outputless order, TAKE item for fee + transfer, the fee
///         leg RISING over time to attract solvers, the spread paid to the solver by
///         the core) that no test ever ran end to end through a real Settlement and a
///         real Permit3 taker book. These tests run exactly that shape, including the
///         rising fee leg: the module's spread pays the signed START fee, and the core
///         bills the clock-driven rise above it to the maker's token allowance.
contract PermitTransferSettlementFlowTest is MockSettlementBase {
    ERC20PermitTransferModule xfer;

    uint256 constant T = 100e18; // transferred to the recipient
    uint256 constant FEE_START = 1e18; // fee at the start of the auction
    uint256 constant FEE_END = 3e18; // fee cap (the leg rises to it)
    uint256 constant DURATION = 1000;
    address recipient = address(0xCAFE);

    function setUp() public override {
        super.setUp();
        xfer = new ERC20PermitTransferModule(address(permit3));
    }

    function _data() internal view returns (bytes memory) {
        return abi.encode(address(tA), recipient, T, FEE_START + T);
    }

    /// Outputless order; legsIn[0] is the solver's fee, rising FEE_START -> FEE_END.
    function _order(uint256 nonce) internal view returns (Order memory o) {
        o = _blank(nonce);
        o.legsIn = PackedEncode.oneLegIn(address(tA), FEE_START, FEE_END);
        o.legsOut = PackedEncode.legsOut(new LegOut[](0));
        _setDecayStart(o, block.timestamp);
        _setDecayDuration(o, DURATION);
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.TAKE, module: address(xfer), amount: FEE_START + T, recipient: address(0), data: _data()});
        o.items = PackedEncode.items(items);
    }

    function _fund() internal {
        tA.mint(maker, 1000e18);
        // Token book: the module pulls the gross; Settlement pulls any fee rise above
        // the module's spread. Taker book: Settlement may dispatch exactly this item.
        _makerApprove(address(xfer), address(tA), FEE_START + T);
        _makerApprove(address(settlement), address(tA), FEE_END);
        vm.prank(maker);
        permit3.approveTaker(
            address(settlement), address(xfer), keccak256(_data()), uint160(FEE_START + T), uint48(block.timestamp + 1 days)
        );
    }

    /// At the start of the auction the module's spread pays the whole fee: the
    /// maker pays exactly fee + transfer, nothing more is pulled.
    function test_audit_MISC_MOD_6_transferFlow_atStart_spreadPaysFee() public {
        _fund();
        Order memory o = _order(1);
        bytes memory sig = _sign(o);
        uint256 makerBefore = tA.balanceOf(maker);

        vm.prank(solver);
        settlement.fill(o, sig, type(uint256).max);

        assertEq(tA.balanceOf(recipient), T, "recipient gets the signed transfer");
        assertEq(tA.balanceOf(solver), FEE_START, "solver gets the start fee");
        assertEq(makerBefore - tA.balanceOf(maker), FEE_START + T, "maker pays fee + transfer");
        assertEq(tA.balanceOf(address(settlement)), 0, "nothing stranded on Settlement");
        assertEq(tA.balanceOf(address(xfer)), 0, "nothing stranded on the module");
    }

    /// Halfway through the rise the fee is (start + end) / 2. The module's spread
    /// covers FEE_START; the core pulls the rest from the maker's Settlement grant.
    function test_audit_MISC_MOD_6_transferFlow_risingFeeLeg_coreBillsTheRise() public {
        _fund();
        Order memory o = _order(2);
        bytes memory sig = _sign(o);
        uint256 makerBefore = tA.balanceOf(maker);

        vm.warp(block.timestamp + DURATION / 2);
        vm.prank(solver);
        settlement.fill(o, sig, type(uint256).max);

        uint256 feeNow = (FEE_START + FEE_END) / 2;
        assertEq(tA.balanceOf(recipient), T, "recipient still gets exactly T");
        assertEq(tA.balanceOf(solver), feeNow, "solver gets the clock-priced fee");
        assertEq(makerBefore - tA.balanceOf(maker), feeNow + T, "maker pays the risen fee + transfer");
        assertEq(tA.balanceOf(address(settlement)), 0, "nothing stranded on Settlement");
    }

    /// The rise is bounded by the maker's own Settlement token grant: without it,
    /// the fill cannot charge above the start fee.
    function test_audit_MISC_MOD_6_transferFlow_riseNeedsMakerGrant() public {
        tA.mint(maker, 1000e18);
        _makerApprove(address(xfer), address(tA), FEE_START + T);
        vm.prank(maker);
        permit3.approveTaker(
            address(settlement), address(xfer), keccak256(_data()), uint160(FEE_START + T), uint48(block.timestamp + 1 days)
        );
        Order memory o = _order(3);
        bytes memory sig = _sign(o);

        vm.warp(block.timestamp + DURATION);
        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(o, sig, type(uint256).max);
        assertEq(tA.balanceOf(recipient), 0, "atomic: nothing transferred");
    }

    /// A partial fill of the rising-fee order is refused by the module (full-fill
    /// only), so the constant transfer is never paid twice.
    function test_audit_MISC_MOD_6_transferFlow_partialRefused() public {
        _fund();
        Order memory o = _order(4);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(FullFillGuard.PartialFillUnsupported.selector, (FEE_START + T) / 2, FEE_START + T)
        );
        settlement.fill(o, sig, FEE_START / 2);
    }
}
