// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {Settlement, CallbackMode, Order} from "@core/settlement/Settlement.sol";

import {MockSettlementBase, MockERC20} from "../shared/MockSettlementBase.t.sol";

/// @title DirectOutputsTest
/// @notice {CallbackMode} bit 2 — DIRECT OUTPUTS. The filler declares it funds
///         its output legs by a plain ERC20 approval, and delivery goes straight
///         to `transferFrom`: no Permit3 probe, no strict-mode read. The four
///         cells that pin the semantics: it works with a direct approval, it does
///         NOT reach into a Permit3 allowance, a strict-mode filler is not stopped
///         by its own flag (the hint is about its own money), and the maker's
///         input pull is untouched by the bit.
contract DirectOutputsTest is MockSettlementBase {
    uint256 constant AMOUNT_IN = 1_000e18;
    uint256 constant AMOUNT_OUT = 900e18;

    function setUp() public override {
        super.setUp();
        tA.mint(maker, AMOUNT_IN);
        _makerApprove(address(settlement), address(tA), AMOUNT_IN);
        tB.mint(solver, AMOUNT_OUT * 4);
    }

    function _o(uint256 nonce) internal view returns (Order memory) {
        return _plainOrder(nonce, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
    }

    function _fill(Order memory o, CallbackMode mode) internal {
        bytes memory sig = _sign(o);
        vm.prank(solver);
        settlement.fillWithCallback(o, sig, AMOUNT_IN, address(0), "", mode);
    }

    /// @dev The whole point: a direct ERC20 approval to Settlement, no Permit3
    ///      allowance anywhere, and the direct bit delivers. (The same fill without
    ///      the bit also succeeds — via the failed Permit3 probe and the fallback —
    ///      so the two are behaviourally identical here; the bit is a gas hint.)
    function test_direct_deliversFromDirectApproval() public {
        vm.prank(solver);
        tB.approve(address(settlement), AMOUNT_OUT);
        _fill(_o(1), CallbackMode.PostInputsDirect);
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "delivered by direct transferFrom");
        assertEq(tA.balanceOf(solver), AMOUNT_IN, "maker's input pulled as usual");
    }

    /// @dev The bit means "use my direct approval" — it never consults Permit3, so
    ///      a filler whose ONLY grant is a Permit3 allowance cannot use it.
    function test_direct_doesNotReachThePermit3Allowance() public {
        _solverApprove(address(settlement), address(tB), uint160(AMOUNT_OUT));
        assertEq(tB.allowance(solver, address(settlement)), 0, "no direct approval");
        Order memory o = _o(2);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert();
        settlement.fillWithCallback(o, sig, AMOUNT_IN, address(0), "", CallbackMode.PostInputsDirect);

        // …while the same grant serves the ordinary mode.
        _fill(_o(3), CallbackMode.PostInputs);
        assertEq(tB.balanceOf(maker), AMOUNT_OUT);
    }

    /// @dev Strict mode is a payer's protection against ITS OWN standing direct
    ///      approvals being used behind its back. A filler that sets the direct bit
    ///      is asking for exactly that, in the same call, about its own funds — so
    ///      the flag is not read. Without the bit the same fill is refused.
    function test_direct_strictFillerIsNotStoppedByItsOwnFlag() public {
        vm.startPrank(solver);
        tB.approve(address(settlement), type(uint256).max);
        permit3.setStrictMode(true);
        vm.stopPrank();

        Order memory o = _o(4);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(IPermit3.Permit3Denied.selector);
        settlement.fillWithCallback(o, sig, AMOUNT_IN, address(0), "", CallbackMode.PostInputs);

        _fill(_o(5), CallbackMode.PostInputsDirect);
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "the filler's own choice, honoured");
    }

    /// @dev The bit is about the filler's legs only. A strict-mode MAKER whose
    ///      Permit3 allowance is revoked stays protected whatever the filler sets.
    function test_direct_makerPullIsUntouched() public {
        vm.startPrank(maker);
        tA.approve(address(settlement), type(uint256).max); // a standing direct approval…
        permit3.setStrictMode(true); // …that strict mode must make unusable
        permit3.approveToken(address(settlement), address(tA), 0, 0); // Permit3 grant revoked
        vm.stopPrank();
        vm.prank(solver);
        tB.approve(address(settlement), AMOUNT_OUT);

        Order memory o = _o(6);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(IPermit3.Permit3Denied.selector);
        settlement.fillWithCallback(o, sig, AMOUNT_IN, address(0), "", CallbackMode.PostInputsDirect);
    }

    /// @dev Both orderings honour the bit.
    function test_direct_preDeliveryOrdering() public {
        vm.prank(solver);
        tB.approve(address(settlement), AMOUNT_OUT);
        _fill(_o(7), CallbackMode.PreDeliveryDirect);
        assertEq(tB.balanceOf(maker), AMOUNT_OUT);
    }
}
