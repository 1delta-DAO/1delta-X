// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {MockSettlementBase} from "@coretest/shared/MockSettlementBase.t.sol";

import {Order, Item, ItemOp, LegOut} from "@core/settlement/Settlement.sol";
import {Proportional} from "@core/settlement/Proportional.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";

import {ProportionalSweepModule} from "../src/ProportionalSweepModule.sol";
import {ERC20PermitTransferModule} from "../src/ERC20PermitTransferModule.sol";

/// @title Audit20260930TransferTest
/// @notice Settlement-routed regressions for the 2026-09-30 audit findings on the
///         transfer modules:
///         - MISC-MOD-1: a fractional {ProportionalSweepModule} item re-applied its bps
///           to the post-sweep balance on every partial fill, sweeping toward the cap.
///         - L-LIB-2 / MISC-MOD-4 / X-ARITH-3: {ERC20PermitTransferModule} paid the
///           constant `transferAmount` on EVERY partial slice, the shortfall billed to
///           the maker's wallet.
contract Audit20260930TransferTest is MockSettlementBase {
    ProportionalSweepModule sweep;
    ERC20PermitTransferModule xfer;

    // ── sweep fixture (PoC MISC_MOD_1) ──
    uint256 constant USDC_IN = 1000e6;
    uint256 constant WETH_OUT = 0.4e18;
    uint256 constant USDT_BAL = 1000e6;
    uint256 constant CAP = 1000e6;

    // ── transfer fixture: fee F >= transfer T, the shape that leaked ──
    uint256 constant T = 1e18;
    uint256 constant F = 3e18;
    address recipient = address(0xCAFE);

    function setUp() public override {
        super.setUp();
        sweep = new ProportionalSweepModule(address(settlement), address(permit3));
        xfer = new ERC20PermitTransferModule(address(permit3));

        tB.mint(solver, 10e18);
        _solverApprove(address(settlement), address(tB), type(uint160).max);
    }

    // ───────────────────────────── MISC-MOD-1 ─────────────────────────────

    function _fundSweep() internal {
        tA.mint(maker, USDC_IN);
        tC.mint(maker, USDT_BAL);
        _makerApprove(address(settlement), address(tA), type(uint160).max);
        _makerApprove(address(sweep), address(tC), type(uint160).max);
    }

    function _sweepOrder(uint256 nonce, bytes memory data) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), USDC_IN, WETH_OUT);
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.SETTLE, module: address(sweep), amount: CAP, recipient: address(0), data: data});
        o.items = PackedEncode.items(items);
    }

    /// The PoC split (two half fills of "50% of my USDT") can no longer compound:
    /// the partial fill is refused, and the one full fill sweeps exactly 50%.
    function test_audit_MISC_MOD_1_fractionalSweep_cannotBeSplit() public {
        _fundSweep();
        Order memory o = _sweepOrder(1, abi.encode(address(tC), Proportional.encode(5000), CAP));
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(FullFillGuard.PartialFillUnsupported.selector, CAP / 2, CAP));
        settlement.fill(o, sig, USDC_IN / 2);

        vm.prank(solver);
        settlement.fill(o, sig, USDC_IN);
        assertEq(tC.balanceOf(solver), 500e6, "swept exactly 50% of the balance");
        assertEq(tC.balanceOf(maker), 500e6, "maker keeps the other half");
        assertEq(tB.balanceOf(maker), WETH_OUT);
    }

    /// The old two-word shape with a FRACTIONAL bps fails closed even on a full fill
    /// (it carries no total to pin the fill to).
    function test_audit_MISC_MOD_1_fractionalTwoWord_failsClosed() public {
        _fundSweep();
        Order memory o = _sweepOrder(2, abi.encode(address(tC), Proportional.encode(5000)));
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSignature("FractionalSweepNeedsTotal(uint256)", uint256(5000)));
        settlement.fill(o, sig, USDC_IN);
        assertEq(tC.balanceOf(maker), USDT_BAL, "nothing swept");
    }

    /// 100% stays split-safe in the two-word form: Σ min(Bₖ, sliceₖ) == min(B, cap).
    function test_audit_MISC_MOD_1_fullSweep_splitSweepsMinBalanceCap() public {
        _fundSweep();
        Order memory o = _sweepOrder(3, abi.encode(address(tC), Proportional.encode(10_000)));
        bytes memory sig = _sign(o);
        for (uint256 i; i < 4; ++i) {
            vm.prank(solver);
            settlement.fill(o, sig, USDC_IN / 4);
        }
        assertEq(tC.balanceOf(solver), USDT_BAL, "100% of the balance, never more");
        assertEq(tC.balanceOf(maker), 0);
    }

    // ───────────────────── L-LIB-2 / MISC-MOD-4 / X-ARITH-3 ─────────────────────

    function _xferData() internal view returns (bytes memory) {
        return abi.encode(address(tA), recipient, T, F + T);
    }

    function _xferOrder(uint256 nonce) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), F, 0);
        o.legsOut = PackedEncode.legsOut(new LegOut[](0)); // outputless: the fee is the solver's pay
        Item[] memory items = new Item[](1);
        items[0] =
            Item({op: ItemOp.TAKE, module: address(xfer), amount: F + T, recipient: address(0), data: _xferData()});
        o.items = PackedEncode.items(items);
    }

    function _fundXfer() internal {
        tA.mint(maker, 100e18);
        _makerApprove(address(xfer), address(tA), type(uint160).max); //      module pulls the gross
        _makerApprove(address(settlement), address(tA), type(uint160).max); // the core's shortfall pull
        vm.prank(maker);
        permit3.approveTaker(
            address(settlement), address(xfer), keccak256(_xferData()), uint160(F + T), uint48(block.timestamp + 1 days)
        );
    }

    /// Four 25% slices used to pay the recipient 4·T and bill the maker 7e18 instead
    /// of 4e18. Now a partial slice is refused and the full fill pays exactly T.
    function test_audit_L_LIB_2_partialSlice_refused_fullFillExact() public {
        _fundXfer();
        Order memory o = _xferOrder(10);
        bytes memory sig = _sign(o);
        uint256 makerBefore = tA.balanceOf(maker);

        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(o, sig, F / 4);
        assertEq(tA.balanceOf(recipient), 0, "no constant re-payment on a slice");

        vm.prank(solver);
        settlement.fill(o, sig, F);
        assertEq(tA.balanceOf(recipient), T, "recipient got exactly the signed transfer");
        assertEq(tA.balanceOf(solver), F, "solver got exactly the signed fee");
        assertEq(makerBefore - tA.balanceOf(maker), F + T, "maker paid exactly fee + transfer");
    }

    /// Direct module call: a slice that is not the signed total is refused.
    function test_audit_MISC_MOD_4_moduleRejectsSlice() public {
        vm.prank(address(permit3));
        vm.expectRevert(abi.encodeWithSelector(FullFillGuard.PartialFillUnsupported.selector, T, F + T));
        xfer.takeOnBehalf(maker, T, address(settlement), _xferData());
    }
}
