// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order, Item, ItemOp, LegIn, LegOut, Validator} from "@core/settlement/Structs.sol";
import {Base} from "@core/settlement/Base.sol";
import {OrderState} from "@core/settlement/OrderState.sol";
import {Proportional} from "@core/settlement/Proportional.sol";
import {IPriceModule} from "@core/interfaces/IPriceModule.sol";
import {SettlementLens} from "@periphery/SettlementLens.sol";

import {MockSettlementBase} from "@coretest/shared/MockSettlementBase.t.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

/// @dev A price module whose answer can be moved mid-test — standing in for one that
///      reads state the fill itself changes (a pool, a balance, a pushed oracle).
contract MutablePriceModule20260930 is IPriceModule {
    uint256 public bps;

    function set(uint256 b) external {
        bps = b;
    }

    function bump(bytes32, address, address, uint256, uint256, uint256, bytes calldata, bytes calldata, bytes calldata)
        external
        view
        override
        returns (uint256)
    {
        return bps;
    }
}

/// @title Audit 2026-09-30 — SettlementLens parity remediation
/// @notice One regression test per lens finding; each asserts the lens now answers
///         the question the settler answers (and, where it costs little, proves the
///         settler's own verdict alongside).
contract Audit20260930LensTest is MockSettlementBase {
    uint256 constant IN_ = 1_000e18;
    uint256 constant OUT_ = 2_500e18;
    address constant DUMMY_MODULE = address(0x7E57); // never reached; no code
    address constant DEAD = address(0xdEaD);

    function _fundSolver(uint256 amt) internal {
        tB.mint(solver, amt);
        _solverApprove(address(settlement), address(tB), type(uint160).max);
    }

    function _state(Order memory o) internal view returns (SettlementLens.OrderStatus st, uint256 fillable) {
        (st, fillable,,) = lens.getOrderRelevantState(o, _sign(o), solver, "");
    }

    function _items1(ItemOp op, address module, uint256 amount, bytes memory data) internal pure returns (bytes memory) {
        Item[] memory its = new Item[](1);
        its[0] = Item({op: op, module: module, amount: amount, recipient: address(0), data: data});
        return PackedEncode.items(its);
    }

    // ═══════════ PERIPH-5: reserved nonce ═══════════

    function test_audit_PERIPH_5_reservedNonce_invalidAndUnquotable() public {
        Order memory o = _plainOrder((uint256(1) << 255) | 7, address(tA), address(tB), IN_, OUT_);
        tA.mint(maker, IN_);
        _makerApprove(address(settlement), address(tA), IN_);
        (SettlementLens.OrderStatus st, uint256 fillable) = _state(o);
        assertEq(uint256(st), uint256(SettlementLens.OrderStatus.Invalid), "reads Invalid, not Fillable");
        assertEq(fillable, 0);
        vm.expectRevert(SettlementLens.OrderNonceReserved.selector);
        lens.previewFill(o, IN_, solver, "");
        // ...exactly the settler's verdict.
        _fundSolver(OUT_);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(Base.OrderNonceReserved.selector);
        settlement.fill(o, sig, IN_);
    }

    // ═══════════ PERIPH-8: a completed 100% proportional sweep ═══════════

    function test_audit_PERIPH_8_completedSweep_readsFilled_remainingZero() public {
        tA.mint(maker, IN_);
        _makerApprove(address(settlement), address(tA), type(uint160).max);
        _fundSolver(OUT_);
        Order memory o = _plainOrder(80, address(tA), address(tB), 1, OUT_);
        o.legsIn = PackedEncode.oneLegIn(address(tA), Proportional.encode(10_000), type(uint128).max);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        settlement.fill(o, sig, IN_);
        assertEq(tA.balanceOf(maker), 0, "100% swept");

        (SettlementLens.OrderStatus st,) = _state(o);
        assertEq(uint256(st), uint256(SettlementLens.OrderStatus.Filled), "an executed sweep is Filled");
        assertEq(lens.remaining(o), 0, "no Panic(0x11)");
    }

    // ═══════════ G-LENS_PARITY-1: the ERC-20 approval to Permit3 ═══════════

    function test_audit_G_LENS_PARITY_1_revokedPermit3Approval_readsUnfunded() public {
        tA.mint(maker, IN_);
        _makerApprove(address(settlement), address(tA), type(uint160).max);
        Order memory o = _plainOrder(10, address(tA), address(tB), IN_, OUT_);
        (, uint256 fillable) = _state(o);
        assertEq(fillable, IN_, "funded");

        vm.prank(maker);
        tA.approve(address(permit3), 0); // the hub kill switch; the book is untouched
        (, fillable) = _state(o);
        assertEq(fillable, 0, "a book Permit3 cannot spend funds nothing");
        _fundSolver(OUT_);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(o, sig, IN_);

        // A direct approval to the settlement funds the fallback pull — and reads so.
        vm.prank(maker);
        tA.approve(address(settlement), type(uint256).max);
        (, fillable) = _state(o);
        assertEq(fillable, IN_, "fallback-funded");
        vm.prank(solver);
        settlement.fill(o, sig, IN_);
    }

    // ═══════════ G-LENS_PARITY-2: the minimum fill ═══════════

    function test_audit_G_LENS_PARITY_2_strandedTail_readsZeroAndIsNamed() public {
        tA.mint(maker, IN_);
        _makerApprove(address(settlement), address(tA), type(uint160).max);
        _fundSolver(OUT_);
        Order memory o = _plainOrder(20, address(tA), address(tB), IN_, OUT_);
        o.minFillAnchor = 100e18;
        bytes memory sig = _sign(o);
        vm.prank(solver);
        settlement.fill(o, sig, 950e18);

        (SettlementLens.OrderStatus st, uint256 fillable) = _state(o);
        assertEq(uint256(st), uint256(SettlementLens.OrderStatus.Fillable));
        assertEq(fillable, 0, "a 50e18 tail under a 100e18 floor can never fill");
        (bool ok, string memory why) = lens.validateOrder(o);
        assertFalse(ok);
        assertEq(why, "remaining below minFillAnchor (stranded tail)");
        vm.prank(solver);
        vm.expectRevert(OrderState.FillTooSmall.selector);
        settlement.fillUpTo(o, sig, type(uint256).max, address(0), 0, "");
    }

    function test_audit_G_LENS_PARITY_2_fundingBelowFloor_readsZero() public {
        tA.mint(maker, IN_);
        _makerApprove(address(settlement), address(tA), 80e18); // under the floor
        Order memory o = _plainOrder(21, address(tA), address(tB), IN_, OUT_);
        o.minFillAnchor = 100e18;
        (, uint256 fillable) = _state(o);
        assertEq(fillable, 0, "fundable 80e18 < floor 100e18: nothing can fill");
    }

    // ═══════════ G-LENS_PARITY-3: the BALANCE descriptor's floor ═══════════

    function _balanceTakeFor(uint256 nonce, uint256 floorBps, uint256 cap) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), IN_, OUT_);
        o.minFillAnchor = IN_;
        uint256 desc = (uint256(1) << 255) | (uint256(1) << 254) | (floorBps << 160) | uint256(uint160(address(tC)));
        o.items = _items1(ItemOp.TAKE_FOR, DUMMY_MODULE, 1e18, abi.encode(desc, cap));
    }

    function test_audit_G_LENS_PARITY_3_balanceUnderFloor_requiresTheFloor() public {
        Order memory o = _balanceTakeFor(30, 0, 10e18); // unset floor = the whole cap
        tC.mint(maker, 9e18);
        SettlementLens.ItemFunding memory f = lens.previewItemFunding(o);
        assertEq(f.required[0], 10e18, "the floor, not the short balance");
        assertGt(f.required[0], tC.balanceOf(maker), "so `available >= required` fails, as the fill does");

        tC.mint(maker, 5e18); // now above the cap
        f = lens.previewItemFunding(o);
        assertEq(f.required[0], 10e18, "min(balance, cap)");

        Order memory z = _balanceTakeFor(31, 1, 10e18); // 0.01% floor
        vm.prank(maker);
        tC.transfer(address(1), 14e18); // balance 0
        f = lens.previewItemFunding(z);
        assertGt(f.required[0], 0, "a zero balance never reads as funded");
    }

    // ═══════════ G-LENS_PARITY-4: a floor above 10_000 bps ═══════════

    function test_audit_G_LENS_PARITY_4_floorAboveBps_isTheFullCap() public view {
        Order memory o = _balanceTakeFor(40, 0xFFFF, 10e18);
        (bool ok, string memory why) = lens.validateOrder(o);
        assertTrue(ok, why);
    }

    // ═══════════ G-LENS_PARITY-5: duplicate legs, `0` vs `maker` ═══════════

    function test_audit_G_LENS_PARITY_5_zeroAndMakerAreTheSameRecipient() public view {
        Order memory o = _plainOrder(50, address(tA), address(tB), IN_, OUT_);
        o.timing |= uint256(1) << 104; // delta-verify
        o.exclusiveFiller = solver;
        LegOut[] memory lo = new LegOut[](2);
        lo[0] = LegOut(address(tB), 500e18, 0, address(0));
        lo[1] = LegOut(address(tB), 10e18, 0, maker);
        o.legsOut = PackedEncode.legsOut(lo);
        (bool ok, string memory why) = lens.validateOrder(o);
        assertFalse(ok);
        assertEq(why, "duplicate output token+recipient");
    }

    // ═══════════ G-LENS_PARITY-6: structurally dead shapes ═══════════

    function _assertInvalid(Order memory o, string memory what) internal view {
        (SettlementLens.OrderStatus st, uint256 fillable) = _state(o);
        assertEq(uint256(st), uint256(SettlementLens.OrderStatus.Invalid), what);
        assertEq(fillable, 0, what);
    }

    function test_audit_G_LENS_PARITY_6_deadShapesReadInvalid() public {
        tA.mint(maker, IN_);
        tC.mint(maker, IN_);
        _makerApprove(address(settlement), address(tA), type(uint160).max);
        _makerApprove(address(settlement), address(tC), type(uint160).max);

        Order memory ok = _plainOrder(60, address(tA), address(tB), IN_, OUT_);
        (SettlementLens.OrderStatus st,) = _state(ok);
        assertEq(uint256(st), uint256(SettlementLens.OrderStatus.Fillable), "control");

        // (a) a proportional marker on legsIn[1]
        Order memory a = _plainOrder(61, address(tA), address(tB), IN_, OUT_);
        LegIn[] memory li = new LegIn[](2);
        li[0] = LegIn(address(tA), IN_, 0);
        li[1] = LegIn(address(tC), Proportional.encode(5_000), 1e30);
        a.legsIn = PackedEncode.legsIn(li);
        _assertInvalid(a, "proportional on leg 1");
        _fundSolver(OUT_);
        bytes memory sig = _sign(a);
        vm.prank(solver);
        vm.expectRevert(Proportional.InvalidProportionalLeg.selector);
        settlement.fill(a, sig, IN_);

        // (b) a SELL output that rises
        Order memory b = _plainOrder(62, address(tA), address(tB), IN_, OUT_);
        b.legsOut = PackedEncode.oneLegOut(address(tB), OUT_, 2 * OUT_, address(0));
        _assertInvalid(b, "rising SELL output");

        // (c) a priority auction without a scale
        Order memory c = _plainOrder(63, address(tA), address(tB), IN_, OUT_);
        c.timing |= uint256(1) << 103;
        _assertInvalid(c, "priority without scale");

        // (d) an unknown item op
        Order memory d = _plainOrder(64, address(tA), address(tB), IN_, OUT_);
        d.items = PackedEncode.itemRawOp(9, DUMMY_MODULE, 1, address(0), "");
        _assertInvalid(d, "unknown op");

        // (e) a malformed invariants blob — the settler reverts at the end of the fill
        Order memory e = _plainOrder(65, address(tA), address(tB), IN_, OUT_);
        e.invariants = hex"01";
        _assertInvalid(e, "malformed invariants");
        sig = _sign(e);
        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(e, sig, IN_);
    }

    // ═══════════ G-BYTE_MAP-6: descriptor classification ═══════════

    function test_audit_G_BYTE_MAP_6_preFundMakeSizedFromItsDescriptor() public view {
        Order memory o = _plainOrder(70, address(tA), address(tB), IN_, OUT_);
        o.legsOut = PackedEncode.oneLegOut(address(tB), OUT_, 0, DUMMY_MODULE);
        uint256 desc = (uint256(5) << 253) | (uint256(uint160(address(tB))) << 16); // pre-fund, leg 0
        o.items = _items1(ItemOp.MAKE, DUMMY_MODULE, 0, abi.encode(desc)); // SDK signs amount 0
        SettlementLens.ItemFunding memory f = lens.previewItemFunding(o);
        assertEq(f.required[0], OUT_, "the leg's delivery, not the unread head amount");
    }

    function test_audit_G_BYTE_MAP_6_settleWordIsNotADescriptor() public view {
        Order memory o = _plainOrder(71, address(tA), address(tB), IN_, OUT_);
        uint256 word = uint256(5) << 253; // module data that happens to open with bits 101
        Item[] memory its = new Item[](2);
        its[0] = Item({op: ItemOp.SETTLE, module: DUMMY_MODULE, amount: 2, recipient: address(0), data: abi.encode(word)});
        its[1] = Item({op: ItemOp.SETTLE, module: DUMMY_MODULE, amount: 2, recipient: address(0), data: abi.encode(word)});
        o.items = PackedEncode.items(its);
        (bool ok, string memory why) = lens.validateOrder(o);
        assertTrue(ok, why);
    }

    // ═══════════ PERIPH-2.v3: funding for the dearest filler ═══════════

    function test_audit_PERIPH_2_v3_softWindow_requiredIncludesOutsiderLift() public {
        Order memory o = _plainOrder(72, address(tA), address(tB), IN_, OUT_); // leg 0 to the maker
        o.items = _items1(ItemOp.TAKE_FOR, DUMMY_MODULE, 1e18, abi.encode(uint256(1) << 255)); // pull leg-ref, j = 0
        o.exclusiveFiller = DEAD;
        _setExclusivityEnd(o, block.timestamp + 10 minutes);
        o.params = 2_000; // 20% soft override
        SettlementLens.ItemFunding memory f = lens.previewItemFunding(o);
        assertEq(f.required[0], OUT_ * 12_000 / 10_000, "an in-window outsider delivers (and funds) the lift");
        (,, uint256[] memory paid) = lens.previewFill(o, IN_, solver, "");
        assertEq(f.required[0], paid[0], "== what an outsider's fill delivers");

        vm.warp(block.timestamp + 10 minutes);
        f = lens.previewItemFunding(o);
        assertEq(f.required[0], OUT_, "after the window: the plain tick");
    }

    // ═══════════ PRICE-15: price-module / priority orders ═══════════

    function test_audit_PRICE_15_itemFundingForPriceModuleOrder() public {
        MutablePriceModule20260930 pm = new MutablePriceModule20260930();
        pm.set(5_000);
        Order memory o = _plainOrder(73, address(tA), address(tB), IN_, OUT_);
        o.legsOut = PackedEncode.oneLegOut(address(tB), OUT_, OUT_ / 2, address(0));
        o.pricingModule = address(pm);
        o.items = _items1(ItemOp.TAKE_FOR, DUMMY_MODULE, 1e18, abi.encode(uint256(1) << 255));
        SettlementLens.ItemFunding memory f = lens.previewItemFunding(o); // used to revert PricingNeedsContext
        assertEq(f.required[0], OUT_, "sized at `start`, the most any filler delivers");

        o.pricingModule = address(0);
        o.timing |= uint256(1) << 103; // priority
        o.params = uint256(1 gwei) << 96;
        f = lens.previewItemFunding(o);
        assertEq(f.required[0], OUT_, "priority: `start` too");
    }

    // ═══════════ VAL-1.v2: the consideration rule ═══════════

    function _invariant() internal pure returns (bytes memory) {
        Validator[] memory v = new Validator[](1);
        v[0] = Validator({target: address(0x1A7), data: hex"01"});
        return PackedEncode.validators(v);
    }

    string constant INV_ONLY = "invariant-only consideration needs a single hard exclusiveFiller for the order's life";

    function test_audit_VAL_1_v2_fillTotalPurchaseOnInvariantFlagged() public view {
        // FullFillModule-style purchase: pay 10,000 USDC, receipt proven by an invariant.
        Order memory o = _blank(90);
        o.legsIn = PackedEncode.oneLegIn(address(tA), 10_000e6, 0);
        o.fillModule = DUMMY_MODULE;
        o.fillTotal = 1;
        o.minFillAnchor = 1;
        o.invariants = _invariant();
        (bool ok, string memory why) = lens.validateOrder(o);
        assertFalse(ok);
        assertEq(why, INV_ONLY);

        // Safe when only a trusted, named, hard filler can fill for the order's life.
        o.exclusiveFiller = solver;
        _setExclusivityEnd(o, _expiry(o));
        (ok, why) = lens.validateOrder(o);
        assertTrue(ok, why);
    }

    function test_audit_VAL_1_v2_settleTradeUpOnInvariantFlagged() public view {
        Order memory o = _blank(91);
        o.legsOut = PackedEncode.oneLegOut(address(tB), 0.5e18, 0, maker); // a sweetener leg
        o.fillModule = DUMMY_MODULE;
        o.fillTotal = 1;
        o.minFillAnchor = 1;
        o.items = _items1(ItemOp.SETTLE, DUMMY_MODULE, 1, abi.encode(address(tC), uint256(1)));
        o.invariants = _invariant();
        (bool ok, string memory why) = lens.validateOrder(o);
        assertFalse(ok);
        assertEq(why, INV_ONLY);
    }

    function test_audit_VAL_1_v2_giveawaysFlaggedWhateverTheDenominator() public view {
        // fillTotal giveaway: input, nothing back.
        Order memory a = _blank(92);
        a.legsIn = PackedEncode.oneLegIn(address(tA), 10_000e6, 0);
        a.fillModule = DUMMY_MODULE;
        a.fillTotal = 1;
        a.minFillAnchor = 1;
        (bool ok, string memory why) = lens.validateOrder(a);
        assertFalse(ok);
        assertEq(why, "no tokenOut and no items (giveaway)");

        // A lone SETTLE item is not consideration: it pays the FILLER.
        Order memory b = _plainOrder(93, address(tA), address(tB), IN_, OUT_);
        b.legsOut = PackedEncode.legsOut(new LegOut[](0));
        b.minFillAnchor = IN_;
        b.items = _items1(ItemOp.SETTLE, DUMMY_MODULE, 1, abi.encode(address(tC), uint256(1)));
        (ok, why) = lens.validateOrder(b);
        assertFalse(ok);
        assertEq(why, "no tokenOut and no items (giveaway)");
    }

    // ═══════════ CORE-FILLER-5: the in-flight bump ═══════════

    function test_audit_CORE_FILLER_5_pinnedPreviewMatchesTheFill() public {
        MutablePriceModule20260930 pm = new MutablePriceModule20260930();
        pm.set(5_000);
        tA.mint(maker, IN_);
        _makerApprove(address(settlement), address(tA), type(uint160).max);
        _fundSolver(OUT_);
        Order memory o = _plainOrder(94, address(tA), address(tB), IN_, OUT_);
        o.legsOut = PackedEncode.oneLegOut(address(tB), OUT_, OUT_ / 2, address(0));
        o.pricingModule = address(pm);
        bytes memory sig = _sign(o);

        (, uint256 prevFilled, uint256 anchor) = lens.fillState(o);
        uint256 pin = lens.pinnedBump(o, solver, "");
        vm.prank(solver);
        settlement.fill(o, sig, IN_);
        uint256 delivered = tB.balanceOf(maker);
        assertEq(delivered, OUT_ * 3 / 4, "the fill pinned bump 5000");

        pm.set(0); // the module's state moves after the pin (as inside a callback)
        (, uint256[] memory reResolved) = lens.previewFillInFlight(o, prevFilled, anchor, solver, "");
        (, uint256[] memory pinned) = lens.previewFillInFlightPinned(o, prevFilled, anchor, solver, pin);
        assertTrue(reResolved[0] != delivered, "re-resolving disagrees with the fill");
        assertEq(pinned[0], delivered, "the captured pin reproduces it exactly");
    }
}
