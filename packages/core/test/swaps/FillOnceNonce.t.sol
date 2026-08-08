// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Order, Item} from "@core/settlement/Settlement.sol";
import {OrderState} from "@core/settlement/OrderState.sol";
import {Base} from "@core/settlement/Base.sol";
import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @dev The fill-once opt-in ({DutchAuction.useNonceInvalidator}, `timing` bit 100):
///      settle against the maker's shared nonce bitmap instead of a dedicated
///      `filled[orderHash]` slot, trading a 22,100-gas zero-to-one write for a warm
///      one on a word 256 orders share.
contract FillOnceNonceTest is CoreSettlementBase {
    uint256 constant FILL_ONCE_BIT = 1 << 100;

    function _approveMakerPlainSwap(uint256 usdcCap) internal {
        vm.prank(maker);
        permit3.approveToken(address(settlement), USDC, uint160(usdcCap), 0);
    }

    function _swap(uint256 nonce, uint256 usdcIn, uint256 wethOut, bool fillOnce)
        internal
        view
        returns (Order memory o)
    {
        o = _order(maker, nonce, USDC, WETH, usdcIn, wethOut, new Item[](0));
        if (fillOnce) o.timing |= FILL_ONCE_BIT;
    }

    function _fund(uint256 usdcIn, uint256 wethOut) internal {
        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);
        _approveMakerPlainSwap(usdcIn);
        _approveSolverSide(wethOut, WETH);
    }

    // ──────────────────── Behaviour ────────────────────

    function test_fillOnce_settlesAndConsumesTheNonce() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        _fund(usdcIn, wethOut);

        Order memory order = _swap(7, usdcIn, wethOut, true);
        bytes memory sig = _sign(order);

        assertFalse(settlement.isNonceCancelled(maker, 7), "nonce unused before the fill");

        vm.prank(solver);
        assertEq(settlement.fill(order, sig, usdcIn)[0], wethOut, "solver paid wethOut");

        assertEq(IERC20(WETH).balanceOf(maker), wethOut, "maker received WETH");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver received USDC");

        // Progress lives in the nonce, NOT in the per-order counter.
        assertTrue(settlement.isNonceCancelled(maker, 7), "fill consumed the nonce");
        assertEq(settlement.filled(_hashOrder(order)), 0, "no per-order slot written");
    }

    /// @dev The load-bearing guard: a fill-once order must never accept a partial
    ///      fill, or the nonce would burn and strand the remainder.
    function test_fillOnce_partialFill_reverts() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        _fund(usdcIn, wethOut);

        Order memory order = _swap(8, usdcIn, wethOut, true);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(OrderState.FillOnceMustBeFull.selector);
        settlement.fill(order, sig, usdcIn / 2);
    }

    /// @dev A second fill is blocked by the nonce gate, not by the over-fill cap.
    function test_fillOnce_secondFill_revertsNonceCancelled() public {
        uint256 usdcIn = 1_000e6;
        uint256 wethOut = 0.5 ether;
        _fund(usdcIn * 2, wethOut * 2);

        Order memory order = _swap(9, usdcIn, wethOut, true);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, usdcIn);

        vm.prank(solver);
        vm.expectRevert(OrderState.NonceCancelled.selector);
        settlement.fill(order, sig, usdcIn);
    }

    /// @dev The maker is opting into shared nonce state: filling this order also kills
    ///      any sibling order signed under the same nonce. Documented, and asserted so
    ///      the footgun stays visible.
    function test_fillOnce_killsSiblingSharingTheNonce() public {
        uint256 usdcIn = 1_000e6;
        uint256 wethOut = 0.5 ether;
        _fund(usdcIn * 2, wethOut * 2);

        Order memory a = _swap(11, usdcIn, wethOut, true);
        Order memory b = _swap(11, usdcIn, wethOut, false); // sibling, same nonce
        b.deadline = a.deadline - 1; // make it a distinct hash
        bytes memory sigA = _sign(a);
        bytes memory sigB = _sign(b);

        vm.prank(solver);
        settlement.fill(a, sigA, usdcIn);

        vm.prank(solver);
        vm.expectRevert(OrderState.NonceCancelled.selector);
        settlement.fill(b, sigB, usdcIn);
    }

    /// @dev An order WITHOUT the flag is untouched — still counter-based, still
    ///      partially fillable. Every order signed before this flag existed reads
    ///      back 0 here, so this is the compatibility assertion.
    function test_withoutFlag_behaviourUnchanged() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        _fund(usdcIn, wethOut);

        Order memory order = _swap(12, usdcIn, wethOut, false);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, usdcIn / 2);
        vm.prank(solver);
        settlement.fill(order, sig, usdcIn / 2);

        assertFalse(settlement.isNonceCancelled(maker, 12), "nonce untouched without the flag");
        assertEq(IERC20(WETH).balanceOf(maker), wethOut, "both halves settled");
    }

    // ──────────────────── The point of it ────────────────────

    /// @dev Same order, flag on vs off. The flag must be cheaper once the maker's
    ///      nonce word is already non-zero — the steady state after that maker's first
    ///      cancellation or fill-once order in the word.
    ///
    ///      MEASUREMENT NOTE: running the two fills back-to-back does NOT isolate the
    ///      effect — they touch the same token balance slots, so whichever runs second
    ///      finds them warm and looks ~37k cheaper for reasons that have nothing to do
    ///      with this flag (measured, in both orderings). The only honest comparison
    ///      runs each fill from IDENTICAL state, so a snapshot is taken first and
    ///      reverted to in between. The two orders then differ in exactly one bit.
    function test_fillOnce_isCheaperThanTheDedicatedSlot() public {
        uint256 usdcIn = 1_000e6;
        uint256 wethOut = 0.5 ether;

        // Warm the maker's nonce word 0 so the comparison reflects steady state, not
        // the one-off first-order-in-the-word cost.
        uint256[] memory warm = new uint256[](1);
        warm[0] = 1;
        vm.prank(maker);
        settlement.cancelOrders(warm);
        _fund(usdcIn, wethOut);

        Order memory onceOrder = _swap(20, usdcIn, wethOut, true);
        Order memory counterOrder = _swap(20, usdcIn, wethOut, false);
        bytes memory sigO = _sign(onceOrder);
        bytes memory sigC = _sign(counterOrder);

        uint256 snap = vm.snapshotState();

        vm.prank(solver);
        uint256 g = gasleft();
        settlement.fill(onceOrder, sigO, usdcIn);
        uint256 onceGas = g - gasleft();

        vm.revertToState(snap); // both fills start from byte-identical state

        vm.prank(solver);
        g = gasleft();
        settlement.fill(counterOrder, sigC, usdcIn);
        uint256 counterGas = g - gasleft();

        emit log_named_uint("counter slot (22,100 zero-to-one)", counterGas);
        emit log_named_uint("fill-once    (warm bitmap write) ", onceGas);
        emit log_named_int("saving                           ", int256(counterGas) - int256(onceGas));
        assertLt(onceGas, counterGas, "fill-once must be cheaper than a dedicated counter slot");
        // Guard the magnitude too: a regression that quietly halved the win would
        // otherwise still pass the strict-less-than above.
        assertGt(counterGas - onceGas, 15_000, "expected ~19,200 of storage saving");
    }
}
