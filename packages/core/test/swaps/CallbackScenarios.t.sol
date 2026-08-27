// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "@core/settlement/Base.sol";
import {OrderState} from "@core/settlement/OrderState.sol";
import {Settlement, CallbackMode, Order, MatchPlan} from "@core/settlement/Settlement.sol";
import {SolverCallbackExecutor} from "@core/settlement/SolverCallbackExecutor.sol";
import {ISettlementCallback} from "@core/interfaces/ISettlementCallback.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";

import {MockSettlementBase, MockERC20} from "../shared/MockSettlementBase.t.sol";

/// @dev Single-overload views of every WRITE entry point, so a reentrancy payload can
///      be built with `abi.encodeCall` (the real ones are overloaded, which
///      `encodeCall` cannot resolve). {SettlementGuards} declares a smaller version of
///      this for the four hand-armed families; this one covers the whole surface.
interface IEveryEntry {
    function fill(Order calldata o, bytes calldata sig, uint256 amt) external returns (uint256[] memory);
    function fillUpTo(
        Order calldata o,
        bytes calldata sig,
        uint256 amt,
        address recipient,
        uint256 minBumpBps,
        bytes calldata takerData
    ) external returns (uint256, uint256[] memory, uint256[] memory);
    function batchFill(
        Order[] calldata orders,
        bytes[] calldata sigs,
        uint256[] calldata fillAmounts,
        bool revertIfIncomplete
    ) external returns (uint256[][] memory, bool[] memory);
    function matchSettle(MatchPlan calldata p)
        external
        returns (uint256[][] memory, address[] memory, uint256[] memory);
    function fillSelf(Order calldata o, bytes calldata sig, uint256 amt, address filler, bytes calldata takerData)
        external
        returns (uint256[] memory);
    function fillWithPermitTake(
        Order calldata o,
        IPermit3.PermitTake calldata permit,
        bytes calldata sig,
        uint256 amt
    ) external returns (uint256[] memory);
}

/// @dev A callback that re-enters Settlement with an ARBITRARY payload, reachable
///      through BOTH callback shapes: `poke()` for the untyped `(target, data)` form
///      and {ISettlementCallback.onSettlementFill} for the `*Typed` modes. One
///      contract covers the whole matrix, and the inner revert is bubbled verbatim so
///      the test can assert on the REAL rejection rather than on "something failed".
contract PayloadCallback is ISettlementCallback {
    Settlement immutable SETTLEMENT;
    bytes public payload;

    constructor(Settlement s) {
        SETTLEMENT = s;
    }

    function setPayload(bytes calldata p) external {
        payload = p;
    }

    function poke() external {
        _reenter();
    }

    /// @inheritdoc ISettlementCallback
    function onSettlementFill(
        bytes32,
        uint256,
        uint256,
        uint256,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external {
        _reenter();
    }

    function _reenter() internal {
        (bool ok, bytes memory ret) = address(SETTLEMENT).call(payload);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}

/// @dev A callback that does nothing at all — the solver promised just-in-time
///      inventory and produced none.
contract DeadbeatCallback {
    function nothing() external pure {}
}

/// @dev Reverts with a caller-chosen payload of arbitrary length, to prove the
///      hand-written `returndatacopy` bubble in {Core._execute} survives a revert
///      far larger than a selector.
contract BigReverter {
    function boomWith(uint256 size) external pure {
        bytes memory big = new bytes(size);
        for (uint256 i; i < size; ++i) {
            big[i] = bytes1(uint8(0xA0 + (i % 16)));
        }
        assembly {
            revert(add(big, 0x20), mload(big))
        }
    }
}

/// @dev Supplies the solver's output AND returns a fat value. {Core._execute} passes
///      0 for the return-data window, so a callback that returns something must be
///      harmless rather than a decode failure.
contract ChattySupplier {
    function supplyAndReturn(address to, address token, uint256 amount) external returns (uint256[] memory chatter) {
        MockERC20(token).transfer(to, amount);
        chatter = new uint256[](32);
        for (uint256 i; i < 32; ++i) {
            chatter[i] = type(uint256).max - i;
        }
    }
}

/// @title CallbackScenarios
/// @notice The solver-callback failure matrix, on the three axes a filler-supplied
///         callback can go wrong:
///
///           1. IT RE-ENTERS. The callback is arbitrary attacker code running with a
///              fill mid-flight — after `_openFill` has already written `filled` and,
///              under a `PostInputs*` mode, after the maker's input has already been
///              handed over. Every write entry point must reject it.
///           2. IT DOES NOT DELIVER. Both delivery primitives — the ordinary pull and
///              the measured {DutchAuction.deltaVerifyOutputs} path — must leave the
///              maker whole, and must leave `filled` unmoved.
///           3. IT REVERTS. The reason must reach the filler intact; a solver's
///              failure taxonomy (docs/filler-strategy.md) is built on telling a
///              stale route from an unfillable order.
///
///         Axis 2's delta-verify half lives in {DeltaVerifyDelivery}, next to the
///         primitive it measures; axis 3's revert-SHAPE taxonomy lives in
///         {CallbackRevertBubbling}. This file covers what neither did: the entry
///         matrix, both callback shapes, and both orderings.
contract CallbackScenariosTest is MockSettlementBase {
    uint256 constant AMOUNT_IN = 1_000e18;
    uint256 constant AMOUNT_OUT = 2_000e18;

    function _fundMaker() internal {
        tA.mint(maker, AMOUNT_IN);
        _makerApprove(address(settlement), address(tA), AMOUNT_IN);
    }

    function _fundSolver(uint256 amount) internal {
        tB.mint(solver, amount);
        _solverApprove(address(settlement), address(tB), amount);
    }

    function _order(uint256 nonce) internal view returns (Order memory) {
        return _plainOrder(nonce, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
    }

    /// @dev The executor wraps a failed callback as `CallbackFailed(ret)` and
    ///      Settlement forwards it verbatim, so every expectation here is one layer
    ///      deep. Asserting the INNER bytes is the point: a bare `expectRevert()`
    ///      would pass on any failure, including the fill failing for an unrelated
    ///      reason, which is exactly what these tests must not do.
    function _expectWrapped(bytes memory inner) internal {
        vm.expectRevert(abi.encodeWithSignature("CallbackFailed(bytes)", inner));
    }

    // ════════════════ 1. Attempted reentrancy, every entry point ════════════════

    /// @dev Runs `payload` from inside the callback of a live fill and asserts the
    ///      inner rejection. `mode` picks the ordering AND the callback shape, so the
    ///      same payload can be proven blocked through all four.
    function _reentersInto(bytes memory payload, CallbackMode mode, bytes memory expectedInner) internal {
        _fundMaker();
        _fundSolver(AMOUNT_OUT);
        PayloadCallback cb = new PayloadCallback(settlement);
        cb.setPayload(payload);

        Order memory o = _order(1);
        bytes memory sig = _sign(o);

        _expectWrapped(expectedInner);
        vm.prank(solver);
        settlement.fillWithCallback(o, sig, AMOUNT_IN, address(cb), abi.encodeCall(PayloadCallback.poke, ()), mode);
    }

    function _reenters(bytes memory payload) internal {
        _reentersInto(payload, CallbackMode.PreDelivery, abi.encodeWithSelector(Base.Reentrancy.selector));
    }

    /// @dev A fresh, independently fillable order — so nothing but the guard can be
    ///      what rejects the inner call.
    function _innerOrder() internal returns (Order memory o, bytes memory sig) {
        tA.mint(maker, AMOUNT_IN);
        _makerApprove(address(settlement), address(tA), 2 * AMOUNT_IN);
        tB.mint(solver, AMOUNT_OUT);
        _solverApprove(address(settlement), address(tB), 2 * AMOUNT_OUT);
        o = _plainOrder(2, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        sig = _sign(o);
    }

    /// THE DOUBLE-SPEND SHAPE, and it is stopped by TWO different things depending on
    /// how much of the order the outer fill opened. Both halves are pinned below,
    /// because the two rejections mean different things to a filler and only one of
    /// them is the reentrancy guard.
    ///
    /// FULL outer fill: `_openFill` has already advanced `filled` to the anchor, and
    /// the inner call's READ-ONLY state gate runs BEFORE `_enter()` (deliberately —
    /// it is what makes a lost priority-auction race cheap, see {Base._enter}). So the
    /// counter rejects it as {OverFill} and the guard is never consulted.
    function test_reenter_sameOrderAfterFullOpen_rejectedByTheCounter() public {
        _fundMaker();
        _fundSolver(2 * AMOUNT_OUT);
        PayloadCallback cb = new PayloadCallback(settlement);

        Order memory o = _order(1);
        bytes memory sig = _sign(o);
        cb.setPayload(abi.encodeCall(IEveryEntry.fill, (o, sig, AMOUNT_IN)));

        _expectWrapped(abi.encodeWithSelector(OrderState.OverFill.selector));
        vm.prank(solver);
        settlement.fillWithCallback(
            o, sig, AMOUNT_IN, address(cb), abi.encodeCall(PayloadCallback.poke, ()), CallbackMode.PreDelivery
        );

        assertEq(settlement.filled(lens.hashOrder(o)), 0, "the whole tx unwound: no progress recorded");
        assertEq(tB.balanceOf(maker), 0, "and nothing was delivered");
    }

    /// PARTIAL outer fill: the order still has room, so the inner call passes the
    /// state gate on its own merits and reaches `_enter()`. THIS is the case that
    /// proves the guard rather than the counter is holding the line — without it a
    /// half-filled order could be advanced twice from inside its own callback.
    function test_reenter_sameOrderAfterPartialOpen_blockedByTheGuard() public {
        _fundMaker();
        _fundSolver(2 * AMOUNT_OUT);
        PayloadCallback cb = new PayloadCallback(settlement);

        Order memory o = _order(1);
        bytes memory sig = _sign(o);
        cb.setPayload(abi.encodeCall(IEveryEntry.fill, (o, sig, AMOUNT_IN / 2)));

        _expectWrapped(abi.encodeWithSelector(Base.Reentrancy.selector));
        vm.prank(solver);
        settlement.fillWithCallback(
            o, sig, AMOUNT_IN / 2, address(cb), abi.encodeCall(PayloadCallback.poke, ()), CallbackMode.PreDelivery
        );

        assertEq(settlement.filled(lens.hashOrder(o)), 0, "no progress recorded");
        assertEq(tB.balanceOf(maker), 0, "and nothing was delivered");
    }

    function test_reenter_fill_blocked() public {
        (Order memory o, bytes memory sig) = _innerOrder();
        _reenters(abi.encodeCall(IEveryEntry.fill, (o, sig, AMOUNT_IN)));
    }

    function test_reenter_fillUpTo_blocked() public {
        (Order memory o, bytes memory sig) = _innerOrder();
        _reenters(abi.encodeCall(IEveryEntry.fillUpTo, (o, sig, AMOUNT_IN, address(0), 0, "")));
    }

    function test_reenter_batchFill_blocked() public {
        _reenters(
            abi.encodeCall(IEveryEntry.batchFill, (new Order[](0), new bytes[](0), new uint256[](0), false))
        );
    }

    /// @dev The netted path wears `nonReentrant` on the function, so an empty plan is
    ///      enough — the guard fires before the plan is ever looked at.
    function test_reenter_matchSettle_blocked() public {
        MatchPlan memory empty;
        _reenters(abi.encodeCall(IEveryEntry.matchSettle, (empty)));
    }

    function test_reenter_fillWithPermitTake_blocked() public {
        (Order memory o, bytes memory sig) = _innerOrder();
        IPermit3.PermitTake memory permit;
        _reenters(abi.encodeCall(IEveryEntry.fillWithPermitTake, (o, permit, sig, AMOUNT_IN)));
    }

    /// @dev `fillSelf` is not guarded — it is gated HARDER, on `msg.sender == this`.
    ///      The callback runs as the EXECUTOR, so it cannot reach the body at all and
    ///      the rejection is `OnlySelf`, not `Reentrancy`. Pinned because the two
    ///      failures mean different things: one says "later", the other "never".
    function test_reenter_fillSelf_rejectedAsOnlySelf() public {
        (Order memory o, bytes memory sig) = _innerOrder();
        _reentersInto(
            abi.encodeCall(IEveryEntry.fillSelf, (o, sig, AMOUNT_IN, solver, "")),
            CallbackMode.PreDelivery,
            abi.encodeWithSelector(Base.OnlySelf.selector)
        );
    }

    /// @dev THE DANGEROUS MOMENT. Under `PostInputs` the maker's tokenIn has ALREADY
    ///      been paid to the solver when the callback runs, and no output has been
    ///      delivered yet — the one window where re-entering could compound a
    ///      half-settled fill. The guard spans it.
    function test_reenter_underPostInputs_blocked() public {
        (Order memory o, bytes memory sig) = _innerOrder();
        _reentersInto(
            abi.encodeCall(IEveryEntry.fill, (o, sig, AMOUNT_IN)),
            CallbackMode.PostInputs,
            abi.encodeWithSelector(Base.Reentrancy.selector)
        );
    }

    /// @dev The typed shapes build a different PAYLOAD but share the ordering and the
    ///      guard, so they must reject identically. Note the callback is reached at
    ///      `onSettlementFill`, not `poke` — same contract, different door.
    function test_reenter_underPreDeliveryTyped_blocked() public {
        (Order memory o, bytes memory sig) = _innerOrder();
        _reentersInto(
            abi.encodeCall(IEveryEntry.fill, (o, sig, AMOUNT_IN)),
            CallbackMode.PreDeliveryTyped,
            abi.encodeWithSelector(Base.Reentrancy.selector)
        );
    }

    function test_reenter_underPostInputsTyped_blocked() public {
        (Order memory o, bytes memory sig) = _innerOrder();
        _reentersInto(
            abi.encodeCall(IEveryEntry.fill, (o, sig, AMOUNT_IN)),
            CallbackMode.PostInputsTyped,
            abi.encodeWithSelector(Base.Reentrancy.selector)
        );
    }

    // ════════════════ 2. Failure to deliver — the ordinary PULL path ════════════════
    //
    // The delta-verify half of this axis is in {DeltaVerifyDelivery}; here the core
    // PULLS from the filler, so "did not deliver" means the pull finds nothing.

    /// @dev The callback produces NOTHING and the solver holds no inventory. Delivery
    ///      is mandatory, so the fill unwinds whole: the maker keeps its input, and —
    ///      the part worth pinning — `filled` is back to zero even though `_openFill`
    ///      advanced it BEFORE the callback ran.
    function test_noDelivery_preDelivery_unwindsAndLeavesNoProgress() public {
        _fundMaker(); // solver deliberately funded with NOTHING
        DeadbeatCallback cb = new DeadbeatCallback();
        Order memory o = _order(1);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert();
        settlement.fillWithCallback(
            o, sig, AMOUNT_IN, address(cb), abi.encodeCall(DeadbeatCallback.nothing, ()), CallbackMode.PreDelivery
        );

        assertEq(tA.balanceOf(maker), AMOUNT_IN, "maker kept its input");
        assertEq(tB.balanceOf(maker), 0, "and received nothing");
        assertEq(settlement.filled(lens.hashOrder(o)), 0, "no progress survived the unwind");
    }

    /// @dev One wei short is still short. This is what makes the passing callback
    ///      tests meaningful: delivery is an exact floor, not an approximation.
    function test_shortDelivery_byOneWei_reverts() public {
        _fundMaker();
        _fundSolver(AMOUNT_OUT - 1);
        DeadbeatCallback cb = new DeadbeatCallback();
        Order memory o = _order(1);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert();
        settlement.fillWithCallback(
            o, sig, AMOUNT_IN, address(cb), abi.encodeCall(DeadbeatCallback.nothing, ()), CallbackMode.PreDelivery
        );

        assertEq(tA.balanceOf(maker), AMOUNT_IN, "maker kept its input");
        assertEq(tB.balanceOf(solver), AMOUNT_OUT - 1, "and the solver kept its short stock");
    }

    /// @dev Delivering the right amount to the WRONG address is not delivering. The
    ///      pull is from the filler to the leg's recipient, so a callback that moves
    ///      its stock elsewhere simply has nothing left to be pulled.
    function test_deliveryToTheWrongAddress_reverts() public {
        _fundMaker();
        _fundSolver(AMOUNT_OUT);
        address elsewhere = makeAddr("elsewhere");

        Order memory o = _order(1);
        bytes memory sig = _sign(o);
        // The callback moves the solver's whole output stock somewhere that is not the
        // maker — from Settlement's point of view the filler is now empty-handed.
        bytes memory cb = abi.encodeWithSignature("transfer(address,uint256)", elsewhere, AMOUNT_OUT);

        vm.prank(solver);
        vm.expectRevert();
        settlement.fillWithCallback(o, sig, AMOUNT_IN, address(tB), cb, CallbackMode.PreDelivery);

        assertEq(tA.balanceOf(maker), AMOUNT_IN, "maker kept its input");
        assertEq(tB.balanceOf(maker), 0, "and received nothing");
    }

    // ════════════════ 3. Revert capture ════════════════
    //
    // The revert SHAPE taxonomy (Error(string) / custom error / bare / Panic / typed
    // mode) is pinned in {CallbackRevertBubbling}. What is left is the hand-written
    // bubble itself: {Core._execute} copies returndata to a buffer past the free
    // pointer, which is only obviously correct for a payload that fits in scratch.

    /// @dev A revert payload of 2KB — far past the 64-byte scratch space the bubble
    ///      deliberately does NOT use — arrives byte-for-byte. A copy to offset 0
    ///      would clobber the free-memory pointer at 0x40 and truncate or corrupt
    ///      this; that is the bug this test would catch.
    function test_bubble_hugeRevertPayload_arrivesIntact() public {
        _fundMaker();
        _fundSolver(AMOUNT_OUT);
        BigReverter target = new BigReverter();
        Order memory o = _order(1);
        bytes memory sig = _sign(o);

        uint256 size = 2_048;
        bytes memory expected = new bytes(size);
        for (uint256 i; i < size; ++i) {
            expected[i] = bytes1(uint8(0xA0 + (i % 16)));
        }

        _expectWrapped(expected);
        vm.prank(solver);
        settlement.fillWithCallback(
            o,
            sig,
            AMOUNT_IN,
            address(target),
            abi.encodeCall(BigReverter.boomWith, (size)),
            CallbackMode.PreDelivery
        );
    }

    /// @dev And the mirror image: a callback that SUCCEEDS while returning a fat
    ///      value. The bubble asks for a zero-length return window, so returndata on
    ///      the happy path must be ignored rather than decoded — otherwise a
    ///      perfectly good route would fail for being talkative.
    function test_callbackReturnData_isIgnored_andTheFillSettles() public {
        _fundMaker();
        ChattySupplier supplier = new ChattySupplier();
        tB.mint(address(supplier), AMOUNT_OUT);
        _solverApprove(address(settlement), address(tB), AMOUNT_OUT);

        Order memory o = _order(1);
        bytes memory sig = _sign(o);
        bytes memory cb = abi.encodeCall(ChattySupplier.supplyAndReturn, (solver, address(tB), AMOUNT_OUT));

        vm.prank(solver);
        settlement.fillWithCallback(o, sig, AMOUNT_IN, address(supplier), cb, CallbackMode.PreDelivery);

        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "maker paid from just-in-time inventory");
        assertEq(tA.balanceOf(solver), AMOUNT_IN, "solver took the input");
    }
}
