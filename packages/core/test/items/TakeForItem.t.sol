// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "../shared/PackedEncode.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {OrderHash} from "@core/settlement/OrderHash.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {ITakerForModule} from "@core/interfaces/ITakerForModule.sol";
import {IFundingSource} from "@core/interfaces/IFundingSource.sol";
import {IProceedsAsset} from "@core/interfaces/IProceedsAsset.sol";
import {Order, Item, ItemOp, LegIn, LegOut, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {SettlementLens} from "@periphery/SettlementLens.sol";

import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @dev TAKE_FOR mock, shaped like a real leverage adapter: it pulls the funding
///      leg from the maker (the "deposit") and hands `amount` of a stashed token to
///      `receiver` (the "borrow"). Both amounts are recorded so the tests can assert
///      on what the CORE sized, not on what the module chose.
contract MockTakeFor is ITakerForModule, IFundingSource, IProceedsAsset {
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

    /// @dev The funding asset is field 2 of this mock's layout, exactly as a real
    ///      adapter names it in its own — the point being that it is named in `data`
    ///      at all, which is what the lens cross-checks against the leg.
    function fundingSource(address onBehalfOf, bytes calldata data)
        external
        view
        override
        returns (address asset, uint256 available)
    {
        (,, asset,) = abi.decode(data, (uint256, uint256, address, address));
        (uint160 allowed, uint48 expiration) = permit3.tokenAllowance(onBehalfOf, address(this), asset);
        if (expiration != 0 && expiration < block.timestamp) return (asset, 0);
        uint256 bal = IERC20(asset).balanceOf(onBehalfOf);
        available = bal < allowed ? bal : allowed;
    }

    /// @dev Field 3 — the token this mock hands to `receiver`, i.e. what an input
    ///      leg has to be able to consume.
    function proceedsAsset(bytes calldata data) external pure override returns (address asset) {
        (,,, asset) = abi.decode(data, (uint256, uint256, address, address));
    }

    function calls() external view returns (uint256) {
        return amounts.length;
    }
}

/// @dev A composite module that does NOT answer the preflight (it reverts). The
///      lens must degrade to the behaviour it had before the preflight existed —
///      report "unknown" and skip both checks — rather than reject an order that
///      fills perfectly well.
contract MockSilentTakeFor is ITakerForModule, IFundingSource {
    IPermit3 public immutable permit3;

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeForOnBehalf(address onBehalfOf, uint256 amount, uint256 forAmount, address receiver, bytes calldata data)
        external
        override
    {
        require(msg.sender == address(permit3), "only permit3");
        (,, address fundingToken, address proceedsToken) = abi.decode(data, (uint256, uint256, address, address));
        if (forAmount != 0) permit3.transferFrom(onBehalfOf, address(this), fundingToken, uint160(forAmount));
        IERC20(proceedsToken).transfer(receiver, amount);
    }

    function fundingSource(address, bytes calldata) external pure override returns (address, uint256) {
        revert("no preflight");
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

    /// @dev The balance form with a funding FLOOR in bits [160:176). The fill-path
    ///      tests above deliberately leave it 0 (a legal encoding — it keeps the
    ///      historical "any non-zero balance will do" rule), but the LENS flags 0 as
    ///      a footgun, so a lens fixture that means to exercise some OTHER defect has
    ///      to be well formed in this respect first.
    function _forBalanceFloor(address token, uint256 bps) internal pure returns (uint256) {
        return (uint256(3) << 254) | (bps << 160) | uint160(token);
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

    /// @dev The live-balance sweep. Carries an EXPLICIT lenient floor: an unset floor
    ///      now resolves to the full cap (see
    ///      `test_balance_unsetFloor_meansFullCap_andFailsClosed`), so "fund with
    ///      whatever I happen to hold" is a choice the maker signs rather than one
    ///      they fall into by leaving a descriptor field blank.
    function test_balance_fundsWhateverTheMakerHolds() public {
        _fundSolver();
        uint256 held = 2.5 ether;
        deal(WETH, maker, held);

        bytes memory data = _data(_forBalanceFloor(WETH, 1), 10 ether); // cap well above
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

    // ──────────────── balance: the FLOOR, the cap's other half ────────────────
    //
    // The cap exists because anyone can RAISE a maker's balance. The floor exists
    // because whoever sequences fills can LOWER it — and `min(balance, cap)` shrinks
    // SMOOTHLY while the value-OUT leg keeps its full signed size, so a dented wallet
    // funds a fraction of the position and borrows all of it. Stopping at zero (the
    // {ForBalanceBelowFloor} tests above) closed the boundary and left the whole
    // neighbourhood of it open.

    /// @dev AUDIT FIX. The wallet is not empty — it holds 40% of the cap — and the
    ///      order says "fund the whole cap or do not fill". Without the floor this
    ///      SETTLED: 4 WETH of collateral against a borrow signed for 10 WETH's worth,
    ///      with nothing anywhere recording that the maker asked for more. The maker
    ///      never chose the smaller position; the filler did, by picking which of the
    ///      maker's orders to fill first.
    function test_balance_belowFloor_reverts() public {
        _fundSolver();
        deal(WETH, maker, 3 ether); // + the 1 WETH delivered inside the fill = 4 of 10

        bytes memory data = _data(_forBalanceFloor(WETH, 10_000), 10 ether);
        _authorise(address(takeFor), data, USDC_IN, 10 ether);
        Order memory o = _order(24, address(takeFor), data);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(Base.ForBalanceBelowFloor.selector);
        settlement.fill(o, sig, USDC_IN);
    }

    /// @dev A PARTIAL floor is the sweep order's setting: "fund at least 80% of what
    ///      I expect, and take whatever is actually there". 9 of 10 clears it, and the
    ///      funding leg is still the live balance — the floor bounds the shrinkage, it
    ///      does not replace the read.
    function test_balance_meetsPartialFloor_fundsTheLiveBalance() public {
        _fundSolver();
        deal(WETH, maker, 8 ether); // + 1 delivered = 9, against a floor of 8

        bytes memory data = _data(_forBalanceFloor(WETH, 8_000), 10 ether);
        _authorise(address(takeFor), data, USDC_IN, 10 ether);
        Order memory o = _order(25, address(takeFor), data);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fill(o, sig, USDC_IN);

        assertEq(takeFor.forAmounts(0), 8 ether + WETH_OUT, "funded with the live balance, floor cleared");
    }

    /// @dev And exactly AT the floor fills — the comparison is `<`, not `<=`, so a
    ///      maker who sizes the floor at the amount they expect is not defeated by
    ///      their own boundary.
    function test_balance_exactlyAtFloor_fills() public {
        _fundSolver();
        deal(WETH, maker, 4 ether); // + 1 delivered = 5, floor = 5000bps of 10 = 5

        bytes memory data = _data(_forBalanceFloor(WETH, 5_000), 10 ether);
        _authorise(address(takeFor), data, USDC_IN, 10 ether);
        Order memory o = _order(26, address(takeFor), data);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fill(o, sig, USDC_IN);

        assertEq(takeFor.forAmounts(0), 5 ether, "at the floor is inside it");
    }

    /// @dev AN UNSET FLOOR MEANS THE FULL CAP, AND IT FAILS CLOSED. `0` is the value
    ///      of a descriptor field nobody filled in, so it must not select the
    ///      dangerous mode — and it used to: it left `bal != 0` as the only bound, so
    ///      this order funded a position with ONE WEI while the value-OUT leg borrowed
    ///      its full signed size. Now it resolves to 10_000 bps and the fill reverts
    ///      rather than under-collateralising the maker.
    function test_balance_unsetFloor_meansFullCap_andFailsClosed() public {
        _fundSolver();
        deal(WETH, maker, 1); // one wei, against a 10 WETH cap

        bytes memory data = _data(_forBalance(WETH), 10 ether);
        _authorise(address(takeFor), data, USDC_IN, 10 ether);
        Order memory o = _order(27, address(takeFor), data);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(Base.ForBalanceBelowFloor.selector);
        settlement.fill(o, sig, USDC_IN);
    }

    /// @dev The sequencing attack the default now closes, end to end. A maker's
    ///      balance is lowered by anyone who can order fills — draining it through
    ///      ANOTHER of the maker's live orders is an ordinary, profitable act and the
    ///      FILLER picks the order — so under the old default a solver could empty the
    ///      funding token first and then take a near-uncollateralised borrow here.
    ///      With the unset floor resolving to the full cap, the second fill reverts.
    function test_balance_unsetFloor_resistsBalanceDrainSequencing() public {
        _fundSolver();
        // The maker held enough to collateralise the position when they signed.
        deal(WETH, maker, 10 ether);

        bytes memory data = _data(_forBalance(WETH), 10 ether);
        _authorise(address(takeFor), data, USDC_IN, 10 ether);
        Order memory o = _order(29, address(takeFor), data);
        bytes memory sig = _sign(o);

        // …and by the time this fill lands, something else has drawn it down.
        deal(WETH, maker, 0.01 ether);

        vm.prank(solver);
        vm.expectRevert(Base.ForBalanceBelowFloor.selector);
        settlement.fill(o, sig, USDC_IN);
    }

    /// @dev Leniency is still expressible — it just has to be SIGNED rather than
    ///      obtained by omission. An explicit 1 bps floor is the old "any non-trivial
    ///      balance will do", and it fills.
    function test_balance_explicitLowFloor_stillFundsWhateverIsHeld() public {
        _fundSolver();
        deal(WETH, maker, 1 ether); // far under the cap, but over an explicit 1bps floor

        bytes memory data = _data(_forBalanceFloor(WETH, 1), 10 ether);
        _authorise(address(takeFor), data, USDC_IN, 10 ether);
        Order memory o = _order(30, address(takeFor), data);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fill(o, sig, USDC_IN);

        assertEq(takeFor.forAmounts(0), 1 ether + WETH_OUT, "an explicitly lenient floor still funds");
    }

    /// @dev The floor is inside `ref = keccak256(data)`, so a filler cannot lower it:
    ///      changing the descriptor changes the taker-allowance bucket, and the
    ///      altered order is not the one the maker approved.
    function test_balance_floorIsInsideTheAllowanceRef() public {
        _fundSolver();
        deal(WETH, maker, 3 ether);

        bytes memory signed = _data(_forBalanceFloor(WETH, 10_000), 10 ether);
        _authorise(address(takeFor), signed, USDC_IN, 10 ether); // the grant covers THIS blob

        // The same order with the floor stripped: a different `ref`, so the taker
        // book has nothing for it and the take is refused before the funding leg is
        // ever resolved.
        bytes memory stripped = _data(_forBalance(WETH), 10 ether);
        Order memory o = _order(28, address(takeFor), stripped);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert();
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
        vm.expectRevert(Base.ForBalanceBelowFloor.selector);
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
        vm.expectRevert(Base.ForBalanceBelowFloor.selector);
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

    /// An UNSET floor is no longer a defect — the core resolves it to the full cap
    /// (10000 bps), so the encoding the lens used to reject is now the STRICTEST one
    /// available and rejecting it would fail a safe order. The footgun moved: leniency
    /// is now something a maker signs explicitly rather than gets by omission.
    function test_lens_acceptsAnUnsetFloorAsFullCap() public {
        Order memory o = _lensOrder(36, _data(_forBalance(WETH), 10 ether));
        o.minFillAnchor = USDC_IN; // balance legs are full-fill only
        assertEq(_lensReason(o), "");
    }

    /// Above 10000 the floor exceeds the cap, so `min(balance, cap)` can never reach
    /// it and the order is unfillable by construction.
    function test_lens_flagsFloorAboveCap() public {
        assertEq(
            _lensReason(_lensOrder(37, _data(_forBalanceFloor(WETH, 10_001), 10 ether))),
            "take_for balance floor exceeds the cap"
        );
    }

    /// A balance-funded order that is partial-fillable is dead on arrival — the core
    /// rejects any slice ({Base.ForBalanceNeedsFullFill}). Pin `minFillAnchor`.
    function test_lens_flagsBalanceWithoutFullFill() public {
        Order memory o = _lensOrder(35, _data(_forBalanceFloor(WETH, 5_000), 10 ether));
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

    // ──────────── a leg reference that funds nothing, forever ────────────

    /// @dev The one-output-leg shape with a ZERO `start`. Everything else matches
    ///      {_order}, so the only variable is the leg amount the descriptor points at.
    function _zeroLegOrder(uint256 nonce, bytes memory data) internal view returns (Order memory) {
        Item[] memory items = new Item[](1);
        items[0] =
            Item({op: ItemOp.TAKE_FOR, module: address(takeFor), amount: USDC_IN, recipient: address(0), data: data});

        LegIn[] memory legsIn = new LegIn[](1);
        legsIn[0] = LegIn(USDC, USDC_IN, 0);
        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(WETH, 0, 0, address(0)); // ← funds nothing, at any tick

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

    /// ⚠ WHY THE LENS CHECK EXISTS — the settler's behaviour, stated plainly.
    ///
    /// A leg with `start == 0` prices to 0 on every fill and in every pricing mode,
    /// so the descriptor funds NOTHING while the value-OUT leg still draws in full:
    /// the composite silently degrades to a bare `TAKE`. That is the same fail-open
    /// shape the core rejects for the BALANCE form ({Base.ForBalanceBelowFloor}).
    ///
    /// It is NOT rejected here, and that is deliberate rather than an oversight: a
    /// zero BALANCE is a live wallet read the maker cannot see at signing time, so
    /// the core has to fail closed on it; a zero-`start` leg is fixed in the bytes
    /// the maker is about to sign, so the preflight catches it earlier and the fill
    /// path pays nothing. This test pins the settler side so the split stays
    /// deliberate — if the core ever starts reverting, this is the test to update.
    function test_zeroOutputLeg_fundsNothing_butTheTakeStillDraws() public {
        bytes memory data = _data(_forLeg(0));
        _authorise(address(takeFor), data, USDC_IN, WETH_OUT);
        Order memory o = _zeroLegOrder(38, data);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fill(o, sig, USDC_IN);

        assertEq(takeFor.amounts(0), USDC_IN, "the value-OUT leg drew in full");
        assertEq(takeFor.forAmounts(0), 0, "and nothing funded it: a bare take");
    }

    /// And the preflight DOES name it — through the general output-leg rule, not a
    /// descriptor-specific one. Worth pinning explicitly: the descriptor branch has
    /// its own "zero literal" check, so the natural reading is that the
    /// leg-reference form is missing the equivalent. It is not. A zero-`start`
    /// output leg is malformed for EVERY order ({SettlementLens} rejects it on both
    /// sides), and that rule runs before the TAKE_FOR walk, so the composite case is
    /// covered by construction and a second check there would be dead code.
    function test_lens_flagsZeroAmountOutputLeg_viaTheGeneralRule() public {
        assertEq(_lensReason(_zeroLegOrder(39, _data(_forLeg(0)))), "output start is zero (giveaway)");
    }

    // ──────────── the funding-leg preflight (asset identity + authorisation) ────────────

    /// The ASSET half of the de-duplication. `TAKE_FOR` makes `legsOut[j]` the one
    /// signed copy of the funding AMOUNT — but the funding ASSET is still named in
    /// `data`, in a layout only the module knows. Name a different one and the leg's
    /// amount lands in the wrong decimals: the exact silent mis-sizing the op exists
    /// to remove. The module reports its asset, the lens compares.
    function test_lens_flagsFundingAssetThatIsNotTheLegsToken() public {
        // Leg 0 delivers WETH; the blob tells the module to pull DAI.
        Order memory o = _order(60, address(takeFor), _dataFunding(_forLeg(0), 0, DAI));
        assertEq(_lensReason(o), "take_for funds a different asset than the leg it is sized by");
    }

    /// The same order with the asset the leg actually delivers passes.
    function test_lens_acceptsMatchingFundingAsset() public {
        SettlementLens lens = new SettlementLens(address(settlement));
        (bool ok, string memory why) = lens.validateOrder(_order(61, address(takeFor), _data(_forLeg(0))));
        assertTrue(ok, why);
    }

    /// A module that cannot answer must leave the caller with the behaviour it had
    /// before the preflight existed. The check is an ADDITION to a preflight that
    /// shipped without it, so "unknown" has to mean "skip", never "reject" — a
    /// rejection here would drop fillable orders out of an orderbook.
    function test_lens_silentModule_isNotRejected() public {
        MockSilentTakeFor silent = new MockSilentTakeFor(address(permit3));
        SettlementLens lens = new SettlementLens(address(settlement));
        // Deliberately MISMATCHED (DAI vs the WETH leg) — the check would bite if the
        // module answered, so this pins that a failed staticcall skips it.
        (bool ok,) = lens.validateOrder(_order(62, address(silent), _dataFunding(_forLeg(0), 0, DAI)));
        assertTrue(ok, "a module that cannot answer must not fail the order");
    }

    /// The authorisation half. The funding pull is the MODULE's, against the maker's
    /// grant to the MODULE — a book neither `previewTakerAllowances` nor the order's
    /// own input-leg preflight reads. Without this view the order previews clean and
    /// reverts on every fill.
    function test_previewItemFunding_reportsTheMissingGrant() public {
        SettlementLens lens = new SettlementLens(address(settlement));
        bytes memory data = _data(_forLeg(0));
        Order memory o = _order(63, address(takeFor), data);

        // Taker side granted, funding side NOT.
        vm.prank(maker);
        permit3.approveTaker(
            address(settlement), address(takeFor), keccak256(data), uint160(USDC_IN), uint48(block.timestamp + 1 hours)
        );

        SettlementLens.ItemFunding memory f = lens.previewItemFunding(o);
        assertEq(f.modules.length, 1, "one composite item");
        assertEq(f.modules[0], address(takeFor));
        assertEq(f.assets[0], WETH, "the module names its own funding asset");
        assertEq(f.required[0], WETH_OUT, "full-fill funding == the referenced leg");
        assertEq(f.available[0], 0, "and the maker has authorised none of it");

        // The preview is predictive: the fill it says cannot be funded, cannot be.
        _fundSolver();
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(o, sig, USDC_IN);
    }

    /// And once the grant exists, `available` covers `required` and the fill lands.
    function test_previewItemFunding_tracksTheGrantAndTheFillSucceeds() public {
        SettlementLens lens = new SettlementLens(address(settlement));
        _fundSolver();
        bytes memory data = _data(_forLeg(0));
        _authorise(address(takeFor), data, USDC_IN, WETH_OUT);
        Order memory o = _order(64, address(takeFor), data);
        bytes memory sig = _sign(o);

        SettlementLens.ItemFunding memory f = lens.previewItemFunding(o);
        // The maker holds no WETH YET — the solver delivers it inside the fill — so
        // `available` is balance-bound at this instant. The assertion is that the view
        // names the right asset and the right requirement, not that it foresees the
        // delivery; the ⚠ on {previewItemFunding} says exactly this.
        assertEq(f.required[0], WETH_OUT);
        assertEq(f.assets[0], WETH);

        vm.prank(solver);
        settlement.fill(o, sig, USDC_IN);
        assertEq(takeFor.totalFor(), WETH_OUT, "the funding leg drew exactly the leg");
    }

    /// A LITERAL descriptor's required amount is the signed total, and a BALANCE
    /// descriptor's is the live capped balance — the two non-leg forms the wallet-
    /// funded shapes use, where there is no output leg to read.
    function test_previewItemFunding_literalAndBalanceForms() public {
        SettlementLens lens = new SettlementLens(address(settlement));

        SettlementLens.ItemFunding memory lit =
            lens.previewItemFunding(_order(65, address(takeFor), _data(3 ether)));
        assertEq(lit.required[0], 3 ether, "literal total is the funding requirement");

        deal(WETH, maker, 2 ether);
        SettlementLens.ItemFunding memory bal =
            lens.previewItemFunding(_order(66, address(takeFor), _data(_forBalance(WETH), 5 ether)));
        assertEq(bal.required[0], 2 ether, "balance form: min(balance, cap)");

        SettlementLens.ItemFunding memory capped =
            lens.previewItemFunding(_order(67, address(takeFor), _data(_forBalance(WETH), 1 ether)));
        assertEq(capped.required[0], 1 ether, "and the cap binds");
    }

    /// An order with no composite items reports nothing — the view is safe to call
    /// unconditionally from a UI that does not know the order's shape.
    function test_previewItemFunding_emptyForAPlainOrder() public {
        SettlementLens lens = new SettlementLens(address(settlement));
        Order memory o = _order(68, address(takeFor), _data(_forLeg(0)));
        o.items = PackedEncode.items(new Item[](0));
        assertEq(lens.previewItemFunding(o).modules.length, 0);
    }

    // ──────────────── proceeds: the token an item delivers (F22) ────────────────

    /// The other half of the asset de-duplication. Proceeds are credited by
    /// MEASUREMENT — the balance delta of an input leg's token — while the delivered
    /// token is named only in `data`. Point it somewhere no leg names and the maker
    /// pays TWICE: every leg measures zero proceeds so the whole `owed` comes out of
    /// their wallet, and the delivered token is stranded in the settler forever.
    function test_lens_flagsProceedsTokenNoLegCanConsume() public {
        // legsIn is USDC; tell the module to deliver DAI.
        Order memory o = _order(70, address(takeFor), abi.encode(_forLeg(0), uint256(0), WETH, DAI));
        assertEq(_lensReason(o), "item delivers a token no input leg can consume");
    }

    /// Delivering the input leg's own token is the well-formed shape.
    function test_lens_acceptsProceedsMatchingAnInputLeg() public {
        SettlementLens lens = new SettlementLens(address(settlement));
        (bool ok, string memory why) = lens.validateOrder(_order(71, address(takeFor), _data(_forLeg(0))));
        assertTrue(ok, why);
    }

    /// A signed non-zero recipient routes proceeds AWAY from the settler on purpose
    /// (chaining into a later item, or straight to the maker), so the settler never
    /// holds them and the check must not fire.
    function test_lens_proceedsCheckSkippedForASignedRecipient() public {
        SettlementLens lens = new SettlementLens(address(settlement));
        Order memory o = _order(72, address(takeFor), abi.encode(_forLeg(0), uint256(0), WETH, DAI));
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE_FOR,
            module: address(takeFor),
            amount: USDC_IN,
            recipient: maker,
            data: abi.encode(_forLeg(0), uint256(0), WETH, DAI)
        });
        o.items = PackedEncode.items(items);
        (bool ok,) = lens.validateOrder(o);
        assertTrue(ok, "a signed recipient opts the proceeds out of the settler");
    }

    /// A module that does not declare its proceeds must not be rejected — same
    /// degrade-to-old-behaviour rule the funding check follows.
    function test_lens_silentProceedsModule_isNotRejected() public {
        MockSilentTakeFor silent = new MockSilentTakeFor(address(permit3));
        SettlementLens lens = new SettlementLens(address(settlement));
        (bool ok,) = lens.validateOrder(_order(73, address(silent), abi.encode(_forLeg(0), uint256(0), WETH, DAI)));
        assertTrue(ok, "unknown proceeds must skip the check, not fail it");
    }

    // ──────────────── the CoW case: `matchSettle` must refuse this op ────────────────
    //
    // `Batch._assertMatchShape` rejects every item op at or above SETTLE, so
    // `TAKE_FOR` never reaches the netted engine. The refusal is pinned per
    // DESCRIPTOR FORM below rather than once, because the three forms fail for
    // materially different reasons and only one of them is a mere ordering
    // inconvenience — see the guard's own comment in {Batch}.
    //
    // ⚠ THE SHARP REASON, and the one that decides the guard stays: the BALANCE
    // form resolves `forAmount = min(balanceOf(token, maker), cap)` AT ITEM TIME.
    // On the single-order path that read is deterministic because the ordering is
    // a property of the CODE — `Core._settleForward` runs `_deliverOutputs` →
    // `_executeItems` → `_payInputsToSolver`, and the one mode that reorders those
    // (`_settlePostInputs`) forbids items outright ({ReverseModeRequiresNoItems}).
    // `test_balance_fundsWhateverTheMakerHolds` is that property, measured: the
    // maker is funded with `held + WETH_OUT`, i.e. the delivered leg included.
    //
    // Under `matchSettle` the ordering would be a property of the SOLVER'S
    // SCHEDULE instead. `ITEM` and `DELIVER` are independently schedulable steps,
    // so a filler could run the item FIRST and resolve the same descriptor against
    // the maker's pre-delivery wallet — funding the position with a fraction of the
    // intended collateral while the value-OUT leg still draws in full. That is
    // exactly the [F16] shape, made filler-controllable, and {ForBalanceEmpty} does
    // NOT close it: that guard only catches a resolved ZERO, so a maker holding one
    // wei pre-delivery would pass it and be near-totally under-collateralised.
    //
    // The LEG-reference form is the benign one — if the pull succeeds the end state
    // is identical whichever order the steps ran in, and if it does not the fill
    // reverts. It is refused anyway because the guard keys on the OP, not on a
    // descriptor it would have to decode; narrowing it later means discriminating
    // by form, which is a bigger change than it looks.

    /// @dev A one-order plan carrying `o`. Enough to prove the refusal fires in
    ///      PHASE 1, before the schedule runs at all.
    function _matchPlan(Order memory o, bytes memory sig) internal pure returns (MatchPlan memory) {
        Order[] memory orders = new Order[](1);
        orders[0] = o;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig;
        uint256[] memory fills = new uint256[](1);
        fills[0] = USDC_IN;
        uint256[] memory schedule = new uint256[](2);
        schedule[0] = MatchStep.PULL; //                   (order 0, leg 0)
        schedule[1] = MatchStep.DELIVER | (uint256(0) << 8);
        return MatchPlan({
            orders: orders,
            sigs: sigs,
            fillAmounts: fills,
            takerDatas: new bytes[](0),
            schedule: schedule,
            callTargets: new address[](0),
            callDatas: new bytes[](0),
            profitRecipient: address(0)
        });
    }

    /// @dev Refused, AND nothing moved. Phase 1 is contract-owned and runs before
    ///      any step, so a rejection here cannot have half-settled the order.
    function _assertMatchRefused(Order memory o, bytes memory sig) internal {
        uint256 mUsdc = IERC20(USDC).balanceOf(maker);
        uint256 mWeth = IERC20(WETH).balanceOf(maker);
        uint256 modUsdc = IERC20(USDC).balanceOf(address(takeFor));
        vm.prank(solver);
        vm.expectRevert(Base.MatchSettleItemUnsupported.selector);
        settlement.matchSettle(_matchPlan(o, sig));
        assertEq(IERC20(USDC).balanceOf(maker), mUsdc, "maker USDC moved on a refused match");
        assertEq(IERC20(WETH).balanceOf(maker), mWeth, "maker WETH moved on a refused match");
        assertEq(IERC20(USDC).balanceOf(address(takeFor)), modUsdc, "module stash moved on a refused match");
    }

    /// LITERAL funding descriptor — the form that is genuinely schedule-independent
    /// (it cumulates off `ctx`, never off a balance). Refused all the same: the
    /// guard keys on the op.
    function test_matchSettle_refusesTakeFor_literalForm() public {
        _fundSolver();
        bytes memory data = _data(WETH_OUT);
        _authorise(address(takeFor), data, USDC_IN, WETH_OUT);
        Order memory o = _order(80, address(takeFor), data);
        _assertMatchRefused(o, _sign(o));
    }

    /// LEG-REFERENCE form — the one the guard's original comment describes.
    function test_matchSettle_refusesTakeFor_legRefForm() public {
        _fundSolver();
        bytes memory data = _data(_forLeg(0));
        _authorise(address(takeFor), data, USDC_IN, WETH_OUT);
        Order memory o = _order(81, address(takeFor), data);
        _assertMatchRefused(o, _sign(o));
    }

    /// BALANCE form — the one that MUST stay refused. See the note above.
    function test_matchSettle_refusesTakeFor_balanceForm() public {
        _fundSolver();
        deal(WETH, maker, 2 ether);
        bytes memory data = _data(_forBalance(WETH), 10 ether);
        _authorise(address(takeFor), data, USDC_IN, 10 ether);
        Order memory o = _order(82, address(takeFor), data);
        _assertMatchRefused(o, _sign(o));
    }

    /// The guard is PER ORDER, not per plan-position: a composite order paired with
    /// a perfectly ordinary one is still refused, and the ordinary one does not
    /// settle either. `_matchOpenAll` loops every order before any step runs.
    function test_matchSettle_refusesTakeFor_pairedWithAPlainOrder() public {
        _fundSolver();
        bytes memory data = _data(_forLeg(0));
        _authorise(address(takeFor), data, USDC_IN, WETH_OUT);
        Order memory composite = _order(83, address(takeFor), data);

        Order memory plain = _order(84, address(takeFor), data);
        plain.items = PackedEncode.noItems(); // same legs, no composite item

        Order[] memory orders = new Order[](2);
        (orders[0], orders[1]) = (plain, composite); // composite SECOND
        bytes[] memory sigs = new bytes[](2);
        (sigs[0], sigs[1]) = (_sign(plain), _sign(composite));
        uint256[] memory fills = new uint256[](2);
        (fills[0], fills[1]) = (USDC_IN, USDC_IN);

        uint256 before = IERC20(USDC).balanceOf(maker);
        vm.prank(solver);
        vm.expectRevert(Base.MatchSettleItemUnsupported.selector);
        settlement.matchSettle(
            MatchPlan({
                orders: orders,
                sigs: sigs,
                fillAmounts: fills,
                takerDatas: new bytes[](0),
                schedule: new uint256[](0),
                callTargets: new address[](0),
                callDatas: new bytes[](0),
                profitRecipient: address(0)
            })
        );
        assertEq(IERC20(USDC).balanceOf(maker), before, "the plain order settled anyway");
    }
}
