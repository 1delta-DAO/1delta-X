// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "../shared/PackedEncode.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {OrderHash} from "@core/settlement/OrderHash.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {ITakerForModule} from "@core/interfaces/ITakerForModule.sol";
import {Order, Item, ItemOp, LegIn, LegOut} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {SettlementLens} from "@periphery/SettlementLens.sol";

import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @dev TAKE_FOR mock, shaped like a real leverage adapter: it pulls the funding
///      leg from the maker (the "deposit") and hands `amount` of a stashed token to
///      `receiver` (the "borrow"). Both amounts are recorded so the tests can assert
///      on what the CORE sized, not on what the module chose.
contract MockTakeFor is ITakerForModule {
    IPermit3 public immutable permit3;

    uint256[] public amounts;
    uint256[] public forAmounts;
    uint256 public totalFor;

    function takeForOnBehalf(address onBehalfOf, uint256 amount, uint256 forAmount, address receiver, bytes calldata data)
        external
        override
    {
        require(msg.sender == address(permit3), "only permit3");
        (,, address fundingToken, address proceedsToken) = abi.decode(data, (uint256, uint256, address, address));

        if (forAmount != 0) permit3.transferFrom(onBehalfOf, address(this), fundingToken, uint160(forAmount));
        IERC20(proceedsToken).transfer(receiver, amount);

        amounts.push(amount);
        forAmounts.push(forAmount);
        totalFor += forAmount;
    }

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function calls() external view returns (uint256) {
        return amounts.length;
    }
}

/// @dev A PLAIN taker module signed into a `TAKE_FOR` item. It has no
///      `takeForOnBehalf`, so the dispatch must fail rather than land in
///      `takeOnBehalf` with a shifted argument list.
contract MockPlainTaker is ITakerModule {
    address public immutable permit3;

    constructor(address _permit3) {
        permit3 = _permit3;
    }

    function takeOnBehalf(address, uint256, address, bytes calldata) external view override {
        require(msg.sender == permit3, "only permit3");
    }
}

/// @title TakeForItem
/// @notice The `TAKE_FOR` item: one dispatch that draws value OUT of the maker's
///         position and funds the value-IN side of the same operation.
///
///  The property under test is where the funding amount COMES FROM. A composite
///  module that carries its own copy of the number in `data` has to re-derive the
///  per-fill share, and that copy is unchecked against the order: mis-scale it and
///  the funding leg silently pulls up to the maker's standing token allowance, or
///  under-funds the position. Here the core computes it from a signed descriptor —
///  either a reference to one of the order's own `legsOut` (so the number exists
///  exactly once, in a typed leg with its token beside it) or a literal total the
///  core slices with the same differencing it applies to `item.amount`.
///
///  The headline assertion is the leg-reference one: over a fill, the maker's net
///  balance in the funding token is ZERO — what the solver delivered is exactly
///  what went back into the position, on full and partial fills alike.
contract TakeForItemTest is CoreSettlementBase {
    MockTakeFor takeFor;
    MockPlainTaker plainTaker;

    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    uint256 constant USDC_IN = 1_500e6; //  the maker's input leg == the SELL anchor
    uint256 constant WETH_OUT = 1 ether; // delivered to the maker, then supplied

    /// @dev `(1 << 255) | index` — fund from `legsOut[index]`.
    function _forLeg(uint256 index) internal pure returns (uint256) {
        return (uint256(1) << 255) | index;
    }

    function setUp() public override {
        super.setUp();
        takeFor = new MockTakeFor(address(permit3));
        plainTaker = new MockPlainTaker(address(permit3));
        vm.label(address(takeFor), "mockTakeFor");

        // Borrow inventory the mock hands out as proceeds.
        deal(USDC, address(takeFor), USDC_IN * 10);
        // The maker's side of the funding pull.
        vm.prank(maker);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
    }

    // ──────────────────── helpers ────────────────────

    /// @dev One layout for all three funding forms — `cap` is only read by the
    ///      core, and only for the balance form.
    function _data(uint256 forDesc) internal view returns (bytes memory) {
        return _data(forDesc, 0);
    }

    function _data(uint256 forDesc, uint256 cap) internal view returns (bytes memory) {
        return _dataFunding(forDesc, cap, WETH);
    }

    function _dataFunding(uint256 forDesc, uint256 cap, address fundingToken) internal view returns (bytes memory) {
        return abi.encode(forDesc, cap, fundingToken, USDC);
    }

    /// @dev `(3 << 254) | token` — fund with `min(balanceOf(token, maker), cap)`.
    function _forBalance(address token) internal pure returns (uint256) {
        return (uint256(3) << 254) | uint160(token);
    }

    /// @dev SELL order: maker gives USDC (funded by the take), receives WETH (which
    ///      the same call supplies back into the position).
    function _order(uint256 nonce, address module, bytes memory data) internal view returns (Order memory o) {
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.TAKE_FOR, module: module, amount: USDC_IN, recipient: address(0), data: data});

        LegIn[] memory legsIn = new LegIn[](1);
        legsIn[0] = LegIn(USDC, USDC_IN, 0);
        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(WETH, WETH_OUT, 0, address(0));

        o = Order({
            params: 0,
            pricingModule: address(0),
            maker: maker,
            nonce: nonce,
            legsIn: PackedEncode.legsIn(legsIn),
            legsOut: PackedEncode.legsOut(legsOut),
            timing: _expiryBits(block.timestamp + 1 hours),
            exclusiveFiller: address(0),
            minFillAnchor: 0,
            curve: PackedEncode.noCurve(),
            items: PackedEncode.items(items),
            validators: PackedEncode.noValidators(),
            invariants: PackedEncode.noValidators(),
            fillModule: address(0),
            fillTotal: 0
        });
    }

    /// @dev Both books the composite item passes through: the TAKER allowance caps
    ///      what leaves the position, the TOKEN allowance caps what funds it.
    function _authorise(address module, bytes memory data, uint256 takeCap, uint256 fundCap) internal {
        vm.startPrank(maker);
        permit3.approveTaker(
            address(settlement), module, keccak256(data), uint160(takeCap), uint48(block.timestamp + 1 hours)
        );
        permit3.approveToken(module, WETH, uint160(fundCap), uint48(block.timestamp + 1 hours));
        vm.stopPrank();
    }

    function _fundSolver() internal {
        deal(WETH, solver, WETH_OUT);
        _approveSolverSide(WETH_OUT, WETH);
    }

    // ──────────────── leg reference: the funding leg IS the output leg ────────────────

    /// One dispatch, both legs, and the two amounts are the order's own signed
    /// numbers — no ratio, no second copy.
    function test_legRef_fullFill_fundsExactlyTheDeliveredLeg() public {
        _fundSolver();
        bytes memory data = _data(_forLeg(0));
        _authorise(address(takeFor), data, USDC_IN, WETH_OUT);
        Order memory o = _order(1, address(takeFor), data);
        bytes memory sig = _sign(o);

        uint256 makerWeth = IERC20(WETH).balanceOf(maker);

        vm.prank(solver);
        settlement.fill(o, sig, USDC_IN);

        assertEq(takeFor.calls(), 1, "one composite dispatch, not two items");
        assertEq(takeFor.amounts(0), USDC_IN, "value-out leg is the item's gated amount");
        assertEq(takeFor.forAmounts(0), WETH_OUT, "value-in leg is the signed output leg");
        assertEq(IERC20(WETH).balanceOf(maker), makerWeth, "maker nets zero: delivered == supplied");
        assertEq(IERC20(USDC).balanceOf(solver), USDC_IN, "solver paid from the take's proceeds");
    }

    /// The headline property, on PARTIAL fills: whatever the core delivered on the
    /// leg this fill is exactly what funds the position, so the maker's balance in
    /// that token never moves. A module that re-derived the amount from its own
    /// signed totals would have to round, and the maker would carry the difference.
    function test_legRef_partialFills_makerNetsZeroEveryFill() public {
        // Headroom on purpose: a SELL output leg is priced per fill with a CEIL, so
        // two slices can deliver a wei or two MORE than the leg total. That is the
        // point — the funding leg is the same number, so the maker still nets zero
        // however the rounding lands, which a separately-signed total cannot promise.
        deal(WETH, solver, WETH_OUT * 2);
        _approveSolverSide(WETH_OUT * 2, WETH);
        uint256 solverBefore = IERC20(WETH).balanceOf(solver);
        bytes memory data = _data(_forLeg(0));
        // The token allowance carries the same ceil margin, for the same reason: it
        // has to cover what was actually DELIVERED, which on a per-fill-ceil SELL leg
        // can exceed the leg total by a wei per slice.
        _authorise(address(takeFor), data, USDC_IN, WETH_OUT + 2);
        Order memory o = _order(2, address(takeFor), data);
        bytes memory sig = _sign(o);

        uint256 makerWeth = IERC20(WETH).balanceOf(maker);

        vm.prank(solver);
        settlement.fill(o, sig, USDC_IN / 3);
        assertEq(IERC20(WETH).balanceOf(maker), makerWeth, "net zero after fill 1");

        vm.prank(solver);
        settlement.fill(o, sig, USDC_IN - USDC_IN / 3);
        assertEq(IERC20(WETH).balanceOf(maker), makerWeth, "net zero after fill 2");

        assertEq(takeFor.calls(), 2, "two fills, two dispatches");
        assertEq(takeFor.amounts(0) + takeFor.amounts(1), USDC_IN, "the gated legs sum to the signed total");
        // Every unit the solver delivered ended up in the position.
        assertEq(takeFor.totalFor(), solverBefore - IERC20(WETH).balanceOf(solver), "funded == delivered");
    }

    // ──────────────── literal: a wallet-funded leg the core slices ────────────────

    /// No output leg to point at (the maker funds from their own wallet — a fresh
    /// position, a new trove). The core slices the signed total with the same
    /// differencing it applies to `item.amount`, so the slices sum EXACTLY to it:
    /// no per-fill ceil drift, and no constant re-executed in full on every slice.
    function test_literal_partialFills_sumExactlyToTheSignedTotal() public {
        deal(WETH, solver, WETH_OUT * 2); // ceil headroom, as above
        _approveSolverSide(WETH_OUT * 2, WETH);
        uint256 fundTotal = 3 ether;
        deal(WETH, maker, fundTotal);

        bytes memory data = _data(fundTotal);
        _authorise(address(takeFor), data, USDC_IN, fundTotal);
        Order memory o = _order(3, address(takeFor), data);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fill(o, sig, USDC_IN / 3);
        vm.prank(solver);
        settlement.fill(o, sig, USDC_IN / 6);
        vm.prank(solver);
        settlement.fill(o, sig, USDC_IN - USDC_IN / 3 - USDC_IN / 6);

        assertEq(takeFor.calls(), 3, "three slices");
        assertEq(takeFor.totalFor(), fundTotal, "slices sum EXACTLY to the signed total");
    }

    // ──────────────── the descriptor is maker-signed and bounded ────────────────

    /// An index past the order's `legsOut` reverts rather than silently defaulting
    /// to leg 0 — funding the wrong leg is worse than not filling.
    function test_legRef_outOfRange_reverts() public {
        _fundSolver();
        bytes memory data = _data(_forLeg(1)); // the order has ONE output leg
        _authorise(address(takeFor), data, USDC_IN, WETH_OUT);
        Order memory o = _order(4, address(takeFor), data);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(Base.ForLegMissing.selector);
        settlement.fill(o, sig, USDC_IN);
    }

    /// `data` too short to hold the descriptor word at all.
    function test_shortData_reverts() public {
        _fundSolver();
        bytes memory data = hex"deadbeef";
        _authorise(address(takeFor), data, USDC_IN, WETH_OUT);
        Order memory o = _order(5, address(takeFor), data);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(Base.ForLegMissing.selector);
        settlement.fill(o, sig, USDC_IN);
    }

    /// The value-OUT leg is gated by the SAME taker-book bucket a plain TAKE uses:
    /// the descriptor buys the funding side no extra authority.
    function test_takerAllowance_capsTheValueOutLeg() public {
        _fundSolver();
        bytes memory data = _data(_forLeg(0));
        _authorise(address(takeFor), data, USDC_IN - 1, WETH_OUT); // one unit short
        Order memory o = _order(6, address(takeFor), data);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(o, sig, USDC_IN);
    }

    /// The funding leg is bounded by the maker's TOKEN allowance to the module —
    /// the same gate a `MAKE` item's funding leg passes through.
    function test_tokenAllowance_capsTheFundingLeg() public {
        _fundSolver();
        bytes memory data = _data(_forLeg(0));
        _authorise(address(takeFor), data, USDC_IN, WETH_OUT - 1); // one wei short
        Order memory o = _order(7, address(takeFor), data);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(o, sig, USDC_IN);
    }

    /// A plain `ITakerModule` signed into a `TAKE_FOR` item must NOT be reachable:
    /// the selectors differ, so the dispatch reverts instead of handing a
    /// single-op module a call whose arguments have shifted by one word.
    function test_plainTakerModule_inTakeForItem_reverts() public {
        _fundSolver();
        bytes memory data = _data(_forLeg(0));
        _authorise(address(plainTaker), data, USDC_IN, WETH_OUT);
        Order memory o = _order(8, address(plainTaker), data);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(o, sig, USDC_IN);
    }

    // ──────────────── balance: "fund with what I hold" ────────────────
    //
    // The NO-CONVERSION shape. There is no output leg to reference and the maker
    // cannot know the amount at signing time — interest accrues, a transfer is in
    // flight, the wallet is being swept. The core reads the balance at item time
    // and caps it with the maker's signed ceiling.

    function test_balance_fundsWhateverTheMakerHolds() public {
        _fundSolver();
        uint256 held = 2.5 ether;
        deal(WETH, maker, held);

        bytes memory data = _data(_forBalance(WETH), 10 ether); // cap well above
        _authorise(address(takeFor), data, USDC_IN, 10 ether);
        Order memory o = _order(9, address(takeFor), data);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fill(o, sig, USDC_IN);

        // The delivered output leg lands in the maker's wallet BEFORE items run, so
        // the sweep takes it too — the balance form means the live balance, not the
        // pre-fill one.
        assertEq(takeFor.forAmounts(0), held + WETH_OUT, "funded with the live balance");
        assertEq(IERC20(WETH).balanceOf(maker), 0, "wallet swept into the position");
    }

    /// The cap is what the maker actually signed, and it binds.
    function test_balance_capBinds() public {
        _fundSolver();
        deal(WETH, maker, 100 ether); // anyone can raise a maker's balance
        uint256 cap = 1.5 ether;

        bytes memory data = _data(_forBalance(WETH), cap);
        _authorise(address(takeFor), data, USDC_IN, cap);
        Order memory o = _order(10, address(takeFor), data);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fill(o, sig, USDC_IN);

        assertEq(takeFor.forAmounts(0), cap, "capped at the signed ceiling");
    }

    /// A live balance cannot pro-rate: every slice would fund the whole remaining
    /// balance again. Rejected in the core, which is the only place that knows.
    function test_balance_partialFill_reverts() public {
        _fundSolver();
        deal(WETH, maker, 5 ether);

        bytes memory data = _data(_forBalance(WETH), 10 ether);
        _authorise(address(takeFor), data, USDC_IN, 10 ether);
        Order memory o = _order(11, address(takeFor), data);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(Base.ForBalanceNeedsFullFill.selector);
        settlement.fill(o, sig, USDC_IN / 2);
    }

    /// The cap is MANDATORY — `0` is what an unset word holds, so the dangerous
    /// mode must not be the default one.
    function test_balance_zeroCap_reverts() public {
        _fundSolver();
        deal(WETH, maker, 5 ether);

        bytes memory data = _data(_forBalance(WETH), 0);
        _authorise(address(takeFor), data, USDC_IN, 10 ether);
        Order memory o = _order(12, address(takeFor), data);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(Base.ForBalanceNeedsCap.selector);
        settlement.fill(o, sig, USDC_IN);
    }

    // ──────────────── audit probes ────────────────

    /// @dev The one-shot permit cannot authorise a composite item: a `PermitTake`
    ///      witnesses `(module, amount)` and says nothing about the funding leg.
    ///      {Base._runItem} therefore never consumes it on the TAKE_FOR branch, and
    ///      {Core.fillWithPermitTake} must fail closed rather than settle a fill
    ///      whose only authorization was never checked.
    function test_permitTake_withTakeForItem_failsClosed() public {
        _fundSolver();
        bytes memory data = _data(_forLeg(0));
        _authorise(address(takeFor), data, USDC_IN, WETH_OUT);
        Order memory o = _order(20, address(takeFor), data);

        IPermit3.PermitTake memory p = IPermit3.PermitTake({
            module: address(takeFor),
            ref: keccak256(data),
            amount: uint160(USDC_IN),
            nonce: 77,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(solver);
        vm.expectRevert(Base.PermitTakeNotConsumed.selector);
        settlement.fillWithPermitTake(o, p, hex"deadbeef", USDC_IN);
    }

    /// @dev AUDIT FIX. The balance form when the maker holds NOTHING of the funding
    ///      token — here a token the order does not deliver, so the read is a true
    ///      zero. Before the fix this FAILED OPEN: `forAmount` came back 0, the
    ///      module supplied nothing, and the value-out leg still drew its full
    ///      1,500 USDC — "deposit what I hold and borrow against it" silently became
    ///      a bare uncollateralised borrow. Reachable with no malice at all: an
    ///      earlier fill of one of the maker's own orders can spend the balance, and
    ///      the filler chooses which order goes first.
    function test_balance_emptyWallet_reverts() public {
        _fundSolver();
        assertEq(IERC20(DAI).balanceOf(maker), 0, "maker holds no DAI");

        bytes memory data = _dataFunding(_forBalance(DAI), 10 ether, DAI);
        _authorise(address(takeFor), data, USDC_IN, 10 ether);
        Order memory o = _order(21, address(takeFor), data);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(Base.ForBalanceEmpty.selector);
        settlement.fill(o, sig, USDC_IN);
    }

    /// @dev …and the same for a descriptor naming a token with no code.
    ///      {SafeTransferLib.balanceOf} multiplies by the staticcall's success, so a
    ///      codeless token reads as a zero balance rather than reverting — which
    ///      would otherwise be the same silent unfunded take.
    function test_balance_codelessToken_reverts() public {
        _fundSolver();
        bytes memory data = _data(_forBalance(address(0xDEAD)), 10 ether);
        _authorise(address(takeFor), data, USDC_IN, 10 ether);
        Order memory o = _order(22, address(takeFor), data);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(Base.ForBalanceEmpty.selector);
        settlement.fill(o, sig, USDC_IN);
    }

    /// @dev AUDIT FIX. The leg-reference form's guarantee is that the funding leg IS
    ///      the delivery — the maker nets zero. That only holds for a leg the MAKER
    ///      receives. Referencing a FEE leg (delivered to a third party) keeps the
    ///      arithmetic but inverts the property: the maker would fund the position
    ///      out of pocket, in the amount of someone else's fee. Rejected.
    function test_legRef_feeLeg_reverts() public {
        // The solver must be able to deliver BOTH output legs, or the fill dies on
        // the delivery before the item is ever reached.
        deal(WETH, solver, WETH_OUT * 2);
        _approveSolverSide(WETH_OUT * 2, WETH);
        bytes memory data = _data(_forLeg(1)); // leg 1 is the fee leg below
        _authorise(address(takeFor), data, USDC_IN, WETH_OUT);

        Order memory o = _feeLegOrder(23, data);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(Base.ForLegNotMakers.selector);
        settlement.fill(o, sig, USDC_IN);
    }

    // ──────────────── lens preflight ────────────────
    //
    // Every descriptor defect above is a revert at FILL time. `validateOrder` is
    // where a maker should meet them instead — before a signature exists. These pin
    // that the preflight mirrors {Base._forSlice} rather than drifting from it.

    function _lensReason(Order memory o) internal returns (string memory) {
        SettlementLens lens = new SettlementLens(address(settlement));
        (, string memory why) = lens.validateOrder(o);
        return why;
    }

    function _lensOrder(uint256 nonce, bytes memory data) internal view returns (Order memory) {
        return _order(nonce, address(takeFor), data);
    }

    function test_lens_flagsShortDescriptor() public {
        assertEq(_lensReason(_lensOrder(30, hex"deadbeef")), "take_for missing funding descriptor");
    }

    function test_lens_flagsZeroLiteral() public {
        assertEq(_lensReason(_lensOrder(31, _data(0))), "take_for funds nothing (zero literal)");
    }

    function test_lens_flagsLegOutOfRange() public {
        assertEq(_lensReason(_lensOrder(32, _data(_forLeg(1)))), "take_for leg index out of range");
    }

    function test_lens_flagsBalanceWithoutCap() public {
        // Descriptor only — no second word at all.
        bytes memory data = abi.encodePacked(_forBalance(WETH));
        assertEq(_lensReason(_lensOrder(33, data)), "take_for balance leg needs a cap");
    }

    function test_lens_flagsZeroCap() public {
        assertEq(_lensReason(_lensOrder(34, _data(_forBalance(WETH), 0))), "take_for balance cap is zero");
    }

    /// A balance-funded order that is partial-fillable is dead on arrival — the core
    /// rejects any slice ({Base.ForBalanceNeedsFullFill}). Pin `minFillAnchor`.
    function test_lens_flagsBalanceWithoutFullFill() public {
        Order memory o = _lensOrder(35, _data(_forBalance(WETH), 10 ether));
        assertEq(_lensReason(o), "take_for balance leg requires full-fill");

        o.minFillAnchor = USDC_IN; // == the anchor ⇒ full-fill only
        assertEq(_lensReason(o), "", "pinned to full-fill, the order is well formed");
    }

    function test_lens_acceptsAWellFormedLegReference() public {
        assertEq(_lensReason(_lensOrder(36, _data(_forLeg(0)))), "", "leg 0 is the maker's own output leg");
    }

    /// @dev The two-output-leg shape used by both fee-leg tests: leg 0 is the
    ///      maker's own, leg 1 is an originator fee to a third party.
    function _feeLegOrder(uint256 nonce, bytes memory data) internal view returns (Order memory) {
        Item[] memory items = new Item[](1);
        items[0] =
            Item({op: ItemOp.TAKE_FOR, module: address(takeFor), amount: USDC_IN, recipient: address(0), data: data});

        LegIn[] memory legsIn = new LegIn[](1);
        legsIn[0] = LegIn(USDC, USDC_IN, 0);
        LegOut[] memory legsOut = new LegOut[](2);
        legsOut[0] = LegOut(WETH, WETH_OUT, 0, address(0)); //   the maker's own leg
        legsOut[1] = LegOut(WETH, 1e15, 0, address(0xFEE)); //   an originator fee leg

        return Order({
            params: 0,
            pricingModule: address(0),
            maker: maker,
            nonce: nonce,
            legsIn: PackedEncode.legsIn(legsIn),
            legsOut: PackedEncode.legsOut(legsOut),
            timing: _expiryBits(block.timestamp + 1 hours),
            exclusiveFiller: address(0),
            minFillAnchor: 0,
            curve: PackedEncode.noCurve(),
            items: PackedEncode.items(items),
            validators: PackedEncode.noValidators(),
            invariants: PackedEncode.noValidators(),
            fillModule: address(0),
            fillTotal: 0
        });
    }

    /// The lens must reject the fee-leg reference too, not just the settler.
    function test_lens_flagsFeeLeg() public {
        assertEq(
            _lensReason(_feeLegOrder(37, _data(_forLeg(1)))), "take_for funds a fee leg (not the maker's)"
        );
    }
}
