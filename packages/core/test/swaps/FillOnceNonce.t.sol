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
        _setExpiry(b, _expiry(a) - 1); // make it a distinct hash
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

    // ════════ Fill-once outside the single-order `fill` — M3/B5 ════════
    //
    //  {OrderState._openFill} owns the rule (`newFilled != total` ⇒
    //  {FillOnceMustBeFull}) and every entry point reaches it, so these cases are
    //  correct by reading. They are here because the CONSEQUENCES differ per path
    //  and the reading does not cover them:
    //
    //    • `fillUpTo` CLAMPS the request to the remaining size. For a fill-once
    //      order that remainder is the whole order, so an over-request must succeed
    //      rather than trip the rule — the clamp and the rule have to agree, and
    //      they are computed in different places.
    //    • `batchFill` swallows a per-order revert into `success[i] = false`, so a
    //      partial fill-once must fail SOFTLY there while its siblings still settle
    //      — and, crucially, must not consume the nonce on the way out.
    //
    //  ({matchSettle} is covered in `MatchSettleGates.t.sol`, alongside the rest of
    //  that path's gate sequence.)

    /// @dev `fillUpTo` clamps to the remaining size, which for an untouched
    ///      fill-once order is the whole order — so asking for more than exists is
    ///      the ORDINARY way to fill one, not a violation of the full-fill rule.
    function test_fillOnce_fillUpTo_overRequestClampsToTheWholeOrder() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        _fund(usdcIn, wethOut);

        Order memory order = _swap(30, usdcIn, wethOut, true);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        (uint256 delta,,) = settlement.fillUpTo(order, sig, type(uint256).max, address(0), 0, "");
        assertEq(delta, usdcIn, "clamped onto the full order");
        assertTrue(settlement.isNonceCancelled(maker, 30), "the nonce is the progress record");
        assertEq(settlement.filled(_hashOrder(order)), 0, "no per-order slot written");
    }

    /// @dev …and an explicit UNDER-request through the same entry point is still a
    ///      partial, so it is still refused. The clamp only ever lowers a request; it
    ///      cannot rescue one the maker never authorised.
    function test_fillOnce_fillUpTo_underRequest_reverts() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        _fund(usdcIn, wethOut);

        Order memory order = _swap(31, usdcIn, wethOut, true);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(OrderState.FillOnceMustBeFull.selector);
        settlement.fillUpTo(order, sig, usdcIn / 2, address(0), 0, "");
        assertFalse(settlement.isNonceCancelled(maker, 31), "a refused fill burns no nonce");
    }

    /// @dev In a batch a fill-once order settles like any other, and its nonce is
    ///      consumed — which also kills any sibling sharing that nonce, exactly as on
    ///      the single-order path.
    function test_fillOnce_batchFill_settlesAndConsumesTheNonce() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        _fund(usdcIn, wethOut);

        Order memory order = _swap(32, usdcIn, wethOut, true);
        Order[] memory orders = new Order[](1);
        orders[0] = order;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(order);
        uint256[] memory amts = new uint256[](1);
        amts[0] = usdcIn;

        vm.prank(solver);
        (, bool[] memory ok) = settlement.batchFill(orders, sigs, amts, true);
        assertTrue(ok[0], "fill-once settles inside a batch");
        assertTrue(settlement.isNonceCancelled(maker, 32), "nonce consumed");
    }

    /// @dev THE PATH-SPECIFIC CASE. `batchFill` catches a per-order revert and
    ///      reports `success[i] = false` rather than reverting the batch, so a
    ///      partial fill-once fails SOFTLY here — and the whole `fillSelf` sub-call
    ///      is rolled back, so the nonce it would have burned survives. Without that,
    ///      one badly-sized batch entry would strand a maker's order permanently.
    function test_fillOnce_batchFill_partialFailsSoftlyAndBurnsNoNonce() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        _fund(usdcIn * 2, wethOut * 2);

        Order memory bad = _swap(33, usdcIn, wethOut, true); //  asked for a partial
        Order memory good = _swap(34, usdcIn, wethOut, false); // an ordinary sibling

        Order[] memory orders = new Order[](2);
        (orders[0], orders[1]) = (bad, good);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(bad);
        sigs[1] = _sign(good);
        uint256[] memory amts = new uint256[](2);
        (amts[0], amts[1]) = (usdcIn / 2, usdcIn);

        vm.prank(solver);
        (, bool[] memory ok) = settlement.batchFill(orders, sigs, amts, false);
        assertFalse(ok[0], "the partial fill-once was skipped, not reverted");
        assertTrue(ok[1], "and its sibling still settled");
        assertFalse(settlement.isNonceCancelled(maker, 33), "the rolled-back attempt burned no nonce");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "only the good order moved funds");

        // The order is untouched, so it is still fillable at its full size.
        vm.prank(solver);
        settlement.fill(bad, sigs[0], usdcIn);
        assertTrue(settlement.isNonceCancelled(maker, 33), "and it settles once asked for in full");
    }

    /// @dev `revertIfIncomplete` turns the soft failure hard, naming the index. The
    ///      pair pins that the choice is the CALLER's and that the rule is what fails.
    function test_fillOnce_batchFill_revertIfIncomplete_namesTheIndex() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        _fund(usdcIn, wethOut);

        Order memory order = _swap(35, usdcIn, wethOut, true);
        Order[] memory orders = new Order[](1);
        orders[0] = order;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(order);
        uint256[] memory amts = new uint256[](1);
        amts[0] = usdcIn / 2;

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.BatchFillIncomplete.selector, uint256(0)));
        settlement.batchFill(orders, sigs, amts, true);
    }
}
