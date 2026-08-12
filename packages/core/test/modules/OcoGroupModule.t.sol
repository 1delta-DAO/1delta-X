// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "../shared/PackedEncode.sol";

import {Base} from "@core/settlement/Base.sol";
import {Order, Item, ItemOp, Validator} from "@core/settlement/Settlement.sol";
import {OcoGroupModule} from "@core/modules/OcoGroupModule.sol";
import {OrderState} from "@core/settlement/OrderState.sol";

import {MockSettlementBase} from "../shared/MockSettlementBase.t.sol";

/// @title OcoGroupModuleTest
/// @notice One-cancels-other coverage. Two mechanisms, both asserted here:
///
///   1. {OcoGroupModule} — a validator that READS the group claim plus a SETTLE
///      item that WRITES it. Survives partial fills of the winner, scales to
///      N-way brackets, costs one CALL + one SSTORE.
///   2. The zero-contract path — two orders sharing a nonce with the fill-once
///      bit set, where the settlement's own nonce gate does the work.
///
/// The adversarial cases matter more than the happy path: signing only one half
/// of the pair must not silently produce a bracket where BOTH legs can fill.
///
/// @dev Every fill signs BEFORE `vm.prank`: `_sign` calls
///      `settlement.DOMAIN_SEPARATOR()`, which would otherwise consume the prank
///      and land the fill from the test contract instead of `solver`.
contract OcoGroupModuleTest is MockSettlementBase {
    uint256 constant AMOUNT_IN = 100e18; // tA the maker gives, per leg (the anchor)
    uint256 constant TP_OUT = 300e18; //    take-profit leg wants more tB
    uint256 constant SL_OUT = 200e18; //    stop-loss leg accepts less

    /// @dev `timing` bit 100 — {DutchAuction.useNonceInvalidator}.
    uint256 constant FILL_ONCE_BIT = uint256(1) << 100;

    uint256 constant GROUP = 0xB4A6E7;
    uint256 constant TP_NONCE = 1;
    uint256 constant SL_NONCE = 2;

    OcoGroupModule oco;

    function setUp() public override {
        super.setUp();
        oco = new OcoGroupModule(address(settlement));
        vm.label(address(oco), "ocoGroupModule");

        // Enough tA for BOTH legs, so nothing but the OCO gate can stop the
        // second fill — a funding shortfall would be a false pass.
        tA.mint(maker, 1_000e18);
        _makerApprove(address(settlement), address(tA), type(uint160).max);

        tB.mint(solver, 10_000e18);
        _solverApprove(address(settlement), address(tB), type(uint160).max);
    }

    // ──────────────────── Builders ────────────────────

    function _ocoValidator(uint256 groupId) internal view returns (bytes memory) {
        Validator[] memory v = new Validator[](1);
        v[0] = Validator({target: address(oco), data: abi.encode(groupId)});
        return PackedEncode.validators(v);
    }

    /// @dev `amount` is the ANCHOR, so the pro-rata slice equals this fill's
    ///      delta and never floors to zero on a partial. The module ignores the
    ///      value itself.
    function _ocoItem(uint256 groupId, uint256 nonce) internal view returns (bytes memory) {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.SETTLE,
            module: address(oco),
            amount: AMOUNT_IN,
            recipient: address(0),
            data: abi.encode(groupId, nonce)
        });
        return PackedEncode.items(items);
    }

    /// @dev One leg of an OCO group: the plain tA→tB order plus BOTH halves of
    ///      the module — the reading validator and the writing SETTLE item.
    function _leg(uint256 nonce, uint256 amountOut, uint256 groupId) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), AMOUNT_IN, amountOut);
        o.validators = _ocoValidator(groupId);
        o.items = _ocoItem(groupId, nonce);
    }

    /// @dev A leg carrying ONLY the validator — reads the gate, never claims it.
    function _legValidatorOnly(uint256 nonce, uint256 amountOut, uint256 groupId)
        internal
        view
        returns (Order memory o)
    {
        o = _plainOrder(nonce, address(tA), address(tB), AMOUNT_IN, amountOut);
        o.validators = _ocoValidator(groupId);
    }

    /// @dev A leg carrying ONLY the claim item — no validator to read it back.
    function _legItemOnly(uint256 nonce, uint256 amountOut, uint256 groupId) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), AMOUNT_IN, amountOut);
        o.items = _ocoItem(groupId, nonce);
    }

    function _fill(Order memory o, uint256 amount) internal {
        bytes memory sig = _sign(o);
        vm.prank(solver);
        settlement.fill(o, sig, amount);
    }

    function _expectValidationFailed() internal {
        vm.expectRevert(abi.encodeWithSelector(Base.ValidationFailed.selector, uint256(0)));
    }

    // ──────────────────── The bracket ────────────────────

    /// Take-profit fills; the stop-loss leg of the same group is dead.
    function test_oco_firstLegFills_secondIsRetired() public {
        Order memory tp = _leg(TP_NONCE, TP_OUT, GROUP);
        Order memory sl = _leg(SL_NONCE, SL_OUT, GROUP);

        _fill(tp, AMOUNT_IN);

        assertEq(oco.claim(maker, GROUP), TP_NONCE + 1, "group claimed by the take-profit leg");
        assertTrue(oco.isRetiredFor(maker, GROUP, SL_NONCE), "stop-loss reads as retired");
        assertFalse(oco.isRetiredFor(maker, GROUP, TP_NONCE), "the winner is not retired against itself");

        bytes memory slSig = _sign(sl);
        vm.prank(solver);
        _expectValidationFailed();
        settlement.fill(sl, slSig, AMOUNT_IN);
    }

    /// Symmetry: the group has no privileged leg — whichever lands first wins.
    function test_oco_isSymmetric_stopLossCanWin() public {
        Order memory tp = _leg(TP_NONCE, TP_OUT, GROUP);
        Order memory sl = _leg(SL_NONCE, SL_OUT, GROUP);

        _fill(sl, AMOUNT_IN);
        assertEq(oco.claim(maker, GROUP), SL_NONCE + 1, "group claimed by the stop-loss leg");

        bytes memory tpSig = _sign(tp);
        vm.prank(solver);
        _expectValidationFailed();
        settlement.fill(tp, tpSig, AMOUNT_IN);
    }

    /// The winner stays PARTIALLY fillable — the regression the nonce-keyed claim
    /// exists to prevent. A plain `claimed = true` flag would brick the winner on
    /// its own second slice.
    function test_oco_winnerKeepsFillingAcrossPartials() public {
        Order memory tp = _leg(TP_NONCE, TP_OUT, GROUP);
        Order memory sl = _leg(SL_NONCE, SL_OUT, GROUP);

        uint256 before = tB.balanceOf(maker);

        _fill(tp, AMOUNT_IN / 4);
        _fill(tp, AMOUNT_IN / 4);
        _fill(tp, AMOUNT_IN / 2);

        assertEq(settlement.filled(_hashOrder(tp)), AMOUNT_IN, "winner filled to completion in three slices");
        assertEq(tB.balanceOf(maker) - before, TP_OUT, "maker received the whole signed output");

        // …and the sibling was dead from the FIRST slice, not the last.
        bytes memory slSig = _sign(sl);
        vm.prank(solver);
        _expectValidationFailed();
        settlement.fill(sl, slSig, AMOUNT_IN);
    }

    /// The sibling dies on the winner's first PARTIAL fill, not only on completion.
    function test_oco_siblingDiesOnFirstPartialFill() public {
        Order memory tp = _leg(TP_NONCE, TP_OUT, GROUP);
        Order memory sl = _leg(SL_NONCE, SL_OUT, GROUP);

        _fill(tp, AMOUNT_IN / 10);

        bytes memory slSig = _sign(sl);
        vm.prank(solver);
        _expectValidationFailed();
        settlement.fill(sl, slSig, AMOUNT_IN);
    }

    /// N-way bracket: TP + SL + a third leg, all retired by one fill.
    function test_oco_nWayBracket() public {
        Order memory a = _leg(1, TP_OUT, GROUP);
        Order memory b = _leg(2, SL_OUT, GROUP);
        Order memory c = _leg(3, 250e18, GROUP);

        _fill(b, AMOUNT_IN);

        bytes memory aSig = _sign(a);
        vm.prank(solver);
        _expectValidationFailed();
        settlement.fill(a, aSig, AMOUNT_IN);

        bytes memory cSig = _sign(c);
        vm.prank(solver);
        _expectValidationFailed();
        settlement.fill(c, cSig, AMOUNT_IN);
    }

    /// Groups are isolated: an unrelated bracket of the same maker is untouched.
    function test_oco_groupsAreIsolated() public {
        Order memory inGroup = _leg(TP_NONCE, TP_OUT, GROUP);
        Order memory other = _leg(SL_NONCE, SL_OUT, GROUP + 1);

        _fill(inGroup, AMOUNT_IN);
        _fill(other, AMOUNT_IN); // different group ⇒ unaffected

        assertEq(oco.claim(maker, GROUP + 1), SL_NONCE + 1, "the other group claimed independently");
    }

    /// Claims are maker-keyed: one maker's bracket cannot retire another's.
    function test_oco_claimsAreMakerScoped() public {
        Order memory mine = _leg(TP_NONCE, TP_OUT, GROUP);
        _fill(mine, AMOUNT_IN);

        assertFalse(oco.isRetiredFor(solver, GROUP, TP_NONCE), "another maker's identical group is untouched");
        assertEq(oco.claim(solver, GROUP), 0, "no cross-maker write");
    }

    // ──────────────────── Adversarial ────────────────────

    /// A solver cannot retire a maker's bracket out of band — {settle} is
    /// settlement-gated, so griefing by direct call is impossible.
    function test_oco_directClaimReverts() public {
        vm.expectRevert(OcoGroupModule.NotSettlement.selector);
        vm.prank(solver);
        oco.settle(maker, solver, AMOUNT_IN, abi.encode(GROUP, TP_NONCE));
    }

    /// Dropping either half is not a solver-side option — both are inside the
    /// EIP-712 hash, so a stripped leg is a DIFFERENT order the maker never
    /// signed. These two tests assert what each half is load-bearing FOR, by
    /// signing the degenerate shapes deliberately.
    ///
    /// Validator only ⇒ reads the gate but never claims it, so two such legs BOTH
    /// fill. The item is what closes the group.
    function test_oco_validatorWithoutItem_doesNotRetireSiblings() public {
        Order memory a = _legValidatorOnly(1, TP_OUT, GROUP);
        Order memory b = _legValidatorOnly(2, SL_OUT, GROUP);

        _fill(a, AMOUNT_IN);
        _fill(b, AMOUNT_IN);

        assertEq(oco.claim(maker, GROUP), 0, "nothing ever claimed the group");
    }

    /// Item only ⇒ claims but never reads. The module's fail-closed backstop
    /// stops the second leg anyway, with the module's own error rather than the
    /// settlement's `ValidationFailed`.
    function test_oco_itemWithoutValidator_stillFailsClosed() public {
        Order memory a = _legItemOnly(1, TP_OUT, GROUP);
        Order memory b = _legItemOnly(2, SL_OUT, GROUP);

        _fill(a, AMOUNT_IN);

        bytes memory bSig = _sign(b);
        vm.prank(solver);
        vm.expectRevert(OcoGroupModule.GroupAlreadyClaimed.selector);
        settlement.fill(b, bSig, AMOUNT_IN);
    }

    /// A zero-slice claim item must never SKIP (which would silently break the
    /// bracket). SETTLE is the op that reverts instead — this pins that posture.
    function test_oco_zeroSliceClaimRevertsRatherThanSkips() public {
        Order memory o = _plainOrder(9, address(tA), address(tB), AMOUNT_IN, TP_OUT);
        o.validators = _ocoValidator(GROUP);
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.SETTLE,
            module: address(oco),
            amount: 1, // ← misconfigured: rounds away on any partial fill
            recipient: address(0),
            data: abi.encode(GROUP, uint256(9))
        });
        o.items = PackedEncode.items(items);

        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(Base.SettleSliceZero.selector);
        settlement.fill(o, sig, AMOUNT_IN / 2);
    }

    /// `nonce == max` cannot be stored as `nonce + 1`; rejected, never wrapped
    /// into the "unclaimed" sentinel (which would silently disable the group).
    function test_oco_maxNonceRejected() public {
        Order memory o = _leg(type(uint256).max, TP_OUT, GROUP);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(OcoGroupModule.NonceNotRepresentable.selector);
        settlement.fill(o, sig, AMOUNT_IN);
    }

    // ──────────────────── The zero-contract path ────────────────────

    /// Shared nonce + fill-once: no module, no extra gas, whole-fill only. The
    /// settlement's existing nonce gate is the entire mechanism.
    function test_oco_sharedNonceFillOnce_needsNoModule() public {
        Order memory tp = _plainOrder(7, address(tA), address(tB), AMOUNT_IN, TP_OUT);
        tp.timing |= FILL_ONCE_BIT;
        Order memory sl = _plainOrder(7, address(tA), address(tB), AMOUNT_IN, SL_OUT); // SAME nonce
        sl.timing |= FILL_ONCE_BIT;

        _fill(tp, AMOUNT_IN);
        assertTrue(settlement.isNonceCancelled(maker, 7), "the shared nonce was consumed by the fill");

        bytes memory slSig = _sign(sl);
        vm.prank(solver);
        vm.expectRevert(OrderState.NonceCancelled.selector);
        settlement.fill(sl, slSig, AMOUNT_IN);
    }

    /// …and its documented limit: fill-once refuses a partial, so this path is
    /// whole-fill brackets only. {OcoGroupModule} is the answer when that is too
    /// strict.
    function test_oco_sharedNonceFillOnce_rejectsPartials() public {
        Order memory tp = _plainOrder(7, address(tA), address(tB), AMOUNT_IN, TP_OUT);
        tp.timing |= FILL_ONCE_BIT;

        bytes memory sig = _sign(tp);
        vm.prank(solver);
        vm.expectRevert(OrderState.FillOnceMustBeFull.selector);
        settlement.fill(tp, sig, AMOUNT_IN / 2);
    }
}
