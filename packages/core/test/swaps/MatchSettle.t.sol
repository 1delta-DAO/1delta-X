// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "../shared/PackedEncode.sol";

import {Base} from "@core/settlement/Base.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {
    Settlement,
    Order,
    Item,
    ItemOp,
    ItemPolicy,
    MatchPlan,
    MatchStep,
    LegIn,
    LegOut,
    OrderSide,
    Validator
} from "@core/settlement/Settlement.sol";
import {MinBalanceInvariant} from "@validators/MinBalanceInvariant.sol";
import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @dev TAKE mock = a borrow/withdraw that DEFERS its own health check — it just
///      hands over `produce` of `token` (both in `data`) from its stash, with no
///      collateral test. That is precisely the behaviour an EVC checks-deferred
///      context gives a real Euler vault, and it is what the cyclic match needs:
///      both makers borrow BEFORE either has posted collateral. Decoupling
///      `produce` from the gated amount also drives the under-funded path.
contract MockFundingTaker is ITakerModule {
    address public immutable permit3;

    constructor(address _permit3) {
        permit3 = _permit3;
    }

    function takeOnBehalf(address, uint256, address receiver, bytes calldata data) external override {
        require(msg.sender == permit3, "only permit3");
        (address token, uint256 produce) = abi.decode(data, (address, uint256));
        IERC20(token).transfer(receiver, produce);
    }
}

/// @dev MAKE mock = a deposit: pulls `amount` of `token` (in `data`) from the maker
///      via Permit3 into itself (stands in for the collateral now held by a lender).
contract MockDepositMaker is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        require(msg.sender == settlement, "only settlement");
        address token = abi.decode(data, (address));
        permit3.transferFrom(onBehalfOf, address(this), token, uint160(amount));
    }
}

/// @dev MAKE mock that sizes itself from LIVE STATE, the way every real repay
///      adapter does (`toRepay = min(amount, debt)` — Aave, Comet, Morpho, Compound
///      all read the live debt and cap to it). `amount` is the maker-signed CEILING,
///      not the amount moved, which is what makes the ORDER of the calls observable
///      in the value that moves.
contract MockCappedRepayMaker is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;

    mapping(address => uint256) public debt;

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function setDebt(address user, uint256 amount) external {
        debt[user] = amount;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        require(msg.sender == settlement, "only settlement");
        address token = abi.decode(data, (address));
        uint256 owed = debt[onBehalfOf];
        uint256 toRepay = amount < owed ? amount : owed;
        if (toRepay != 0) {
            permit3.transferFrom(onBehalfOf, address(this), token, uint160(toRepay));
            debt[onBehalfOf] = owed - toRepay;
        }
    }
}

/// @dev `matchSettle` — the deferred-check, schedule-driven match.
///
/// The headline is the MUTUAL-LEVERAGE CYCLE, which no `sequence` over whole
/// orders can express (that is why this replaced `batchSettleItems`):
///
///   Alice: collateral WETH, debt USDC  — legsIn=[2000 USDC], legsOut=[1 WETH]
///   Bob:   collateral USDC, debt WETH  — legsIn=[1 WETH],    legsOut=[2000 USDC]
///
/// Each maker's collateral is the other's borrow, so whichever order you run
/// first, its delivery finds an empty pool. Interleaving at STEP granularity —
/// both borrows first, then the deliveries and deposits — closes the cycle with
/// zero solver capital, zero flash, and no re-entrancy anywhere.
contract MatchSettleTest is CoreSettlementBase {
    uint256 bobPk = 0xB0B;
    address bob = vm.addr(bobPk);

    MockFundingTaker taker; //     the "borrow"
    MockDepositMaker depositor; // the "deposit"

    uint256 constant WETH_AMT = 1 ether;
    uint256 constant USDC_AMT = 2_000e6;

    function setUp() public override {
        super.setUp();
        vm.label(bob, "bob");
        taker = new MockFundingTaker(address(permit3));
        depositor = new MockDepositMaker(address(permit3), address(settlement));
        vm.label(address(taker), "borrowModule");
        vm.label(address(depositor), "depositModule");

        vm.startPrank(bob);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        vm.stopPrank();
    }

    // ──────────────────── builders ────────────────────

    /// @dev A leverage order: give up `debt` (borrowed, item-funded), receive
    ///      `collateral` (delivered from the pool, then deposited).
    function _leverage(
        address who,
        uint256 nonce,
        address collateralToken,
        uint256 collateral,
        address debtToken,
        uint256 debt,
        uint256 produce
    ) internal view returns (Order memory o) {
        Item[] memory items = new Item[](2);
        items[0] = Item({
            op: ItemOp.MAKE, //           deposit the delivered collateral
            module: address(depositor),
            amount: collateral,
            recipient: address(0),
            data: abi.encode(collateralToken)
        });
        items[1] = Item({
            op: ItemOp.TAKE, //           borrow — proceeds to the pool
            module: address(taker),
            amount: debt,
            recipient: address(0),
            data: abi.encode(debtToken, produce)
        });
        o = Order({
            params: 0,
            pricingModule: address(0),
            maker: who,
            nonce: nonce,
            legsIn: _legsIn1(debtToken, debt),
            legsOut: _legsOut1(collateralToken, collateral),
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

    function _spot(address who, uint256 nonce, address tokenIn, uint256 amtIn, address tokenOut, uint256 amtOut)
        internal
        view
        returns (Order memory)
    {
        return _sellOrder(nonce, who, tokenIn, tokenOut, amtIn, amtOut, new Item[](0));
    }

    function _signAs(Order memory o, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(o)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Mirror of {MatchStep.pack} — a solver's schedule builder in miniature.
    function _step(uint256 kind, uint256 a, uint256 b) internal pure returns (uint256) {
        return kind | (a << 8) | (b << 24);
    }

    function _plan(Order[] memory orders, bytes[] memory sigs, uint256[] memory fills, uint256[] memory schedule)
        internal
        pure
        returns (MatchPlan memory)
    {
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

    function _two(Order memory a, Order memory b, uint256 pkA, uint256 pkB, uint256[] memory schedule)
        internal
        view
        returns (MatchPlan memory)
    {
        Order[] memory orders = new Order[](2);
        orders[0] = a;
        orders[1] = b;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signAs(a, pkA);
        sigs[1] = _signAs(b, pkB);
        uint256[] memory fills = new uint256[](2);
        fills[0] = PackedEncode.getLegInStart(a.legsIn, 0);
        fills[1] = PackedEncode.getLegInStart(b.legsIn, 0);
        return _plan(orders, sigs, fills, schedule);
    }

    // ──────────────────── the cyclic match ────────────────────

    /// @dev Approvals for one leverage maker: the deposit module may pull the
    ///      delivered collateral, and Settlement may consume the borrow gate.
    function _authLeverage(address who, Order memory o) internal {
        vm.startPrank(who);
        permit3.approveToken(
            address(depositor),
            PackedEncode.getLegOutToken(o.legsOut, 0),
            uint160(PackedEncode.getLegOutStart(o.legsOut, 0)),
            0
        );
        permit3.approveTaker(
            address(settlement),
            address(taker),
            keccak256(PackedEncode.getItemData(o.items, 1)),
            uint160(PackedEncode.getLegInStart(o.legsIn, 0)),
            uint48(block.timestamp + 1 hours)
        );
        vm.stopPrank();
    }

    function _cyclePair() internal returns (Order memory a, Order memory b) {
        a = _leverage(maker, 1, WETH, WETH_AMT, USDC, USDC_AMT, USDC_AMT); // Alice: WETH coll / USDC debt
        b = _leverage(bob, 2, USDC, USDC_AMT, WETH, WETH_AMT, WETH_AMT); //  Bob:   USDC coll / WETH debt
        _authLeverage(maker, a);
        _authLeverage(bob, b);
        // The "lenders" hold what they lend out. NOBODY else is dealt anything.
        deal(USDC, address(taker), USDC_AMT);
        deal(WETH, address(taker), WETH_AMT);
    }

    /// @dev Both borrows first (each uncollateralized at the time it runs — the
    ///      deferred-health-check premise), then each delivery and its deposit.
    function _cycleSchedule() internal pure returns (uint256[] memory s) {
        s = new uint256[](6);
        s[0] = _step(MatchStep.ITEM, 0, 1); //    Alice borrows 2000 USDC → pool
        s[1] = _step(MatchStep.ITEM, 1, 1); //    Bob   borrows 1 WETH    → pool
        s[2] = _step(MatchStep.DELIVER, 0, 0); // pool → Alice: 1 WETH
        s[3] = _step(MatchStep.ITEM, 0, 0); //    Alice deposits it as collateral
        s[4] = _step(MatchStep.DELIVER, 1, 0); // pool → Bob: 2000 USDC
        s[5] = _step(MatchStep.ITEM, 1, 0); //    Bob deposits it as collateral
    }

    // ── The headline: a mutual dependency with NO valid order-granular sequence
    //    settles with zero solver capital, zero flash, zero re-entrancy. ──
    function test_cycle_mutualLeverage_zeroCapital() public {
        (Order memory a, Order memory b) = _cyclePair();

        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver starts flat");
        assertEq(IERC20(USDC).balanceOf(solver), 0, "solver starts flat");
        assertEq(IERC20(WETH).balanceOf(maker), 0, "Alice starts flat");
        assertEq(IERC20(USDC).balanceOf(bob), 0, "Bob starts flat");

        vm.prank(solver);
        settlement.matchSettle(_two(a, b, makerPk, bobPk, _cycleSchedule()));

        // Both positions exist: collateral deposited, debt drawn, wallets flat.
        assertEq(IERC20(WETH).balanceOf(address(depositor)), WETH_AMT, "Alice's WETH collateral");
        assertEq(IERC20(USDC).balanceOf(address(depositor)), USDC_AMT, "Bob's USDC collateral");
        assertEq(IERC20(WETH).balanceOf(maker), 0, "Alice holds no loose WETH");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "Alice's borrow funded Bob, not her wallet");
        assertEq(IERC20(USDC).balanceOf(bob), 0, "Bob holds no loose USDC");
        assertEq(IERC20(WETH).balanceOf(bob), 0, "Bob's borrow funded Alice, not his wallet");
        // Solver: pure orchestrator.
        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver flat WETH");
        assertEq(IERC20(USDC).balanceOf(solver), 0, "solver flat USDC");
        // Pool: nothing stranded.
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "no WETH pooled");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "no USDC pooled");
    }

    // ── S8: a repeated DELIVER would pay a maker twice out of what the other
    //    orders are owed. Guarded AT THE STEP, not by a post-hoc compare. ──
    function test_doubleDeliver_reverts() public {
        (Order memory a, Order memory b) = _cyclePair();
        uint256[] memory s = new uint256[](7);
        uint256[] memory base = _cycleSchedule();
        for (uint256 i; i < 3; i++) {
            s[i] = base[i];
        }
        s[3] = _step(MatchStep.DELIVER, 0, 0); // ← the repeat
        for (uint256 i = 3; i < 6; i++) {
            s[i + 1] = base[i];
        }

        MatchPlan memory p = _two(a, b, makerPk, bobPk, s);
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.PlanBadStep.selector, 3));
        settlement.matchSettle(p);
    }

    // ── S8: a repeated ITEM is a SECOND BORROW against the maker's credit. ──
    function test_doubleItem_reverts() public {
        (Order memory a, Order memory b) = _cyclePair();
        uint256[] memory s = new uint256[](3);
        s[0] = _step(MatchStep.ITEM, 0, 1);
        s[1] = _step(MatchStep.ITEM, 1, 1);
        s[2] = _step(MatchStep.ITEM, 0, 1); // ← the repeat

        MatchPlan memory p = _two(a, b, makerPk, bobPk, s);
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.PlanBadStep.selector, 2));
        settlement.matchSettle(p);
    }

    // ── Completeness: deliveries are SCHEDULED, so "every maker was paid" cannot
    //    be structural — Phase 3 asserts it. Dropping Bob's delivery reverts. ──
    function test_omittedDeliver_reverts() public {
        (Order memory a, Order memory b) = _cyclePair();
        uint256[] memory base = _cycleSchedule();
        uint256[] memory s = new uint256[](4);
        s[0] = base[0];
        s[1] = base[1];
        s[2] = base[2];
        s[3] = base[3]; // Alice fully settled; Bob's DELIVER + deposit dropped

        MatchPlan memory p = _two(a, b, makerPk, bobPk, s);
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.PlanIncomplete.selector, 1));
        settlement.matchSettle(p);
    }

    // ── Completeness: an item the schedule never ran. Alice's collateral would
    //    sit in her wallet instead of backing the debt she just drew. ──
    function test_omittedItem_reverts() public {
        (Order memory a, Order memory b) = _cyclePair();
        uint256[] memory base = _cycleSchedule();
        uint256[] memory s = new uint256[](5);
        s[0] = base[0];
        s[1] = base[1];
        s[2] = base[2];
        s[3] = base[4]; // skip Alice's MAKE deposit
        s[4] = base[5];

        MatchPlan memory p = _two(a, b, makerPk, bobPk, s);
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.PlanIncomplete.selector, 0));
        settlement.matchSettle(p);
    }

    // ── A malformed step (unknown kind / out-of-range index) reverts, naming the
    //    step so a solver need not bisect its schedule. ──
    function test_badStep_reverts() public {
        (Order memory a, Order memory b) = _cyclePair();

        uint256[] memory s = new uint256[](1);
        s[0] = _step(99, 0, 0); // unknown kind
        MatchPlan memory p = _two(a, b, makerPk, bobPk, s);
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.PlanBadStep.selector, 0));
        settlement.matchSettle(p);

        s[0] = _step(MatchStep.ITEM, 0, 7); // item index past the order's items
        MatchPlan memory p2 = _two(a, b, makerPk, bobPk, s);
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.PlanBadStep.selector, 0));
        settlement.matchSettle(p2);

        s[0] = _step(MatchStep.DELIVER, 5, 0); // order index past the plan
        MatchPlan memory p3 = _two(a, b, makerPk, bobPk, s);
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.PlanBadStep.selector, 0));
        settlement.matchSettle(p3);
    }

    // ── An input leg whose items under-produce is named exactly: (order, leg). ──
    function test_itemUnderproduces_legUnfunded() public {
        // Alice's "lender" only hands over 1500 of the 2000 USDC she owes in.
        Order memory a = _leverage(maker, 1, WETH, WETH_AMT, USDC, USDC_AMT, 1_500e6);
        Order memory b = _leverage(bob, 2, USDC, USDC_AMT, WETH, WETH_AMT, WETH_AMT);
        _authLeverage(maker, a);
        _authLeverage(bob, b);
        deal(USDC, address(taker), USDC_AMT);
        deal(WETH, address(taker), WETH_AMT);
        // Bob's delivery is short by 500 USDC, so top the pool up from the solver
        // to isolate the FUNDING failure from a delivery failure.
        deal(USDC, address(settlement), 500e6);

        MatchPlan memory p = _two(a, b, makerPk, bobPk, _cycleSchedule());
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.LegUnfunded.selector, 0, 0));
        settlement.matchSettle(p);
    }

    // ──────────────────── ledger & bound behaviour (item-free) ────────────────────

    /// @dev A balanced spot CoW: Alice sells WETH for USDC, Bob the mirror.
    function _mirrorPair(uint256 aliceWeth) internal returns (Order memory a, Order memory b) {
        a = _spot(maker, 1, WETH, WETH_AMT, USDC, USDC_AMT);
        b = _spot(bob, 2, USDC, USDC_AMT, WETH, WETH_AMT);
        deal(WETH, maker, aliceWeth);
        deal(USDC, bob, USDC_AMT);
        _approveMakerToSettlement(WETH, aliceWeth);
        vm.prank(bob);
        permit3.approveToken(address(settlement), USDC, uint160(USDC_AMT), 0);
    }

    function _mirrorSchedule() internal pure returns (uint256[] memory s) {
        s = new uint256[](4);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.DELIVER, 0, 0);
        s[3] = _step(MatchStep.DELIVER, 1, 0);
    }

    // ── A duplicate PULL needs no exactly-once guard: the extra is credited and
    //    Phase 3 hands it back to the MAKER (never the solver). ──
    function test_duplicatePull_returnsSurplusToMaker() public {
        (Order memory a, Order memory b) = _mirrorPair(2 * WETH_AMT); // Alice can fund two pulls

        uint256[] memory s = new uint256[](5);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 0, 0); // ← the duplicate
        s[2] = _step(MatchStep.PULL, 1, 0);
        s[3] = _step(MatchStep.DELIVER, 0, 0);
        s[4] = _step(MatchStep.DELIVER, 1, 0);

        vm.prank(solver);
        settlement.matchSettle(_two(a, b, makerPk, bobPk, s));

        assertEq(IERC20(WETH).balanceOf(maker), WETH_AMT, "over-pull returned to Alice");
        assertEq(IERC20(USDC).balanceOf(maker), USDC_AMT, "Alice paid in full");
        assertEq(IERC20(WETH).balanceOf(bob), WETH_AMT, "Bob paid in full");
        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver got none of the over-pull");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "pool flat");
    }

    // ── PRESEND nets against obligations NOT YET DELIVERED, so a mid-schedule
    //    pre-send on a balanced match hands the solver nothing. ──
    function test_presend_boundedByOutstanding() public {
        (Order memory a, Order memory b) = _mirrorPair(WETH_AMT);

        uint256[] memory s = new uint256[](6);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.PRESEND, 0, 0); // token 0 = WETH (legsIn[0] of order 0)
        s[3] = _step(MatchStep.PRESEND, 1, 0); // token 1 = USDC
        s[4] = _step(MatchStep.DELIVER, 0, 0);
        s[5] = _step(MatchStep.DELIVER, 1, 0);

        vm.prank(solver);
        settlement.matchSettle(_two(a, b, makerPk, bobPk, s));

        assertEq(IERC20(WETH).balanceOf(solver), 0, "pooled WETH was owed to Bob, not surplus");
        assertEq(IERC20(USDC).balanceOf(solver), 0, "pooled USDC was owed to Alice, not surplus");
        assertEq(IERC20(USDC).balanceOf(maker), USDC_AMT, "Alice paid");
        assertEq(IERC20(WETH).balanceOf(bob), WETH_AMT, "Bob paid");
    }

    // ── S4/S5: a pre-existing (donated) pool balance is floored, never swept and
    //    never reachable by a pre-send. ──
    function test_donatedBalance_untouched() public {
        (Order memory a, Order memory b) = _mirrorPair(WETH_AMT);
        deal(WETH, address(settlement), 5 ether); // donation, before the context

        vm.prank(solver);
        settlement.matchSettle(_two(a, b, makerPk, bobPk, _mirrorSchedule()));

        assertEq(IERC20(WETH).balanceOf(address(settlement)), 5 ether, "donation intact");
        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver reached none of it");
    }

    // ── The deferred check itself: an invariant broken mid-context and restored
    //    by a LATER order passes, because it is asserted on the END STATE. Under
    //    the per-order model it ran while Alice's WETH was still pooled. ──
    function test_deferredInvariant_restoredByLaterOrder() public {
        MinBalanceInvariant inv = new MinBalanceInvariant();
        (Order memory a, Order memory b) = _mirrorPair(WETH_AMT);
        // Alice is both sides: she sells 1 WETH (order a) and buys 1 WETH back
        // (order b is Bob's mirror, so re-point its output at her instead).
        b.legsOut = PackedEncode.setLegOutRecipient(b.legsOut, 0, maker);

        Validator[] memory invs = new Validator[](1);
        invs[0] = Validator({target: address(inv), data: abi.encode(WETH, maker, WETH_AMT)});
        a.invariants = PackedEncode.validators(invs);

        // Order a's own steps (pull + deliver) all complete before order b's
        // delivery restores Alice's WETH — so this only passes because the check
        // was deferred past the end of order a.
        vm.prank(solver);
        settlement.matchSettle(_two(a, b, makerPk, bobPk, _mirrorSchedule()));

        assertEq(IERC20(WETH).balanceOf(maker), WETH_AMT, "Alice's floor holds at the end");
    }

    // ──────────── Can a solver sweep the maker's over-provision surplus? ────────────
    //
    // A TAKE that produces MORE than its leg owes leaves a surplus the maker is
    // entitled to — the "cash back" a dutch-auctioned leverage order pays when it
    // fills early. It sits in the pool between the item and the deferred flush, and
    // `PRESEND`'s bound (`outstanding`) tracks only UNDELIVERED OUTPUT LEGS — it
    // knows nothing about a pending surplus refund. So: can the solver take it?

    /// @dev A leverage order whose borrow over-produces by `excess` — the surplus is
    ///      owed back to the maker.
    function _overProducingLeverage(uint256 excess) internal returns (Order memory a, Order memory b) {
        a = _spot(maker, 1, WETH, WETH_AMT, USDC, USDC_AMT);
        b = _leverage(bob, 2, WETH, WETH_AMT, USDC, USDC_AMT, USDC_AMT + excess);
        deal(WETH, maker, WETH_AMT);
        _approveMakerToSettlement(WETH, WETH_AMT);
        _authLeverage(bob, b);
        deal(USDC, address(taker), USDC_AMT + excess);
    }

    // ── Control: with no PRESEND, the over-provision reaches the MAKER, and the
    //    solver sweeps nothing. ──
    function test_surplus_overProduction_goesToMaker() public {
        uint256 excess = 500e6;
        (Order memory a, Order memory b) = _overProducingLeverage(excess);

        uint256[] memory s = new uint256[](5);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.DELIVER, 1, 0);
        s[2] = _step(MatchStep.ITEM, 1, 0); //    deposit
        s[3] = _step(MatchStep.ITEM, 1, 1); //    borrow 2500 into a 2000 leg
        s[4] = _step(MatchStep.DELIVER, 0, 0);

        vm.prank(solver);
        settlement.matchSettle(_two(a, b, makerPk, bobPk, s));

        assertEq(IERC20(USDC).balanceOf(bob), excess, "the over-provision went to the MAKER");
        assertEq(IERC20(USDC).balanceOf(solver), 0, "solver swept none of it");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "pool flat");
    }

    // ── The attack: PRESEND the surplus to the solver before the deferred flush can
    //    refund it. `outstanding` is 0 by then (every output delivered), so the
    //    pre-send bound does NOT protect the maker's refund — it hands the whole
    //    unencumbered balance over. The flush then cannot pay the maker, and the
    //    whole context reverts. The surplus is unstealable, not unreachable. ──
    function test_surplus_cannotBePresentAwayFromMaker() public {
        uint256 excess = 500e6;
        (Order memory a, Order memory b) = _overProducingLeverage(excess);

        uint256[] memory s = new uint256[](6);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.DELIVER, 1, 0);
        s[2] = _step(MatchStep.ITEM, 1, 0);
        s[3] = _step(MatchStep.ITEM, 1, 1); //    pool now holds 2500 USDC
        s[4] = _step(MatchStep.DELIVER, 0, 0); // pays Alice 2000 → 500 left, owed to Bob
        s[5] = _step(MatchStep.PRESEND, 1, 0); // ← grab it: outstanding[USDC] is now 0

        MatchPlan memory p = _two(a, b, makerPk, bobPk, s);
        vm.prank(solver);
        vm.expectRevert(); // the flush's refund to Bob finds an empty pool
        settlement.matchSettle(p);

        // Atomic: nothing moved at all.
        assertEq(IERC20(USDC).balanceOf(solver), 0, "solver got nothing");
        assertEq(IERC20(USDC).balanceOf(bob), 0, "maker's balance untouched");
    }

    // ── …and the same holds if the solver tries to cover its grab with the pool's
    //    own funds: taking ANY of the surplus makes some reconciliation short, so
    //    there is no ordering that both extracts it and settles. ──
    function test_surplus_presendBeforeDelivery_alsoFails() public {
        uint256 excess = 500e6;
        (Order memory a, Order memory b) = _overProducingLeverage(excess);

        uint256[] memory s = new uint256[](6);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.DELIVER, 1, 0);
        s[2] = _step(MatchStep.ITEM, 1, 0);
        s[3] = _step(MatchStep.ITEM, 1, 1);
        s[4] = _step(MatchStep.PRESEND, 1, 0); // outstanding[USDC] = 2000 (Alice undelivered)
        s[5] = _step(MatchStep.DELIVER, 0, 0); // …so this grabs exactly the 500 surplus

        MatchPlan memory p = _two(a, b, makerPk, bobPk, s);
        vm.prank(solver);
        vm.expectRevert();
        settlement.matchSettle(p);

        assertEq(IERC20(USDC).balanceOf(solver), 0, "solver got nothing");
        assertEq(IERC20(USDC).balanceOf(bob), 0, "maker's balance untouched");
    }

    // ── Single-order path: `fillUpTo`'s `recipient` redirect moves the filler's
    //    OWED proceeds only. The surplus destination is hardcoded to the maker
    //    (`Core.sol:543`), so the redirect cannot reach it: were the surplus part of
    //    the redirected payout, the recipient would end up with owed + excess. ──
    function test_surplus_fillUpToRecipientCannotTakeIt() public {
        uint256 excess = 500e6;
        Order memory lev = _leverage(bob, 2, WETH, WETH_AMT, USDC, USDC_AMT, USDC_AMT + excess);
        _authLeverage(bob, lev);
        deal(USDC, address(taker), USDC_AMT + excess);
        deal(WETH, solver, WETH_AMT);
        vm.startPrank(solver);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), WETH, uint160(WETH_AMT), 0);
        vm.stopPrank();

        bytes memory sig = _signAs(lev, bobPk);
        vm.prank(solver);
        settlement.fillUpTo(lev, sig, USDC_AMT, solver, 0, "");

        assertEq(IERC20(USDC).balanceOf(solver), USDC_AMT, "recipient got the OWED amount, not a wei more");
        assertEq(IERC20(USDC).balanceOf(bob), excess, "the surplus still reached the maker");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "nothing stranded");
    }

    // ──────────────── Maker-controlled item ordering ({ItemPolicy}) ────────────────
    //
    // The cycle above works because an order's borrow is hoisted AHEAD of its own
    // delivery. That is only safe on a lender that defers its health check — on
    // Aave/Comet/Morpho the same schedule reverts. A maker targeting those wants to
    // say so in the order itself, and can: `timing` bits [96:100), already signed,
    // no new field and no golden-hash change.

    /// @dev Stamp a policy into an order's (otherwise unused) `timing` word.
    function _withPolicy(Order memory o, uint256 policy) internal pure returns (Order memory) {
        o.timing = ItemPolicy.pack(o.timing, policy);
        return o;
    }

    // ── ANY (the default, and every order signed before the policy existed) still
    //    permits the cycle. This is the regression guard on "no behaviour change". ──
    function test_itemPolicy_anyIsTheDefault_andPermitsTheCycle() public {
        (Order memory a, Order memory b) = _cyclePair();
        // ANY == 0: no policy bits [96:100). (The deadline now rides in timing bits
        // [160:208), so the whole word is no longer zero — mask to the policy nibble.)
        assertEq((a.timing >> 96) & 0xf, 0, "default order carries no policy bits");

        vm.prank(solver);
        settlement.matchSettle(_two(a, b, makerPk, bobPk, _cycleSchedule()));

        assertEq(IERC20(WETH).balanceOf(address(depositor)), WETH_AMT, "cycle still settles");
    }

    // ── ORDERED: Alice's borrow (item 1) may not run before her deposit (item 0),
    //    which is exactly what the cycle needs — so the cycle is refused. ──
    function test_itemPolicy_ordered_refusesHoistedBorrow() public {
        Order memory a = _leverage(maker, 1, WETH, WETH_AMT, USDC, USDC_AMT, USDC_AMT);
        a = _withPolicy(a, ItemPolicy.ORDERED);
        Order memory b = _leverage(bob, 2, USDC, USDC_AMT, WETH, WETH_AMT, WETH_AMT);
        _authLeverage(maker, a);
        _authLeverage(bob, b);
        deal(USDC, address(taker), USDC_AMT);
        deal(WETH, address(taker), WETH_AMT);

        // Step 0 of the cycle is ITEM(0,1) — Alice's borrow, ahead of her deposit.
        MatchPlan memory p = _two(a, b, makerPk, bobPk, _cycleSchedule());
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.ItemPolicyViolated.selector, uint256(0), uint256(1)));
        settlement.matchSettle(p);
    }

    // ── ATOMIC: signed order is not enough — the items must also be back-to-back.
    //    Here they are in order but another order's step is wedged between them. ──
    function test_itemPolicy_atomic_refusesInterleavedItems() public {
        Order memory spot = _spot(maker, 1, WETH, WETH_AMT, USDC, USDC_AMT);
        Order memory lev = _leverage(bob, 2, WETH, WETH_AMT, USDC, USDC_AMT, USDC_AMT);
        lev = _withPolicy(lev, ItemPolicy.ATOMIC);
        deal(WETH, maker, WETH_AMT);
        _approveMakerToSettlement(WETH, WETH_AMT);
        _authLeverage(bob, lev);
        deal(USDC, address(taker), USDC_AMT);

        uint256[] memory s = new uint256[](5);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.DELIVER, 1, 0);
        s[2] = _step(MatchStep.ITEM, 1, 0); //    deposit
        // A deliberately INERT wedge: token 1 is USDC, and with the borrow still
        // pending there is no USDC surplus, so this step moves nothing. It is here
        // purely to prove ATOMIC rejects on ADJACENCY, not on side effects — a
        // wedge that itself failed would not test the policy at all.
        s[3] = _step(MatchStep.PRESEND, 1, 0);
        s[4] = _step(MatchStep.ITEM, 1, 1); //    borrow — no longer back-to-back

        MatchPlan memory p = _two(spot, lev, makerPk, bobPk, s);
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.ItemPolicyViolated.selector, uint256(1), uint256(1)));
        settlement.matchSettle(p);
    }

    // ── ATOMIC accepts the instant-fill shape: deliver, then deposit+borrow
    //    contiguously. This is the schedule a non-deferring lender requires, and the
    //    policy now makes it the only one the maker's order admits. ──
    function test_itemPolicy_atomic_acceptsContiguousDepositBorrow() public {
        Order memory spot = _spot(maker, 1, WETH, WETH_AMT, USDC, USDC_AMT);
        Order memory lev = _leverage(bob, 2, WETH, WETH_AMT, USDC, USDC_AMT, USDC_AMT);
        lev = _withPolicy(lev, ItemPolicy.ATOMIC);
        deal(WETH, maker, WETH_AMT);
        _approveMakerToSettlement(WETH, WETH_AMT);
        _authLeverage(bob, lev);
        deal(USDC, address(taker), USDC_AMT);

        uint256[] memory s = new uint256[](5);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.DELIVER, 1, 0);
        s[2] = _step(MatchStep.ITEM, 1, 0); //    deposit ┐ contiguous
        s[3] = _step(MatchStep.ITEM, 1, 1); //    borrow  ┘
        s[4] = _step(MatchStep.DELIVER, 0, 0);

        vm.prank(solver);
        settlement.matchSettle(_two(spot, lev, makerPk, bobPk, s));

        assertEq(IERC20(WETH).balanceOf(address(depositor)), WETH_AMT, "collateral deposited");
        assertEq(IERC20(USDC).balanceOf(maker), USDC_AMT, "spot maker paid from the borrow");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "pool flat");
    }

    // ── The single-order path runs items in signed order by construction, so it
    //    satisfies every policy and pays nothing for it. ──
    function test_itemPolicy_singleOrderFillUnaffected() public {
        Order memory lev = _leverage(bob, 2, WETH, WETH_AMT, USDC, USDC_AMT, USDC_AMT);
        lev = _withPolicy(lev, ItemPolicy.ATOMIC);
        _authLeverage(bob, lev);
        deal(USDC, address(taker), USDC_AMT);
        // The solver delivers the collateral itself on this path.
        deal(WETH, solver, WETH_AMT);
        vm.startPrank(solver);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), WETH, uint160(WETH_AMT), 0);
        vm.stopPrank();

        bytes memory sig = _signAs(lev, bobPk);
        vm.prank(solver);
        settlement.fill(lev, sig, USDC_AMT);

        assertEq(IERC20(WETH).balanceOf(address(depositor)), WETH_AMT, "ATOMIC order fills normally");
    }

    // ──────────── CANONICAL: the two orderings ATOMIC does not constrain ────────────
    //
    // ATOMIC pins the items relative to EACH OTHER. It says nothing about where the
    // group sits relative to the DELIVERY that funds it, or to the PULL that draws
    // the order's inputs — and both of those change the VALUE that moves, not merely
    // the intermediate state. CANONICAL adds them, which makes the netted path run
    // this order in exactly the shape `fill` always did: deliver → items → pay.

    /// @dev The hoist, under the DEFAULT policy — this is the behaviour CANONICAL
    ///      exists to forbid, pinned so it cannot change silently.
    ///
    ///      Bob's order says "deliver me 1 WETH, deposit it as collateral, borrow
    ///      2000 USDC". Running his deposit BEFORE his delivery is a legal `ANY`
    ///      schedule, and it funds the deposit from the WETH already in his wallet;
    ///      the delivery then lands in that wallet and stays there. The end state is
    ///      token-neutral HERE only because the mock deposits a fixed amount — the
    ///      hazard is that it spends the maker's own balance and standing allowance,
    ///      and that a module which sizes itself from live state (see
    ///      {MockCappedRepayMaker}) moves a DIFFERENT amount from either position.
    function test_hoistedItem_underAny_fundsFromTheMakersOwnWallet() public {
        Order memory spot = _spot(maker, 1, WETH, WETH_AMT, USDC, USDC_AMT);
        Order memory lev = _leverage(bob, 2, WETH, WETH_AMT, USDC, USDC_AMT, USDC_AMT);
        deal(WETH, maker, WETH_AMT);
        deal(WETH, bob, WETH_AMT); // Bob's OWN collateral, unrelated to this order
        _approveMakerToSettlement(WETH, WETH_AMT);
        _authLeverage(bob, lev);
        deal(USDC, address(taker), USDC_AMT);

        // Build the plan BEFORE the prank: `_signAs` makes cheatcode calls, and those
        // consume a pending `vm.prank`. (Every assertion here is on the makers, so it
        // would not change the outcome — but the filler should be the filler.)
        MatchPlan memory p = _two(spot, lev, makerPk, bobPk, _hoistedSchedule());
        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(IERC20(WETH).balanceOf(address(depositor)), WETH_AMT, "collateral deposited");
        // The tell: the DELIVERED WETH is still sitting in Bob's wallet, because the
        // deposit consumed the WETH he already held. Under the canonical ordering he
        // ends at 0 — see the companion test below.
        assertEq(IERC20(WETH).balanceOf(bob), WETH_AMT, "delivery landed after the deposit and stayed");
    }

    /// @dev CANONICAL refuses that schedule: an item may not run before its own
    ///      order's delivery.
    function test_itemPolicy_canonical_refusesItemAheadOfDelivery() public {
        Order memory spot = _spot(maker, 1, WETH, WETH_AMT, USDC, USDC_AMT);
        Order memory lev = _leverage(bob, 2, WETH, WETH_AMT, USDC, USDC_AMT, USDC_AMT);
        lev = _withPolicy(lev, ItemPolicy.CANONICAL);
        deal(WETH, maker, WETH_AMT);
        deal(WETH, bob, WETH_AMT);
        _approveMakerToSettlement(WETH, WETH_AMT);
        _authLeverage(bob, lev);
        deal(USDC, address(taker), USDC_AMT);

        MatchPlan memory p = _two(spot, lev, makerPk, bobPk, _hoistedSchedule());
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.ItemPolicyViolated.selector, uint256(1), uint256(0)));
        settlement.matchSettle(p);
    }

    /// @dev …and accepts the canonical one, which spends Bob's delivery rather than
    ///      his wallet. Same orders, same amounts, one different schedule.
    function test_itemPolicy_canonical_acceptsDeliverItemsThenPull() public {
        Order memory spot = _spot(maker, 1, WETH, WETH_AMT, USDC, USDC_AMT);
        Order memory lev = _leverage(bob, 2, WETH, WETH_AMT, USDC, USDC_AMT, USDC_AMT);
        lev = _withPolicy(lev, ItemPolicy.CANONICAL);
        deal(WETH, maker, WETH_AMT);
        deal(WETH, bob, WETH_AMT);
        _approveMakerToSettlement(WETH, WETH_AMT);
        _authLeverage(bob, lev);
        _approveBobUsdcToSettlement(USDC_AMT);
        deal(USDC, address(taker), USDC_AMT);

        uint256[] memory s = new uint256[](6);
        s[0] = _step(MatchStep.PULL, 0, 0); //    Alice's WETH seeds the pool
        s[1] = _step(MatchStep.DELIVER, 1, 0); // pool → Bob: 1 WETH
        s[2] = _step(MatchStep.ITEM, 1, 0); //    deposit it ┐ contiguous, after delivery
        s[3] = _step(MatchStep.ITEM, 1, 1); //    borrow     ┘
        s[4] = _step(MatchStep.PULL, 1, 0); //    legal, and a NO-OP: the borrow already credited the leg
        s[5] = _step(MatchStep.DELIVER, 0, 0); // pool → Alice: 2000 USDC

        MatchPlan memory p = _two(spot, lev, makerPk, bobPk, s);
        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(IERC20(WETH).balanceOf(address(depositor)), WETH_AMT, "collateral deposited");
        assertEq(IERC20(WETH).balanceOf(bob), WETH_AMT, "his own WETH untouched: the DELIVERY was deposited");
        assertEq(_bobUsdcAllowance(), USDC_AMT, "the no-op pull drew nothing and spent no allowance");
    }

    /// @dev The PULL half, under the DEFAULT policy: a pull scheduled ahead of the
    ///      item that was going to fund the leg makes the maker front the whole leg
    ///      from their wallet. The tokens come back — {_matchReconcileInputs} refunds
    ///      the over-credit — but the Permit3 ALLOWANCE they moved with does not, and
    ///      `matchSettle` is permissionless, so any filler can spend it. Same class as
    ///      the duplicate-pull finding {_stepPull} documents, reached by ORDERING
    ///      rather than by repetition.
    function test_pullAheadOfItem_underAny_spendsTheMakersAllowance() public {
        (Order memory spot, Order memory lev) = _pullFirstPair(ItemPolicy.ANY);

        MatchPlan memory p = _two(spot, lev, makerPk, bobPk, _pullFirstSchedule());
        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(IERC20(USDC).balanceOf(bob), USDC_AMT, "tokens refunded: the maker is whole");
        assertEq(_bobUsdcAllowance(), 0, "but the allowance is gone, and nothing gives it back");
    }

    /// @dev CANONICAL refuses it: this order's inputs are drawn only once the order
    ///      is otherwise complete, so the item that funds the leg has always run.
    function test_itemPolicy_canonical_refusesPullAheadOfItem() public {
        (Order memory spot, Order memory lev) = _pullFirstPair(ItemPolicy.CANONICAL);

        MatchPlan memory p = _two(spot, lev, makerPk, bobPk, _pullFirstSchedule());
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.ItemPolicyViolated.selector, uint256(1), uint256(0)));
        settlement.matchSettle(p);
    }

    // ──────────── live-state-sized items across two orders of one maker ────────────

    /// @dev DOCUMENTED BEHAVIOUR, not a settler defect — and the reason a maker with
    ///      two live orders on the same position wants an OCO group or `fill-once`.
    ///
    ///      Every real repay adapter caps to the live debt (`min(amount, debt)`), so
    ///      the signed `amount` is a CEILING. Bundle two of the maker's own close
    ///      orders into one plan and the first repay clears the debt; the second caps
    ///      to zero, pulls nothing — while its value-OUT item (the withdraw) still
    ///      runs at full size and its proceeds still pay the filler. No policy fixes
    ///      this: both orders are separately valid, every item runs exactly once, and
    ///      the ordering that produces it is not even unusual. What fixes it is not
    ///      having two live orders against one debt.
    function test_sameMakerOverlap_liveStateItemDegradesButPaysInFull() public {
        MockCappedRepayMaker repayer = new MockCappedRepayMaker(address(permit3), address(settlement));
        Order memory a = _close(repayer, 41);
        Order memory b = _close(repayer, 42);

        repayer.setDebt(maker, USDC_AMT); //     ONE debt, and both orders mean to clear it
        deal(USDC, maker, USDC_AMT * 2); //      the maker can afford both
        deal(WETH, address(taker), WETH_AMT * 2); // the "lender" holds the collateral
        vm.startPrank(maker);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(repayer), USDC, uint160(USDC_AMT * 2), 0);
        permit3.approveTaker(
            address(settlement),
            address(taker),
            keccak256(abi.encode(WETH, WETH_AMT)),
            uint160(WETH_AMT * 2),
            uint48(block.timestamp + 1 hours)
        );
        vm.stopPrank();

        uint256[] memory s = new uint256[](4);
        s[0] = _step(MatchStep.ITEM, 0, 0); // repay  — takes the whole 2000 debt
        s[1] = _step(MatchStep.ITEM, 0, 1); // withdraw
        s[2] = _step(MatchStep.ITEM, 1, 0); // repay  — caps to ZERO, pulls nothing
        s[3] = _step(MatchStep.ITEM, 1, 1); // withdraw — runs in full anyway

        MatchPlan memory p = _two(a, b, makerPk, makerPk, s);
        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(repayer.debt(maker), 0, "debt cleared, once");
        assertEq(IERC20(USDC).balanceOf(maker), USDC_AMT, "only ONE order's funding leg actually moved");
        assertEq(IERC20(WETH).balanceOf(solver), WETH_AMT * 2, "but BOTH value-out legs paid the filler");
    }

    // ──────────────────── builders for the ordering tests ────────────────────

    /// @dev The leverage order's deposit hoisted AHEAD of the delivery that funds it.
    function _hoistedSchedule() internal pure returns (uint256[] memory s) {
        s = new uint256[](5);
        s[0] = _step(MatchStep.PULL, 0, 0); //    Alice's WETH seeds the pool
        s[1] = _step(MatchStep.ITEM, 1, 0); //    Bob deposits — BEFORE his delivery
        s[2] = _step(MatchStep.DELIVER, 1, 0); // pool → Bob: 1 WETH
        s[3] = _step(MatchStep.ITEM, 1, 1); //    Bob borrows 2000 USDC → pool
        s[4] = _step(MatchStep.DELIVER, 0, 0); // pool → Alice: 2000 USDC
    }

    /// @dev A leverage order whose input leg the solver draws from the maker's WALLET
    ///      before the borrow that was going to fund it, plus the spot order that
    ///      seeds the pool. Bob holds the USDC and has granted Settlement exactly the
    ///      leg amount, which is what makes the allowance spend visible.
    function _pullFirstPair(uint256 policy) internal returns (Order memory spot, Order memory lev) {
        spot = _spot(maker, 1, WETH, WETH_AMT, USDC, USDC_AMT);
        lev = _leverage(bob, 2, WETH, WETH_AMT, USDC, USDC_AMT, USDC_AMT);
        if (policy != ItemPolicy.ANY) lev = _withPolicy(lev, policy);
        deal(WETH, maker, WETH_AMT);
        deal(USDC, bob, USDC_AMT);
        _approveMakerToSettlement(WETH, WETH_AMT);
        _authLeverage(bob, lev);
        _approveBobUsdcToSettlement(USDC_AMT);
        deal(USDC, address(taker), USDC_AMT);
    }

    function _pullFirstSchedule() internal pure returns (uint256[] memory s) {
        s = new uint256[](6);
        s[0] = _step(MatchStep.PULL, 0, 0); //    Alice's WETH seeds the pool
        s[1] = _step(MatchStep.DELIVER, 1, 0); // pool → Bob: 1 WETH
        s[2] = _step(MatchStep.ITEM, 1, 0); //    deposit
        s[3] = _step(MatchStep.PULL, 1, 0); //    Bob's USDC leg — BEFORE the borrow funds it
        s[4] = _step(MatchStep.ITEM, 1, 1); //    borrow (now redundant funding)
        s[5] = _step(MatchStep.DELIVER, 0, 0); // pool → Alice: 2000 USDC
    }

    function _approveBobUsdcToSettlement(uint256 cap) internal {
        vm.startPrank(bob);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDC, uint160(cap), 0);
        vm.stopPrank();
    }

    function _bobUsdcAllowance() internal view returns (uint256) {
        (uint160 amount,) = permit3.tokenAllowance(bob, address(settlement), USDC);
        return amount;
    }

    /// @dev A CLOSE order: repay from the maker's wallet (a live-state-sized MAKE)
    ///      and withdraw the collateral, whose proceeds pay the filler. No output
    ///      leg, so nothing is delivered and `DELIVERED_BIT` is pre-set at open.
    function _close(MockCappedRepayMaker repayer, uint256 nonce) internal view returns (Order memory o) {
        Item[] memory items = new Item[](2);
        items[0] = Item({
            op: ItemOp.MAKE, //     repay, capped at the LIVE debt
            module: address(repayer),
            amount: USDC_AMT,
            recipient: address(0),
            data: abi.encode(USDC)
        });
        items[1] = Item({
            op: ItemOp.TAKE, //     withdraw the collateral → pool → filler
            module: address(taker),
            amount: WETH_AMT,
            recipient: address(0),
            data: abi.encode(WETH, WETH_AMT)
        });
        o = Order({
            params: 0,
            pricingModule: address(0),
            maker: maker,
            nonce: nonce,
            legsIn: _legsIn1(WETH, WETH_AMT),
            legsOut: PackedEncode.legsOut(new LegOut[](0)),
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

    // ──────────────────── shape guards ────────────────────

    // ── SETTLE routes to the filler, not the pool — rejected at open. ──
    function test_settleItem_reverts() public {
        (Order memory a, Order memory b) = _cyclePair();
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.SETTLE, module: address(0x5E7), amount: 1, recipient: address(0), data: ""});
        b.items = PackedEncode.items(items);

        MatchPlan memory p = _two(a, b, makerPk, bobPk, _cycleSchedule());
        vm.prank(solver);
        vm.expectRevert(Base.MatchSettleItemUnsupported.selector);
        settlement.matchSettle(p);
    }

    // ── A repeated input token would double-count one arrival in the credit
    //    ledger (proceeds are attributed per token) — rejected at open. ──
    function test_duplicateInput_reverts() public {
        (Order memory a, Order memory b) = _cyclePair();
        LegIn[] memory _tmplegsIn = new LegIn[](2);
        _tmplegsIn[0] = LegIn(WETH, WETH_AMT, 0);
        _tmplegsIn[1] = LegIn(WETH, 1, 0);
        b.legsIn = PackedEncode.legsIn(_tmplegsIn);

        MatchPlan memory p = _two(a, b, makerPk, bobPk, _cycleSchedule());
        vm.prank(solver);
        vm.expectRevert(Base.MatchDuplicateInput.selector);
        settlement.matchSettle(p);
    }

    // ── Misaligned plan arrays are rejected before anything runs. ──
    function test_lengthMismatch_reverts() public {
        (Order memory a, Order memory b) = _cyclePair();
        MatchPlan memory p = _two(a, b, makerPk, bobPk, _cycleSchedule());
        p.takerDatas = new bytes[](1); // neither empty nor aligned

        vm.prank(solver);
        vm.expectRevert(Base.LengthMismatch.selector);
        settlement.matchSettle(p);
    }

    // ──────────────────── parity with the old item path ────────────────────

    // ── The `batchSettleItems` headline, expressed as a schedule: a SPOT order's
    //    pooled liquidity funds a LEVERAGE order, zero solver capital. Proves the
    //    old order-granular flow is a special case of the new one. ──
    function test_spotFundsLeverage_zeroSolverCapital() public {
        Order memory spot = _spot(maker, 1, WETH, WETH_AMT, USDC, USDC_AMT);
        Order memory lev = _leverage(bob, 2, WETH, WETH_AMT, USDC, USDC_AMT, USDC_AMT);
        deal(WETH, maker, WETH_AMT);
        _approveMakerToSettlement(WETH, WETH_AMT);
        _authLeverage(bob, lev);
        deal(USDC, address(taker), USDC_AMT);

        // The old `pullMask=[1,0], sequence=[1,0]` in step form.
        uint256[] memory s = new uint256[](5);
        s[0] = _step(MatchStep.PULL, 0, 0); //    Alice's WETH → pool (the seed)
        s[1] = _step(MatchStep.DELIVER, 1, 0); // pool → Bob: 1 WETH
        s[2] = _step(MatchStep.ITEM, 1, 0); //    Bob deposits it
        s[3] = _step(MatchStep.ITEM, 1, 1); //    Bob borrows 2000 USDC → pool
        s[4] = _step(MatchStep.DELIVER, 0, 0); // pool → Alice: 2000 USDC

        vm.prank(solver);
        settlement.matchSettle(_two(spot, lev, makerPk, bobPk, s));

        assertEq(IERC20(WETH).balanceOf(maker), 0, "Alice's WETH spent");
        assertEq(IERC20(USDC).balanceOf(maker), USDC_AMT, "Alice received 2000 USDC");
        assertEq(IERC20(WETH).balanceOf(address(depositor)), WETH_AMT, "Bob's collateral deposited");
        assertEq(IERC20(USDC).balanceOf(bob), 0, "Bob's borrow went to the pool");
        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver flat WETH");
        assertEq(IERC20(USDC).balanceOf(solver), 0, "solver flat USDC");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "no WETH pooled");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "no USDC pooled");
    }

    // ──────────────────── un-attributed item proceeds ────────────────────

    /// @dev SECURITY REGRESSION — a TAKE whose proceeds token is in NO input leg of
    ///      its own order must not become the SOLVER's profit.
    ///
    ///      `Base._executeItems` states the maker constraint (a TAKE's proceeds token
    ///      MUST appear in `legsIn`) and argues a violating order merely STRANDS the
    ///      proceeds, because the batch paths "floor every touched token at its
    ///      pre-batch balance". That floor is the PRE-batch balance — proceeds
    ///      arriving DURING the context sit above it. So if the token appears in any
    ///      OTHER order's legs (putting it in the derived universe, hence in the final
    ///      sweep), `_sweepSurplus` used to hand the maker's money to the filler:
    ///      the same mis-authored order loses funds to NOBODY via `fill` but to the
    ///      SOLVER via `matchSettle`, which also gives a solver a reason to hunt for
    ///      such orders and bundle them with anything touching the same token.
    ///
    ///      {Batch._creditItemProceeds} now returns anything landing outside the
    ///      order's own `legsIn` to that order's MAKER, as the item runs.
    ///
    ///      The shape is deliberately synthetic — Alice's order gives up USDC for no
    ///      output at all — so the accounting is the only thing under test. Bob's
    ///      ordinary spot order exists solely to put WETH in the token universe.
    function test_strayItemProceeds_goToMakerNotSolver() public {
        uint256 STRAY = 3 ether; // what Alice's "borrow" actually produces
        uint256 GATE = 1; // the amount-gated slice; the mock ignores it

        // Alice: pays 2000 USDC in, NO output legs, one TAKE that produces WETH —
        // a token that appears nowhere in her own `legsIn`.
        bytes memory strayData = abi.encode(WETH, STRAY);
        Item[] memory items = new Item[](1);
        items[0] =
            Item({op: ItemOp.TAKE, module: address(taker), amount: GATE, recipient: address(0), data: strayData});
        Order memory a = Order({
            params: 0,
            pricingModule: address(0),
            maker: maker,
            nonce: 11,
            legsIn: _legsIn1(USDC, USDC_AMT),
            legsOut: PackedEncode.legsOut(new LegOut[](0)),
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

        // Bob: a plain spot order. Its only job is to put WETH in the universe.
        Order memory b = _spot(bob, 12, WETH, WETH_AMT, USDC, USDC_AMT);

        deal(USDC, maker, USDC_AMT);
        deal(WETH, bob, WETH_AMT);
        deal(WETH, address(taker), STRAY); // the "lender" holds what it lends
        _approveMakerToSettlement(USDC, USDC_AMT);
        vm.startPrank(maker);
        permit3.approveTaker(
            address(settlement), address(taker), keccak256(strayData), uint160(GATE), uint48(block.timestamp + 1 hours)
        );
        vm.stopPrank();
        vm.startPrank(bob);
        permit3.approveToken(address(settlement), WETH, uint160(WETH_AMT), 0);
        vm.stopPrank();

        uint256[] memory s = new uint256[](4);
        s[0] = _step(MatchStep.PULL, 0, 0); //    Alice's USDC → pool (credits her leg)
        s[1] = _step(MatchStep.ITEM, 0, 0); //    the borrow → 3 WETH lands in the pool
        s[2] = _step(MatchStep.PULL, 1, 0); //    Bob's WETH → pool
        s[3] = _step(MatchStep.DELIVER, 1, 0); // pool → Bob, 2000 USDC

        MatchPlan memory p = _two(a, b, makerPk, bobPk, s);
        p.fillAmounts[0] = USDC_AMT;
        p.fillAmounts[1] = WETH_AMT;

        vm.prank(solver);
        settlement.matchSettle(p);

        // THE assertion. Before the fix the solver swept STRAY + WETH_AMT.
        assertEq(IERC20(WETH).balanceOf(maker), STRAY, "stray proceeds returned to their own maker");
        assertEq(IERC20(WETH).balanceOf(solver), WETH_AMT, "solver keeps only the real CoW surplus");
        assertEq(IERC20(USDC).balanceOf(bob), USDC_AMT, "Bob still settled normally");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "pool flat in WETH");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "pool flat in USDC");
    }
}
