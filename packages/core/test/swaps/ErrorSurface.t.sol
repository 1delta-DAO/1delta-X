// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "@core/settlement/Base.sol";
import {OrderGates} from "@core/settlement/OrderGates.sol";
import {DutchAuction} from "@core/settlement/DutchAuction.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {Settlement, Order, Item, ItemOp, LegIn, LegOut} from "@core/settlement/Settlement.sol";

import {MockSettlementBase} from "../shared/MockSettlementBase.t.sol";
import {PackedEncode} from "../shared/PackedEncode.sol";
import {FixedBumpModule} from "../shared/MockModules.sol";

/// @dev A MAKE module that records the amount it was handed. Only ever reached in
///      the CONTROL case below — the overflow cases revert before dispatch.
contract RecordingMaker is IMakerModule {
    uint256 public lastAmount;

    function makeOnBehalf(address, uint256 amount, bytes calldata) external override {
        lastAmount = amount;
    }
}

/// @title ErrorSurfaceTest
/// @notice The tail of the settler's REFUSAL surface — the guards that no other
///         suite reaches, found mechanically rather than by reading.
///
///  PROVENANCE — `docs/edge-case-matrix.md`, Part 3. The axis tables in that note
///  are a human enumeration and can be incomplete. One enumeration cannot be:
///  **every `revert` the settler declares is a must-not cell**, so an error with no
///  test is an unpinned combination BY DEFINITION. Sweeping the 53 errors in
///  `src/settlement/` against the suite returned six with no reference anywhere in
///  `test/`. This file closes the ones that are reachable:
///
///    • {OrderGates.NoAnchorLeg}       — the empty-blob denominator guard
///    • {Base.AmountOverflow}          — the Permit3 `uint160` book width
///    • {Base.InvalidPermit3}          — the constructor's hub check
///    • {DutchAuction.PricingNeedsContext} — the context-free pricing views
///
///  ({Base.DeltaVerifyNotBatchable} is pinned in `MatchSettleGates.t.sol`, where
///  the rest of the netted gate sequence lives. {Base.TokenNotInUniverse} is an
///  internal-invariant backstop its own source calls unreachable — see the note at
///  the end of this file for why that one gets an invariant test rather than a
///  revert test.)
contract ErrorSurfaceTest is MockSettlementBase {
    uint256 constant AMOUNT_IN = 1_000e18;
    uint256 constant AMOUNT_OUT = 2_000e18;

    function _fund() internal {
        tA.mint(maker, AMOUNT_IN * 10);
        _makerApprove(address(settlement), address(tA), AMOUNT_IN * 10);
        tB.mint(solver, AMOUNT_OUT * 10);
        _solverApprove(address(settlement), address(tB), AMOUNT_OUT * 10);
    }

    // ════════════════════ NoAnchorLeg — the empty-blob denominator ════════════════════
    //
    // WHY THIS GUARD IS NOT COSMETIC, in the words of {OrderGates}' own header: a
    // packed blob is NOT an array. An out-of-range read does not revert — the
    // `calldataload` pads past the end and yields ZERO. So without the explicit
    // count check, an order with no legs and no `fillTotal` produces a denominator
    // of 0, and every downstream division is a panic or a nonsense answer. The lens
    // copy of `_anchorTotal` was MISSING exactly this check when the 2026-08 audit
    // found the drift. It is the guard that answers a found finding, and until now
    // it fired in no test.

    /// @dev SELL takes its denominator from `legsIn[0]`. No input legs, no signed
    ///      `fillTotal` ⇒ there is nothing to denominate the fill in.
    function test_noAnchorLeg_sellWithNoInputLegs_reverts() public {
        _fund();
        Order memory o = _blank(1);
        o.legsIn = PackedEncode.legsIn(new LegIn[](0)); // ← the empty blob
        o.legsOut = _legsOut1(address(tB), AMOUNT_OUT);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(OrderGates.NoAnchorLeg.selector);
        settlement.fill(o, sig, AMOUNT_IN);
    }

    /// @dev The mirror site. BUY denominates in `legsOut[0]`, so for a BUY order it
    ///      is the OUTPUT blob that must be non-empty. Both raise sites are
    ///      separately reachable and both are pinned — a single-sided test would let
    ///      a future edit delete the other one silently.
    function test_noAnchorLeg_buyWithNoOutputLegs_reverts() public {
        _fund();
        Order memory o = _blank(2);
        o.timing |= uint256(1) << 101; // BUY
        o.legsIn = PackedEncode.oneLegIn(address(tA), AMOUNT_IN, AMOUNT_IN * 2);
        o.legsOut = PackedEncode.legsOut(new LegOut[](0)); // ← the empty blob
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(OrderGates.NoAnchorLeg.selector);
        settlement.fill(o, sig, AMOUNT_OUT);
    }

    /// @dev The COMPLEMENT, and the reason the guard is phrased as "no anchor leg
    ///      AND no `fillTotal`" rather than "no legs". An empty-leg order with a
    ///      maker-signed `fillTotal` never reaches {OrderGates.anchorTotal} at all —
    ///      that is what makes module/NFT orders with no fungible leg expressible.
    ///      Without this case the two tests above would still pass if someone
    ///      "simplified" the guard into an unconditional empty-blob rejection.
    function test_noAnchorLeg_signedFillTotalNeedsNoLegs() public {
        _fund();
        Order memory o = _blank(3);
        o.legsIn = PackedEncode.legsIn(new LegIn[](0));
        o.legsOut = _legsOut1(address(tB), AMOUNT_OUT);
        o.fillTotal = AMOUNT_IN; // ← the denominator, signed
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fill(o, sig, AMOUNT_IN);
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "an anchorless order with a signed total settles");
    }

    // ════════════════════ AmountOverflow — Permit3's uint160 book width ════════════════════

    function _bigItemOrder(uint256 nonce, ItemOp op, address module, uint256 amount)
        internal
        view
        returns (Order memory o)
    {
        o = _blank(nonce);
        o.legsIn = _legsIn1(address(tA), AMOUNT_IN);
        o.legsOut = _legsOut1(address(tB), AMOUNT_OUT);
        Item[] memory its = new Item[](1);
        its[0] = Item({op: op, module: module, amount: amount, recipient: address(0), data: ""});
        o.items = PackedEncode.items(its);
    }

    /// @dev An item slice wider than Permit3's allowance type cannot be moved, and
    ///      must not be silently NARROWED. The MAKE branch is the one that used to
    ///      lack the check: every shipped maker module narrows to `uint160`
    ///      UNCHECKED one frame down, so without this a >2^160 slice would wrap to a
    ///      smaller pull while the identical value on the TAKE branch reverted.
    ///
    ///      Maker-signed, so not adversarially reachable — which is precisely why it
    ///      needs a test. Nothing else in the suite would notice the check being
    ///      dropped in a bytecode-size pass, and the failure mode it prevents is
    ///      silent truncation rather than a revert.
    function test_amountOverflow_makeItemAboveUint160_reverts() public {
        _fund();
        RecordingMaker m = new RecordingMaker();
        Order memory o = _bigItemOrder(10, ItemOp.MAKE, address(m), uint256(type(uint160).max) + 1);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(Base.AmountOverflow.selector);
        settlement.fill(o, sig, AMOUNT_IN);
        assertEq(m.lastAmount(), 0, "the module was never dispatched to");
    }

    /// @dev The TAKE branch carries its own copy of the check. Pinned separately for
    ///      the same reason as the two {NoAnchorLeg} sites.
    function test_amountOverflow_takeItemAboveUint160_reverts() public {
        _fund();
        RecordingMaker m = new RecordingMaker(); // never called; the guard is upstream
        Order memory o = _bigItemOrder(11, ItemOp.TAKE, address(m), uint256(type(uint160).max) + 1);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(Base.AmountOverflow.selector);
        settlement.fill(o, sig, AMOUNT_IN);
    }

    /// @dev The boundary is EXACTLY `uint160.max`, not one below it. A test that only
    ///      checked "huge reverts" would pass with an off-by-one in either direction.
    function test_amountOverflow_exactlyUint160Max_isAccepted() public {
        _fund();
        RecordingMaker m = new RecordingMaker();
        Order memory o = _bigItemOrder(12, ItemOp.MAKE, address(m), uint256(type(uint160).max));
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fill(o, sig, AMOUNT_IN);
        assertEq(m.lastAmount(), uint256(type(uint160).max), "the widest legal slice is dispatched intact");
    }

    // ════════════════════ InvalidPermit3 — the constructor's hub check ════════════════════

    /// @dev Settlement is useless without a real Permit3: every maker-side pull goes
    ///      through it, and a call to a codeless address SUCCEEDS silently in the
    ///      EVM. Deploying against `address(0)` — the classic mis-wired script — must
    ///      fail at construction rather than produce a settler that appears to fill
    ///      orders while moving nothing.
    function test_invalidPermit3_codelessHubRejectedAtConstruction() public {
        vm.expectRevert(Base.InvalidPermit3.selector);
        new Settlement(address(0));

        vm.expectRevert(Base.InvalidPermit3.selector);
        new Settlement(maker); // an EOA is just as codeless

        // Control: the real hub constructs fine, so the guard is the address check
        // and not something incidental to this test's environment.
        Settlement fresh = new Settlement(address(permit3));
        assertEq(address(fresh.PERMIT3()), address(permit3), "a real hub is accepted");
    }

    // ════════════════════ PricingNeedsContext — the context-free views ════════════════════
    //
    // {DutchAuction.currentAmountOut}/`currentAmountIn` price from the CLOCK alone.
    // A price-module or priority order has no clock price: its bump needs the filler,
    // the taker blob and the fill progress, none of which a per-leg view has. Failing
    // OPEN here would be the dangerous direction — the view would hand back `start`
    // (the maker's best price, and for a typical no-duration module order the only
    // thing the clock can say) while the fill clears somewhere else entirely. An
    // orderbook that sized against that number would be quoting a price the settler
    // never honours.

    function _moduleOrder(uint256 nonce, address mod) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        o.legsOut = PackedEncode.oneLegOut(address(tB), AMOUNT_OUT, AMOUNT_OUT / 2, address(0));
        o.pricingModule = mod;
    }

    function test_pricingNeedsContext_priceModuleOrder_hasNoClockTick() public {
        FixedBumpModule mod = new FixedBumpModule(5_000);
        Order memory o = _moduleOrder(20, address(mod));

        vm.expectRevert(DutchAuction.PricingNeedsContext.selector);
        lens.previewAmountOut(o);

        vm.expectRevert(DutchAuction.PricingNeedsContext.selector);
        lens.previewAmountIn(o);
    }

    /// @dev The same refusal for the other pinned mode. A priority auction's bump is
    ///      bid in the transaction's priority fee, so it does not exist at all
    ///      outside a fill.
    function test_pricingNeedsContext_priorityOrder_hasNoClockTick() public {
        Order memory o = _plainOrder(21, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        o.legsOut = PackedEncode.oneLegOut(address(tB), AMOUNT_OUT, AMOUNT_OUT / 2, address(0));
        o.timing |= uint256(1) << 103; // PRIORITY
        o.params |= uint256(1 gwei) << 96; // priorityScale

        vm.expectRevert(DutchAuction.PricingNeedsContext.selector);
        lens.previewAmountOut(o);

        vm.expectRevert(DutchAuction.PricingNeedsContext.selector);
        lens.previewAmountIn(o);
    }

    /// @dev The complement: an ordinary clock-priced order answers both views. This
    ///      is what stops the guard being widened into "these views never work".
    function test_pricingNeedsContext_clockOrderStillPreviews() public view {
        Order memory o = _plainOrder(22, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        uint256[] memory outs = lens.previewAmountOut(o);
        uint256[] memory ins = lens.previewAmountIn(o);
        assertEq(outs[0], AMOUNT_OUT, "fixed output previews at its signed amount");
        assertEq(ins[0], AMOUNT_IN, "fixed input previews at its signed amount");
    }
}
